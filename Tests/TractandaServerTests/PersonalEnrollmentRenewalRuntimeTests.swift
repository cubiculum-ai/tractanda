import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

final class PersonalEnrollmentRenewalRuntimeTests: XCTestCase, @unchecked Sendable {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else { throw PersonalEnrollmentError.invalid() }
            return .init(uid: uid, name: "admin", primaryGroupName: "staff", groupIDs: [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard name == "admin" else { throw PersonalEnrollmentError.invalid() }
            return try user(forUID: tractanda_uid())
        }
        func groupID(named name: String) throws -> UInt32 { 74001 }
    }
    private actor ValidationGate {
        private var blocked = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func block() {
            blocked = true
            entered = false
        }
        func pass() async {
            guard blocked else { return }
            entered = true
            await withCheckedContinuation { waiters.append($0) }
        }
        func hasEntered() -> Bool { entered }
        func release() {
            blocked = false
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }
    private final class Controls: Sendable {
        let clock = Mutex<Int64>(1_021)
        let appCalls = Mutex(0)
        let gate = ValidationGate()
    }
    private struct Fixture: Sendable {
        let root: URL
        let sourceRoot: URL
        let targetRoot: URL
        let source: ServiceCoordinator
        let target: ServiceCoordinator
        let sourceRuntime: PersonalPeerRuntime
        let targetRuntime: PersonalPeerRuntime
        let probe: PersonalEnrollmentInvitation
        let pending: PersonalEnrollmentClaim
        let pendingInvitation: PersonalEnrollmentInvitationMetadata
        let controls: Controls
        var probeBinding: PeerExchangeBinding {
            get throws { try PersonalEnrollmentPeerMaterial.invitation(probe, localIsIssuer: false).binding }
        }
        var pendingBinding: PeerExchangeBinding {
            get throws {
                try PersonalEnrollmentPeerMaterial.continuation(
                    invitation: pendingInvitation,
                    claim: pending, localIsIssuer: false
                ).binding
            }
        }
    }
    private var policy: ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")]),
        ])
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func unusedPort(_ group: MultiThreadedEventLoopGroup) async throws -> Int {
        let socket = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(socket.localAddress?.port)
        try await socket.close().get()
        return port
    }
    private func fingerprints(_ root: URL) throws -> [String: String] {
        let directory = root.appendingPathComponent(".personal-enrollment")
        var result: [String: String] = [:]
        for path in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        {
            if try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[path.lastPathComponent] = PersonalSyncValidation.digest(try Data(contentsOf: path))
            }
        }
        return result
    }
    private func fixtureBytes(_ root: URL) throws -> UInt64 {
        var bytes: UInt64 = 0
        let entries = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        for case let file as URL in entries {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if value.isRegularFile == true { bytes += UInt64(value.fileSize ?? 0) }
        }
        return bytes
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await condition()) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw TractandaError("fixtureWait", "Finite loopback fixture observation did not complete.")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func controlCancelled(_ control: PeerExchangeControl) async throws {
        try await waitUntil { (try? control.check()) == nil }
    }
    private func fixture(
        blockedProbeWithClaimedPending: Bool = false,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        try PeerFixtureCapacity.requireFree()
        #if os(macOS)
            let temporary = URL(fileURLWithPath: "/private/tmp")
        #else
            let temporary = URL(fileURLWithPath: "/tmp")
        #endif
        let root = temporary.appendingPathComponent("trac121-renewal-" + String(UUID().uuidString.prefix(8)))
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let controls = Controls()
        var blackhole: (any Channel)?
        var listenerOwner: (any Channel)?
        var sourceOwner: ServiceCoordinator?
        var targetOwner: ServiceCoordinator?
        var sourceNetwork: PersonalPeerRuntime?
        var targetNetwork: PersonalPeerRuntime?
        func cleanup() async {
            await controls.gate.release()
            try? await listenerOwner?.close().get()
            try? await blackhole?.close().get()
            await targetNetwork?.close()
            await sourceNetwork?.close()
            await targetOwner?.close()
            await sourceOwner?.close()
            try? await group.shutdownGracefully()
        }
        do {
            let port = try await unusedPort(group)
            if blockedProbeWithClaimedPending {
                blackhole = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            }
            let accounts = Accounts()
            let sourceRoot = root.appendingPathComponent("source")
            let targetRoot = root.appendingPathComponent("target")
            let probe: PersonalEnrollmentInvitation
            let pending: PersonalEnrollmentClaim
            let pendingInvitation: PersonalEnrollmentInvitationMetadata
            do {
                let source = try ItemStore.initializePersonalWorkgroup(
                    root: sourceRoot, accounts: accounts, accessConfiguration: policy)
                let authorization = try PersonalEnrollmentLocalAuthorization.authorize(
                    store: source, forUID: tractanda_uid())
                let issuer = PersonalEnrollmentRegistry(root: sourceRoot, ownerUID: tractanda_uid())
                func issue(_ now: Int64) throws -> PersonalEnrollmentInvitation {
                    try issuer.issue(
                        authorization: authorization, endpoints: [.init(host: "localhost", port: port)],
                        now: now, lifetimeSeconds: 10)
                }
                let first = try issue(1_000)
                let target = try ItemStore.createJoiningPersonalSyncReplica(
                    root: targetRoot,
                    indexDirectory: root.appendingPathComponent("target-index"),
                    storeID: first.metadata.storeID,
                    accessConfiguration: policy, accounts: accounts)
                let registry = PersonalEnrollmentTargetRegistry(root: targetRoot)
                _ = try registry.begin(
                    store: target, forUID: tractanda_uid(), invitation: first, hostname: "target.fixture")
                let second = try issue(1_010)
                _ = try registry.beginReplacement(
                    store: target, forUID: tractanda_uid(), invitation: second,
                    hostname: "target.fixture", now: 1_011)
                pending = try XCTUnwrap(registry.replacementRuntimeMaterial(store: target)?.2)
                pendingInvitation = second.metadata
                if let blackhole {
                    // Models an invalid user-supplied probe while the older grant really is
                    // accepted. Its endpoint never completes TLS; it cannot authorize state.
                    _ = try issuer.claim(
                        pending, authenticatedInvitation: second.metadata, authorization: authorization,
                        now: 1_011)
                    probe = try .init(
                        metadata: .init(
                            operationID: id(), storeID: first.metadata.storeID,
                            issuerReplicaID: first.metadata.issuerReplicaID, bootstrapReplicaID: id(),
                            pairingID: id(),
                            endpoints: [
                                .init(host: "localhost", port: XCTUnwrap(blackhole.localAddress?.port))
                            ],
                            expiresAt: 1_050, expectedMembershipDigest: nil,
                            unusedFamilyID: first.metadata.familyID), secret: .generate())
                } else {
                    probe = try issue(1_020)
                }
                _ = try registry.beginReplacement(
                    store: target, forUID: tractanda_uid(), invitation: probe,
                    hostname: "target.fixture", now: 1_021)
            }
            let source = try await ServiceCoordinator(opening: sourceRoot, makeAccountDirectory: { accounts })
            sourceOwner = source
            let target = try await ServiceCoordinator(
                opening: targetRoot, indexDirectory: root.appendingPathComponent("target-index"),
                makeAccountDirectory: { accounts })
            targetOwner = target
            let sourceRuntime = try PersonalPeerRuntime(
                configuration: .init(), configurationPath: "private-source-fixture",
                coordinator: source, group: group)
            sourceNetwork = sourceRuntime
            let targetRuntime = try PersonalPeerRuntime(
                configuration: .init(), configurationPath: "private-target-fixture",
                coordinator: target, group: group)
            targetNetwork = targetRuntime
            await sourceRuntime.activate()
            await targetRuntime.activate()
            await sourceRuntime.setEnrollmentBridge(
                material: {
                    try await source.personalEnrollmentRuntimeMaterial(now: controls.clock.withLock { $0 })
                },
                validate: { binding, purpose in
                    await controls.gate.pass()
                    try await source.personalEnrollmentValidateTransport(
                        binding, purpose: purpose, now: controls.clock.withLock { $0 })
                },
                handle: { _, purpose, request in
                    controls.appCalls.withLock { $0 += 1 }
                    guard purpose == .continuation, request.operation == "enrollment.job.status" else {
                        throw TractandaError("unsupportedPeerOperation", "Fixture never accepts a claim RPC.")
                    }
                    return try JSON.encode(["operationID": pending.metadata.operationID])
                })
            await targetRuntime.setEnrollmentBridge(
                material: {
                    try await target.personalEnrollmentRuntimeMaterial(now: controls.clock.withLock { $0 })
                },
                validate: { binding, purpose in
                    try await target.personalEnrollmentValidateTransport(
                        binding, purpose: purpose, now: controls.clock.withLock { $0 })
                }, handle: { _, _, _ in throw PersonalEnrollmentError.invalid() })
            let listener = try await ServerBootstrap(group: group).childChannelInitializer {
                sourceRuntime.install(on: $0)
            }
            .bind(host: "127.0.0.1", port: port).get()
            listenerOwner = listener
            let values = Fixture(
                root: root, sourceRoot: sourceRoot, targetRoot: targetRoot, source: source, target: target,
                sourceRuntime: sourceRuntime, targetRuntime: targetRuntime, probe: probe, pending: pending,
                pendingInvitation: pendingInvitation, controls: controls)
            try await body(values)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
        XCTAssertLessThanOrEqual(try fixtureBytes(root), PeerFixtureCapacity.fixtureCapBytes)
        try PeerFixtureCapacity.requireFree()
    }

    func testActualTLSHelloReadyIsSingleUseAndIssuesNoClaimRPC() async throws {
        try await fixture { f in
            let before = try fingerprints(f.targetRoot)
            let proof = try await f.targetRuntime.authenticateRenewalProbe(binding: f.probeBinding)
            XCTAssertEqual(proof.binding, try f.probeBinding)
            let control = try proof.consume()
            XCTAssertNoThrow(try control.check())
            XCTAssertThrowsError(try proof.consume()) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentConflict")
            }
            XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 0)
            XCTAssertEqual(try fingerprints(f.targetRoot), before)
            // This Core publication uses the control from the actual authenticated ready
            // event above, not a fabricated expected binding or status counter.
            try await f.target.personalEnrollmentAcceptRenewal(binding: proof.binding, control: control)
            let state = try await f.target.personalEnrollmentHostState()
            XCTAssertEqual(state.replacement?.invitation, f.probe.metadata)
            XCTAssertNil(state.renewal)
            XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 0)
        }
    }

    func testCachedReadyCannotBypassFreshIssuerExpiryConsumptionOrRotation() async throws {
        for invalidation in ["expired", "consumed", "rotated"] {
            try await fixture { f in
                let before = try fingerprints(f.targetRoot)
                let cached = try await f.targetRuntime.authenticateRenewalProbe(binding: f.probeBinding)
                let cachedControl = try cached.consume()
                if invalidation == "expired" {
                    f.controls.clock.withLock { $0 = f.probe.metadata.expiresAt }
                } else if invalidation == "consumed" {
                    let claim = PersonalEnrollmentClaim(
                        metadata: .init(
                            operationID: f.probe.metadata.operationID,
                            targetReplicaID: f.pending.metadata.targetReplicaID,
                            targetHostname: "target.fixture",
                            continuationPairingID: try id()), continuationSecret: try .generate())
                    let local = try PersonalEnrollmentPeerMaterial.invitation(f.probe, localIsIssuer: true)
                    _ = try await f.source.personalEnrollmentClaim(claim, binding: local.binding, now: 1_022)
                } else {
                    f.controls.clock.withLock { $0 = f.probe.metadata.expiresAt }
                    _ = try await f.source.personalEnrollmentIssue(
                        forUID: tractanda_uid(),
                        endpoints: f.probe.metadata.endpoints, now: f.probe.metadata.expiresAt)
                }
                // Deliberately do not refresh the issuer Runtime: the installed TLS context
                // remains cached, so rejection must come from actual fresh admission.
                do {
                    _ = try await f.targetRuntime.authenticateRenewalProbe(binding: f.probeBinding)
                    XCTFail("Cached invitation readiness bypassed fresh issuer state")
                } catch {}
                try await controlCancelled(cachedControl)
                XCTAssertEqual(try fingerprints(f.targetRoot), before)
                XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 0)
            }
        }
    }

    func testDisconnectCancelsConsumedProofBeforeCorePublication() async throws {
        try await fixture { f in
            let before = try fingerprints(f.targetRoot)
            let proof = try await f.targetRuntime.authenticateRenewalProbe(binding: f.probeBinding)
            let control = try proof.consume()
            await f.sourceRuntime.close()
            try await controlCancelled(control)
            do {
                try await f.target.personalEnrollmentAcceptRenewal(binding: proof.binding, control: control)
                XCTFail("Disconnected proof permitted candidate publication")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "cancelled") }
            XCTAssertEqual(try fingerprints(f.targetRoot), before)
            XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 0)
        }
    }

    func testCancelledHandshakeAndWrongPurposeCannotMutateTarget() async throws {
        try await fixture { f in
            let before = try fingerprints(f.targetRoot)
            do {
                _ = try await f.targetRuntime.authenticateRenewalProbe(binding: f.pendingBinding)
                XCTFail("Continuation accepted as invitation probe")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
            await f.controls.gate.block()
            let probe = Task { try await f.targetRuntime.authenticateRenewalProbe(binding: f.probeBinding) }
            do { try await waitUntil { await f.controls.gate.hasEntered() } } catch {
                probe.cancel()
                await f.controls.gate.release()
                _ = await probe.result
                throw error
            }
            probe.cancel()
            await f.controls.gate.release()
            switch await probe.result {
            case .success: XCTFail("Cancelled handshake returned usable proof")
            case .failure: break
            }
            XCTAssertEqual(try fingerprints(f.targetRoot), before)
            XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 0)
        }
    }

    func testEmptyCacheBlockedProbeDoesNotBlockActualAcceptedOlderContinuation() async throws {
        try await fixture(blockedProbeWithClaimedPending: true) { f in
            let probeBinding = try f.probeBinding
            let before = try fingerprints(f.targetRoot)
            let initial = await f.targetRuntime.enrollmentCountsForTesting()
            XCTAssertEqual(initial.sessions, 0)
            let completed = Mutex(false)
            let recovery = Task {
                defer { completed.withLock { $0 = true } }
                return try await PersonalEnrollmentRuntime.raceRenewalRecovery(
                    retained: [
                        {
                            let data = try await f.targetRuntime.privateRequest(
                                binding: f.pendingBinding,
                                request: .init(
                                    "enrollment.job.status",
                                    ["operationID": .text(f.pending.metadata.operationID)]))
                            guard
                                try JSON.decode([String: String].self, data)["operationID"]
                                    == f.pending.metadata.operationID
                            else {
                                throw PersonalEnrollmentError.conflict()
                            }
                            return .continuation(try f.pendingBinding)
                        }
                    ],
                    probe: {
                        .renewal(try await f.targetRuntime.authenticateRenewalProbe(binding: probeBinding))
                    })
            }
            do { try await waitUntil { completed.withLock { $0 } } } catch {
                recovery.cancel()
                await f.targetRuntime.cancelRenewalProbe(binding: probeBinding)
                await f.targetRuntime.close()
                _ = await recovery.result
                throw error
            }
            let result = try await recovery.value
            guard case .continuation(let actual) = result else {
                return XCTFail("Blocked probe displaced a live older grant")
            }
            XCTAssertEqual(actual, try f.pendingBinding)
            XCTAssertEqual(f.controls.appCalls.withLock { $0 }, 1)
            XCTAssertEqual(
                try fingerprints(f.targetRoot), before,
                "Transport observation alone must not publish target state.")
            await f.targetRuntime.cancelRenewalProbe(binding: probeBinding)
            try await f.target.personalEnrollmentConfirmRetainedContinuation(binding: actual)
            let state = try await f.target.personalEnrollmentHostState()
            XCTAssertEqual(state.target?.invitation.operationID, f.pending.metadata.operationID)
            XCTAssertEqual(state.target?.phase, .claimed)
            XCTAssertNil(state.replacement)
            XCTAssertNil(state.renewal)
            let counts = await f.targetRuntime.enrollmentCountsForTesting()
            XCTAssertEqual(counts.dials, 0)
        }
    }
}
