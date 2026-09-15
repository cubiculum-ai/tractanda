import Foundation
import MCP
import TractandaCore

/// In-process Streamable HTTP MCP endpoint. HTTP sessions are routing state only; every
/// request re-authenticates its bearer token before reaching the native dispatcher.
public actor MCPHTTPService {
    public typealias Authorizer = @Sendable (String) async throws -> AccountIdentity
    public typealias Dispatcher = @Sendable (Data, String) async throws -> Data

    private struct Session {
        let identity: AccountIdentity
        let server: Server
        let transport: StatelessHTTPServerTransport
        var pendingIDs: Set<String> = []
        var pending = 0
        var lastUsed = Date()
    }

    private let authorize: Authorizer
    private let dispatch: Dispatcher
    private let resultFormat: MCPResultFormat
    private let now: @Sendable () -> Date
    private var sessions: [String: Session] = [:]
    private var initializing = 0
    private var initializingByUID: [UInt32: Int] = [:]
    private var reservedSessionIDs: Set<String> = []
    private var closed = false

    public init(
        authorize: @escaping Authorizer,
        dispatch: @escaping Dispatcher,
        resultFormat: MCPResultFormat = .both, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authorize = authorize
        self.dispatch = dispatch
        self.resultFormat = resultFormat
        self.now = now
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard !closed else { return failure(503, "Service unavailable") }
        guard (request.body?.count ?? 0) <= 1024 * 1024 else { return failure(413, "Request too large") }
        guard !hasDuplicateHeader("mcp-session-id", in: request), !hasDuplicateHeader("origin", in: request),
            !hasDuplicateHeader("host", in: request)
        else {
            return failure(400, "Invalid request headers")
        }
        guard allowedOrigin(request) else { return failure(403, "Forbidden") }
        let authorization: String
        do { authorization = try bearer(from: request) } catch { return failure(401, "Unauthorized") }
        let identity: AccountIdentity
        do { identity = try await authorize(authorization) } catch { return failure(401, "Unauthorized") }
        guard !closed else { return failure(503, "Service unavailable") }
        await prune()
        switch request.method.uppercased() {
        case "GET": return failure(405, "Method Not Allowed", headers: ["Allow": "POST, DELETE"])
        case "DELETE": return await delete(request, identity: identity)
        case "POST": return await post(request, token: authorization, identity: identity)
        default: return failure(405, "Method Not Allowed", headers: ["Allow": "POST, DELETE"])
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let existing = sessions.values
        sessions.removeAll()
        for session in existing {
            await session.server.stop()
            await session.transport.disconnect()
        }
    }

    private func post(_ request: HTTPRequest, token: String, identity: AccountIdentity) async -> HTTPResponse
    {
        let isInitialize = jsonMethod(request.body) == "initialize"
        let sessionID = header("mcp-session-id", in: request)
        if sessionID == nil {
            guard isInitialize, jsonID(request.body) != nil else {
                return failure(400, "MCP initialize request is required")
            }
            guard sessions.count + initializing < 128,
                sessions.values.filter({ $0.identity.uid == identity.uid }).count
                    + (initializingByUID[identity.uid] ?? 0) < 8
            else {
                return failure(429, "Session limit reached")
            }
            initializing += 1
            initializingByUID[identity.uid, default: 0] += 1
            guard let id = reserveSessionID() else { return failure(500, "Session allocation failed") }
            defer {
                releaseReservation(identity.uid)
                reservedSessionIDs.remove(id)
            }
            do {
                let session = try await makeSession(identity: identity)
                guard !closed else {
                    await session.server.stop()
                    await session.transport.disconnect()
                    return failure(503, "Service unavailable")
                }
                let response = await session.transport.handleRequest(request)
                guard !closed else {
                    await session.server.stop()
                    await session.transport.disconnect()
                    return failure(503, "Service unavailable")
                }
                if isSuccessfulInitialize(response) {
                    var retained = session
                    retained.lastUsed = now()
                    sessions[id] = retained
                    return addSessionID(id, to: response)
                }
                await session.server.stop()
                await session.transport.disconnect()
                return response
            } catch { return failure(500, "MCP initialization failed") }
        }
        guard let id = sessionID, var session = sessions[id] else { return failure(404, "Not Found") }
        guard Self.same(identity, session.identity) else { return failure(404, "Not Found") }
        guard !isInitialize else { return failure(400, "Session already initialized") }
        let requestID = jsonID(request.body)
        guard session.pending < 8 else { return failure(429, "Request limit reached") }
        if let requestID {
            guard !session.pendingIDs.contains(requestID) else {
                return failure(429, "Request limit reached")
            }
            session.pendingIDs.insert(requestID)
        }
        session.pending += 1
        session.lastUsed = now()
        sessions[id] = session
        let response = await session.transport.handleRequest(request)
        if var current = sessions[id] {
            if let requestID { current.pendingIDs.remove(requestID) }
            current.pending -= 1
            current.lastUsed = now()
            sessions[id] = current
        }
        return response
    }

    private func delete(_ request: HTTPRequest, identity: AccountIdentity) async -> HTTPResponse {
        guard let id = header("mcp-session-id", in: request), let session = sessions[id],
            Self.same(identity, session.identity)
        else { return failure(404, "Not Found") }
        sessions.removeValue(forKey: id)
        await session.server.stop()
        await session.transport.disconnect()
        return .ok()
    }

    private func makeSession(identity: AccountIdentity) async throws -> Session {
        let authorize = authorize
        let dispatch = dispatch
        let gateway = NativeGateway(backend: { data in
            guard let request = Server.currentHandlerContext?.httpContext,
                let token = try? Self.extractBearer(from: request)
            else { throw TractandaError("unauthorized", "Bearer authorization is required.") }
            let current = try await authorize(token)
            guard Self.same(current, identity) else {
                throw TractandaError("unauthorized", "Session identity changed.")
            }
            return try await dispatch(data, token)
        })
        let (server, gate) = await MCPAdapter.makeServer(gateway: gateway, resultFormat: resultFormat)
        let transport = StatelessHTTPServerTransport()
        try await server.start(transport: transport) { _, _ in await gate.markReady() }
        return Session(identity: identity, server: server, transport: transport)
    }

    private func releaseReservation(_ uid: UInt32) {
        initializing -= 1
        let remaining = (initializingByUID[uid] ?? 1) - 1
        if remaining == 0 {
            initializingByUID.removeValue(forKey: uid)
        } else {
            initializingByUID[uid] = remaining
        }
    }

    private func prune() async {
        let cutoff = now().addingTimeInterval(-3600)
        let expired = sessions.filter { $0.value.pending == 0 && $0.value.lastUsed < cutoff }
        for (id, session) in expired {
            sessions.removeValue(forKey: id)
            await session.server.stop()
            await session.transport.disconnect()
        }
    }

    private func bearer(from request: HTTPRequest) throws -> String {
        try Self.extractBearer(from: request)
    }

    private static func extractBearer(from request: HTTPRequest) throws -> String {
        let values = request.headers.filter { $0.key.lowercased() == "authorization" }
        guard values.count == 1, let value = values.first?.value, value.hasPrefix("Bearer ") else {
            throw TractandaError("unauthorized", "Bearer authorization is required.")
        }
        let token = String(value.dropFirst(7))
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            throw TractandaError("unauthorized", "Invalid bearer token.")
        }
        return token
    }

    private func header(_ name: String, in request: HTTPRequest) -> String? {
        let values = request.headers.filter { $0.key.lowercased() == name }
        return values.count == 1 ? values.first?.value : nil
    }
    private func hasDuplicateHeader(_ name: String, in request: HTTPRequest) -> Bool {
        request.headers.filter { $0.key.lowercased() == name }.count > 1
    }
    private func allowedOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = header("origin", in: request) else { return true }
        guard let url = URL(string: origin), ["http", "https"].contains(url.scheme),
            ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        else { return false }
        return url.path.isEmpty || url.path == "/"
    }
    private func jsonMethod(_ body: Data?) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }
    private func jsonID(_ body: Data?) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any],
            let id = object["id"]
        else { return nil }
        if let text = id as? String { return "s:\(text)" }
        if let number = id as? NSNumber, String(cString: number.objCType) != "c" {
            return "n:\(number.stringValue)"
        }
        return nil
    }
    private func reserveSessionID() -> String? {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<16 {
            let id = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
            }.joined()
            if sessions[id] == nil && !reservedSessionIDs.contains(id) {
                reservedSessionIDs.insert(id)
                return id
            }
        }
        return nil
    }
    private static func same(_ lhs: AccountIdentity, _ rhs: AccountIdentity) -> Bool {
        lhs.uid == rhs.uid && lhs.name == rhs.name
    }
    private func failure(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        .error(statusCode: status, .invalidRequest(message), extraHeaders: headers)
    }
    private func addSessionID(_ id: String, to response: HTTPResponse) -> HTTPResponse {
        switch response {
        case .data(let data, var headers):
            headers["Mcp-Session-Id"] = id
            return .data(data, headers: headers)
        case .accepted(var headers):
            headers["Mcp-Session-Id"] = id
            return .accepted(headers: headers)
        case .ok(var headers):
            headers["Mcp-Session-Id"] = id
            return .ok(headers: headers)
        default: return response
        }
    }
    private func isSuccessfulInitialize(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 200, let data = response.bodyData,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["result"] != nil && object["error"] == nil
    }
}
