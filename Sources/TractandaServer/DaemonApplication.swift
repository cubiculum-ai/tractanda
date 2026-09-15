import Foundation
import MCP
import TractandaCore
import TractandaMCP

public actor DaemonApplication {
    private let coordinator: ServiceCoordinator
    private let sessions: SessionAuthority
    private let page: Data
    private let manual: Data
    private let nonce: String
    private let mcp: MCPHTTPService
    private var closed = false

    public init(
        coordinator: ServiceCoordinator, sessions: SessionAuthority, page: Data, manual: Data, nonce: String
    ) {
        self.coordinator = coordinator
        self.sessions = sessions
        self.page = page
        self.manual = manual
        self.nonce = nonce
        mcp = MCPHTTPService(
            authorize: { try await sessions.authorize($0) },
            dispatch: { try await sessions.dispatch($0, token: $1) })
    }

    public func native(_ request: Data, forUID uid: UInt32) async throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
            Set(object.keys) == ["using", "methodCalls"],
            let using = object["using"] as? [String], using == [ItemService.capability],
            let calls = object["methodCalls"] as? [[Any]], calls.count == 1,
            calls[0].count == 3, let method = calls[0][0] as? String,
            method == "TractandaAuth/createSession", let args = calls[0][1] as? [String: Any], args.isEmpty,
            let callID = calls[0][2] as? String, !callID.isEmpty
        else { return try await coordinator.handle(request, forUID: uid) }
        let session = try await sessions.issue(forUID: uid)
        return try JSONSerialization.data(withJSONObject: [
            "methodResponses": [
                [
                    method,
                    ["token": session.token, "username": session.username, "expiresAt": session.expiresAt],
                    callID,
                ]
            ]
        ])
    }
    public func close() async {
        guard !closed else { return }
        closed = true
        await mcp.close()
        await sessions.close()
    }

    public func http(_ request: DaemonHTTPRequest) async throws -> DaemonHTTPResponse {
        guard !closed else { return failure(503, "serviceUnavailable", "Service unavailable") }
        let parts = request.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? request.uri
        guard parts.count == 1 || (request.method == "GET" && path == "/") else {
            return failure(404, "notFound", "Not found")
        }
        guard validHost(request), validOrigin(request, path: path) else {
            return failure(403, "invalidOrigin", "Forbidden")
        }
        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/login"): return asset(page, type: "text/html; charset=utf-8")
        case ("GET", "/manual"), ("GET", "/manual.html"):
            return asset(manual, type: "text/html; charset=utf-8")
        case ("GET", "/auth/session"): return try json(200, await sessions.profile(for: bearer(request)))
        case ("POST", "/auth/logout"):
            guard let token = bearer(request) else { return response(401, json: ["error": "Unauthorized"]) }
            await sessions.signOut(token)
            return response(200, json: ["signedOut": true])
        case ("POST", "/auth/login"): return await login(request)
        case ("POST", "/api"): return await api(request)
        case (_, "/mcp"): return await mcpResponse(request)
        case (_, "/api"), (_, "/auth/login"), (_, "/auth/logout"), (_, "/auth/session"), (_, "/manual"),
            (_, "/manual.html"), (_, "/login"):
            return response(405, json: ["error": "Method not allowed"])
        default:
            return failure(
                ["/", "/login", "/manual", "/manual.html", "/auth/session"].contains(path) ? 405 : 404,
                "notFound", "Not found")
        }
    }

    private func login(_ request: DaemonHTTPRequest) async -> DaemonHTTPResponse {
        guard request.body.count <= 16 * 1024 else {
            return failure(413, "requestTooLarge", "Request too large")
        }
        guard jsonContentType(request) else {
            return failure(415, "unsupportedMediaType", "Use application/json")
        }
        guard let value = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
            Set(value.keys) == ["username", "password"], let username = value["username"],
            let password = value["password"]
        else { return failure(400, "invalidRequest", "Invalid request") }
        do { return try json(200, await sessions.signIn(username: username, password: password)) } catch let
            error as TractandaError
        {
            return failure(
                error.code == "authenticationUnavailable" ? 503 : error.code == "signInLimited" ? 429 : 401,
                error.code, "Authentication failed")
        } catch { return failure(401, "authenticationFailed", "Authentication failed") }
    }
    private func api(_ request: DaemonHTTPRequest) async -> DaemonHTTPResponse {
        guard request.body.count <= 8 * 1024 * 1024 else {
            return failure(413, "requestTooLarge", "Request too large")
        }
        guard jsonContentType(request) else {
            return failure(415, "unsupportedMediaType", "Content-Type must be application/json")
        }
        guard let token = bearer(request) else { return failure(401, "unauthorized", "Unauthorized") }
        do {
            return DaemonHTTPResponse(
                status: 200, headers: security(["Content-Type": "application/json"]),
                body: try await sessions.dispatch(request.body, token: token))
        } catch let error as TractandaError {
            return failure(
                error.code == "serviceClosed" || error.code == "serviceBusy" ? 503 : 401, error.code,
                error.code == "serviceClosed" || error.code == "serviceBusy"
                    ? "Service unavailable" : "Unauthorized")
        } catch { return failure(503, "serviceUnavailable", "Service unavailable") }
    }
    private func mcpResponse(_ request: DaemonHTTPRequest) async -> DaemonHTTPResponse {
        let critical = ["authorization", "host", "origin", "mcp-session-id"]
        guard !critical.contains(where: { (request.headers[$0] ?? []).count > 1 }) else {
            return failure(400, "invalidHeaders", "Invalid headers")
        }
        let flattened = request.headers.compactMapValues { $0.first }
        let result = await mcp.handle(
            .init(method: request.method, headers: flattened, body: request.body, path: "/mcp"))
        return DaemonHTTPResponse(
            status: result.statusCode, headers: security(result.headers), body: result.bodyData ?? Data())
    }
    private func bearer(_ request: DaemonHTTPRequest) -> String? {
        guard let value = request.headers["authorization"], value.count == 1, value[0].hasPrefix("Bearer ")
        else { return nil }
        let token = String(value[0].dropFirst(7))
        return token.utf8.count == 64 && token.allSatisfy { $0.isHexDigit } ? token : nil
    }
    private func validHost(_ request: DaemonHTTPRequest) -> Bool {
        request.headers["host"] == ["127.0.0.1:\(request.localPort)"]
            || request.headers["host"] == ["localhost:\(request.localPort)"]
    }
    private func validOrigin(_ request: DaemonHTTPRequest, path: String) -> Bool {
        guard path == "/api" || path.hasPrefix("/auth") || path == "/mcp" else { return true }
        let host = request.headers["host"]!.first!
        return (request.headers["origin"] ?? []).count <= 1
            && (request.headers["origin"] ?? []).allSatisfy { $0 == "http://\(host)" }
            && !(request.headers["sec-fetch-site"] ?? []).contains { $0 == "cross-site" || $0 == "same-site" }
    }
    private func asset(_ data: Data, type: String) -> DaemonHTTPResponse {
        DaemonHTTPResponse(status: 200, headers: security(["Content-Type": type]), body: data)
    }
    private func json<T: Encodable>(_ status: Int, _ value: T) throws -> DaemonHTTPResponse {
        DaemonHTTPResponse(
            status: status, headers: security(["Content-Type": "application/json"]),
            body: try JSONEncoder().encode(value))
    }
    private func failure(_ status: Int, _ code: String, _ message: String) -> DaemonHTTPResponse {
        DaemonHTTPResponse(
            status: status, headers: security(["Content-Type": "application/json"]),
            body: (try? JSONSerialization.data(withJSONObject: ["code": code, "message": message])) ?? Data())
    }
    private func response(_ status: Int, json: [String: Any]) -> DaemonHTTPResponse {
        if status < 400 {
            return DaemonHTTPResponse(
                status: status, headers: security(["Content-Type": "application/json"]),
                body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        }
        let defaultCode =
            switch status {
            case 400: "invalidRequest"
            case 401: "unauthorized"
            case 403: "forbidden"
            case 404: "notFound"
            case 405: "methodNotAllowed"
            default: "requestFailed"
            }
        return failure(
            status, json["code"] as? String ?? defaultCode,
            json["message"] as? String ?? json["error"] as? String ?? "Error")
    }
    private func jsonContentType(_ request: DaemonHTTPRequest) -> Bool {
        guard let values = request.headers["content-type"], values.count == 1 else { return false }
        return values[0].lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
            == "application/json"
    }
    private func security(_ extra: [String: String]) -> [String: String] {
        extra.merging([
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy":
                "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        ]) { $1 }
    }
}
