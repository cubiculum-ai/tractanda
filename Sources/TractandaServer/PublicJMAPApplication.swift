import Foundation
import TractandaClient
import TractandaCore

struct PublicJMAPRequestHead: Sendable {
    let method: String
    let uri: String
    let headers: [String: [String]]
}
enum PublicJMAPResponseBody: Sendable {
    case bytes(Data)
    case download(JMAPBlobDownload)
    case events(any JMAPSSESubscription)
}
struct PublicJMAPResponse: Sendable {
    let status: Int
    var headers: [String: String]
    let body: PublicJMAPResponseBody
}
protocol PublicJMAPRequestSink: Sendable {
    func append(_ data: Data) async throws
    func finish() async throws -> PublicJMAPResponse
    func cancel() async
    func checkAuthorization() async throws
}
struct PublicJMAPHTTPError: Error, Sendable {
    let status: Int
    let code: String
    let detail: String
    let headers: [String: String]
    init(_ status: Int, _ code: String, _ detail: String, headers: [String: String] = [:]) {
        self.status = status
        self.code = code
        self.detail = detail
        self.headers = headers
    }
}

/// A public binding of the same dispatcher. Trusted configuration determines URLs; credentials determine UID.
actor PublicJMAPApplication {
    let coordinator: ServiceCoordinator
    let sessions: SessionAuthority
    let blobs: any JMAPBlobHTTPProvider
    let notifications: any JMAPNotificationHTTPProvider
    let binding: JMAPPublicBinding
    private let origin: String
    private let authority: String
    private let prefix: String
    private var closed = false
    private var activeUploads = 0

    init(
        coordinator: ServiceCoordinator, sessions: SessionAuthority, blobs: any JMAPBlobHTTPProvider,
        notifications: any JMAPNotificationHTTPProvider, baseURL: String
    ) throws {
        self.coordinator = coordinator
        self.sessions = sessions
        self.blobs = blobs
        self.notifications = notifications
        let exposure = try JMAPHTTPSExposure(
            baseURL: baseURL, resources: .init(api: true, upload: true, download: true, eventSource: true))
        guard let parts = URLComponents(string: exposure.baseURL), let host = parts.host else {
            throw JMAPSessionError.invalidExposure
        }
        let hostText = host.contains(":") ? "[\(host)]" : host
        authority = hostText.lowercased() + (parts.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        origin = "https://" + authority
        prefix = parts.path
        binding = try JMAPPublicBinding(
            exposure: exposure,
            limits: .init(
                maxSizeUpload: blobs.maximumUploadBytes, maxConcurrentUpload: blobs.maximumConcurrentUploads,
                maxSizeRequest: Int64(JMAPKernel.Limits().maximumRequestBytes), maxConcurrentRequests: 64,
                maxCallsInRequest: Int64(JMAPKernel.Limits().maximumCalls),
                maxObjectsInGet: Int64(TractandaJMAP.maximumObjectsInGet),
                maxObjectsInSet: notifications.maximumObjectsInSet, collationAlgorithms: []))
    }

    func begin(_ head: PublicJMAPRequestHead) async throws -> any PublicJMAPRequestSink {
        guard !closed else { throw PublicJMAPHTTPError(503, "serviceUnavailable", "Service unavailable.") }
        try validateHeaders(head)
        let route = try parse(head.uri)
        if head.method == "GET",
            (try contentLength(head) ?? 0) > 0 || head.headers["transfer-encoding"] != nil
        {
            throw PublicJMAPHTTPError(400, "invalidArguments", "GET resources do not accept request bodies.")
        }
        if route.path == "/auth/login", head.method == "POST" {
            try requireJSON(head)
            return CollectedJMAPRequest(maximum: 16 * 1024) { [sessions] data in
                guard let object = try? JMAPValue.decode(data), let members = object.members,
                    Set(members.map(\.name)) == ["username", "password"],
                    let username = object["username"]?.text,
                    let password = object["password"]?.text
                else {
                    throw PublicJMAPHTTPError(400, "invalidArguments", "Supply username and password.")
                }
                let session = try await sessions.signIn(username: username, password: password)
                return try Self.json(session)
            }
        }
        let authentication = try await sessions.authenticateHTTP(try bearer(head))
        switch (head.method, route.path) {
        case ("GET", "/jmap/session"), ("GET", "/.well-known/jmap"):
            let snapshot = try await coordinator.publicJMAPSession(
                authentication: authentication, binding: binding)
            return CollectedJMAPRequest(maximum: 0, authentication: authentication) { _ in
                .init(
                    status: 200, headers: Self.headers(type: "application/json"),
                    body: .bytes(try snapshot.document.encoded()))
            }
        case ("POST", "/jmap/api"):
            try requireJSON(head)
            if let length = try contentLength(head), length > binding.limits.maxSizeRequest {
                throw JMAPProblem("limit", status: 413, limit: "maxSizeRequest")
            }
            let coordinator = coordinator
            let binding = binding
            let blobs = blobs
            let notifications = notifications
            return CollectedJMAPRequest(
                maximum: Int(binding.limits.maxSizeRequest), standardLimit: "maxSizeRequest",
                authentication: authentication
            ) { data in
                var methods = try await blobs.methods(authentication: authentication)
                for (name, definition) in try await notifications.methods(authentication: authentication) {
                    guard methods[name] == nil else {
                        throw PublicJMAPHTTPError(
                            503, "serviceUnavailable", "Resource method registration conflict.")
                    }
                    methods[name] = definition
                }
                // This native-only session issuance shortcut cannot renew a remote bearer indefinitely.
                guard methods["TractandaAuth/createSession"] == nil else {
                    throw PublicJMAPHTTPError(503, "serviceUnavailable", "Invalid remote registry.")
                }
                let response = try await coordinator.handlePublicJMAP(
                    data, authentication: authentication, binding: binding, additionalMethods: methods)
                return .init(
                    status: 200, headers: Self.headers(type: "application/json"), body: .bytes(response))
            }
        case ("POST", "/auth/logout"):
            let token = try bearer(head)
            return CollectedJMAPRequest(maximum: 0, authentication: authentication) { [sessions] _ in
                await sessions.signOut(token)
                return .init(
                    status: 200, headers: Self.headers(type: "application/json"),
                    body: .bytes(Data("{\"signedOut\":true}".utf8)))
            }
        case ("GET", "/auth/session"):
            let token = try bearer(head)
            return CollectedJMAPRequest(maximum: 0, authentication: authentication) { [sessions] _ in
                try await Self.json(sessions.profile(for: token))
            }
        case ("GET", "/jmap/events"):
            guard Set(route.query.keys).isSubset(of: ["types", "closeafter", "ping"]) else {
                throw PublicJMAPHTTPError(400, "invalidArguments", "Unknown event query parameter.")
            }
            guard let typeText = route.query["types"], let closeAfter = route.query["closeafter"],
                ["no", "state"].contains(closeAfter),
                let pingText = route.query["ping"], let ping = Int(pingText), ping >= 0,
                String(ping) == pingText
            else {
                throw PublicJMAPHTTPError(400, "invalidArguments", "Invalid event query parameters.")
            }
            let types: [String]? =
                typeText == "*"
                ? nil : typeText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard
                types == nil
                    || (types!.count <= 32 && types!.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }))
            else { throw PublicJMAPHTTPError(400, "invalidArguments", "Invalid event types.") }
            let last = head.headers["last-event-id"]?.first
            let subscription = try await notifications.subscribe(
                types: types, closeAfterState: closeAfter == "state", pingSeconds: ping, lastEventID: last,
                authentication: authentication)
            return CollectedJMAPRequest(
                maximum: 0, authentication: authentication, cancel: { await subscription.cancel() }
            ) { _ in
                .init(
                    status: 200, headers: Self.headers(type: "text/event-stream"), body: .events(subscription)
                )
            }
        default:
            let parts = route.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 4, parts[1] == "jmap", parts[2] == "upload", head.method == "POST" {
                let accountID = try component(String(parts[3]))
                try await requireAccount(accountID, authentication: authentication, writable: true)
                guard route.query.isEmpty else {
                    throw PublicJMAPHTTPError(400, "invalidArguments", "Upload has no query parameters.")
                }
                let type = head.headers["content-type"]?.first ?? "application/octet-stream"
                try Self.validateMediaType(type)
                let size = try contentLength(head)
                if let size, size > blobs.maximumUploadBytes {
                    throw PublicJMAPHTTPError(413, "limit", "Upload exceeds maxSizeUpload.")
                }
                guard Int64(activeUploads) < blobs.maximumConcurrentUploads else {
                    throw PublicJMAPHTTPError(429, "limit", "maxConcurrentUpload is in use.")
                }
                activeUploads += 1
                do {
                    let upload = try await blobs.beginUpload(
                        accountID: accountID, type: type, expectedSize: size, authentication: authentication)
                    return UploadedJMAPRequest(
                        upload: upload, maximum: blobs.maximumUploadBytes, authentication: authentication,
                        release: { [weak self] in await self?.releaseUpload() })
                } catch {
                    activeUploads -= 1
                    throw error
                }
            }
            if parts.count == 6, parts[1] == "jmap", parts[2] == "download", head.method == "GET" {
                let accountID = try component(String(parts[3]))
                let blobID = try component(String(parts[4]))
                let name = try component(String(parts[5]))
                try JMAPGetIDs.validate(blobID)
                guard name.utf8.count <= 255, Set(route.query.keys) == ["type"],
                    let type = route.query["type"]
                else {
                    throw PublicJMAPHTTPError(
                        400, "invalidArguments", "Download requires type and a bounded filename.")
                }
                try Self.validateMediaType(type)
                try await requireAccount(accountID, authentication: authentication, writable: false)
                let source = try await blobs.openDownload(
                    accountID: accountID, blobID: blobID, authentication: authentication)
                var headers = Self.headers(type: type)
                let escaped = name.utf8.map { byte -> String in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                        || [45, 46, 95].contains(byte)
                        ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
                }.joined()
                headers["Content-Disposition"] =
                    "attachment; filename=\"download\"; filename*=UTF-8''" + escaped
                let responseHeaders = headers
                return CollectedJMAPRequest(
                    maximum: 0, authentication: authentication, cancel: { await source.close() }
                ) { _ in
                    .init(status: 200, headers: responseHeaders, body: .download(source))
                }
            }
            let allowedMethods = Self.allowedMethods(for: route.path)
            throw PublicJMAPHTTPError(
                allowedMethods == nil ? 404 : 405, "notFound", "Resource unavailable.",
                headers: allowedMethods.map { ["Allow": $0] } ?? [:])
        }
    }
    private func releaseUpload() {
        precondition(activeUploads > 0)
        activeUploads -= 1
    }
    private func requireAccount(_ id: String, authentication: JMAPHTTPAuthentication, writable: Bool)
        async throws
    {
        try JMAPGetIDs.validate(id)
        let snapshot = try await coordinator.publicJMAPSession(
            authentication: authentication, binding: binding)
        guard let account = snapshot.accounts.first(where: { $0.accountID == id }) else {
            throw PublicJMAPHTTPError(404, "accountNotFound", "Account unavailable.")
        }
        guard !writable || !account.isReadOnly else {
            throw PublicJMAPHTTPError(403, "accountReadOnly", "Account is read-only.")
        }
    }
    func close() async {
        closed = true
        await notifications.close()
    }

    private func validateHeaders(_ head: PublicJMAPRequestHead) throws {
        for key in [
            "host", "origin", "authorization", "content-length", "transfer-encoding", "content-type",
            "content-encoding", "last-event-id", "expect",
        ] where (head.headers[key]?.count ?? 0) > 1 {
            throw PublicJMAPHTTPError(400, "invalidHeaders", "Ambiguous HTTP headers.")
        }
        guard let host = head.headers["host"]?.first?.lowercased(),
            host == authority || (authority.contains(":") == false && host == authority + ":443")
        else {
            throw PublicJMAPHTTPError(403, "invalidOrigin", "Unexpected Host.")
        }
        if let supplied = head.headers["origin"]?.first, supplied != origin {
            throw PublicJMAPHTTPError(403, "invalidOrigin", "Unexpected Origin.")
        }
        guard
            !(head.headers["sec-fetch-site"] ?? []).contains(where: {
                $0 == "cross-site" || $0 == "same-site"
            })
        else { throw PublicJMAPHTTPError(403, "invalidOrigin", "Cross-origin request denied.") }
        guard head.headers["content-length"] == nil || head.headers["transfer-encoding"] == nil else {
            throw PublicJMAPHTTPError(400, "invalidHeaders", "Ambiguous request framing.")
        }
        if let coding = head.headers["transfer-encoding"]?.first, coding.lowercased() != "chunked" {
            throw PublicJMAPHTTPError(400, "invalidHeaders", "Unsupported transfer coding.")
        }
        if let encoding = head.headers["content-encoding"]?.first, encoding.lowercased() != "identity" {
            throw PublicJMAPHTTPError(415, "unsupportedMediaType", "Encoded request bodies are unsupported.")
        }
        if let expectation = head.headers["expect"]?.first, expectation.lowercased() != "100-continue" {
            throw PublicJMAPHTTPError(417, "expectationFailed", "Unsupported HTTP expectation.")
        }
        _ = try contentLength(head)
    }
    private func bearer(_ head: PublicJMAPRequestHead) throws -> String {
        guard let value = head.headers["authorization"]?.first, value.hasPrefix("Bearer ") else {
            throw PublicJMAPHTTPError(401, "unauthorized", "Bearer authentication required.")
        }
        let token = String(value.dropFirst(7))
        guard token.utf8.count == 64,
            token.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { throw PublicJMAPHTTPError(401, "unauthorized", "Invalid bearer.") }
        return token
    }
    private func requireJSON(_ head: PublicJMAPRequestHead) throws {
        guard
            head.headers["content-type"]?.first?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
        else { throw JMAPProblem("notJSON", status: 415) }
    }
    private func contentLength(_ head: PublicJMAPRequestHead) throws -> Int64? {
        guard let value = head.headers["content-length"]?.first else { return nil }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int64(value)
        else { throw PublicJMAPHTTPError(400, "invalidHeaders", "Invalid Content-Length.") }
        return size
    }
    private func component(_ raw: String) throws -> String {
        guard let value = raw.removingPercentEncoding, !value.isEmpty,
            value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }), !value.contains("/"), !value.contains("\\")
        else { throw PublicJMAPHTTPError(400, "invalidArguments", "Invalid resource path component.") }
        return value
    }
    private func parse(_ uri: String) throws -> (path: String, query: [String: String]) {
        guard uri.utf8.count <= 16 * 1024, uri.hasPrefix("/"), !uri.hasPrefix("//"), !uri.contains("#"),
            let parts = URLComponents(string: "https://request.invalid" + uri)
        else { throw PublicJMAPHTTPError(400, "invalidArguments", "Invalid resource URI.") }
        let path: String
        if parts.percentEncodedPath == "/.well-known/jmap" {
            path = parts.percentEncodedPath
        } else if prefix.isEmpty {
            path = parts.percentEncodedPath
        } else {
            guard parts.percentEncodedPath.hasPrefix(prefix + "/") else {
                throw PublicJMAPHTTPError(404, "notFound", "Resource unavailable.")
            }
            path = String(parts.percentEncodedPath.dropFirst(prefix.count))
        }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else {
                throw PublicJMAPHTTPError(400, "invalidArguments", "Duplicate or missing query value.")
            }
            query[item.name] = value
        }
        if !path.hasPrefix("/jmap/download/"), path != "/jmap/events", !query.isEmpty {
            throw PublicJMAPHTTPError(400, "invalidArguments", "Unexpected query parameters.")
        }
        return (path, query)
    }
    static func validateMediaType(_ value: String) throws {
        let base = value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let tokens = base.split(separator: "/", omittingEmptySubsequences: false)
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        guard value.utf8.count <= 255, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }), tokens.count == 2,
            tokens.allSatisfy({
                !$0.isEmpty
                    && $0.utf8.allSatisfy({
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                            || punctuation.contains($0)
                    })
            })
        else { throw PublicJMAPHTTPError(400, "invalidArguments", "Invalid media type.") }
    }
    static func headers(type: String) -> [String: String] {
        [
            "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
    }
    private static func allowedMethods(for path: String) -> String? {
        switch path {
        case "/.well-known/jmap", "/jmap/session", "/auth/session", "/jmap/events": return "GET"
        case "/jmap/api", "/auth/login", "/auth/logout": return "POST"
        default:
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 4, parts[1] == "jmap", parts[2] == "upload" { return "POST" }
            if parts.count == 6, parts[1] == "jmap", parts[2] == "download" { return "GET" }
            return nil
        }
    }
    private static func json<T: Encodable>(_ value: T) throws -> PublicJMAPResponse {
        .init(status: 200, headers: headers(type: "application/json"), body: .bytes(try JSON.encode(value)))
    }
    static func problem(_ error: any Error) -> PublicJMAPResponse {
        let status: Int
        let value: JMAPValue
        if let problem = error as? JMAPProblem {
            status = problem.status
            value = problem.value
        } else {
            let code: String
            let detail: String
            if let problem = error as? PublicJMAPHTTPError {
                status = problem.status
                code = problem.code
                detail = problem.detail
            } else if let problem = error as? TractandaError {
                code = problem.code
                switch code {
                case "invalidArguments", "invalidID": status = 400
                case "invalidSession", "authenticationFailed", "invalidCredentials": status = 401
                case "forbidden", "accountReadOnly": status = 403
                case "notFound", "accountNotFound": status = 404
                case "overQuota", "resourceLimit": status = 413
                case "signInLimited": status = 429
                default: status = 503
                }
                detail = status >= 500 ? "Service unavailable." : "Request could not be completed."
            } else {
                status = 503
                code = "serviceUnavailable"
                detail = "Service unavailable."
            }
            value = .object([
                .init("type", .string("https://tractanda.ai/problems/" + code)),
                .init("status", .number(try! JMAPNumber(String(status)))), .init("detail", .string(detail)),
            ])
        }
        var headers = headers(type: "application/problem+json")
        if let problem = error as? PublicJMAPHTTPError {
            headers.merge(problem.headers) { _, new in new }
        }
        if status == 401 { headers["WWW-Authenticate"] = "Bearer" }
        return .init(status: status, headers: headers, body: .bytes((try? value.encoded()) ?? Data()))
    }
}

private actor CollectedJMAPRequest: PublicJMAPRequestSink {
    let maximum: Int
    let standardLimit: String?
    let complete: @Sendable (Data) async throws -> PublicJMAPResponse
    let cleanup: @Sendable () async -> Void
    let authentication: JMAPHTTPAuthentication?
    var bytes = Data()
    var done = false
    init(
        maximum: Int, standardLimit: String? = nil, authentication: JMAPHTTPAuthentication? = nil,
        cancel: @escaping @Sendable () async -> Void = {},
        complete: @escaping @Sendable (Data) async throws -> PublicJMAPResponse
    ) {
        self.maximum = maximum
        self.standardLimit = standardLimit
        self.authentication = authentication
        self.complete = complete
        cleanup = cancel
    }
    func append(_ data: Data) throws {
        guard !done else { throw CancellationError() }
        guard data.count <= maximum - bytes.count else {
            if let standardLimit { throw JMAPProblem("limit", status: 413, limit: standardLimit) }
            throw PublicJMAPHTTPError(413, "limit", "Request body exceeds its limit.")
        }
        bytes.append(data)
    }
    func finish() async throws -> PublicJMAPResponse {
        guard !done else { throw CancellationError() }
        done = true
        defer { bytes.removeAll() }
        return try await complete(bytes)
    }
    func cancel() async {
        done = true
        bytes.removeAll()
        await cleanup()
    }
    func checkAuthorization() async throws { _ = try await authentication?.checkCurrent() }
}
private actor UploadedJMAPRequest: PublicJMAPRequestSink {
    let upload: any JMAPBlobUpload
    let maximum: Int64
    let authentication: JMAPHTTPAuthentication
    let release: @Sendable () async -> Void
    var released = false
    var count: Int64 = 0
    var done = false
    init(
        upload: any JMAPBlobUpload, maximum: Int64, authentication: JMAPHTTPAuthentication,
        release: @escaping @Sendable () async -> Void
    ) {
        self.upload = upload
        self.maximum = maximum
        self.authentication = authentication
        self.release = release
    }
    func append(_ data: Data) async throws {
        guard !done, data.count <= 262_144, Int64(data.count) <= maximum - count else {
            throw PublicJMAPHTTPError(413, "limit", "Upload exceeds maxSizeUpload.")
        }
        try await upload.append(data)
        count += Int64(data.count)
    }
    func finish() async throws -> PublicJMAPResponse {
        guard !done else { throw CancellationError() }
        done = true
        let value = try await upload.finish()
        await releaseOnce()
        return .init(
            status: 200, headers: PublicJMAPApplication.headers(type: "application/json"),
            body: .bytes(try value.encoded()))
    }
    func cancel() async {
        done = true
        await upload.cancel()
        await releaseOnce()
    }
    private func releaseOnce() async {
        if !released {
            released = true
            await release()
        }
    }
    func checkAuthorization() async throws { _ = try await authentication.checkCurrent() }
}
