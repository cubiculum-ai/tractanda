import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaPeerTLS
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

private final class ResponderAccounts: AccountDirectory, @unchecked Sendable {
    let base: any AccountDirectory
    init(_ base: any AccountDirectory) { self.base = base }
    func user(forUID uid: UInt32) throws -> AccountIdentity { try base.user(forUID: uid) }
    func user(named name: String) throws -> AccountIdentity { try base.user(named: name) }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}

private final class LoopbackConnections: Sendable {
    private let values = Mutex<[PeerExchangeConnection]>([])
    func append(_ value: PeerExchangeConnection) { values.withLock { $0.append(value) } }
    func snapshot() -> [PeerExchangeConnection] { values.withLock { $0 } }
}

final class PeerResponderLoopbackTests: XCTestCase {
    typealias Fixture = PeerTransportStoreFixtures.Fixture

    private func coordinator(_ root: URL, accounts: ResponderAccounts) async throws -> ServiceCoordinator {
        try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { accounts })
    }

    private func credential(
        _ context: PeerPackage.Context, local: String, remote: String, pairingID: String,
        initiator: Bool, key: UInt8
    ) throws -> PeerCredential {
        try PeerCredential(
            binding: PeerExchangeBinding(
                peerID: context.peerID, storeID: context.storeID, localReplicaID: local,
                remoteReplicaID: remote, pairingID: pairingID, localIsInitiator: initiator,
                configurationDigest: context.configurationDigest), secret: [UInt8](repeating: key, count: 32))
    }

    func testTwoDistinctReplicasShareLoopbackResponderAndRejectUnpairedOrWrongKeyClients() async throws {
        try AttachmentFixtureCapacity.requireFree()
        // Three tiny stores and their WALs are estimated below24MiB; no payload/scale fixture.
        XCTAssertLessThanOrEqual(24 * 1024 * 1024, AttachmentFixtureCapacity.fixtureCapBytes)
        let f = try Fixture(
            directory: GuardedFixtureDirectory.create(
                prefix: "l", source: "PeerResponderLoopbackTests", test: name))
        try f.bootstrap()
        let thirdRoot = f.directory.appendingPathComponent("third")
        let thirdAccounts = PeerTransportStoreFixtures.Accounts()
        var third: ItemStore? = try ItemStore(
            root: thirdRoot, accounts: thirdAccounts,
            revisionProjectionEnabled: true)
        third = nil
        // The same explicit fixture-only clone mechanism as the existing two-store fixture:
        // shared logical StoreID, independently allocated ReplicaID, no user data removed.
        let identity = ".tractanda-store-identity.json"
        try Data(contentsOf: f.sourceRoot.appendingPathComponent(identity)).write(
            to: thirdRoot.appendingPathComponent(identity), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: thirdRoot.appendingPathComponent(identity).path)
        try FileManager.default.removeItem(at: thirdRoot.appendingPathComponent("index"))
        third = try Fixture.open(thirdRoot, thirdAccounts)
        let thirdID = try XCTUnwrap(third?.replicaID)
        let receiverID = try XCTUnwrap(f.receiver.replicaID)
        let origins = [f.origin, receiverID, thirdID].sorted()
        let bootstrap = try PeerPackage.Context(
            peerID: "third-bootstrap", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("third-bootstrap".utf8)),
            permittedOrigins: origins)
        try third!.configurePeerIntake(peers: [bootstrap])
        let old = f.context!
        f.context = bootstrap
        try f.bootstrap(to: third)
        f.context = old
        let first = try PeerPackage.Context(
            peerID: "first", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("first-generation".utf8)),
            permittedOrigins: origins)
        let second = try PeerPackage.Context(
            peerID: "second", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("second-generation".utf8)),
            permittedOrigins: origins)
        try f.source.configurePeerIntake(peers: [first])
        try f.receiver.configurePeerIntake(peers: [old, first, second])
        try third!.configurePeerIntake(peers: [bootstrap, second])
        let firstID = try Fixture.id()
        let secondID = try Fixture.id()
        let firstClient = try credential(
            first, local: f.origin, remote: receiverID,
            pairingID: firstID, initiator: true, key: 0x51)
        let firstServer = try credential(
            first, local: receiverID, remote: f.origin,
            pairingID: firstID, initiator: false, key: 0x51)
        let secondClient = try credential(
            second, local: thirdID, remote: receiverID,
            pairingID: secondID, initiator: true, key: 0x72)
        let secondServer = try credential(
            second, local: receiverID, remote: thirdID,
            pairingID: secondID, initiator: false, key: 0x72)
        for (store, context, credential) in [
            (f.source!, first, firstClient), (f.receiver!, first, firstServer),
            (third!, second, secondClient), (f.receiver!, second, secondServer),
        ] {
            try store.registerPeerCredential(
                credential, context: context,
                expectedContextToken: store.peerIntakeContextToken(), operationID: Fixture.id())
        }
        try f.capacity()
        let sourceAccounts = ResponderAccounts(f.sourceAccounts)
        let receiverAccounts = ResponderAccounts(f.receiverAccounts)
        let remainingAccounts = ResponderAccounts(thirdAccounts)
        f.source = nil
        f.receiver = nil
        third = nil
        let source = try await coordinator(f.sourceRoot, accounts: sourceAccounts)
        defer { await source.close() }
        let receiver = try await coordinator(f.receiverRoot, accounts: receiverAccounts)
        defer { await receiver.close() }
        let remaining = try await coordinator(thirdRoot, accounts: remainingAccounts)
        defer { await remaining.close() }
        let responder = try PeerExchangeResponder(pairings: [
            await PeerPairing.load(peerID: second.peerID, coordinator: receiver),
            await PeerPairing.load(peerID: first.peerID, coordinator: receiver),
        ])
        let left = try await PeerPairing.load(peerID: first.peerID, coordinator: source)
        let right = try await PeerPairing.load(peerID: second.peerID, coordinator: remaining)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let accepted = LoopbackConnections()
        let clients = LoopbackConnections()
        var settings = PeerExchangeLimits()
        settings.maximumRequests = 8
        settings.maximumWireBytes = 1024 * 1024
        settings.operationSeconds = 5
        settings.sessionSeconds = 15
        let limits = settings
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelInitializer { channel in
                PeerExchangeConnection.install(
                    on: channel, responder: responder,
                    coordinator: receiver, limits: limits
                ).map { accepted.append($0) }
            }.bind(host: "127.0.0.1", port: 0).get()
        defer {
            try? await listener.close().get()
            for connection in clients.snapshot() + accepted.snapshot() {
                try? await connection.close().get()
            }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        for (pairing, coordinator) in [(left, source), (right, remaining)] {
            let installed = LoopbackConnections()
            _ = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
                .channelInitializer { channel in
                    PeerExchangeConnection.install(
                        on: channel, pairing: pairing,
                        coordinator: coordinator, limits: limits
                    ).map {
                        installed.append($0)
                        clients.append($0)
                    }
                }.connect(host: "127.0.0.1", port: port).get()
            let connection = try XCTUnwrap(installed.snapshot().first)
            try await connection.ready.get()
            let response = try await connection.request(.init("inventory")).get()
            XCTAssertNotNil(try JSON.decode([String: ItemValue].self, response)["entries"])
        }
        XCTAssertEqual(accepted.snapshot().count, 2)
        // Both independently authorized physical clients stay connected to this one port.
        for server in accepted.snapshot() {
            try await server.ready.get()
            let response = try await server.request(.init("inventory")).get()
            XCTAssertNotNil(try JSON.decode([String: ItemValue].self, response)["entries"])
        }
        let unknown = try credential(
            first, local: f.origin, remote: receiverID,
            pairingID: Fixture.id(), initiator: true, key: 0x51)
        let wrong = try credential(
            first, local: f.origin, remote: receiverID,
            pairingID: firstID, initiator: true, key: 0x52)
        for input in [unknown, wrong] {
            let pairing = try PeerPairing(credential: input)
            let installed = LoopbackConnections()
            _ = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
                .channelInitializer { channel in
                    PeerExchangeConnection.install(
                        on: channel, pairing: pairing,
                        coordinator: source, limits: limits
                    ).map {
                        installed.append($0)
                        clients.append($0)
                    }
                }.connect(host: "127.0.0.1", port: port).get()
            let connection = try XCTUnwrap(installed.snapshot().first)
            do {
                try await connection.ready.get()
                XCTFail("unpaired or wrong-key client reached application readiness")
            } catch {
                XCTAssertTrue(
                    error as? PeerTLSError == .handshakeRejected
                        || (error as? TractandaError)?.code == "serviceClosed")
            }
        }
        XCTAssertEqual(accepted.snapshot().count, 4)
        try f.capacity()
    }
}
