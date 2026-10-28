import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

final class PersonalEnrollmentRuntimeTests: XCTestCase {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else { throw PersonalEnrollmentError.invalid() }
            return .init(uid: uid, name: "owner", primaryGroupName: "staff", groupIDs: [72001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "owner" else { throw PersonalEnrollmentError.invalid() }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw PersonalEnrollmentError.invalid() }; return 72001
        }
    }
    private final class Connections: Sendable {
        let values = Mutex<[PersonalPeerConnection]>([])
        func add(_ value: PersonalPeerConnection) { values.withLock { $0.append(value) } }
        var first: PersonalPeerConnection? { values.withLock { $0.first } }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func runtimeFixture(peers: [PeerRuntimeConfiguration.Peer] = [],
        _ body: (URL, PersonalPeerRuntime, ServiceCoordinator, MultiThreadedEventLoopGroup) async throws -> Void) async throws {
        try PeerFixtureCapacity.requireFree()
        let root = URL(fileURLWithPath: "/tmp/trac121-runtime-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store"), accounts = Accounts()
        do {
            _ = try ItemStore.initializePersonalWorkgroup(root: storeRoot, accounts: accounts,
                accessConfiguration: .object(["profile": .text(AccessConfiguration.profile), "users": .list([.text("owner")])]))
        }
        let coordinator = try await ServiceCoordinator(opening: storeRoot, makeAccountDirectory: { accounts })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let runtime = try PersonalPeerRuntime(configuration: .init(listen: .init(host: "127.0.0.1", port: 48732), peers: peers),
            configurationPath: root.appendingPathComponent("unchanged-runtime.json").path,
            coordinator: coordinator, group: group)
        await runtime.activate()
        await runtime.refreshNow()
        do { try await body(root, runtime, coordinator, group) }
        catch { await runtime.close(); await coordinator.close(); try? await group.shutdownGracefully(); throw error }
        await runtime.close(); await coordinator.close(); try await group.shutdownGracefully()
        let counts = await runtime.enrollmentCountsForTesting()
        XCTAssertEqual(counts.sessions, 0); XCTAssertEqual(counts.dials, 0); XCTAssertEqual(counts.slots, 0)
    }
    func testConfiguredNodeLocalAlternativesTakePriorityOverSharedPlanRoutes() async throws {
        let remote = try id(), digest = String(repeating: "a", count: 64)
        let local = try PeerRuntimeConfiguration.Peer(alias: remote + "-dial", host: "remote.lan", port: 48732,
            fallbackEndpoints: [.init(host: "remote.tailnet", port: 48733)])
        let global = try PeerRuntimeConfiguration.Endpoint(host: "remote.public", port: 48734)
        let operation = try id()
        try await runtimeFixture(peers: [local]) { _, runtime, coordinator, _ in
            let identity = try JSON.decode(PersonalSyncIdentity.self,
                await coordinator.personalPeerLocalRequest(.init("identity"), forUID: tractanda_uid()))
            await runtime.setEnrollmentBridge(material: {
                .init(routes: .init(operationID: operation, configurationDigest: digest, endpoints: [remote: [global]]))
            }, validate: { _, _ in }, handle: { _, _, _ in Data("{}".utf8) })
            let binding = try PeerExchangeBinding(peerID: remote + "-dial", storeID: identity.storeID,
                localReplicaID: identity.replicaID, remoteReplicaID: remote, pairingID: id(),
                localIsInitiator: true, configurationDigest: digest)
            let endpoints = await runtime.endpointsForTesting(binding)
            XCTAssertEqual(endpoints, local.endpoints)
        }
    }

    func testConsumedInvitationReplyFlushesBeforeEOFAndCannotAdmitAnotherCall() async throws {
        try await runtimeFixture { root, runtime, _, group in
            let metadata = try PersonalEnrollmentInvitationMetadata(operationID: id(), storeID: id(),
                issuerReplicaID: id(), bootstrapReplicaID: id(), pairingID: id(),
                endpoints: [.init(host: "source.fixture", port: 48732)], expiresAt: 100_000,
                expectedMembershipDigest: nil)
            let invitation = try PersonalEnrollmentInvitation(metadata: metadata,
                secret: .init(bytes: Array(repeating: 0x67, count: 32)))
            let local = try PersonalEnrollmentPeerMaterial.invitation(invitation, localIsIssuer: true)
            let remote = try PersonalEnrollmentPeerMaterial.invitation(invitation, localIsIssuer: false)
            let live = Mutex(true), calls = Mutex(0)
            await runtime.setEnrollmentBridge(material: {
                .init(privatePeers: live.withLock { $0 } ? [local] : [])
            }, validate: { binding, purpose in
                guard live.withLock({ $0 }), binding == local.binding, purpose == .invitation else {
                    throw TractandaError("untrustedPeer", "Consumed fixture invitation")
                }
            }, handle: { _, purpose, request in
                XCTAssertEqual(purpose, .invitation); XCTAssertEqual(request.operation, "enrollment.claim")
                calls.withLock { $0 += 1 }; live.withLock { $0 = false }
                // Withdraw the actual listener context while the handler still owns the
                // accepted claim. Its committed response must drain before EOF.
                await runtime.refreshNow()
                return Data("{\"accepted\":true}".utf8)
            })
            let socket = root.appendingPathComponent("private.sock").path
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                runtime.install(on: channel)
            }.bind(unixDomainSocketPath: socket).get()
            defer { try? await listener.close().get() }
            let clients = Connections()
            let ops = PersonalPeerOperations(validate: { _ in throw PersonalEnrollmentError.invalid() },
                handle: { _, _ in throw PersonalEnrollmentError.invalid() },
                enrollmentValidate: { _, purpose in XCTAssertEqual(purpose, .invitation) },
                enrollmentHandle: { _, _, _ in throw PersonalEnrollmentError.invalid() })
            let pairing = try PeerPairing(enrollment: remote)
            _ = try await ClientBootstrap(group: group).channelInitializer { channel in
                PersonalPeerConnection.install(on: channel, pairing: pairing, operations: ops)
                    .map { clients.add($0) }
            }.connect(unixDomainSocketPath: socket).get()
            let connection = try XCTUnwrap(clients.first)
            defer { try? await connection.close().get() }
            _ = try await connection.ready.get()
            let claim = PersonalEnrollmentClaim(metadata: .init(operationID: metadata.operationID,
                targetReplicaID: try id(), targetHostname: "target.fixture", continuationPairingID: try id()),
                continuationSecret: try .init(bytes: Array(repeating: 0x78, count: 32)))
            let request = PeerExchangeRequest("enrollment.claim", ["claim": .bytes(try claim.privateEncodedBytes())])
            let bytes = try await connection.request(request).get()
            XCTAssertEqual(try JSON.decode([String: Bool].self, bytes)["accepted"], true)
            try await connection.closed.get()
            XCTAssertEqual(calls.withLock { $0 }, 1)
            do { _ = try await connection.request(request).get(); XCTFail("Consumed connection accepted another claim") }
            catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
            let status = try await runtime.operatorStatus()
            XCTAssertEqual(status.incomingConnectionCount, 0)
            XCTAssertEqual(status.outgoingConnectionCount, 0)
            XCTAssertTrue(status.personalPeers?.isEmpty ?? true)
        }
    }

    func testIssuerPushAndCancellationUseTheSingleTargetInitiatedContinuationSocket() async throws {
        try await runtimeFixture { root, runtime, _, group in
            let metadata = try PersonalEnrollmentInvitationMetadata(operationID: id(), storeID: id(),
                issuerReplicaID: id(), bootstrapReplicaID: id(), pairingID: id(),
                endpoints: [.init(host: "source.fixture", port: 48732)], expiresAt: 1,
                expectedMembershipDigest: nil)
            let claim = PersonalEnrollmentClaim(metadata: .init(operationID: metadata.operationID,
                targetReplicaID: try id(), targetHostname: "target.fixture", continuationPairingID: try id()),
                continuationSecret: try .init(bytes: Array(repeating: 0x78, count: 32)))
            let local = try PersonalEnrollmentPeerMaterial.continuation(invitation: metadata, claim: claim, localIsIssuer: true)
            let remote = try PersonalEnrollmentPeerMaterial.continuation(invitation: metadata, claim: claim, localIsIssuer: false)
            let calls = Mutex(0), holding = Mutex(false)
            await runtime.setEnrollmentBridge(material: { .init(privatePeers: [local]) }, validate: { binding, purpose in
                XCTAssertEqual(binding, local.binding); XCTAssertEqual(purpose, .continuation)
            }, handle: { _, _, _ in Data("{}".utf8) })
            let socket = root.appendingPathComponent("continuation.sock").path
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { runtime.install(on: $0) }
                .bind(unixDomainSocketPath: socket).get()
            defer { try? await listener.close().get() }
            let clients = Connections(), pairing = try PeerPairing(enrollment: remote)
            let ops = PersonalPeerOperations(validate: { _ in throw PersonalEnrollmentError.invalid() },
                handle: { _, _ in throw PersonalEnrollmentError.invalid() },
                enrollmentValidate: { binding, purpose in
                    XCTAssertEqual(binding, remote.binding); XCTAssertEqual(purpose, .continuation)
                }, enrollmentHandle: { _, _, request in
                    calls.withLock { $0 += 1 }
                    if request.operation == "enrollment.target.status" {
                        holding.withLock { $0 = true }
                        try await Task.sleep(for: .seconds(86_400))
                        try Task.checkCancellation()
                    }
                    return Data("{\"staged\":true}".utf8)
                })
            _ = try await ClientBootstrap(group: group).channelInitializer { channel in
                PersonalPeerConnection.install(on: channel, pairing: pairing, operations: ops).map { clients.add($0) }
            }.connect(unixDomainSocketPath: socket).get()
            let connection = try XCTUnwrap(clients.first)
            defer { try? await connection.close().get() }
            _ = try await connection.ready.get()
            while await runtime.enrollmentCountsForTesting().sessions == 0 {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(1))
            }
            let response = try await runtime.privateRequest(binding: local.binding,
                request: .init("enrollment.target.stage", ["operationID": .text(metadata.operationID),
                    "payload": .bytes(Data("{}".utf8))]))
            XCTAssertEqual(try JSON.decode([String: Bool].self, response)["staged"], true)
            let counts = await runtime.enrollmentCountsForTesting()
            XCTAssertEqual(counts.sessions, 1); XCTAssertEqual(counts.dials, 0)
            XCTAssertEqual(calls.withLock { $0 }, 1)
            let pending = Task {
                try await runtime.privateRequest(binding: local.binding,
                    request: .init("enrollment.target.status", ["operationID": .text(metadata.operationID)]))
            }
            while !holding.withLock({ $0 }) {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(1))
            }
            pending.cancel()
            switch await pending.result {
            case .success: XCTFail("Cancelled private request succeeded")
            case .failure: break
            }
            try await connection.closed.get()
            XCTAssertEqual(calls.withLock { $0 }, 2)
        }
    }

    func testRetainedControlCredentialCannotRunOrdinaryMethodsOrAppearAsDataSession() async throws {
        try await runtimeFixture { root, runtime, coordinator, group in
            let identity = try JSON.decode(PersonalSyncIdentity.self,
                await coordinator.personalPeerLocalRequest(.init("identity"), forUID: tractanda_uid()))
            let remoteID = try id(), pairingID = try id(), digest = String(repeating: "a", count: 64)
            let localBinding = try PeerExchangeBinding(peerID: "exact-retained-in", storeID: identity.storeID,
                localReplicaID: identity.replicaID, remoteReplicaID: remoteID, pairingID: pairingID,
                localIsInitiator: false, configurationDigest: digest)
            let remoteBinding = try PeerExchangeBinding(peerID: "exact-retained-out", storeID: identity.storeID,
                localReplicaID: remoteID, remoteReplicaID: identity.replicaID, pairingID: pairingID,
                localIsInitiator: true, configurationDigest: digest)
            let local = try PeerCredential(binding: localBinding, secret: Array(repeating: 0x67, count: 32))
            let remote = try PeerCredential(binding: remoteBinding, secret: Array(repeating: 0x67, count: 32))
            let calls = Mutex(0), exactJobStillCurrent = Mutex(true)
            await runtime.setEnrollmentBridge(material: { .init(retainedControlCredentials: [local]) },
                validate: { binding, purpose in
                    guard exactJobStillCurrent.withLock({ $0 }), binding == localBinding, purpose == .memberControl else {
                        throw TractandaError("untrustedPeer", "The exact retained operation is no longer current.")
                    }
                }, handle: { _, _, request in
                    XCTAssertEqual(request.operation, "enrollment.member.inspect")
                    calls.withLock { $0 += 1 }; return Data("{\"supported\":true}".utf8)
                })
            let socket = root.appendingPathComponent("retained.sock").path
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { runtime.install(on: $0) }
                .bind(unixDomainSocketPath: socket).get()
            defer { try? await listener.close().get() }
            let clients = Connections(), pairing = try PeerPairing(credential: remote)
            let ops = PersonalPeerOperations(validate: { _ in }, handle: { _, _ in Data("{}".utf8) })
            _ = try await ClientBootstrap(group: group).channelInitializer { channel in
                PersonalPeerConnection.install(on: channel, pairing: pairing, operations: ops).map { clients.add($0) }
            }.connect(unixDomainSocketPath: socket).get()
            let connection = try XCTUnwrap(clients.first)
            defer { try? await connection.close().get() }
            _ = try await connection.ready.get()
            let request = PeerExchangeRequest("enrollment.member.inspect", ["operationID": .text(try id())])
            _ = try await connection.request(request).get()
            XCTAssertEqual(calls.withLock { $0 }, 1)
            do { _ = try await connection.request(.init("personal.sync.ready")).get(); XCTFail("Retained context entered ordinary peer methods") }
            catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
            // A denied ordinary read does not consume exact-job control authority.
            _ = try await connection.request(request).get()
            XCTAssertEqual(calls.withLock { $0 }, 2)
            // A fresh domain proof may reject a job after unrelated membership drift,
            // even while the cached responder material still contains its old PSK.
            exactJobStillCurrent.withLock { $0 = false }
            do { _ = try await connection.request(request).get(); XCTFail("Stale exact-job proof remained admitted") }
            catch { XCTAssertEqual(calls.withLock { $0 }, 2) }
            let rejected = Connections()
            let second = try await ClientBootstrap(group: group).channelInitializer { channel in
                PersonalPeerConnection.install(on: channel, pairing: pairing, operations: ops).map { rejected.add($0) }
            }.connect(unixDomainSocketPath: socket).get()
            defer { try? await second.close().get() }
            do { _ = try await XCTUnwrap(rejected.first).ready.get(); XCTFail("Old PSK bypassed fresh exact-job proof") }
            catch { XCTAssertEqual(calls.withLock { $0 }, 2) }
            let status = try await runtime.operatorStatus()
            XCTAssertEqual(status.incomingConnectionCount, 0); XCTAssertEqual(status.outgoingConnectionCount, 0)
            XCTAssertTrue(status.personalPeers?.isEmpty ?? true)
        }
    }

    func testPrivateDialsAndUnauthenticatedHandshakesShareTheSame64ConnectionCap() async throws {
        try await runtimeFixture { root, runtime, _, group in
            func invitation() throws -> PersonalEnrollmentInvitation {
                try .init(metadata: .init(operationID: id(), storeID: id(), issuerReplicaID: id(),
                    bootstrapReplicaID: id(), pairingID: id(), endpoints: [.init(host: "source.fixture", port: 48732)],
                    expiresAt: 100_000, expectedMembershipDigest: nil), secret: .init(bytes: Array(repeating: 0x67, count: 32)))
            }
            let incomingInvitation = try invitation(), outgoingInvitation = try invitation()
            let incoming = try PersonalEnrollmentPeerMaterial.invitation(incomingInvitation, localIsIssuer: true)
            let outgoing = try PersonalEnrollmentPeerMaterial.invitation(outgoingInvitation, localIsIssuer: false)
            let mutations = Mutex(0)
            await runtime.setEnrollmentBridge(material: { .init(privatePeers: [incoming, outgoing]) },
                validate: { _, _ in }, handle: { _, _, _ in mutations.withLock { $0 += 1 }; return Data("{}".utf8) })
            let socket = root.appendingPathComponent("capacity.sock").path
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { runtime.install(on: $0) }
                .bind(unixDomainSocketPath: socket).get()
            defer { try? await listener.close().get() }
            var channels: [any Channel] = []
            defer { for channel in channels { try? await channel.close().get() } }
            for count in 1...64 {
                channels.append(try await ClientBootstrap(group: group).connect(unixDomainSocketPath: socket).get())
                while await runtime.enrollmentCountsForTesting().slots < count {
                    try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(1))
                }
            }
            let full = await runtime.enrollmentCountsForTesting()
            XCTAssertEqual(full.slots, 64)
            let claim = PersonalEnrollmentClaim(metadata: .init(operationID: outgoingInvitation.metadata.operationID,
                targetReplicaID: try id(), targetHostname: "target.fixture", continuationPairingID: try id()),
                continuationSecret: try .init(bytes: Array(repeating: 0x78, count: 32)))
            do {
                _ = try await runtime.privateRequest(binding: outgoing.binding,
                    request: .init("enrollment.claim", ["claim": .bytes(try claim.privateEncodedBytes())]))
                XCTFail("Private dialing bypassed the shared connection cap")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit") }
            XCTAssertEqual(mutations.withLock { $0 }, 0)
        }
    }

    func testOverlayCannotChangeListenPolicyAndBadMaterialDisablesOnlyEnrollment() async throws {
        try await runtimeFixture { _, runtime, _, _ in
            let old = try await runtime.operatorStatus()
            let route = PersonalEnrollmentRouteState(operationID: try id(), configurationDigest: String(repeating: "a", count: 64),
                endpoints: [try id(): [try .init(host: "different.fixture", port: 12345)]])
            await runtime.setEnrollmentBridge(material: { .init(routes: route) }, validate: { _, _ in },
                handle: { _, _, _ in Data("{}".utf8) })
            let endpoints = try await runtime.effectiveOwnEndpoints(hostname: "source.fixture")
            XCTAssertEqual(endpoints, [try .init(host: "source.fixture", port: 48732)])
            let routed = try await runtime.operatorStatus()
            XCTAssertEqual(old.settingsDigest, routed.settingsDigest)
            await runtime.setEnrollmentBridge(material: { throw TractandaError("secret-value", "secret-value") },
                validate: { _, _ in }, handle: { _, _, _ in Data("{}".utf8) })
            let failed = try await runtime.operatorStatus()
            XCTAssertEqual(failed.state, .active)
            XCTAssertEqual(failed.settingsDigest, old.settingsDigest)
            XCTAssertEqual(failed.lastErrorCode, "enrollmentRuntimeUnavailable")
            XCTAssertFalse(String(decoding: try JSON.encode(failed), as: UTF8.self).contains("secret-value"))
        }
    }
}
