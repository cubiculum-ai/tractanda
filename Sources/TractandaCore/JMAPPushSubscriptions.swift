import Crypto
import Foundation
import TractandaClient

/// Node-private, credential-scoped operational state. Never canonical history or replicated trust.
public actor JMAPPushSubscriptions {
    private struct Keys: Sendable {
        let publicKey: Data
        let auth: Data
    }
    private struct Record: Sendable {
        let id: String
        let credentialID: String
        let uid: UInt32
        let principalName: String
        let credentialExpiry: Date
        let deviceClientID: String
        let url: String
        let keys: Keys?
        var challenge: Data?
        var verified: Bool
        // Public only after the client supplies valid proof; the unverified challenge stays private.
        var verifiedCode: String?
        var expires: Date?
        var types: [String]?
        var lastStateID: String?
        var nextAttempt: Date
        var failures: Int = 0
    }
    private let stateProvider: JMAPStateProvider
    private let transport: any JMAPCallbackTransport
    private let resolver: @Sendable (String) async throws -> JMAPHTTPAuthentication?
    private let now: @Sendable () -> Date
    private var records: [String: Record] = [:]
    private var calls: [String: [Date]] = [:]
    private var globalCalls: [Date] = []
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var pump: Task<Void, Never>?
    private var started = false
    private var closed = false
    private var schedulerOffset = 0

    public init(
        stateProvider: @escaping JMAPStateProvider, transport: any JMAPCallbackTransport,
        credentialResolver: @escaping @Sendable (String) async throws -> JMAPHTTPAuthentication?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.stateProvider = stateProvider
        self.transport = transport
        self.resolver = credentialResolver
        self.now = now

    }
    public func methods(authentication: JMAPHTTPAuthentication) async -> [String: JMAPMethodDefinition] {
        await start()
        return [
            "PushSubscription/get": .init(
                capability: JMAPKernel.core, effect: .readOnly, scope: .session,
                maximumResponseBytes: 262_144
            ) { [weak self] args, context in
                guard let self else { return .failure(.init("serverUnavailable"), effects: .none) }
                return await self.get(args, authentication: authentication, createdIDs: context.createdIDs)
            },
            "PushSubscription/set": .init(
                capability: JMAPKernel.core, effect: .mayMutate, scope: .session,
                maximumResponseBytes: 262_144, maximumCreatedIDBytes: 65_536,
                requiresMutationAdmission: true
            ) { [weak self] args, context in
                guard let self else { return .failure(.init("serverUnavailable"), effects: .none) }
                return await self.set(args, authentication: authentication, context: context)
            },
        ]
    }
    private func start() async {
        guard !started, !closed else { return }
        started = true
        await reap()
        guard !closed else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self else { break }
                await self.processPending()
            }
        }
    }
    private func authenticate(_ auth: JMAPHTTPAuthentication) async throws {
        guard !closed, auth.expiresAt > now() else { throw JMAPMethodError("invalidSession") }
        try await auth.revalidate()
        guard !closed, auth.expiresAt > now() else { throw JMAPMethodError("invalidSession") }
    }
    /// Delivery/maintenance is server activity, not client activity; never refresh idle credentials.
    private func inspect(_ auth: JMAPHTTPAuthentication) async throws {
        guard !closed, auth.expiresAt > now() else { throw JMAPMethodError("invalidSession") }
        try await auth.checkCurrent()
        guard !closed, auth.expiresAt > now() else { throw JMAPMethodError("invalidSession") }
    }
    private func belongs(_ record: Record, _ auth: JMAPHTTPAuthentication) -> Bool {
        record.credentialID == auth.credentialID && record.uid == auth.uid
            && record.principalName == auth.principalName
    }
    private func get(
        _ args: JMAPValue, authentication auth: JMAPHTTPAuthentication, createdIDs: [String: String]
    ) async -> JMAPMethodOutcome {
        do {
            try await authenticate(auth)
            guard let members = args.members,
                members.allSatisfy({ ["ids", "properties"].contains($0.name) })
            else {
                throw JMAPMethodError("invalidArguments")
            }
            let properties = try strings(args["properties"])
            if properties?.contains(where: { $0 == "url" || $0 == "keys" }) == true {
                throw JMAPMethodError("forbidden")
            }
            let known: Set<String> = ["id", "deviceClientId", "verificationCode", "expires", "types"]
            guard properties?.allSatisfy({ known.contains($0) }) ?? true else {
                throw JMAPMethodError("invalidArguments")
            }
            let requested = try strings(args["ids"], distinct: false)
            guard requested?.allSatisfy(validObjectID) ?? true else {
                throw JMAPMethodError("invalidArguments")
            }
            guard Set(requested ?? []).count <= TractandaJMAP.maximumObjectsInGet else {
                throw JMAPMethodError("requestTooLarge")
            }
            await reap()
            let ids = requested ?? records.values.filter { belongs($0, auth) }.map(\.id).sorted()
            var list: [JMAPValue] = []
            var missing: [JMAPValue] = []
            var seen: Set<String> = []
            for requestedID in ids {
                let id = resolve(requestedID, createdIDs: createdIDs)
                guard seen.insert(id).inserted else { continue }
                guard let record = records[id], belongs(record, auth) else {
                    missing.append(.string(id))
                    continue
                }
                let full: [JMAPMember] = [
                    .init("id", .string(id)), .init("deviceClientId", .string(record.deviceClientID)),
                    // Unverified challenge bytes never enter this object; only consumed client proof does.
                    .init("verificationCode", record.verifiedCode.map(JMAPValue.string) ?? .null),
                    .init("expires", record.expires.map { .string(Timestamp.format($0)) } ?? .null),
                    .init("types", record.types.map { .array($0.map(JMAPValue.string)) } ?? .null),
                ]
                list.append(
                    .object(full.filter { $0.name == "id" || (properties?.contains($0.name) ?? true) }))
            }
            return .success([
                .init(
                    "PushSubscription/get",
                    .object([
                        .init("list", .array(list)), .init("notFound", .array(missing)),
                    ]))
            ])
        } catch { return failure(error, effects: .none) }
    }
    private func set(
        _ args: JMAPValue, authentication auth: JMAPHTTPAuthentication, context: JMAPMethodContext
    ) async -> JMAPMethodOutcome {
        var changed = false
        do {
            try await authenticate(auth)
            guard let members = args.members,
                members.allSatisfy({ ["create", "update", "destroy"].contains($0.name) })
            else {
                throw JMAPMethodError("invalidArguments")
            }
            let creates = try object(args["create"])
            let updates = try object(args["update"])
            let destroys = try strings(args["destroy"]) ?? []
            guard creates.count + updates.count + destroys.count <= TractandaJMAP.maximumObjectsInSet else {
                throw JMAPMethodError("requestTooLarge")
            }
            guard creates.allSatisfy({ JMAPRequest.validID($0.name) && $0.name.utf8.count <= 256 }),
                updates.allSatisfy({ validObjectID($0.name) }),
                destroys.allSatisfy(validObjectID)
            else {
                throw JMAPMethodError("invalidArguments")
            }
            // The fixed object/error bound includes omitted null defaults and excludes only the
            // caller's unrestricted call ID. Reserve its actual wire size before any record mutation
            // or verification callback can begin. Consumed proof is validated against32 random bytes.
            let callIDBytes = try JMAPValue.string(context.callID).encoded().count
            try context.replyBudget.reserveMutationResponse(
                maximumResponseBytes: 262_144 + callIDBytes, maximumCreatedIDBytes: 65_536)
            context.replyBudget.useCompletePublicationObservation()
            await reap()
            var created: [JMAPMember] = []
            var notCreated: [JMAPMember] = []
            var updated: [JMAPMember] = []
            var notUpdated: [JMAPMember] = []
            var destroyed: [JMAPValue] = []
            var notDestroyed: [JMAPMember] = []
            var createdIDs: [String: String] = [:]
            for entry in creates {
                do {
                    try await authenticate(auth)
                    let record = try await make(entry.value, auth: auth)
                    context.replyBudget.markPublicationAttempt()
                    changed = true
                    records[record.id] = record
                    createdIDs[entry.name] = record.id
                    // RFC8620 section5.3: acknowledge all omitted/defaulted properties. Never
                    // return a provided URL or encryption key, even when acknowledging creation.
                    var defaults: [JMAPMember] = [.init("id", .string(record.id))]
                    for name in ["keys", "verificationCode", "expires", "types"]
                    where entry.value[name] == nil {
                        defaults.append(.init(name, .null))
                    }
                    created.append(.init(entry.name, .object(defaults)))
                    // Exactly one initial verification attempt. Even an uncertain outcome is not retried.
                    launchVerification(record, auth: auth)
                } catch { notCreated.append(.init(entry.name, setError(error))) }
            }
            for entry in updates {
                let id = resolve(entry.name, createdIDs: createdIDs.merging(context.createdIDs) { a, _ in a })
                do {
                    try await authenticate(auth)
                    guard var record = records[id], belongs(record, auth) else {
                        throw JMAPMethodError("notFound")
                    }
                    let old = objectValue(record)
                    let patched = try applyPatch(entry.value, to: old)
                    let immutable = ["id", "deviceClientId", "url", "keys"].filter {
                        (patched[$0] ?? .null) != (old[$0] ?? .null)
                    }
                    guard immutable.isEmpty else { throw invalidProperties(immutable) }
                    let allowed: Set<String> = [
                        "id", "deviceClientId", "url", "keys", "verificationCode", "expires", "types",
                    ]
                    let invalid = (patched.members ?? []).filter { !allowed.contains($0.name) }.map(\.name)
                    guard invalid.isEmpty else { throw invalidProperties(invalid) }
                    let code = patched["verificationCode"] ?? .null
                    if code != (old["verificationCode"] ?? .null) {
                        guard let text = code.text,
                            let supplied = JMAPWebPushEncryption.decodeBase64URL(text),
                            let challenge = record.challenge, !record.verified,
                            constantEqual(supplied, challenge)
                        else { throw invalidProperties(["verificationCode"]) }
                        record.verified = true
                        record.verifiedCode = text
                        record.challenge = nil
                    }
                    record.expires = try expiry(patched["expires"] ?? .null)
                    let selected = try typeList(patched["types"] ?? .null)
                    if record.types != selected { record.lastStateID = nil }
                    record.types = selected
                    context.replyBudget.markPublicationAttempt()
                    changed = true
                    records[id] = record
                    updated.append(.init(id, .null))
                } catch { notUpdated.append(.init(id, setError(error))) }
            }
            for requested in destroys {
                let id = resolve(requested, createdIDs: createdIDs.merging(context.createdIDs) { a, _ in a })
                do {
                    try await authenticate(auth)
                    guard let record = records[id], belongs(record, auth) else {
                        throw JMAPMethodError("notFound")
                    }
                    context.replyBudget.markPublicationAttempt()
                    changed = true
                    try remove(id)
                    destroyed.append(.string(id))
                } catch { notDestroyed.append(.init(id, setError(error))) }
            }
            return .success(
                [
                    .init(
                        "PushSubscription/set",
                        .object([
                            .init("created", created.isEmpty ? .null : .object(created)),
                            .init("notCreated", notCreated.isEmpty ? .null : .object(notCreated)),
                            .init("updated", updated.isEmpty ? .null : .object(updated)),
                            .init("notUpdated", notUpdated.isEmpty ? .null : .object(notUpdated)),
                            .init("destroyed", destroyed.isEmpty ? .null : .array(destroyed)),
                            .init("notDestroyed", notDestroyed.isEmpty ? .null : .object(notDestroyed)),
                        ]))
                ], createdIDs: createdIDs)
        } catch { return failure(error, effects: changed ? .unknown : .none) }
    }
    private func make(_ value: JMAPValue, auth: JMAPHTTPAuthentication) async throws -> Record {
        guard let members = value.members else { throw invalidProperties([]) }
        let allowed: Set<String> = ["deviceClientId", "url", "keys", "verificationCode", "expires", "types"]
        let invalid = members.filter { !allowed.contains($0.name) }.map(\.name)
        guard invalid.isEmpty else { throw invalidProperties(invalid) }
        guard let device = value["deviceClientId"]?.text, !device.isEmpty, device.utf8.count <= 512 else {
            throw invalidProperties(["deviceClientId"])
        }
        guard value["verificationCode"] == nil || value["verificationCode"] == .null else {
            throw invalidProperties(["verificationCode"])
        }
        guard let url = value["url"]?.text else { throw invalidProperties(["url"]) }
        do { _ = try JMAPCallbackEndpoint(url) } catch { throw invalidProperties(["url"]) }
        try await authenticate(auth)
        guard records.count < 128, records.values.filter({ belongs($0, auth) }).count < 8 else {
            throw JMAPMethodError("overQuota")
        }
        let keys: Keys?
        if let input = value["keys"], input != .null {
            guard let fields = input.members, Set(fields.map(\.name)) == Set(["p256dh", "auth"]),
                let publicText = input["p256dh"]?.text, let authText = input["auth"]?.text,
                let publicKey = JMAPWebPushEncryption.decodeBase64URL(publicText),
                let secret = JMAPWebPushEncryption.decodeBase64URL(authText)
            else {
                throw invalidProperties(["keys"])
            }
            do { try JMAPWebPushEncryption.validate(publicKey: publicKey, auth: secret) } catch {
                throw invalidProperties(["keys"])
            }
            keys = .init(publicKey: publicKey, auth: secret)
        } else {
            keys = nil
        }
        let instant = now()
        let cutoff = instant.addingTimeInterval(-60)
        calls = calls.compactMapValues {
            let kept = $0.filter { $0 > cutoff }
            return kept.isEmpty ? nil : kept
        }
        globalCalls.removeAll { $0 <= cutoff }
        guard calls[auth.credentialID, default: []].count < 4, globalCalls.count < 32,
            deliveries.count < 4
        else { throw JMAPMethodError("rateLimit") }
        calls[auth.credentialID, default: []].append(instant)
        globalCalls.append(instant)
        do { try await transport.validate(url: url) } catch { throw invalidProperties(["url"]) }
        try await authenticate(auth)
        guard records.count < 128, records.values.filter({ belongs($0, auth) }).count < 8,
            deliveries.count < 4
        else { throw JMAPMethodError("overQuota") }
        return Record(
            id: try UUID.makeVersion1().uuidString.lowercased(), credentialID: auth.credentialID,
            uid: auth.uid, principalName: auth.principalName, credentialExpiry: auth.expiresAt,
            deviceClientID: device, url: url, keys: keys,
            challenge: JMAPWebPushEncryption.random(32), verified: false, verifiedCode: nil,
            expires: try expiry(value["expires"] ?? .null), types: try typeList(value["types"] ?? .null),
            nextAttempt: instant)
    }
    private func launchVerification(_ record: Record, auth: JMAPHTTPAuthentication) {
        guard !closed, let challenge = record.challenge else { return }
        deliveries[record.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.inspect(auth)
                let payload = JMAPValue.object([
                    .init("@type", .string("PushVerification")),
                    .init("pushSubscriptionId", .string(record.id)),
                    .init("verificationCode", .string(JMAPWebPushEncryption.base64URL(challenge))),
                ])
                _ = try await self.send(record, payload: payload)
            } catch { /* Deliberately no retry before verification, including unknown outcomes. */  }
            await self.finishedVerification(record.id)
        }
    }
    private func finishedVerification(_ id: String) { deliveries.removeValue(forKey: id) }
    private func send(_ record: Record, payload: JMAPValue) async throws -> JMAPCallbackResponse {
        try Task.checkCancellation()
        let deadline = min(record.credentialExpiry, record.expires ?? .distantFuture)
        guard deadline > now() else { throw JMAPMethodError("notFound") }
        let data = try payload.encoded()
        let body =
            try record.keys.map {
                try JMAPWebPushEncryption.encrypt(data, publicKey: $0.publicKey, auth: $0.auth)
            } ?? data
        return try await transport.post(
            url: record.url, body: body, encrypted: record.keys != nil,
            ttlSeconds: max(0, min(60, Int(deadline.timeIntervalSince(now())))), expiresAt: deadline)
    }
    package func processPending() async {
        guard !closed else { return }
        await reap()
        let ordered = records.values.sorted(by: { $0.id < $1.id })
        guard !ordered.isEmpty else { return }
        let offset = schedulerOffset % ordered.count
        let rotated = Array(ordered[offset...]) + Array(ordered[..<offset])
        for record in rotated where record.verified {
            guard !closed, deliveries.count < 4 else { break }
            guard deliveries[record.id] == nil, record.nextAttempt <= now() else { continue }
            schedulerOffset = ((ordered.firstIndex(where: { $0.id == record.id }) ?? 0) + 1) % ordered.count
            deliveries[record.id] = Task { [weak self] in
                guard let self else { return }
                await self.deliverState(record)
            }
        }
    }
    private func deliverState(_ snapshot: Record) async {
        var stateID: String?
        var response: JMAPCallbackResponse?
        do {
            guard let auth = try await resolver(snapshot.credentialID), belongs(snapshot, auth) else {
                try remove(snapshot.id)
                return
            }
            try await inspect(auth)
            let state = JMAPEventState.filtered(
                try await stateProvider(auth), types: try JMAPEventState.types(snapshot.types))
            stateID = try JMAPEventState.id(state)
            guard stateID != snapshot.lastStateID, !state.isEmpty else {
                deliveries.removeValue(forKey: snapshot.id)
                return
            }
            try await inspect(auth)
            guard let current = records[snapshot.id], current.verified,
                current.types == snapshot.types, current.expires == snapshot.expires
            else {
                deliveries.removeValue(forKey: snapshot.id)
                return
            }
            response = try await send(current, payload: JMAPEventState.value(state))
        } catch { /* Observed errors back off; no unbounded retry queue or retained payload. */  }
        deliveries.removeValue(forKey: snapshot.id)
        guard var record = records[snapshot.id], !closed else { return }
        if let response, response.status == 404 || response.status == 410 {
            try? remove(snapshot.id)
            return
        }
        if let response, (200...299).contains(response.status) {
            record.lastStateID = stateID
            record.failures = 0
            record.nextAttempt = now().addingTimeInterval(1)
        } else {
            record.failures = min(10, record.failures + 1)
            let backoff = min(3600, 1 << record.failures)
            let requested = response?.retryAfterSeconds ?? 0
            let delay = response?.status == 429 ? max(60, backoff, requested) : max(backoff, requested)
            record.nextAttempt = now().addingTimeInterval(Double(min(86_400, delay)))
        }
        records[record.id] = record
    }
    private func reap() async {
        for snapshot in Array(records.values) {
            var valid = false
            if snapshot.credentialExpiry > now(), snapshot.expires ?? .distantFuture > now(),
                let auth = try? await resolver(snapshot.credentialID), belongs(snapshot, auth),
                auth.expiresAt > now(), (try? await auth.checkCurrent()) != nil
            {
                valid = true
            }
            if !valid { try? remove(snapshot.id) }
        }
    }
    package var subscriptionCountForTesting: Int { records.count }
    public func close() async {
        closed = true
        pump?.cancel()
        pump = nil
        let tasks = Array(deliveries.values)
        deliveries.removeAll()
        for task in tasks { task.cancel() }
        // In-memory credentials expire on daemon restart; subscriptions share that lifetime.
        records.removeAll()
        calls.removeAll()
        globalCalls.removeAll()
        await transport.close()
    }
    private func remove(_ id: String) throws {
        deliveries.removeValue(forKey: id)?.cancel()
        records.removeValue(forKey: id)

    }
    private func objectValue(_ record: Record) -> JMAPValue {
        .object([
            .init("id", .string(record.id)), .init("deviceClientId", .string(record.deviceClientID)),
            .init("url", .string(record.url)),
            .init(
                "keys",
                record.keys.map {
                    .object([
                        .init("p256dh", .string(JMAPWebPushEncryption.base64URL($0.publicKey))),
                        .init("auth", .string(JMAPWebPushEncryption.base64URL($0.auth))),
                    ])
                } ?? .null),
            .init("verificationCode", record.verifiedCode.map(JMAPValue.string) ?? .null),
            .init("expires", record.expires.map { .string(Timestamp.format($0)) } ?? .null),
            .init("types", record.types.map { .array($0.map(JMAPValue.string)) } ?? .null),
        ])
    }
    private func applyPatch(_ patch: JMAPValue, to object: JMAPValue) throws -> JMAPValue {
        guard let members = patch.members else { throw JMAPMethodError("invalidPatch") }
        func decode(_ value: Substring) throws -> String {
            var result = ""
            var cursor = value.startIndex
            while cursor < value.endIndex {
                let char = value[cursor]
                cursor = value.index(after: cursor)
                if char == "~" {
                    guard cursor < value.endIndex else { throw JMAPMethodError("invalidPatch") }
                    let escaped = value[cursor]
                    cursor = value.index(after: cursor)
                    guard escaped == "0" || escaped == "1" else { throw JMAPMethodError("invalidPatch") }
                    result.append(escaped == "0" ? "~" : "/")
                } else {
                    result.append(char)
                }
            }
            return result
        }
        let paths = try members.map {
            try $0.name.split(separator: "/", omittingEmptySubsequences: false).map(decode)
        }
        for i in paths.indices {
            for j in paths.indices where i != j {
                guard !paths[j].starts(with: paths[i]) else { throw JMAPMethodError("invalidPatch") }
            }
        }
        func replacing(_ value: JMAPValue, path: ArraySlice<String>, with replacement: JMAPValue) throws
            -> JMAPValue
        {
            guard var fields = value.members, let first = path.first else {
                throw JMAPMethodError("invalidPatch")
            }
            if path.count == 1 {
                fields.removeAll { $0.name == first }
                if replacement != .null { fields.append(.init(first, replacement)) }
            } else {
                guard let index = fields.firstIndex(where: { $0.name == first }) else {
                    throw JMAPMethodError("invalidPatch")
                }
                fields[index] = .init(
                    first, try replacing(fields[index].value, path: path.dropFirst(), with: replacement))
            }
            return .object(fields)
        }
        var result = object
        for (member, path) in zip(members, paths) {
            result = try replacing(result, path: path[...], with: member.value)
        }
        return result
    }
    private func object(_ value: JMAPValue?) throws -> [JMAPMember] {
        guard let value, value != .null else { return [] }
        guard let result = value.members else { throw JMAPMethodError("invalidArguments") }
        return result
    }
    private func strings(_ value: JMAPValue?, distinct: Bool = true) throws -> [String]? {
        guard let value, value != .null else { return nil }
        guard let array = value.elements else { throw JMAPMethodError("invalidArguments") }
        let result = array.compactMap(\.text)
        guard result.count == array.count, !distinct || Set(result).count == result.count,
            result.allSatisfy({ $0.utf8.count <= 512 })
        else { throw JMAPMethodError("invalidArguments") }
        return result
    }
    private func typeList(_ value: JMAPValue) throws -> [String]? {
        do {
            let result = try strings(value)
            _ = try JMAPEventState.types(result)
            return result
        } catch { throw invalidProperties(["types"]) }
    }
    private func expiry(_ value: JMAPValue) throws -> Date? {
        if value == .null { return nil }
        guard let text = value.text, text.hasSuffix("Z"), let date = Timestamp.parse(text), date > now()
        else {
            throw invalidProperties(["expires"])
        }
        return date
    }
    private func validObjectID(_ id: String) -> Bool {
        JMAPRequest.validID(id) || (id.hasPrefix("#") && JMAPRequest.validID(String(id.dropFirst())))
    }
    private func resolve(_ id: String, createdIDs: [String: String]) -> String {
        id.hasPrefix("#") ? createdIDs[String(id.dropFirst())] ?? id : id
    }
    private func invalidProperties(_ names: [String]) -> JMAPMethodError {
        // RFC8620 section5.3 recommends the complete properties list; it is not mandatory. Omit
        // it as a whole when oversized, rather than truncate names or hide an earlier create by
        // exceeding the reserved reply. At 64 objects, <=2 KiB detail each fits the 262 KiB body bound.
        guard names.count <= 128, names.allSatisfy({ $0.utf8.count <= 1024 }) else {
            return .init("invalidProperties")
        }
        let properties = JMAPValue.array(names.map(JMAPValue.string))
        guard let bytes = try? properties.encoded(), bytes.count <= 2048 else {
            return .init("invalidProperties")
        }
        return .init("invalidProperties", details: [.init("properties", properties)])
    }
    private func setError(_ error: any Error) -> JMAPValue {
        let method = error as? JMAPMethodError
        return .object([.init("type", .string(method?.type ?? "serverFail"))] + (method?.details ?? []))
    }
    private func failure(_ error: any Error, effects: JMAPEffects) -> JMAPMethodOutcome {
        .failure(error as? JMAPMethodError ?? .init("serverFail"), effects: effects)
    }
    private func constantEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
