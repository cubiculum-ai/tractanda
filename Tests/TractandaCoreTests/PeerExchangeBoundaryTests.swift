import XCTest

@testable import TractandaCore

private actor CompatibilityAdoptionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func hold(_ entered: XCTestExpectation) async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class PeerExchangeBoundaryTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func fixture() throws -> Fixture {
        try Fixture(directory: GuardedFixtureDirectory.create(prefix: "c", source: "PeerExchangeBoundaryTests", test: name))
    }

    private func state(_ fixture: Fixture) throws -> PeerExchangeState {
        try fixture.bootstrap()
        let local = try XCTUnwrap(fixture.receiver.replicaID)
        let binding = try PeerExchangeBinding(
            peerID: fixture.context.peerID, storeID: fixture.storeID,
            localReplicaID: local, remoteReplicaID: fixture.origin,
            pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: fixture.context.configurationDigest)
        let result = try fixture.receiver.withPeerExchange(
            binding: binding, progress: {},
            { _, security in
                var state = PeerExchangeState(binding: binding, securityBinding: security)
                let declaration = try state.compatibility.advance(.declare, store: fixture.receiver, storeID: binding.storeID)
                let ack = try state.compatibility.advance(.accept(declaration), store: fixture.receiver, storeID: binding.storeID)
                _ = try state.compatibility.advance(.acknowledge(ack), store: fixture.receiver, storeID: binding.storeID)
                return state
            })
        return result
    }

    private func perform(
        _ request: Data, fixture: Fixture, state: inout PeerExchangeState,
        control: PeerExchangeControl? = nil
    ) throws -> Data {
        try fixture.receiver.withPeerExchange(
            binding: state.binding, expectedSecurity: state.securityBinding, progress: {},
            { context, _ in
                try state.perform(
                    request, store: fixture.receiver, context: context,
                    control: control ?? PeerExchangeControl())
            })
    }

    func testWireSchemaRejectsMalformedAndAuthorityInjectionBeforeInventory() throws {
        let fixture = try fixture()
        var state = try self.state(fixture)
        let before = try fixture.receiver.exportCatalogueForVerification().map(\.revisionID)
        let injected = [
            #"{"operation":"inventory","fields":{},"context":{},"uid":51001,"permittedOrigins":[]}"#,
            #"{"operation":"inventory","fields":{},"uid":"51001"}"#,
            #"{"operation":"inventory","fields":{"context":{}}}"#,
            #"{"operation":"inventory","fields":[]}"#,
        ]
        for wire in injected {
            XCTAssertThrowsError(try perform(Data(wire.utf8), fixture: fixture, state: &state))
        }
        XCTAssertEqual(try fixture.receiver.exportCatalogueForVerification().map(\.revisionID), before)
        try fixture.capacity()
    }

    func testBindingMustMatchCurrentStoreReplicaPeerAndConfiguration() throws {
        let fixture = try fixture()
        try fixture.bootstrap()
        let local = try XCTUnwrap(fixture.receiver.replicaID)
        let valid = try PeerExchangeBinding(
            peerID: fixture.context.peerID, storeID: fixture.storeID,
            localReplicaID: local, remoteReplicaID: fixture.origin,
            pairingID: Fixture.id(), localIsInitiator: false,
            configurationDigest: fixture.context.configurationDigest)
        let variants = [
            try PeerExchangeBinding(
                peerID: valid.peerID, storeID: try Fixture.id(), localReplicaID: local,
                remoteReplicaID: fixture.origin, pairingID: valid.pairingID,
                localIsInitiator: false, configurationDigest: valid.configurationDigest),
            try PeerExchangeBinding(
                peerID: valid.peerID, storeID: valid.storeID, localReplicaID: try Fixture.id(),
                remoteReplicaID: fixture.origin, pairingID: valid.pairingID,
                localIsInitiator: false, configurationDigest: valid.configurationDigest),
            try PeerExchangeBinding(
                peerID: valid.peerID, storeID: valid.storeID, localReplicaID: local,
                remoteReplicaID: try Fixture.id(), pairingID: valid.pairingID,
                localIsInitiator: false, configurationDigest: valid.configurationDigest),
            try PeerExchangeBinding(
                peerID: valid.peerID, storeID: valid.storeID, localReplicaID: local,
                remoteReplicaID: fixture.origin, pairingID: valid.pairingID,
                localIsInitiator: false,
                configurationDigest: AuthorityRecordCodec.sha256(Data("stale".utf8))),
        ]
        for binding in variants {
            XCTAssertThrowsError(
                try fixture.receiver.withPeerExchange(binding: binding, progress: {}) { _, _ in true })
        }
        XCTAssertTrue(try fixture.receiver.withPeerExchange(binding: valid, progress: {}) { _, _ in true })
        try fixture.capacity()
    }

    func testCancellationAndExpiredDeadlineLeaveCanonicalInventoryUnchanged() throws {
        let fixture = try fixture()
        var state = try self.state(fixture)
        let before = try fixture.receiver.exportCatalogueForVerification().map(\.revisionID)
        let request = try JSON.encode(PeerExchangeRequest("inventory"))
        let cancelled = try PeerExchangeControl()
        cancelled.cancel()
        XCTAssertThrowsError(try perform(request, fixture: fixture, state: &state, control: cancelled)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "cancelled")
        }
        let expired = try PeerExchangeControl(maximumSeconds: 0.000_001)
        Thread.sleep(forTimeInterval: 0.002)
        XCTAssertThrowsError(try perform(request, fixture: fixture, state: &state, control: expired)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "deadlineExceeded")
        }
        XCTAssertEqual(try fixture.receiver.exportCatalogueForVerification().map(\.revisionID), before)
        try fixture.capacity()
    }

    func testCredentialRotationInvalidatesOldStateAndAllowsOrdinaryWrite() throws {
        let fixture = try fixture()
        var state = try self.state(fixture)
        let oldSecurity = state.securityBinding
        let replacement = try PeerPackage.Context(
            peerID: fixture.context.peerID, storeID: fixture.context.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("rotated-boundary".utf8)),
            permittedOrigins: fixture.context.permittedOrigins)
        try fixture.receiver.rotatePeerIntakeCredential(
            peerID: replacement.peerID, replacement: replacement, operationID: try Fixture.id())
        XCTAssertThrowsError(
            try fixture.receiver.withPeerExchange(
                binding: state.binding, expectedSecurity: oldSecurity, progress: {}
            ) { context, security in
                try state.perform(
                    JSON.encode(PeerExchangeRequest("inventory")), store: fixture.receiver,
                    context: context, control: PeerExchangeControl())
            }
        ) {
            XCTAssertTrue(
                ["peerConfigurationChanged", "unknownPeer"].contains(($0 as? TractandaError)?.code ?? ""))
        }
        let revision = try fixture.receiver.withAccess(forUID: fixture.receiverAccounts.alice) {
            try fixture.receiver.commit(
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("unrelated local write")],
                    operationID: try Fixture.id())
            ).revision
        }
        XCTAssertEqual(try fixture.receiver.get(revision.itemID), revision)
        try fixture.capacity()
    }
    func testDirectCoreGatewayRequiresMutualAdmissionAndRechecksAdvancedOrMissingFloor() async throws {
        let f = try fixture()
        var state = try self.state(f)
        state.compatibility = PeerExchangeCompatibility()
        let inventory = try JSON.encode(PeerExchangeRequest("inventory"))
        XCTAssertThrowsError(try perform(inventory, fixture: f, state: &state)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerCompatibilityRequired")
        }
        let root = f.receiverRoot
        f.receiver = nil
        let coordinator = try await ServiceCoordinator(opening: root, embeddingProviderForTesting: nil,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        defer { await coordinator.close() }
        let control = try PeerExchangeControl()
        do { try await coordinator.authorizePeerExchange(state, control: control); XCTFail("Direct authorize bypassed admission") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        do { _ = try await coordinator.peerSyncWork(state: state, replacement: nil, control: control); XCTFail("Direct sync work bypassed admission") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        let gateway = try await PeerExchangeGateway(coordinator: coordinator, binding: state.binding)
        do { _ = try await gateway.execute(inventory, control: control); XCTFail("Gateway bypassed admission") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        do { _ = try await gateway.advanceCompatibility(.acknowledge(Data()), control: control); XCTFail("Early acknowledgement accepted") }
        catch {}
        let declaration = try await gateway.advanceCompatibility(.declare, control: control)
        do { _ = try await gateway.advanceCompatibility(.declare, control: control); XCTFail("Duplicate declaration accepted") }
        catch {}
        let acknowledgement = try await gateway.advanceCompatibility(.accept(declaration), control: control)
        _ = try await gateway.advanceCompatibility(.acknowledge(acknowledgement), control: control)
        _ = try await gateway.execute(inventory, control: control)
        let floor = root.appendingPathComponent(CanonicalReaderRequirement.fileName)
        let original = try Data(contentsOf: floor)
        defer { try? original.write(to: floor) }
        let prior = try JSON.decode(CanonicalReaderRequirement.self, original)
        let advanced = CanonicalReaderRequirement(storeID: prior.storeID, minimumReaderLevel: 15,
            recordFormats: prior.recordFormats, capabilities: prior.capabilities)
        // Model a newer writer's durable floor; no newer item is published by this fixture.
        try JSON.encode(advanced).write(to: floor)
        do { _ = try await gateway.execute(inventory, control: control); XCTFail("Advanced floor did not fence ordinary exchange") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "incompatibleCanonicalReader") }
        do { try await gateway.authorize(control: control); XCTFail("Advanced floor did not fence delivery") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "incompatibleCanonicalReader") }
        try FileManager.default.removeItem(at: floor)
        let newGateway = try await PeerExchangeGateway(coordinator: coordinator, binding: state.binding)
        do { _ = try await newGateway.advanceCompatibility(.declare, control: control); XCTFail("Missing floor was inferred") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        try original.write(to: floor)
        try f.capacity()
    }

    func testOpaqueAdmissionHandoffFencesFullIdentityLifetimeAndOwnerAwait() async throws {
        let f = try fixture()
        var initial = try self.state(f)
        initial.compatibility = PeerExchangeCompatibility()
        let empty = initial, binding = initial.binding
        f.receiver = nil
        let coordinator = try await ServiceCoordinator(opening: f.receiverRoot, embeddingProviderForTesting: nil,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { PeerIntakeStoreTests.Accounts() })
        defer { await coordinator.close() }
        let control = try PeerExchangeControl()
        func admitted() async throws -> (PeerCompatibilityLifetime, PeerCompatibilityAdmission) {
            // Core-only handshake fixture. The existing Server reconnect case exercises actual TLS handoff.
            let gateway = try await PeerExchangeGateway(coordinator: coordinator, binding: binding)
            let declaration = try await gateway.advanceCompatibility(.declare, control: control)
            let wrongProfile = Data(String(decoding: declaration, as: UTF8.self)
                .replacingOccurrences(of: PeerCompatibilityDeclaration.semanticProfile, with: "tractanda.peer-exchange.v1").utf8)
            do { _ = try await gateway.advanceCompatibility(.accept(wrongProfile), control: control); XCTFail("Wrong semantic profile admitted") }
            catch {}
            do { _ = try await gateway.compatibilityAdmission(lifetime: PeerCompatibilityLifetime(), control: control); XCTFail("Absent mutual acknowledgement minted proof") }
            catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
            let acknowledgement = try await gateway.advanceCompatibility(.accept(declaration), control: control)
            _ = try await gateway.advanceCompatibility(.acknowledge(acknowledgement), control: control)
            let lifetime = PeerCompatibilityLifetime()
            return (lifetime, try await gateway.compatibilityAdmission(lifetime: lifetime, control: control))
        }
        let (oldLifetime, proof) = try await admitted()
        let wrongPair = try PeerExchangeBinding(peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: Fixture.id(), localIsInitiator: binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        let wrongRole = try PeerExchangeBinding(peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: !binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        let wrongStore = try PeerExchangeBinding(peerID: binding.peerID, storeID: Fixture.id(),
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        let wrongConfiguration = try PeerExchangeBinding(peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: binding.localIsInitiator,
            configurationDigest: AuthorityRecordCodec.sha256(Data("different configuration".utf8)))
        let wrongPeer = try PeerExchangeBinding(peerID: "different-peer", storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        let wrongLocal = try PeerExchangeBinding(peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: Fixture.id(), remoteReplicaID: binding.remoteReplicaID,
            pairingID: binding.pairingID, localIsInitiator: binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        let wrongRemote = try PeerExchangeBinding(peerID: binding.peerID, storeID: binding.storeID,
            localReplicaID: binding.localReplicaID, remoteReplicaID: Fixture.id(),
            pairingID: binding.pairingID, localIsInitiator: binding.localIsInitiator,
            configurationDigest: binding.configurationDigest)
        for wrong in [wrongPair, wrongRole, wrongStore, wrongConfiguration, wrongPeer, wrongLocal, wrongRemote] {
            do { _ = try await coordinator.adoptPeerCompatibility(proof, expectedBinding: wrong, state: empty, control: control); XCTFail("Wrong full identity adopted") }
            catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        }
        let adopted = try await coordinator.adoptPeerCompatibility(proof, expectedBinding: binding, state: empty, control: control)
        try await coordinator.authorizePeerExchange(adopted, control: control)
        oldLifetime.cancel()
        do { _ = try await coordinator.adoptPeerCompatibility(proof, expectedBinding: binding, state: empty, control: control); XCTFail("Closed admission adopted") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        do { try await coordinator.authorizePeerExchange(adopted, control: control); XCTFail("Post-adoption close did not fence delivery") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        do { _ = try await coordinator.peerSyncWork(state: adopted, replacement: nil, control: control); XCTFail("Post-adoption close did not fence work") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        let (replacementLifetime, replacement) = try await admitted()
        let fresh = try await coordinator.adoptPeerCompatibility(replacement, expectedBinding: binding, state: empty, control: control)
        oldLifetime.cancel()
        try await coordinator.authorizePeerExchange(fresh, control: control)
        let floor = f.receiverRoot.appendingPathComponent(CanonicalReaderRequirement.fileName)
        let originalFloor = try Data(contentsOf: floor)
        defer { try? originalFloor.write(to: floor) }
        let prior = try JSON.decode(CanonicalReaderRequirement.self, originalFloor)
        try JSON.encode(CanonicalReaderRequirement(storeID: prior.storeID, minimumReaderLevel: 15,
            recordFormats: prior.recordFormats, capabilities: prior.capabilities)).write(to: floor)
        do { _ = try await coordinator.adoptPeerCompatibility(replacement, expectedBinding: binding, state: empty, control: control); XCTFail("Advanced floor admitted handoff") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "incompatibleCanonicalReader") }
        try originalFloor.write(to: floor)
        let gate = CompatibilityAdoptionGate(), entered = expectation(description: "adoption owner held")
        await coordinator.setPeerExchangeAuthorizationHookForTesting { await gate.hold(entered) }
        defer { await gate.release(); await coordinator.setPeerExchangeAuthorizationHookForTesting(nil) }
        let pending = Task { try await coordinator.adoptPeerCompatibility(replacement,
            expectedBinding: binding, state: empty, control: control) }
        await fulfillment(of: [entered], timeout: 5)
        replacementLifetime.cancel()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Close across owner await published adoption") }
        catch { XCTAssertEqual((error as? TractandaError)?.code, "peerCompatibilityRequired") }
        try f.capacity()
    }

}
