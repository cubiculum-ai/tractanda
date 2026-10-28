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
    private let values = Mutex<[PersonalPeerConnection]>([])
    func append(_ value: PersonalPeerConnection) { values.withLock { $0.append(value) } }
    func snapshot() -> [PersonalPeerConnection] { values.withLock { $0 } }
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
        // Current wire only: distinct replica identities and two independent PSKs, no retired
        // authority-store genesis, metadata intake, compatibility declaration or cloned store.
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        let storeID = try id()
        let receiverID = try id()
        let firstID = try id()
        let secondID = try id()
        let firstPairing = try id()
        let secondPairing = try id()
        let digest = String(repeating: "a", count: 64)
        func credential(_ replica: String, pairing: String, initiator: Bool, key: UInt8) throws
            -> PeerCredential
        {
            try PeerCredential(
                binding: .init(
                    peerID: initiator ? "receiver" : replica, storeID: storeID,
                    localReplicaID: initiator ? replica : receiverID,
                    remoteReplicaID: initiator ? receiverID : replica,
                    pairingID: pairing, localIsInitiator: initiator, configurationDigest: digest),
                secret: [UInt8](repeating: key, count: 32))
        }
        let first = try credential(firstID, pairing: firstPairing, initiator: true, key: 0x51)
        let second = try credential(secondID, pairing: secondPairing, initiator: true, key: 0x72)
        let responder = try PeerExchangeResponder(pairings: [
            PeerPairing(credential: credential(firstID, pairing: firstPairing, initiator: false, key: 0x51)),
            PeerPairing(
                credential: credential(secondID, pairing: secondPairing, initiator: false, key: 0x72)),
        ])
        let handoffs = Mutex(0)
        let operations = PersonalPeerOperations(
            validate: { binding in
                XCTAssertEqual(binding.storeID, storeID)
                XCTAssertTrue([receiverID, firstID, secondID].contains(binding.remoteReplicaID))
            },
            handle: { _, request in
                XCTAssertEqual(request.operation, "personal.sync.ready")
                handoffs.withLock { $0 += 1 }
                return Data("{\"ready\":true}".utf8)
            })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let accepted = LoopbackConnections()
        let clients = LoopbackConnections()
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelInitializer { channel in
                PersonalPeerConnection.install(on: channel, responder: responder, operations: operations)
                    .map { accepted.append($0) }
            }.bind(host: "127.0.0.1", port: 0).get()
        defer {
            try? await listener.close().get()
            for connection in clients.snapshot() + accepted.snapshot() {
                try? await connection.close().get()
            }
        }
        let port = try XCTUnwrap(listener.localAddress?.port)
        for credential in [first, second] {
            let pairing = try PeerPairing(credential: credential)
            let installed = LoopbackConnections()
            _ = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
                .channelInitializer { channel in
                    PersonalPeerConnection.install(on: channel, pairing: pairing, operations: operations)
                        .map {
                            installed.append($0)
                            clients.append($0)
                        }
                }.connect(host: "127.0.0.1", port: port).get()
            let connection = try XCTUnwrap(installed.snapshot().first)
            let ready = try await connection.ready.get()
            XCTAssertEqual(ready.remoteReplicaID, receiverID)
            let response = try await connection.request(.init("personal.sync.ready")).get()
            XCTAssertEqual(try JSON.decode([String: Bool].self, response)["ready"], true)
        }
        XCTAssertEqual(accepted.snapshot().count, 2)
        for server in accepted.snapshot() {
            let ready = try await server.ready.get()
            XCTAssertTrue([firstID, secondID].contains(ready.remoteReplicaID))
            let response = try await server.request(.init("personal.sync.ready")).get()
            XCTAssertEqual(try JSON.decode([String: Bool].self, response)["ready"], true)
        }
        XCTAssertEqual(handoffs.withLock { $0 }, 4)
        let unknown = try credential(firstID, pairing: id(), initiator: true, key: 0x51)
        let wrong = try credential(firstID, pairing: firstPairing, initiator: true, key: 0x52)
        for input in [unknown, wrong] {
            let pairing = try PeerPairing(credential: input)
            let installed = LoopbackConnections()
            _ = try await ClientBootstrap(group: group).connectTimeout(.seconds(3))
                .channelInitializer { channel in
                    PersonalPeerConnection.install(on: channel, pairing: pairing, operations: operations)
                        .map {
                            installed.append($0)
                            clients.append($0)
                        }
                }.connect(host: "127.0.0.1", port: port).get()
            let connection = try XCTUnwrap(installed.snapshot().first)
            do {
                _ = try await connection.ready.get()
                XCTFail("unpaired or wrong-key client reached application readiness")
            } catch {
                XCTAssertTrue(
                    error as? PeerTLSError == .handshakeRejected
                        || (error as? TractandaError)?.code == "serviceClosed")
            }
            try await connection.closed.get()
            XCTAssertEqual(handoffs.withLock { $0 }, 4, "Rejected TLS must never enter current application")
        }
        XCTAssertEqual(accepted.snapshot().count, 4)
        // Invalid handshakes cannot evict either independently authenticated client.
        for connection in clients.snapshot().prefix(2) { XCTAssertTrue(connection.isActive) }
    }
}
