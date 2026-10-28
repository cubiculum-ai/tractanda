import Crypto
import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

private final class NotificationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date()
    func now() -> Date { lock.withLock { instant } }
    func advance(_ seconds: Double) { lock.withLock { instant += seconds } }
}
/// A suspension barrier, not a timing race: tests observe arrival before scheduling close().
private actor NotificationSuspensionBarrier {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        let pending = observers
        observers.removeAll()
        for observer in pending { observer.resume() }
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        blocked?.resume()
        blocked = nil
    }
}
private struct NotificationUnusedAuthenticator: PasswordAuthenticating {
    func authenticate(username: String, password: String) throws -> UInt32 {
        throw TractandaError("fixtureFailure", "Idle fixtures issue local memory-only grants directly.")
    }
}
private actor NotificationFixtureAuthority {
    var revoked: Set<String> = []
    var states: JMAPVisibleStates = ["account": ["TractandaItem": "s1", "TractandaRevision": "s1"]]
    let clock: NotificationClock
    init(_ clock: NotificationClock) { self.clock = clock }
    func auth(_ id: String = "credential-a") -> JMAPHTTPAuthentication {
        .init(
            credentialID: id, uid: 501, principalName: "alice", expiresAt: clock.now() + 43_200,
            revalidate: { try await self.validate(id) })
    }
    func validate(_ id: String) throws -> AccountIdentity {
        guard !revoked.contains(id) else { throw TractandaError("invalidSession", "Revoked.") }
        return .init(uid: 501, name: "alice", primaryGroupName: "staff", groupIDs: [20])
    }
    func resolve(_ id: String) -> JMAPHTTPAuthentication? { revoked.contains(id) ? nil : auth(id) }
    func revoke(_ id: String) { revoked.insert(id) }
    func state(_ auth: JMAPHTTPAuthentication) throws -> JMAPVisibleStates {
        _ = try validate(auth.credentialID)
        return states
    }
    func change(_ token: String) {
        states = ["account": ["TractandaItem": token, "TractandaRevision": token]]
    }
}
private actor NotificationFixtureTransport: JMAPCallbackTransport {
    struct Sent: Sendable {
        let body: Data
        let encrypted: Bool
        let ttl: Int
    }
    var sent: [Sent] = []
    private var messageWaiters: [(Int, CheckedContinuation<[Sent], Never>)] = []
    var status = 201
    var failure = false
    var validationBarrier: NotificationSuspensionBarrier?
    func setValidationBarrier(_ barrier: NotificationSuspensionBarrier) { validationBarrier = barrier }
    func validate(url: String) async throws {
        _ = try JMAPCallbackEndpoint(url)
        if let barrier = validationBarrier { await barrier.wait() }
    }
    func post(url: String, body: Data, encrypted: Bool, ttlSeconds: Int, expiresAt: Date) throws
        -> JMAPCallbackResponse
    {
        sent.append(.init(body: body, encrypted: encrypted, ttl: ttlSeconds))
        let ready = messageWaiters.filter { $0.0 <= sent.count }
        messageWaiters.removeAll { $0.0 <= sent.count }
        for (_, waiter) in ready { waiter.resume(returning: sent) }
        if failure { throw TractandaError("fixtureUnknownOutcome", "Fixture failure.") }
        return .init(status: status, retryAfterSeconds: status == 429 ? 120 : nil)
    }
    func close() {}
    func messages() -> [Sent] { sent }
    func nextMessages(count: Int) async -> [Sent] {
        if sent.count >= count { return sent }
        return await withCheckedContinuation { messageWaiters.append((count, $0)) }
    }
    func configure(status: Int = 201, failure: Bool = false) {
        self.status = status
        self.failure = failure
    }
}

final class JMAPNotificationTests: XCTestCase {
    private func registry(
        _ clock: NotificationClock, _ authority: NotificationFixtureAuthority,
        _ transport: NotificationFixtureTransport
    ) throws -> JMAPPushSubscriptions {
        try .init(
            stateProvider: { try await authority.state($0) }, transport: transport,
            credentialResolver: { await authority.resolve($0) }, now: { clock.now() })
    }
    private func call(
        _ registry: JMAPPushSubscriptions, _ auth: JMAPHTTPAuthentication,
        _ method: String, _ args: JMAPValue = .object([])
    ) async throws -> JMAPInvocation {
        let methods = await registry.methods(authentication: auth)
        let kernel = JMAPKernel(methods: methods, sessionState: { try! .init("session") })
        let request = JMAPValue.object([
            .init("using", .array([.string(JMAPKernel.core)])),
            .init("methodCalls", .array([JMAPInvocation(name: method, arguments: args, callID: "0").value])),
        ])
        return try await kernel.execute(request.encoded()).methodResponses[0]
    }
    private func create(
        _ registry: JMAPPushSubscriptions, _ auth: JMAPHTTPAuthentication,
        extra: [JMAPMember] = []
    ) async throws -> String {
        let response = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "new",
                            .object(
                                [
                                    .init("deviceClientId", .string("device-a")),
                                    .init("url", .string("https://fixture.example/push?private=token")),
                                ] + extra))
                    ]))
            ]))
        return try XCTUnwrap(response.arguments["created"]?["new"]?["id"]?.text, "\(response)")
    }
    private func waitMessages(_ transport: NotificationFixtureTransport, _ count: Int) async throws
        -> [NotificationFixtureTransport.Sent]
    {
        for _ in 0..<100 {
            let messages = await transport.messages()
            if messages.count >= count { return messages }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) fixture callbacks")
        return await transport.messages()
    }
    private func assertMessageCount(
        _ transport: NotificationFixtureTransport, _ count: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let actual = await transport.messages().count
        XCTAssertEqual(actual, count, file: file, line: line)
    }
    private func verify(
        _ registry: JMAPPushSubscriptions, _ auth: JMAPHTTPAuthentication,
        id: String, transport: NotificationFixtureTransport
    ) async throws {
        let messages = try await waitMessages(transport, 1)
        let challenge = try JMAPValue.decode(messages[0].body)
        let response = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "update",
                    .object([
                        .init(
                            id,
                            .object([
                                .init("verificationCode", try XCTUnwrap(challenge["verificationCode"]))
                            ]))
                    ]))
            ]))
        XCTAssertEqual(response.arguments["updated"]?[id], .null)
    }
    func testGetPrivacyCredentialIsolationAndSessionScopedContract() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let other = await authority.auth("credential-b")
        let id = try await create(registry, auth)
        let response = try await call(registry, auth, "PushSubscription/get")
        XCTAssertNil(response.arguments["accountId"])
        XCTAssertNil(response.arguments["state"])
        let object = try XCTUnwrap(response.arguments["list"]?.elements?.first)
        XCTAssertEqual(object["id"]?.text, id)
        XCTAssertNil(object["url"])
        XCTAssertNil(object["keys"])
        XCTAssertEqual(object["verificationCode"], .null)
        let hidden = try await call(
            registry, other, "PushSubscription/get",
            .object([
                .init("ids", .array([.string(id)]))
            ]))
        XCTAssertEqual(hidden.arguments["notFound"], .array([.string(id)]))
        for field in ["url", "keys"] {
            let forbidden = try await call(
                registry, auth, "PushSubscription/get",
                .object([
                    .init("properties", .array([.string(field)]))
                ]))
            XCTAssertEqual(forbidden.name, "error")
            XCTAssertEqual(forbidden.arguments["type"]?.text, "forbidden")
        }
        let badAccount = try await call(
            registry, auth, "PushSubscription/set", .object([.init("accountId", .string("account"))]))
        XCTAssertEqual(badAccount.arguments["type"]?.text, "invalidArguments")
        await registry.close()
    }
    func testExactlyOneVerificationAndNoPushBeforeVerificationIncludingUnknownOutcome() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        await transport.configure(failure: true)
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let id = try await create(registry, auth)
        let first = try await waitMessages(transport, 1)
        let payload = try JMAPValue.decode(first[0].body)
        XCTAssertEqual(payload["@type"]?.text, "PushVerification")
        XCTAssertEqual(payload["pushSubscriptionId"]?.text, id)
        let secret = try XCTUnwrap(payload["verificationCode"]?.text)
        XCTAssertEqual(JMAPWebPushEncryption.decodeBase64URL(secret)?.count, 32)
        XCTAssertNil(UUID(uuidString: secret))
        clock.advance(600)
        await authority.change("s2")
        await registry.processPending()
        try await Task.sleep(for: .milliseconds(50))
        await assertMessageCount(transport, 1)
        let invalid = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("update", .object([.init(id, .object([.init("verificationCode", .string("wrong"))]))]))
            ]))
        XCTAssertEqual(invalid.arguments["notUpdated"]?[id]?["type"]?.text, "invalidProperties")
        await registry.close()
    }
    func testVerifiedStateCoalescingImmutablePropertiesReplayAnd429Backoff() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let id = try await create(registry, auth)
        try await verify(registry, auth, id: id, transport: transport)
        await authority.change("s2")
        await authority.change("s3")
        await registry.processPending()
        var messages = try await waitMessages(transport, 2)
        XCTAssertEqual(
            try JMAPValue.decode(messages[1].body)["changed"]?["account"]?["TractandaItem"]?.text, "s3")
        clock.advance(2)
        await registry.processPending()
        try await Task.sleep(for: .milliseconds(50))
        await assertMessageCount(transport, 2)
        let challenge = try JMAPValue.decode(messages[0].body)["verificationCode"]!
        let replay = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("update", .object([.init(id, .object([.init("verificationCode", challenge)]))]))
            ]))
        XCTAssertEqual(replay.arguments["updated"]?[id], .null, "Identical consumed client proof is a no-op")
        let changedProof = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("update", .object([.init(id, .object([.init("verificationCode", .string("wrong"))]))]))
            ]))
        XCTAssertEqual(changedProof.arguments["notUpdated"]?[id]?["type"]?.text, "invalidProperties")
        let immutable = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "update", .object([.init(id, .object([.init("url", .string("https://other.example/"))]))])
                )
            ]))
        XCTAssertEqual(immutable.arguments["notUpdated"]?[id]?["type"]?.text, "invalidProperties")
        await transport.configure(status: 429)
        await authority.change("s4")
        clock.advance(2)
        await registry.processPending()
        messages = try await waitMessages(transport, 3)
        try await Task.sleep(for: .milliseconds(50))
        clock.advance(61)
        await registry.processPending()
        try await Task.sleep(for: .milliseconds(50))
        await assertMessageCount(transport, 3)
        clock.advance(60)
        await registry.processPending()
        _ = try await waitMessages(transport, 4)
        await registry.close()
    }
    func testRevocationExpiryAndRestartDropCredentialBoundSubscriptions() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let id = try await create(
            registry, auth,
            extra: [
                .init("expires", .string(Timestamp.format(clock.now() + 5)))
            ])
        _ = try await waitMessages(transport, 1)
        clock.advance(6)
        let expired = try await call(
            registry, auth, "PushSubscription/get", .object([.init("ids", .array([.string(id)]))]))
        XCTAssertEqual(expired.arguments["notFound"], .array([.string(id)]))
        let second = try await create(registry, auth)
        await authority.revoke(auth.credentialID)
        await registry.processPending()
        let other = await authority.auth("new-credential")
        let hidden = try await call(
            registry, other, "PushSubscription/get", .object([.init("ids", .array([.string(second)]))]))
        XCTAssertEqual(hidden.arguments["notFound"], .array([.string(second)]))
        await registry.close()
        let restarted = try self.registry(clock, authority, NotificationFixtureTransport())
        let empty = try await call(restarted, other, "PushSubscription/get")
        XCTAssertEqual(empty.arguments["list"], .array([]))
        await restarted.close()
    }
    func testPerObjectErrorsBatchAndVerificationRateAreBounded() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let bad = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("create", .object([.init("x", .object([.init("deviceClientId", .string("x"))]))])),
                .init("update", .object([.init("missing", .object([]))])),
                .init("destroy", .array([.string("missing")])),
            ]))
        XCTAssertEqual(bad.arguments["notCreated"]?["x"]?["type"]?.text, "invalidProperties")
        XCTAssertEqual(bad.arguments["notUpdated"]?["missing"]?["type"]?.text, "notFound")
        XCTAssertEqual(bad.arguments["notDestroyed"]?["missing"]?["type"]?.text, "notFound")
        let batch = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("destroy", .array((0..<65).map { .string("id-\($0)") }))
            ]))
        XCTAssertEqual(batch.arguments["type"]?.text, "requestTooLarge")
        for _ in 0..<4 {
            _ = try await create(registry, auth)
            try await Task.sleep(for: .milliseconds(20))
        }
        let fifth = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "fifth",
                            .object([
                                .init("deviceClientId", .string("device")),
                                .init("url", .string("https://fixture.example/")),
                            ]))
                    ]))
            ]))
        XCTAssertEqual(fifth.arguments["notCreated"]?["fifth"]?["type"]?.text, "rateLimit")
        await registry.close()
    }
    func testSSESelectedTypesCloseAfterReconnectPingAndCurrentStateCoalescing() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let hub = try JMAPEventHub(
            stateProvider: { try await authority.state($0) },
            callbackTransport: NotificationFixtureTransport(),
            credentialResolver: { await authority.resolve($0) },
            now: { clock.now() })
        let auth = await authority.auth()
        let once = try await hub.subscribe(
            types: ["TractandaItem"], closeAfterState: true,
            pingSeconds: 0, lastEventID: nil, authentication: auth)
        let firstEvent = try await once.next()
        let event = try XCTUnwrap(firstEvent)
        XCTAssertEqual(event.name, "state")
        XCTAssertNil(event.data["changed"]?["account"]?["TractandaRevision"])
        let ended = try await once.next()
        XCTAssertNil(ended)
        let reconnect = try await hub.subscribe(
            types: ["TractandaItem"], closeAfterState: false,
            pingSeconds: 1, lastEventID: event.id, authentication: auth)
        clock.advance(1)
        let pingEvent = try await reconnect.next()
        let ping = try XCTUnwrap(pingEvent)
        XCTAssertEqual(ping.name, "ping")
        XCTAssertNil(ping.id)
        XCTAssertEqual(ping.data["interval"], .number(try JMAPNumber("1")))
        await authority.change("s2")
        await authority.change("s3")
        let changedEvent = try await reconnect.next()
        let changed = try XCTUnwrap(changedEvent)
        XCTAssertEqual(changed.data["changed"]?["account"]?["TractandaItem"]?.text, "s3")
        XCTAssertNotEqual(changed.id, event.id)
        await reconnect.cancel()
        let cancelled = try await reconnect.next()
        XCTAssertNil(cancelled)
        await hub.close()
    }
    func testSSECredentialRevocationClosesAndCapacityReclaimsCancellation() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let hub = try JMAPEventHub(
            stateProvider: { try await authority.state($0) },
            callbackTransport: NotificationFixtureTransport(),
            credentialResolver: { await authority.resolve($0) },
            now: { clock.now() })
        let auth = await authority.auth()
        var streams: [any JMAPSSESubscription] = []
        for _ in 0..<4 {
            streams.append(
                try await hub.subscribe(
                    types: nil, closeAfterState: false, pingSeconds: 0, lastEventID: nil, authentication: auth
                ))
        }
        do {
            _ = try await hub.subscribe(
                types: nil, closeAfterState: false, pingSeconds: 0, lastEventID: nil, authentication: auth)
            XCTFail("Capacity")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit") }
        await streams[0].cancel()
        let replacement = try await hub.subscribe(
            types: nil, closeAfterState: false, pingSeconds: 0, lastEventID: nil, authentication: auth)
        await authority.revoke(auth.credentialID)
        do {
            _ = try await replacement.next()
            XCTFail("Revoked")
        } catch {}
        let ended = try await replacement.next()
        XCTAssertNil(ended)
        await hub.close()
    }
    func testStandardDuplicateIDsCreationReferencesAndPatchObjectRules() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let methods = await registry.methods(authentication: auth)
        let kernel = JMAPKernel(methods: methods, sessionState: { try! .init("session") })
        let calls: [JMAPInvocation] = [
            .init(
                name: "PushSubscription/set",
                arguments: .object([
                    .init(
                        "create",
                        .object([
                            .init(
                                "fresh",
                                .object([
                                    .init("deviceClientId", .string("device")),
                                    .init("url", .string("https://fixture.example/")),
                                ]))
                        ]))
                ]), callID: "create"),
            .init(
                name: "PushSubscription/get",
                arguments: .object([
                    .init(
                        "ids",
                        .array([.string("#fresh"), .string("#fresh"), .string("absent"), .string("absent")]))
                ]), callID: "get"),
            .init(
                name: "PushSubscription/set",
                arguments: .object([
                    .init(
                        "update",
                        .object([
                            .init("#fresh", .object([.init("types", .array([.string("TractandaItem")]))]))
                        ]))
                ]), callID: "update"),
        ]
        let response = try await kernel.execute(
            JMAPValue.object([
                .init("using", .array([.string(JMAPKernel.core)])),
                .init("methodCalls", .array(calls.map(\.value))),
            ]).encoded())
        let id = try XCTUnwrap(response.methodResponses[0].arguments["created"]?["fresh"]?["id"]?.text)
        XCTAssertEqual(response.methodResponses[1].arguments["list"]?.elements?.count, 1)
        XCTAssertEqual(response.methodResponses[1].arguments["notFound"], .array([.string("absent")]))
        XCTAssertEqual(response.methodResponses[2].arguments["updated"]?[id], .null)
        let whole = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "update",
                    .object([
                        .init(
                            id,
                            .object([
                                .init("id", .string(id)), .init("deviceClientId", .string("device")),
                                .init("verificationCode", .null),
                                .init("types", .array([.string("TractandaItem")])),
                            ]))
                    ]))
            ]))
        XCTAssertEqual(whole.arguments["updated"]?[id], .null)
        for patch in [
            JMAPValue.object([.init("types/0", .string("TractandaRevision"))]),
            .object([.init("types", .null), .init("types/0", .string("TractandaItem"))]),
            .object([.init("invalid~2path", .string("value"))]),
        ] {
            let invalid = try await call(
                registry, auth, "PushSubscription/set",
                .object([
                    .init("update", .object([.init(id, patch)]))
                ]))
            XCTAssertEqual(invalid.arguments["notUpdated"]?[id]?["type"]?.text, "invalidPatch")
        }
        await registry.close()
    }
    func testRevokedSlowSSEIsReapedWithoutAnotherRead() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let hub = try JMAPEventHub(
            stateProvider: { try await authority.state($0) },
            callbackTransport: NotificationFixtureTransport(),
            credentialResolver: { await authority.resolve($0) },
            now: { clock.now() })
        let auth = await authority.auth()
        let stream = try await hub.subscribe(
            types: nil, closeAfterState: false, pingSeconds: 0, lastEventID: nil, authentication: auth)
        await authority.revoke(auth.credentialID)
        try await Task.sleep(for: .milliseconds(1200))
        let ended = try await stream.next()
        XCTAssertNil(ended)
        await hub.close()
    }
    func testEncryptedSubscriptionChallengeAndStateDeliveryUseSuppliedWebPushKeys() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let auth = await authority.auth()
        let receiver = P256.KeyAgreement.PrivateKey()
        let secret = JMAPWebPushEncryption.random(16)
        let id = try await create(
            registry, auth,
            extra: [
                .init(
                    "keys",
                    .object([
                        .init(
                            "p256dh",
                            .string(JMAPWebPushEncryption.base64URL(receiver.publicKey.x963Representation))),
                        .init("auth", .string(JMAPWebPushEncryption.base64URL(secret))),
                    ]))
            ])
        // Independent receiver-side reconstruction; the separate RFC8291 known vector checks the algorithm.
        func decrypt(_ body: Data) throws -> JMAPValue {
            XCTAssertGreaterThan(body.count, 102)
            XCTAssertEqual(body[20], 65)
            let sender = try P256.KeyAgreement.PublicKey(x963Representation: body.subdata(in: 21..<86))
            let shared = try receiver.sharedSecretFromKeyAgreement(with: sender)
            let ikm = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: secret,
                sharedInfo: Data("WebPush: info\0".utf8) + receiver.publicKey.x963Representation
                    + sender.x963Representation,
                outputByteCount: 32)
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm, salt: body.prefix(16),
                info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
            let nonceBytes = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm, salt: body.prefix(16),
                info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
            let nonce = try AES.GCM.Nonce(data: nonceBytes.withUnsafeBytes { Data($0) })
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: body.subdata(in: 86..<(body.count - 16)), tag: body.suffix(16))
            let clear = try AES.GCM.open(box, using: key)
            XCTAssertEqual(clear.last, 2)
            return try JMAPValue.decode(clear.dropLast())
        }
        let messages = try await waitMessages(transport, 1)
        XCTAssertTrue(messages[0].encrypted)
        XCTAssertLessThanOrEqual(messages[0].ttl, 60)
        let challenge = try decrypt(messages[0].body)
        XCTAssertEqual(challenge["@type"]?.text, "PushVerification")
        let verified = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "update",
                    .object([
                        .init(
                            id,
                            .object([
                                .init("verificationCode", try XCTUnwrap(challenge["verificationCode"]))
                            ]))
                    ]))
            ]))
        XCTAssertEqual(verified.arguments["updated"]?[id], .null)
        await registry.processPending()
        let states = try await waitMessages(transport, 2)
        XCTAssertTrue(states[1].encrypted)
        XCTAssertEqual(try decrypt(states[1].body)["changed"]?["account"]?["TractandaItem"]?.text, "s1")
        XCTAssertNotEqual(states[0].body.prefix(16), states[1].body.prefix(16))
        await registry.close()
    }
    func testCloseDuringSSECleanupCannotReadmitStreamOrRestartMonitor() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let hub = try JMAPEventHub(
            stateProvider: { try await authority.state($0) },
            callbackTransport: NotificationFixtureTransport(),
            credentialResolver: { await authority.resolve($0) },
            now: { clock.now() })
        let originalAuth = await authority.auth()
        let original = try await hub.subscribe(
            types: nil, closeAfterState: false, pingSeconds: 0,
            lastEventID: nil, authentication: originalAuth)
        // Leave an expired stream for admission cleanup and issue a new, still-valid credential.
        clock.advance(43_201)
        let nextAuth = await authority.auth("next-credential")
        let barrier = NotificationSuspensionBarrier()
        await hub.setStreamAdmissionBarrierForTesting { await barrier.wait() }
        let pending = Task {
            try await hub.subscribe(
                types: nil, closeAfterState: false, pingSeconds: 0,
                lastEventID: nil, authentication: nextAuth)
        }
        await barrier.waitUntilEntered()
        await hub.close()
        await barrier.release()
        do {
            let unexpected = try await pending.value
            await unexpected.cancel()
            XCTFail("A closed provider must not admit another stream")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceClosed") }
        let ended = try await original.next()
        XCTAssertNil(ended)
        // A later call must reject before reaching the still-installed admission barrier.
        do {
            _ = try await hub.subscribe(
                types: nil, closeAfterState: false, pingSeconds: 0,
                lastEventID: nil, authentication: nextAuth)
            XCTFail("Provider remained closed")
        } catch {}
    }
    func testCloseDuringCallbackValidationCannotRegisterOrSendVerification() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        let barrier = NotificationSuspensionBarrier()
        let auth = await authority.auth()
        await transport.setValidationBarrier(barrier)
        let methods = await registry.methods(authentication: auth)
        let kernel = JMAPKernel(methods: methods, sessionState: { try! .init("session") })
        let request = try JMAPValue.object([
            .init("using", .array([.string(JMAPKernel.core)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: "PushSubscription/set",
                        arguments: .object([
                            .init(
                                "create",
                                .object([
                                    .init(
                                        "late",
                                        .object([
                                            .init("deviceClientId", .string("device")),
                                            .init("url", .string("https://fixture.example/")),
                                        ]))
                                ]))
                        ]), callID: "0"
                    ).value
                ])),
        ]).encoded()
        let pending = Task { try await kernel.execute(request).methodResponses[0] }
        await barrier.waitUntilEntered()
        await registry.close()
        await barrier.release()
        let response = try await pending.value
        XCTAssertEqual(response.arguments["created"], .null)
        XCTAssertEqual(response.arguments["notCreated"]?["late"]?["type"]?.text, "invalidSession")
        await assertMessageCount(transport, 0)
    }
    func testIdleMaintenanceDoesNotRenewCredentialsButUserAPIActivityDoes() async throws {
        let clock = NotificationClock()
        let sessions = SessionAuthority(
            authenticator: NotificationUnusedAuthenticator(),
            identity: { uid in
                .init(uid: uid, name: "alice", primaryGroupName: "staff", groupIDs: [20])
            }, handle: { data, _ in data }, now: { clock.now() })
        let transport = NotificationFixtureTransport()
        let states: JMAPVisibleStates = ["account": ["TractandaItem": "s1", "TractandaRevision": "s1"]]
        let registry = try JMAPPushSubscriptions(
            stateProvider: { auth in
                try await auth.checkCurrent()
                return states
            }, transport: transport,
            credentialResolver: { try await sessions.authentication(credentialID: $0) },
            now: { clock.now() })
        let issued = try await sessions.issue(forUID: 501)
        let auth = try await sessions.authenticateHTTP(issued.token)
        _ = try await create(registry, auth)
        _ = await transport.nextMessages(count: 1)
        clock.advance(1800)
        await registry.processPending()
        let stillPresent = await registry.subscriptionCountForTesting
        XCTAssertEqual(stillPresent, 1)
        clock.advance(1801)
        await registry.processPending()
        let removed = await registry.subscriptionCountForTesting
        XCTAssertEqual(removed, 0)
        let expired = try await sessions.authentication(credentialID: auth.credentialID)
        XCTAssertNil(expired)
        await registry.processPending()
        let messages = await transport.messages()
        XCTAssertEqual(
            messages.count, 1, "Only the initial verification attempt; no state or retry after expiry")

        // A real API method invocation still renews the established one-hour idle window.
        let second = try await sessions.issue(forUID: 501)
        let activeAuth = try await sessions.authenticateHTTP(second.token)
        clock.advance(1800)
        let response = try await call(registry, activeAuth, "PushSubscription/get")
        XCTAssertEqual(response.name, "PushSubscription/get")
        clock.advance(1801)
        let renewed = try await sessions.authentication(credentialID: activeAuth.credentialID)
        XCTAssertNotNil(renewed, "Actual client API traffic extends idle lifetime")
        clock.advance(1800)
        let idleAgain = try await sessions.authentication(credentialID: activeAuth.credentialID)
        XCTAssertNil(idleAgain, "Non-renewing lookup must not extend the API-renewed idle window")
        await registry.close()

        // An open SSE stream's unchanged-state polling/pings are also background activity.
        let third = try await sessions.issue(forUID: 501)
        let eventAuth = try await sessions.authenticateHTTP(third.token)
        let hub = try JMAPEventHub(
            stateProvider: { auth in
                try await auth.checkCurrent()
                return states
            }, callbackTransport: NotificationFixtureTransport(),
            credentialResolver: { try await sessions.authentication(credentialID: $0) }, now: { clock.now() })
        let stream = try await hub.subscribe(
            types: nil, closeAfterState: false, pingSeconds: 1,
            lastEventID: nil, authentication: eventAuth)
        let initial = try await stream.next()
        XCTAssertEqual(initial?.name, "state")
        clock.advance(1800)
        let ping = try await stream.next()
        XCTAssertEqual(ping?.name, "ping")
        clock.advance(1801)
        do {
            let ended = try await stream.next()
            XCTAssertNil(ended, "Idle credential must expire despite server pings")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "invalidSession") }
        let eventExpired = try await sessions.authentication(credentialID: eventAuth.credentialID)
        XCTAssertNil(eventExpired)
        await hub.close()
        await sessions.close()
    }
    func testCommonKernelAcknowledgesCreateBeforeOversizedInvalidPropertyAndPatchErrors() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        defer { await registry.close() }
        let auth = await authority.auth()
        let methods = await registry.methods(authentication: auth)
        let kernel = JMAPKernel(methods: methods, sessionState: { try! .init("session") })
        let huge = String(repeating: "x", count: 300 * 1024)
        let callID = String(repeating: "c", count: 300 * 1024)
        let set = JMAPInvocation(
            name: "PushSubscription/set",
            arguments: .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "a",
                            .object([
                                .init("deviceClientId", .string("device")),
                                .init("url", .string("https://fixture.example/")),
                            ])),
                        .init("b", .object([.init(huge, .bool(true))])),
                    ])),
                .init(
                    "update",
                    .object([
                        .init(
                            "#a",
                            .object([
                                .init(huge + "~1unknown", .bool(true))
                            ]))
                    ])),
            ]), callID: callID)
        let get = JMAPInvocation(
            name: "PushSubscription/get",
            arguments: .object([
                .init("ids", .array([.string("#a")]))
            ]), callID: "confirm")
        let wire = try JMAPValue.object([
            .init("using", .array([.string(JMAPKernel.core)])), .init("createdIds", .object([])),
            .init("methodCalls", .array([set.value, get.value])),
        ]).encoded()
        XCTAssertLessThan(wire.count, 8 * 1024 * 1024)
        let response = try await kernel.execute(wire)
        XCTAssertEqual(response.methodResponses.count, 2)
        let result = response.methodResponses[0]
        XCTAssertEqual(result.name, "PushSubscription/set", "No foreseeable serverPartialFail after create")
        XCTAssertEqual(result.callID, callID)
        let id = try XCTUnwrap(result.arguments["created"]?["a"]?["id"]?.text)
        XCTAssertEqual(response.createdIDs?["a"], id)
        XCTAssertEqual(result.arguments["notCreated"]?["b"]?["type"]?.text, "invalidProperties")
        XCTAssertNil(result.arguments["notCreated"]?["b"]?["properties"])
        XCTAssertEqual(result.arguments["notUpdated"]?[id]?["type"]?.text, "invalidProperties")
        XCTAssertNil(result.arguments["notUpdated"]?[id]?["properties"])
        XCTAssertLessThan(try result.arguments.encoded().count, 8192)
        XCTAssertLessThan(
            try response.value.encoded().count, try JMAPValue.string(callID).encoded().count + 16_384)
        XCTAssertEqual(response.methodResponses[1].name, "PushSubscription/get")
        XCTAssertEqual(response.methodResponses[1].arguments["list"]?.elements?.first?["id"]?.text, id)
        let sent = await transport.nextMessages(count: 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(try JMAPValue.decode(sent[0].body)["pushSubscriptionId"]?.text, id)
    }
    func testCreatedDefaultsAndConsumedProofMatchIndependentJSONTranscript() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try self.registry(clock, authority, transport)
        defer { await registry.close() }
        let auth = await authority.auth()
        let created = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "new",
                            .object([
                                .init("deviceClientId", .string("device-a")),
                                .init("url", .string("https://fixture.example/private-token")),
                            ]))
                    ]))
            ]))
        let id = try XCTUnwrap(created.arguments["created"]?["new"]?["id"]?.text)
        let expectedCreate = try JMAPValue.decode(
            Data(
                """
                {"created":{"new":{"id":"\(id)","keys":null,"verificationCode":null,"expires":null,"types":null}},
                 "notCreated":null,"updated":null,"notUpdated":null,"destroyed":null,"notDestroyed":null}
                """.utf8))
        XCTAssertEqual(created.arguments, expectedCreate)
        let delivered = await transport.nextMessages(count: 1)
        let proof = try XCTUnwrap(try JMAPValue.decode(delivered[0].body)["verificationCode"]?.text)
        let before = try await call(registry, auth, "PushSubscription/get")
        let expectedBefore = try JMAPValue.decode(
            Data(
                """
                {"list":[{"id":"\(id)","deviceClientId":"device-a","verificationCode":null,"expires":null,"types":null}],"notFound":[]}
                """.utf8))
        XCTAssertEqual(
            before.arguments, expectedBefore, "Delivery alone must not expose the unverified challenge")
        let verified = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("update", .object([.init(id, .object([.init("verificationCode", .string(proof))]))]))
            ]))
        let expectedUpdate = try JMAPValue.decode(
            Data(
                """
                {"created":null,"notCreated":null,"updated":{"\(id)":null},"notUpdated":null,"destroyed":null,"notDestroyed":null}
                """.utf8))
        XCTAssertEqual(verified.arguments, expectedUpdate)
        let after = try await call(registry, auth, "PushSubscription/get")
        let expectedAfter = try JMAPValue.decode(
            Data(
                """
                {"list":[{"id":"\(id)","deviceClientId":"device-a","verificationCode":"\(proof)","expires":null,"types":null}],"notFound":[]}
                """.utf8))
        XCTAssertEqual(after.arguments, expectedAfter)
        // Returning the complete public object is a valid same-value patch, including consumed proof.
        let whole = try XCTUnwrap(after.arguments["list"]?.elements?.first)
        let same = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init("update", .object([.init(id, whole)]))
            ]))
        XCTAssertEqual(same.arguments, expectedUpdate)

        let receiver = P256.KeyAgreement.PrivateKey()
        let keyText = JMAPWebPushEncryption.base64URL(receiver.publicKey.x963Representation)
        let authText = JMAPWebPushEncryption.base64URL(JMAPWebPushEncryption.random(16))
        let supplied = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "provided",
                            .object([
                                .init("deviceClientId", .string("device-b")),
                                .init("url", .string("https://fixture.example/secret-url")),
                                .init(
                                    "keys",
                                    .object([
                                        .init("p256dh", .string(keyText)), .init("auth", .string(authText)),
                                    ])),
                                .init("verificationCode", .null), .init("expires", .null),
                                .init("types", .null),
                            ]))
                    ]))
            ]))
        let suppliedID = try XCTUnwrap(supplied.arguments["created"]?["provided"]?["id"]?.text)
        let expectedSupplied = try JMAPValue.decode(
            Data(
                """
                {"created":{"provided":{"id":"\(suppliedID)"}},"notCreated":null,"updated":null,"notUpdated":null,"destroyed":null,"notDestroyed":null}
                """.utf8))
        XCTAssertEqual(supplied.arguments, expectedSupplied, "Provided keys and URL must never be echoed")
        let explicitNull = try await call(
            registry, auth, "PushSubscription/set",
            .object([
                .init(
                    "create",
                    .object([
                        .init(
                            "null-key",
                            .object([
                                .init("deviceClientId", .string("device-c")),
                                .init("url", .string("https://fixture.example/")),
                                .init("keys", .null),
                            ]))
                    ]))
            ]))
        let nullID = try XCTUnwrap(explicitNull.arguments["created"]?["null-key"]?["id"]?.text)
        let expectedNullKey = try JMAPValue.decode(
            Data(
                """
                {"created":{"null-key":{"id":"\(nullID)","verificationCode":null,"expires":null,"types":null}},
                 "notCreated":null,"updated":null,"notUpdated":null,"destroyed":null,"notDestroyed":null}
                """.utf8))
        XCTAssertEqual(
            explicitNull.arguments, expectedNullKey, "Explicit null keys are not an omitted default")
    }
    func testRFC8291PublishedVector() throws {
        func decode(_ text: String) throws -> Data {
            try XCTUnwrap(JMAPWebPushEncryption.decodeBase64URL(text))
        }
        let receiver = try decode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let sender = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
        let encoded = try JMAPWebPushEncryption.encrypt(
            Data("When I grow up, I want to be a watermelon".utf8), publicKey: receiver,
            auth: decode("BTBZMqHH6r4Tts7J_aSIgg"), sender: sender, salt: decode("DGv6ra1nlYgDCS1FRnbzlw"))
        XCTAssertEqual(
            encoded,
            try decode(
                "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
            ))
    }
}

extension JMAPNotificationTests {
    func testGetUsesSharedAdvertisedObjectLimitAfterDuplicateNormalization() async throws {
        let clock = NotificationClock()
        let authority = NotificationFixtureAuthority(clock)
        let transport = NotificationFixtureTransport()
        let registry = try registry(clock, authority, transport)
        let auth = await authority.auth()
        let maximum = TractandaJMAP.maximumObjectsInGet
        let accepted = try await call(
            registry, auth, "PushSubscription/get",
            .object([.init("ids", .array((0..<maximum).map { .string("unknown-\($0)") }))]))
        XCTAssertEqual(accepted.name, "PushSubscription/get")
        XCTAssertEqual(accepted.arguments["notFound"]?.elements?.count, maximum)
        let denied = try await call(
            registry, auth, "PushSubscription/get",
            .object([.init("ids", .array((0...maximum).map { .string("unknown-\($0)") }))]))
        XCTAssertEqual(denied.name, "error")
        XCTAssertEqual(denied.arguments["type"]?.text, "requestTooLarge")
        let repeated = try await call(
            registry, auth, "PushSubscription/get",
            .object([.init("ids", .array(Array(repeating: .string("same-unknown"), count: maximum + 10)))]))
        XCTAssertEqual(repeated.name, "PushSubscription/get")
        XCTAssertEqual(repeated.arguments["notFound"]?.elements?.count, 1)
        await registry.close()
    }
}
