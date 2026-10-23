import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Real Store permission/header/context callbacks and native writer lock, tiny disposable stores.
/// These cases validate private work only; full writer/publication/replication gates remain separate.
final class AtomicAuthorityStoreValidationTests: XCTestCase {
    private static func draft(_ f: PeerIntakeStoreTests.Fixture, target: Revision, evidenceID: String? = nil)
        throws
        -> (AtomicAuthorityArchive, AtomicAuthorityArchive.Handle, ItemIndex)
    {
        try f.capacity()
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        do {
            let coordinator = PeerIntakeCoordinator(
                root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
            let origin = try XCTUnwrap(f.receiver.replicaID)
            let previous = try XCTUnwrap(index.authorityControlHead(originID: origin))
            let bootstrap = try coordinator.logicalControlHeader(previous, index: index).bootstrap
            var parents = [previous]
            if let source = try index.authorityControlHead(originID: f.origin), source != previous {
                parents.append(source)
            }
            let raw = try XCTUnwrap(
                evidenceID.flatMap { try index.retainedAuthorityObject(id: $0) }
                    ?? index.authorityEvidence(revisionID: target.revisionID))
            let evidence = try AuthorityRecordCodec.decode(coordinator.bytes(raw)).record
            let policies = try
                (AuthorityRecord.list(evidence.payload["admissionPolicies"])
                + AuthorityRecord.list(evidence.payload["itemPolicies"])).map {
                    try AuthorityRecord.binding($0).revisionID
                }
            let delta = try AuthorityStore.DispositionDelta(
                target: .init(
                    itemID: target.itemID,
                    revisionID: target.revisionID,
                    sha256: AuthorityRecordCodec.sha256(try RecordCodec.encode(target))),
                eligible: true, actor: try XCTUnwrap(target.fields["actor"]?.string),
                policyIDs: Array(Set(policies)).sorted(),
                evidence: .init(recordID: raw.descriptor.id, sha256: raw.descriptor.sha256))
            let directory = f.directory.appendingPathComponent(
                "atomic-" + (try PeerIntakeStoreTests.Fixture.id()))
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let archive = try AtomicAuthorityArchive(
                root: directory,
                limits: .init(maximumStoredBytes: 4 * 1024 * 1024, maximumParts: 1024), chunkBytes: 257)
            var p = parents.sorted { $0.recordID < $1.recordID }.map(\.itemValue).makeIterator()
            var d = [delta.itemValue].makeIterator()
            let handle = try archive.build(
                context: .init(
                    rootID: PeerIntakeStoreTests.Fixture.id(),
                    storeID: f.storeID, origin: origin, actor: "user:admin", createdAt: Timestamp.now(),
                    inputIdentity: String(repeating: "a", count: 64), previous: previous, bootstrap: bootstrap
                ),
                parents: { p.next() }, effects: { d.next() })
            return (archive, handle, index)
        } catch {
            index.close()
            throw error
        }
    }

    func testStoreOwnedLocalWindowHonorsRealTaskCancellation() async throws {
        let task = Task { () throws -> Bool in
            let f = try PeerIntakeStoreTests.Fixture()
            try f.bootstrap()
            let (archive, handle, index) = try Self.draft(f, target: f.base)
            defer { index.close() }
            return try f.receiver.withAccess(forUID: tractanda_uid()) {
                let work = try f.receiver.beginAtomicAuthorityValidation(archive: archive, handle: handle)
                defer { try? work.close() }
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try f.receiver.stepAtomicLocalWindowForTesting(
                        work, enclosingVM: 6000, enclosingReadBytes: 1024)
                    return false
                } catch is CancellationError { return true }
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
    }

    func testStoreOwnedLocalWindowsPreserveTinyEnclosingTailAndCompleteAcrossSteps() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let (archive, handle, index) = try Self.draft(f, target: f.base)
        defer { index.close() }
        try f.receiver.withAccess(forUID: tractanda_uid()) {
            let work = try f.receiver.beginAtomicAuthorityValidation(archive: archive, handle: handle)
            defer { try? work.close() }
            var windows = 0
            while !work.complete {
                let sample = try f.receiver.stepAtomicLocalWindowForTesting(
                    work, enclosingVM: 6000, enclosingReadBytes: 1024)
                XCTAssertEqual(sample.readBefore, 1023)
                XCTAssertEqual(sample.readAfter, sample.readBefore)
                XCTAssertEqual(sample.vmAfter, sample.vmBefore)
                windows += 1
                XCTAssertLessThan(windows, 512)
            }
            XCTAssertGreaterThan(windows, 2)
            XCTAssertFalse(try index.hasValidatedAuthorityControl(handle.binding))
        }
        try f.capacity()
    }

    func testActualStoreWorkStagesComparesAndValidatesWithoutAnyAuthorityTransition() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let (archive, handle, index) = try Self.draft(f, target: f.base)
        defer { index.close() }
        try f.receiver.withAccess(forUID: tractanda_uid()) {
            let old = try index.authorityControlHead(originID: XCTUnwrap(f.receiver.replicaID))
            let work = try f.receiver.beginAtomicAuthorityValidation(archive: archive, handle: handle)
            defer { try? work.close() }
            var windows = 0
            while !work.complete {
                _ = try work.step(maximumUnits: 1)
                windows += 1
                XCTAssertLessThan(windows, 512)
            }
            XCTAssertEqual(work.validatedFacts, 1)
            var entered = false
            try work.withFinalWriter {
                plan in
                XCTAssertEqual(plan.binding, handle.binding)
                entered = true
            }
            XCTAssertTrue(entered)
            XCTAssertFalse(try index.hasValidatedAuthorityControl(handle.binding))
            XCTAssertEqual(try index.authorityControlHead(originID: XCTUnwrap(f.receiver.replicaID)), old)
            XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        }
        try f.capacity()
    }

    func testActualStoreWorkRejectsMutationOfAlreadyComparedPrefix() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let (archive, handle, index) = try Self.draft(f, target: f.base)
        defer { index.close() }
        try f.receiver.withAccess(forUID: tractanda_uid()) {
            let work = try f.receiver.beginAtomicAuthorityValidation(archive: archive, handle: handle)
            defer { try? work.close() }
            while work.canonicalComparedFacts == 0 { _ = try work.step(maximumUnits: 1) }
            // Another connection changes the already-compared parent bytes. No current/policy
            // head changes: the stable-stage binding itself must detect this foreign rewrite.
            try index.execute(
                "UPDATE authority_atomic_parent_stage SET sha256=? WHERE root=? AND ordinal=0",
                [String(repeating: "f", count: 64), handle.binding.recordID])
            XCTAssertThrowsError(try work.step(maximumUnits: 1))
            XCTAssertFalse(try index.hasValidatedAuthorityControl(handle.binding))
        }
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
    }
    func testActualStoreOrdinaryPositiveCannotEraseGenuineHeldCompletePRE() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        // The source revokes first; its disconnected receiver then authors with stale rights.
        let revoked = try f.source.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("admin"), .text("alice")]),
            ]), operationID: "atomic-revoke-bob"
        ).revision
        let offline = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) {
            try f.receiver.commit(
                .init(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID, changes: ["subject": .text("stale offline")],
                    operationID: "atomic-offline-bob")
            ).revision
        }
        let oldEvidence = try XCTUnwrap(
            f.receiver.peerMetadataObjects(revisionID: offline.revisionID)
                .first { PeerIntakeStoreTests.Fixture.isEvidence($0, for: offline.revisionID) }
        ).0.id
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: revoked.revisionID)))
        let (archive, handle, index) = try Self.draft(f, target: offline, evidenceID: oldEvidence)
        defer { index.close() }
        XCTAssertEqual(try index.authorityDisposition(id: offline.revisionID)?.disposition, .held)
        try f.receiver.withAccess(forUID: tractanda_uid()) {
            let work = try f.receiver.beginAtomicAuthorityValidation(archive: archive, handle: handle)
            defer { try? work.close() }
            XCTAssertThrowsError(
                try {
                    var windows = 0
                    while !work.complete {
                        _ = try work.step(maximumUnits: 1)
                        windows += 1
                        XCTAssertLessThan(windows, 1024)
                    }
                }()
            ) { error in
                XCTAssertEqual((error as? TractandaError)?.code, "authorityReviewRequired")
            }
            XCTAssertFalse(try index.hasValidatedAuthorityControl(handle.binding))
            XCTAssertEqual(try index.authorityDisposition(id: offline.revisionID)?.disposition, .held)
        }
        try f.capacity()
    }

    func testAtomicGenesisRequiresExactConfiguredBootstrapAndValidatedBaseline() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let index = try ItemIndex(
            path: f.receiverRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = PeerIntakeCoordinator(
            root: f.receiverRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let pin = try XCTUnwrap(coordinator.configuration()?.bootstrap)
        let bootstrap = try AuthorityBinding(recordID: pin.recordID, sha256: pin.sha256)
        let pinnedRaw = try XCTUnwrap(index.retainedAuthorityObject(id: pin.recordID))
        let sourceActor = try AuthorityRecordCodec.decode(coordinator.bytes(pinnedRaw)).record.actorPrincipal
        XCTAssertNotEqual(pin.actor, sourceActor, "Fixture separates receiver approver from source creator")
        func first(_ baseline: AuthorityBinding?) throws -> LogicalControlSource.Header {
            try .init(
                binding: .init(
                    recordID: PeerIntakeStoreTests.Fixture.id(), sha256: String(repeating: "a", count: 64)),
                storeID: f.storeID, origin: PeerIntakeStoreTests.Fixture.id(), actor: "user:admin",
                createdAt: Timestamp.now(), previous: nil, bootstrap: baseline)
        }
        XCTAssertNoThrow(try coordinator.requireAtomicBootstrap(first(bootstrap), index: index))
        XCTAssertThrowsError(try coordinator.requireAtomicBootstrap(first(nil), index: index))
        let ordinary = try XCTUnwrap(index.authorityEvidence(revisionID: f.base.revisionID))
        let wrong = try AuthorityBinding(recordID: ordinary.descriptor.id, sha256: ordinary.descriptor.sha256)
        XCTAssertThrowsError(try coordinator.requireAtomicBootstrap(first(wrong), index: index))
        // A configured pin/retained original is not itself a completed native baseline admission.
        // Removing disposable proof in this tiny guard fixture cannot manufacture that authority.
        try index.execute("DELETE FROM authority_local_bootstrap WHERE pin=?", [pin.recordID])
        XCTAssertThrowsError(try coordinator.requireAtomicBootstrap(first(bootstrap), index: index)) {
            error in
            XCTAssertEqual((error as? TractandaError)?.code, "missingDependencies")
        }
        // A separate uninitialized source has no configured initial pin: self/empty SQL is denied.
        let freshRoot = f.directory.appendingPathComponent("uninitialized")
        var fresh: ItemStore? = try PeerIntakeStoreTests.Fixture.open(freshRoot, f.receiverAccounts)
        let freshOrigin = try XCTUnwrap(fresh?.replicaID)
        let freshIndex = try ItemIndex(
            path: freshRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        defer {
            freshIndex.close()
            fresh = nil
        }
        let localContext = try XCTUnwrap(fresh).peerIntakeContext(peerID: "local")
        let freshCoordinator = PeerIntakeCoordinator(
            root: freshRoot, ownerUID: tractanda_uid(),
            storeID: localContext.storeID)
        let emptyHeader = try LogicalControlSource.Header(
            binding: .init(
                recordID: PeerIntakeStoreTests.Fixture.id(),
                sha256: String(repeating: "b", count: 64)), storeID: freshCoordinator.storeID,
            origin: freshOrigin, actor: "user:admin", createdAt: Timestamp.now(), previous: nil,
            bootstrap: nil)
        XCTAssertThrowsError(try freshCoordinator.requireAtomicBootstrap(emptyHeader, index: freshIndex)) {
            error in
            XCTAssertEqual((error as? TractandaError)?.code, "missingBootstrap")
        }
    }

}
