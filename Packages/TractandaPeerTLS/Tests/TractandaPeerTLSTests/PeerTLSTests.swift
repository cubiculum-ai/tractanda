import CNIOBoringSSL
import Foundation
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOSSL
@testable import TractandaPeerTLS

final class PeerTLSTests: XCTestCase {
    private func rejected(_ pair: Pair, file: StaticString = #filePath, line: UInt = #line) throws {
        try pair.start()
        XCTAssertEqual(pair.clientSessions.count, 0, file: file, line: line)
        XCTAssertEqual(pair.clientCapture.active, 0, file: file, line: line)
        XCTAssertTrue(
            pair.clientCapture.received.isEmpty && pair.serverCapture.received.isEmpty, file: file, line: line
        )
        XCTAssertFalse(
            pair.clientCapture.errors.isEmpty && pair.serverCapture.errors.isEmpty,
            "Stalling is not explicit handshake rejection", file: file, line: line)
    }

    func testFrozenContextAndIdentityValidation() throws {
        let value = try fixtureProfile()
        var hash = [UInt8](repeating: 0, count: 32)
        value.importerContext.withUnsafeBufferPointer { _ = SHA256($0.baseAddress, $0.count, &hash) }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "105f3e0c434eff1aa6e03aa70b1030fbd2207d70d06a7f67d1f87481c02bd7d5")
        XCTAssertThrowsError(try fixtureProfile(store: "not-a-uuid"))
        XCTAssertThrowsError(try fixtureProfile(pairing: "00000000-0000-4000-8000-000000000000"))
        XCTAssertThrowsError(try fixtureProfile(initiator: value.responderReplicaID))
    }

    func testSecretLengthGenerationAndRedaction() throws {
        XCTAssertThrowsError(try PeerTLSSecret(bytes: []))
        XCTAssertThrowsError(try PeerTLSSecret(bytes: [UInt8](repeating: 7, count: 31)))
        let secret = try PeerTLSSecret.generate()
        XCTAssertEqual(String(describing: secret), "PeerTLSSecret(<redacted>)")
        XCTAssertEqual(String(reflecting: secret), "PeerTLSSecret(<redacted>)")
        XCTAssertEqual(secret.customMirror.children.count, 0)
        let client = try context(.initiator, secret)
        XCTAssertEqual(String(describing: client), "PeerTLSContext(profile-v1)")
    }

    func testEnrollmentPurposeSeparatesImportedKeyContextWithoutChangingPeerContext() throws {
        let ordinary = try fixtureProfile()
        let invitation = try PeerTLSProfile(storeID: ordinary.storeID,
            initiatorReplicaID: ordinary.initiatorReplicaID, responderReplicaID: ordinary.responderReplicaID,
            pairingID: ordinary.pairingID, purpose: .enrollmentInvitation)
        let continuation = try PeerTLSProfile(storeID: ordinary.storeID,
            initiatorReplicaID: ordinary.initiatorReplicaID, responderReplicaID: ordinary.responderReplicaID,
            pairingID: ordinary.pairingID, purpose: .enrollmentContinuation)
        XCTAssertEqual(ordinary.purpose, .peer)
        XCTAssertNotEqual(ordinary.importerContext, invitation.importerContext)
        XCTAssertNotEqual(invitation.importerContext, continuation.importerContext)
        let secret = try PeerTLSSecret.generate()
        try rejected(Pair(client: PeerTLSContext(profile: ordinary, role: .initiator, secret: secret),
            server: PeerTLSContext(profile: invitation, role: .responder, secret: secret)))
        try rejected(Pair(client: PeerTLSContext(profile: invitation, role: .initiator, secret: secret),
            server: PeerTLSContext(profile: continuation, role: .responder, secret: secret)))
    }

    func testEnrollmentInvitationAndContinuationRetainQualifiedHybridTLSProperties() throws {
        let ordinary = try fixtureProfile()
        for purpose in [PeerTLSProfile.Purpose.enrollmentInvitation, .enrollmentContinuation] {
            let profile = try PeerTLSProfile(storeID: ordinary.storeID,
                initiatorReplicaID: ordinary.initiatorReplicaID, responderReplicaID: ordinary.responderReplicaID,
                pairingID: ordinary.pairingID, purpose: purpose)
            let secret = try PeerTLSSecret.generate()
            let pair = try Pair(client: PeerTLSContext(profile: profile, role: .initiator, secret: secret),
                server: PeerTLSContext(profile: profile, role: .responder, secret: secret))
            try pair.start()
            try pair.payload()
            XCTAssertEqual(pair.clientSessions.count, 1)
            let session = pair.clientSessions.values.withLock { $0[0] }
            XCTAssertEqual(session.profile.purpose, purpose)
            XCTAssertEqual(session.cipherSuite, 0x1302)
            XCTAssertEqual(session.keyExchangeGroup, 0x11ec)
            XCTAssertFalse(pair.wire.early)
        }
    }

    func testFreshConnectionsUseImportedPSKHybridCipherAndProtectedPayload() throws {
        let secret = try PeerTLSSecret.generate()
        let client = try context(.initiator, secret)
        let server = try context(.responder, secret)
        var shares: [(client: [UInt8], server: [UInt8])] = []
        for _ in 0..<2 {
            let pair = try Pair(client: client, server: server)
            XCTAssertEqual(pair.clientCapture.active, 0)
            try pair.start()
            XCTAssertEqual(pair.clientSessions.count, 1)
            XCTAssertEqual(pair.serverSessions.count, 1)
            XCTAssertEqual(pair.clientCapture.active, 1)
            XCTAssertEqual(pair.serverCapture.active, 1)
            let session = pair.clientSessions.values.withLock { $0[0] }
            XCTAssertEqual(session.remoteReplicaID, try fixtureProfile().responderReplicaID)
            XCTAssertEqual(session.cipherSuite, 0x1302)
            XCTAssertEqual(session.keyExchangeGroup, 0x11ec)
            XCTAssertTrue(pair.wire.selectedPSK)
            XCTAssertEqual(pair.wire.modes, [1])
            XCTAssertFalse(pair.wire.early)
            XCTAssertEqual(pair.wire.cipher, 0x1302)
            XCTAssertEqual(pair.wire.clientShares.count, 1)
            XCTAssertEqual(pair.wire.serverShares.count, 1)
            XCTAssertEqual(pair.wire.clientShares[0].count, 1216)
            XCTAssertEqual(pair.wire.serverShares[0].count, 1120)
            try pair.payload()
            XCTAssertTrue(pair.clientCapture.errors.isEmpty && pair.serverCapture.errors.isEmpty)
            shares.append((pair.wire.clientShares[0], pair.wire.serverShares[0]))
        }
        XCTAssertTrue(shares[0].client != shares[1].client && shares[0].server != shares[1].server)
    }

    func testWrongSecretIsExplicitlyRejected() throws {
        let client = try context(.initiator, PeerTLSSecret.generate())
        let server = try context(.responder, PeerTLSSecret.generate())
        try rejected(Pair(client: client, server: server))
    }

    func testSharedResponderAuthenticatesDistinctPeersWithTheirOwnProfiles() throws {
        let first = try fixtureProfile()
        let second = try fixtureProfile(
            initiator: "06060606-0606-1606-8606-060606060606",
            pairing: "08080808-0808-1808-8808-080808080808")
        let firstSecret = try PeerTLSSecret.generate(), secondSecret = try PeerTLSSecret.generate()
        let responder = try PeerTLSResponderContext(contexts: [
            context(.responder, firstSecret, first), context(.responder, secondSecret, second),
        ])
        // Reuse one frozen context and select the non-first credential before the first one.
        for (profile, secret) in [(second, secondSecret), (first, firstSecret)] {
            let pair = try Pair(client: context(.initiator, secret, profile), responder: responder)
            try pair.start()
            XCTAssertEqual(pair.serverSessions.values.withLock { $0.map(\.profile) }, [profile])
            XCTAssertEqual(pair.serverSessions.values.withLock { $0.map(\.remoteReplicaID) },
                [profile.initiatorReplicaID])
            XCTAssertEqual(pair.clientSessions.values.withLock { $0.map(\.profile) }, [profile])
            XCTAssertTrue(pair.wire.selectedPSK)
            XCTAssertEqual(pair.wire.modes, [1])
            XCTAssertEqual(pair.wire.cipher, 0x1302)
            XCTAssertFalse(pair.wire.early)
            try pair.payload()
            XCTAssertTrue(pair.clientCapture.errors.isEmpty && pair.serverCapture.errors.isEmpty)
        }
        XCTAssertEqual(String(reflecting: responder), "PeerTLSResponderContext(profile-v1)")
        XCTAssertEqual(responder.customMirror.children.count, 0)
    }

    func testSharedResponderRejectsAmbiguousForeignRoleAndExcessiveInputs() throws {
        let secret = try PeerTLSSecret.generate()
        let server = try context(.responder, secret)
        XCTAssertThrowsError(try PeerTLSResponderContext(contexts: []))
        XCTAssertThrowsError(try PeerTLSResponderContext(contexts: [server, server]))
        XCTAssertThrowsError(try PeerTLSResponderContext(contexts: [context(.initiator, secret)]))
        XCTAssertThrowsError(try PeerTLSResponderContext(contexts:
            Array(repeating: server, count: PeerTLSResponderContext.maximumContexts + 1)))
        for profile in [
            try fixtureProfile(store: "05050505-0505-1505-8505-050505050505",
                pairing: "08080808-0808-1808-8808-080808080808"),
            try fixtureProfile(responder: "07070707-0707-1707-8707-070707070707",
                pairing: "08080808-0808-1808-8808-080808080808"),
        ] {
            XCTAssertThrowsError(try PeerTLSResponderContext(contexts: [
                server, context(.responder, secret, profile),
            ]))
        }
    }

    func testSharedResponderRejectsUnknownIdentityWrongSecretAndForeignImporterContext() throws {
        let secret = try PeerTLSSecret.generate()
        let responder = try PeerTLSResponderContext(contexts: [context(.responder, secret)])
        let unknown = try fixtureProfile(pairing: "08080808-0808-1808-8808-080808080808")
        let foreign = try fixtureProfile(store: "05050505-0505-1505-8505-050505050505")
        for client in [
            try context(.initiator, secret, unknown),
            try context(.initiator, PeerTLSSecret.generate()),
            try context(.initiator, secret, foreign),
        ] {
            try rejected(Pair(client: client, responder: responder))
        }
    }

    func testSharedResponderMissingALPNCannotCrossGate() throws {
        let secret = try PeerTLSSecret.generate()
        let responder = try PeerTLSResponderContext(contexts: [context(.responder, secret)])
        let pair = try Pair(client: nil, rawClient: rawServer(secret: secret, noALPN: true),
            responder: responder)
        try pair.start()
        XCTAssertEqual(pair.serverSessions.count, 0)
        XCTAssertEqual(pair.serverCapture.active, 0)
        XCTAssertTrue(pair.serverCapture.received.isEmpty)
        XCTAssertTrue(pair.serverCapture.errors.contains { ($0 as? PeerTLSError) == .profileRejected })
    }

    func testStorePeerOrderAndUnknownPairingAreBound() throws {
        let secret = try PeerTLSSecret.generate()
        let client = try context(.initiator, secret)
        let normal = try fixtureProfile()
        for profile in [
            try fixtureProfile(store: "05050505-0505-1505-8505-050505050505"),
            try fixtureProfile(initiator: "06060606-0606-1606-8606-060606060606"),
            try fixtureProfile(responder: "07070707-0707-1707-8707-070707070707"),
            try fixtureProfile(initiator: normal.responderReplicaID, responder: normal.initiatorReplicaID),
            try fixtureProfile(pairing: "08080808-0808-1808-8808-080808080808"),
        ] { try rejected(Pair(client: client, server: context(.responder, secret, profile))) }
    }

    func testProtocolVersionAndRoleImporterContextAreBound() throws {
        let secret = try PeerTLSSecret.generate()
        let profile = try fixtureProfile()
        let client = try context(.initiator, secret)
        let normal = [
            PeerTLSProfile.protocolName, "1", profile.storeID, profile.initiatorReplicaID,
            profile.responderReplicaID, "initiator/tls-client", "responder/tls-server",
        ]
        for (position, replacement) in [(0, "wrong-protocol"), (1, "2"), (5, "responder/tls-server")] {
            var fields = normal
            fields[position] = replacement
            let bytes = fields.flatMap { value -> [UInt8] in
                let text = Array(value.utf8)
                return [UInt8(text.count >> 8), UInt8(text.count & 255)] + text
            }
            try rejected(Pair(client: client, rawServer: rawServer(secret: secret, importerContext: bytes)))
        }
    }

    func testClassicalOnlyAndTLS12PeersAreRejected() throws {
        let secret = try PeerTLSSecret.generate()
        let client = try context(.initiator, secret)
        try rejected(Pair(client: client, rawServer: rawServer(secret: secret, classical: true)))
        try rejected(Pair(client: client, rawServer: rawServer(secret: secret, oldTLS: true)))
    }

    func testCertificateFallbackIsRejectedAfterCertificateControlWorks() throws {
        let certificateServer = try rawServer(secret: nil, certificate: true)
        var config = TLSConfiguration.makeClientConfiguration()
        config.minimumTLSVersion = .tlsv13
        config.maximumTLSVersion = .tlsv13
        config.certificateVerification = .none
        config.trustRoots = .certificates([])
        config.curves = [.x25519_MLKEM768]
        config.applicationProtocols = [PeerTLSProfile.alpn]
        let control = try Pair(
            client: nil, rawClient: NIOSSLContext(configuration: config), rawServer: certificateServer)
        try control.start()
        XCTAssertEqual(control.clientCapture.handshakes, 1)
        XCTAssertEqual(control.serverCapture.handshakes, 1)
        try control.payload()
        let client = try context(.initiator, PeerTLSSecret.generate())
        try rejected(Pair(client: client, rawServer: certificateServer))
    }

    func testMissingALPNFailsBeforeAuthenticatedHandoff() throws {
        let secret = try PeerTLSSecret.generate()
        let pair = try Pair(
            client: context(.initiator, secret), rawServer: rawServer(secret: secret, noALPN: true))
        try rejected(pair)
        XCTAssertTrue(pair.clientCapture.errors.contains { ($0 as? PeerTLSError) == .profileRejected })
    }

    func testForgedWeakerCipherFailsBeforeAuthenticatedHandoff() throws {
        let secret = try PeerTLSSecret.generate()
        let pair = try Pair(client: context(.initiator, secret), server: context(.responder, secret))
        pair.corruptServerCipher = true
        try rejected(pair)
    }

    func testApplicationWriteBeforeAuthenticationIsRejectedWithoutQueueing() throws {
        let secret = try PeerTLSSecret.generate()
        let pair = try Pair(client: context(.initiator, secret), server: context(.responder, secret))
        let written = pair.client.writeAndFlush(ByteBuffer(string: "must not be queued"))
        pair.client.embeddedEventLoop.run()
        XCTAssertThrowsError(try written.wait()) {
            XCTAssertEqual($0 as? PeerTLSError, .authenticationPending)
        }
        XCTAssertNil(try pair.client.readOutbound(as: IOData.self))
        try pair.start()
        try pair.payload()
        XCTAssertEqual(pair.clientSessions.count, 1)
    }

    func testAlreadyActiveChannelCannotInstallTLS() throws {
        let channel = EmbeddedChannel()
        _ = channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1))
        channel.embeddedEventLoop.run()
        let future = try context(.initiator, PeerTLSSecret.generate()).install(on: channel) { _ in
            XCTFail("must not authenticate")
        }
        channel.embeddedEventLoop.run()
        XCTAssertThrowsError(try future.wait()) { XCTAssertEqual($0 as? PeerTLSError, .alreadyActive) }
        let responder = try PeerTLSResponderContext(contexts: [context(.responder, PeerTLSSecret.generate())])
        let responderFuture = responder.install(on: channel) { _ in XCTFail("must not authenticate") }
        channel.embeddedEventLoop.run()
        XCTAssertThrowsError(try responderFuture.wait()) {
            XCTAssertEqual($0 as? PeerTLSError, .alreadyActive)
        }
        _ = try channel.finish()
    }

    func testTamperedProtectedPayloadIsRejected() throws {
        let secret = try PeerTLSSecret.generate()
        let pair = try Pair(client: context(.initiator, secret), server: context(.responder, secret))
        try pair.start()
        pair.corruptNextCiphertext = true
        _ = pair.client.writeAndFlush(ByteBuffer(string: "synthetic tampered packet"))
        try pair.pump()
        XCTAssertTrue(pair.serverCapture.received.isEmpty)
        XCTAssertFalse(pair.serverCapture.errors.isEmpty)
    }
}
