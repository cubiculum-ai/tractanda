import Foundation
import MCP
import TractandaClient
import TractandaCore
import TractandaMCP

public actor DaemonApplication {
    private let coordinator: ServiceCoordinator
    private let sessions: SessionAuthority
    private let page: Data
    private let manual: Data
    private let nonce: String
    private let mcp: MCPHTTPService
    private var blobProvider: (any JMAPBlobHTTPProvider)?
    func setBlobProvider(_ provider: any JMAPBlobHTTPProvider) { blobProvider = provider }
    private var closed = false
    private var privateEnrollmentControls: [UUID: PeerExchangeControl] = [:]
    private var modelStatusProvider: (@Sendable () -> [ModelProvisioningStatus])?
    func setModelStatusProvider(_ provider: @escaping @Sendable () -> [ModelProvisioningStatus]) {
        modelStatusProvider = provider
    }
    private var peerStatusProvider: (@Sendable () async throws -> PeerOperatorRuntimeStatus)?

    private var personalPeerAdminProvider: (@Sendable (PeerExchangeRequest, UInt32) async throws -> Data)?
    private var personalEnrollmentProvider:
        (@Sendable (Data, UInt32, NativePrincipalPin) async throws -> Data)?
    func setPersonalEnrollmentProvider(
        _ provider: @escaping @Sendable (Data, UInt32, NativePrincipalPin) async throws -> Data
    ) {
        personalEnrollmentProvider = provider
    }
    func makePrivatePersonalEnrollmentSession(
        _ request: NativePersonalEnrollment.Begin,
        forUID uid: UInt32, control: PeerExchangeControl
    ) async throws -> NativePersonalEnrollmentSession {
        guard !closed, let provider = personalEnrollmentProvider else {
            throw TractandaError(
                "peerRuntimeUnavailable", "Explicit peer runtime policy is required before native pairing.")
        }
        // This actual Unix peer UID is never supplied by the private JMAP body.
        let authentication = try await coordinator.localJMAPAuthentication(forUID: uid)
        let principal = NativePrincipalPin(authentication)
        _ = try await coordinator.personalPeerLocalRequest(
            .init("identity"), forUID: uid, principal: principal)
        try control.check()
        return .init(
            byteCount: request.byteCount,
            commit: { data in
                try control.check()
                guard data.count == request.byteCount else { throw NativePersonalEnrollment.failure() }
                _ = try await self.coordinator.personalPeerLocalRequest(
                    .init("identity"), forUID: uid, principal: principal)
                // Once accepted, the independent daemon job owns its lifetime. Disconnect
                // cancels delivery, not a successfully persisted join or membership decision.
                return try await provider(data, uid, principal)
            }, cancel: { control.cancel() }, control: control)
    }
    func setPersonalPeerAdminProvider(
        _ provider: @escaping @Sendable (PeerExchangeRequest, UInt32) async throws -> Data
    ) {
        personalPeerAdminProvider = provider
    }

    func setPeerStatusProvider(_ provider: @escaping @Sendable () async throws -> PeerOperatorRuntimeStatus) {
        peerStatusProvider = provider
    }

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

    public func native(_ data: Data, forUID uid: UInt32) async throws -> Data {
        do {
            let request = try JMAPRequest.decode(data)
            var methods: [String: JMAPMethodDefinition] = [:]
            if let blobProvider {
                let authentication = try await coordinator.localJMAPAuthentication(forUID: uid)
                methods = try await blobProvider.methods(authentication: authentication)
            }
            let names = [
                "TractandaModel/status", PersonalPeerAdminCall.method, PeerOperatorStatus.nativeMethod,
                "TractandaAuth/createSession", "TractandaPeerEnrollment/step",
                "TractandaPeerEnrollment/status",
                "TractandaPeerEnrollment/accept", "TractandaPeerEnrollment/register",
                "TractandaPeerEnrollment/read",
            ]
            for method in names {
                let readOnly =
                    method == "TractandaModel/status" || method == PeerOperatorStatus.nativeMethod
                    || method == "TractandaPeerEnrollment/status"
                    || method == "TractandaPeerEnrollment/read"
                methods[method] = .init(
                    capability: ItemService.capability, effect: readOnly ? .readOnly : .mayMutate,
                    scope: TractandaJMAP.scope(of: method) ?? .account,
                    maximumResponseBytes: 8 * 1024 * 1024 - 16 * 1024,
                    requiresMutationAdmission: !readOnly
                ) { args, context in
                    await self.nativeControl(
                        NativeMethodInvocation(
                            .init(name: method, arguments: args, callID: context.callID), context: context),
                        forUID: uid)
                }
            }
            return try await coordinator.handle(request, forUID: uid, additionalMethods: methods)
        } catch let problem as JMAPProblem { return try problem.value.encoded() } catch {
            return try JSON.encode(
                error as? TractandaError
                    ?? TractandaError("serverFail", "Native request could not be completed."))
        }
    }

    private func nativeControl(_ invocation: NativeMethodInvocation, forUID uid: UInt32) async
        -> NativeMethodOutcome
    {
        await NativeInvocationScope.$budget.withValue(invocation.replyBudget) {
            do {
                let invocation = try invocation.normalizedForDomain()
                guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
                if invocation.method == "TractandaModel/status" {
                    guard invocation.arguments.members?.isEmpty == true else {
                        throw TractandaError("invalidArguments", "Model status takes no arguments.")
                    }
                    _ = try await coordinator.localJMAPAuthentication(forUID: uid)
                    let statuses = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(modelStatusProvider?() ?? []))
                    return try .nativeSuccess(invocation.method, ["artifacts": statuses])
                }
                if let call = try PeerOperatorStatusNativeCall.parse(invocation) {
                    do {
                        _ = try await coordinator.peerOperatorCanonicalStatus(forUID: uid)
                        let runtime: PeerOperatorRuntimeStatus
                        do { runtime = try await peerStatusProvider?() ?? .unavailable } catch {
                            runtime = .unavailable
                        }
                        let canonical = try await coordinator.peerOperatorCanonicalStatus(forUID: uid)
                        guard !closed else {
                            throw TractandaError("serviceClosed", "Native application is closed.")
                        }
                        return try call.response(.init(canonical: canonical, runtime: runtime))
                    } catch { return call.failure(error) }
                }
                let overhead =
                    try JMAPInvocation(
                        name: invocation.method, arguments: .object([]), callID: invocation.callID
                    ).value.encoded().count - 2
                if let call = try PersonalPeerAdminCall.parse(invocation) {
                    guard let provider = personalPeerAdminProvider else {
                        throw TractandaError("serviceClosed", "Personal peer administration is unavailable.")
                    }
                    try invocation.replyBudget?.reserveMutationResponse(
                        maximumResponseBytes: overhead + 256 * 1024)
                    invocation.replyBudget?.markDomainOperationBegan()
                    return try call.response(await provider(call.request, uid))
                }
                if let call = try PeerEnrollmentNativeCall.parse(invocation) {
                    if invocation.method != "TractandaPeerEnrollment/status"
                        && invocation.method != "TractandaPeerEnrollment/read"
                    {
                        try invocation.replyBudget?.reserveMutationResponse(
                            maximumResponseBytes: overhead + NativePeerEnrollment.maximumMetadata)
                        invocation.replyBudget?.markDomainOperationBegan()
                    }
                    let data = try await coordinator.nativeEnrollmentCall(call, forUID: uid)
                    guard !closed else {
                        throw TractandaError("serviceClosed", "Native application is closed.")
                    }
                    return try .nativeSuccess(invocation.method, JSONSerialization.jsonObject(with: data))
                }
                if invocation.method == "TractandaAuth/createSession" {
                    guard invocation.callCount == 1, invocation.arguments.members?.isEmpty == true else {
                        throw TractandaError(
                            "invalidArguments", "Use one session-creation invocation with empty arguments.")
                    }
                    // Bounded native session schema: random32-byte token, validated OS name, ISO timestamp.
                    try invocation.replyBudget?.reserveMutationResponse(maximumResponseBytes: overhead + 8192)
                    invocation.replyBudget?.markDomainOperationBegan()
                    return try .nativeEncodedSuccess(invocation.method, await sessions.issue(forUID: uid))
                }
                return .failure(.init("unknownMethod"), effects: .none)
            } catch { return .nativeFailure(error, budget: invocation.replyBudget) }
        }
    }
    func makePrivateCredentialSession(
        _ request: NativePeerCredentialRegistration.Begin,
        forUID uid: UInt32, control: PeerExchangeControl
    ) async throws -> NativeCredentialRegistrationSession {
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        let admission = try await coordinator.beginNativeCredentialRegistration(
            request, forUID: uid, control: control)
        do {
            guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
            try control.check()
        } catch {
            await coordinator.cancelNativeCredentialRegistration(admission)
            throw error
        }
        let coordinator = coordinator
        return NativeCredentialRegistrationSession(
            byteCount: request.byteCount,
            commit: { input in
                try await self.finishPrivateCredential(admission, input: input, control: control)
            },
            cancel: { await coordinator.cancelNativeCredentialRegistration(admission) })
    }
    private func finishPrivateCredential(
        _ admission: PeerCredentialRegistrationAdmission,
        input: PeerPrivateCredentialInput, control: PeerExchangeControl
    ) async throws -> Data {
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        try control.check()
        return try await coordinator.finishNativeCredentialRegistration(admission, input: input)
    }
    func makePrivateEnrollmentSession(
        _ request: NativePeerEnrollment.PrivateRequest,
        forUID uid: UInt32, control: PeerExchangeControl
    ) async throws -> NativePeerEnrollmentSession {
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        let token = UUID()
        privateEnrollmentControls[token] = control
        let admission: PeerNativeEnrollmentAdmission
        do {
            admission = try await coordinator.beginNativeEnrollment(request, forUID: uid, control: control)
        } catch {
            privateEnrollmentControls.removeValue(forKey: token)
            throw error
        }
        do {
            guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
            try control.check()
        } catch {
            await cancelPrivateEnrollment(token, admission: admission)
            throw error
        }
        return .init(
            operation: request.operation, byteCount: request.byteCount,
            commit: { data in
                try await self.finishPrivateEnrollment(
                    admission, data: data, request: request, control: control)
            },
            cancel: { await self.cancelPrivateEnrollment(token, admission: admission) },
            validateBeforeDelivery: {
                if request.operation == .exportTarget {
                    try await self.validatePrivateEnrollmentDelivery(admission, control: control)
                }
            }, control: control)
    }
    private func cancelPrivateEnrollment(_ token: UUID, admission: PeerNativeEnrollmentAdmission) async {
        privateEnrollmentControls.removeValue(forKey: token)?.cancel()
        await coordinator.cancelNativeEnrollment(admission)
    }
    private func validatePrivateEnrollmentDelivery(
        _ admission: PeerNativeEnrollmentAdmission,
        control: PeerExchangeControl
    ) async throws {
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        try control.check()
        try await coordinator.validateNativeEnrollmentExportDelivery(admission)
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        try control.check()
    }
    private func finishPrivateEnrollment(
        _ admission: PeerNativeEnrollmentAdmission, data: Data?,
        request: NativePeerEnrollment.PrivateRequest, control: PeerExchangeControl
    ) async throws -> Data {
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        try control.check()
        let input: PeerEnrollmentPairInput?
        if request.operation == .begin {
            guard let data else { throw NativePeerEnrollment.failure() }
            input = try .init(bytes: data)
        } else {
            guard data == nil else { throw NativePeerEnrollment.failure() }
            input = nil
        }
        let result = try await coordinator.finishNativeEnrollment(admission, input: input)
        guard !closed else { throw TractandaError("serviceClosed", "Native application is closed.") }
        try control.check()
        return result
    }
    public func close() async {
        guard !closed else { return }
        closed = true
        for control in privateEnrollmentControls.values { control.cancel() }
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
            return problem(JMAPProblem("limit", status: 413, limit: "maxSizeRequest"))
        }
        guard jsonContentType(request) else {
            return problem(JMAPProblem("notJSON", status: 415))
        }
        guard let token = bearer(request) else { return failure(401, "unauthorized", "Unauthorized") }
        do {
            return DaemonHTTPResponse(
                status: 200, headers: security(["Content-Type": "application/json"]),
                body: try await sessions.dispatch(request.body, token: token))
        } catch let failure as JMAPProblem {
            return problem(failure)
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
    private func problem(_ failure: JMAPProblem) -> DaemonHTTPResponse {
        .init(
            status: failure.status, headers: security(["Content-Type": "application/problem+json"]),
            body: (try? failure.value.encoded()) ?? Data())
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
