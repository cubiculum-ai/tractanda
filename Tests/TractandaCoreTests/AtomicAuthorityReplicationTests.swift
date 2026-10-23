import CTractandaPlatform
import XCTest

@testable import TractandaCore

/// Real native founding/prepared-target/registration, then an explicit quiescent floor15
/// transition on both physical replicas. No synthetic acceptance or shared ReplicaID.
final class AtomicAuthorityReplicationTests: XCTestCase {
    final class Fixture {
        let enrolled: PeerEnrollmentActivationTests.Fixture
        let targetAccounts = PeerEnrollmentApprovalTests.Accounts()
        var source: ItemStore { enrolled.source.source }
        var target: ItemStore { enrolled.target! }
        init(nonAdministratorWriter: Bool = false) throws {
            let policy: ItemValue? =
                nonAdministratorWriter
                ? .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("human"), .text("contributor")]),
                    "administration": .text("system"), "administratorGroup": .text("staff"),
                ]) : nil
            let permissions: ItemValue? =
                nonAdministratorWriter
                ? .object([
                    "profile": .text(ItemPermissions.profile), "owner": .text("human"),
                    "group": .text("writers"), "mode": .integer(0o660), "acl": .object([:]),
                ]) : nil
            enrolled = try .init(sourcePolicy: policy, basePermissions: permissions)
            do {
                try enrolled.open()
                try enrolled.transfer()
                _ = try enrolled.finish()
                try enrolled.source.source.registerAcceptedPeerEnrollment(
                    enrolled.handle, forUID: enrolled.source.uid)
                enrolled.closeSession()
                enrolled.target = nil
                enrolled.source.source = nil
                try AtomicAuthorityStoreFixture.transition(enrolled.source.sourceRoot)
                try AtomicAuthorityStoreFixture.transition(enrolled.source.targetRoot)
                enrolled.source.source = try AtomicAuthorityStoreFixture.open(
                    enrolled.source.sourceRoot, accounts: enrolled.source.accounts)
                enrolled.target = try AtomicAuthorityStoreFixture.open(
                    enrolled.source.targetRoot, accounts: targetAccounts)
                try enrolled.source.capacity()
            } catch {
                cleanup()
                throw error
            }
        }
        deinit { cleanup() }
        private func cleanup() {
            enrolled.target = nil
            enrolled.source.source = nil
            if let scan = FileManager.default.enumerator(
                at: enrolled.source.root, includingPropertiesForKeys: nil)
            {
                for case let path as URL in scan {
                    if let metadata = try? FileMetadata.read(at: path), metadata.type == .regular {
                        _ = chmod(path.path, 0o600)
                    }
                }
            }
        }
        func revise(_ parent: Revision, operation: String, subject: String) throws -> Revision {
            let result = try source.withAccess(forUID: enrolled.source.uid) {
                try source.commit(
                    .init(
                        action: .revise, itemID: parent.itemID, expectedRevisionID: parent.revisionID,
                        changes: ["subject": .text(subject)], operationID: operation))
            }
            XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
            return result.revision
        }
        func packet(
            _ revisionID: String, from sender: ItemStore? = nil,
            context suppliedContext: PeerPackage.Context? = nil
        ) throws -> (PeerExportPlan.Handle, PeerPackage.Manifest) {
            let source = sender ?? self.source
            let context = suppliedContext ?? enrolled.material.sourceContext
            let boundary = try source.capturePeerInventory(context: context)
            let handle = try source.beginPeerExport(
                context: context,
                planID: UUID.makeVersion1().uuidString.lowercased(),
                packageID: UUID.makeVersion1().uuidString.lowercased(), boundary: boundary)
            var cursor: PeerInventory.Cursor?
            var selected: PeerInventory.Entry?
            repeat {
                let page = try source.peerInventoryPage(
                    context: context, boundary: boundary, cursor: cursor, limit: 32)
                selected = page.entries.first { $0.descriptor.id == revisionID } ?? selected
                cursor = page.nextCursor
            } while cursor != nil && selected == nil
            _ = try source.selectPeerExport(
                context: context, handle: handle,
                entries: [try XCTUnwrap(selected)], finish: true)
            for call in 0..<2048 {
                if call % 16 == 0 { try enrolled.source.capacity() }
                let status = try source.stepPeerExport(
                    context: context, handle: handle,
                    window: .init(maximumUnits: 4, maximumEdges: 4))
                XCTAssertEqual(status.unsupported, 0)
                if let manifest = status.manifest { return (handle, manifest) }
            }
            throw TractandaError("fixture", "Tiny actual export did not complete its bounded native work")
        }
        func send(
            _ handle: PeerExportPlan.Handle, manifest: PeerPackage.Manifest,
            from sender: ItemStore? = nil, to receiver: ItemStore? = nil,
            outgoing suppliedOutgoing: PeerPackage.Context? = nil,
            incoming suppliedIncoming: PeerPackage.Context? = nil,
            binding suppliedBinding: PeerExchangeBinding? = nil,
            interleaveWhenReady: Bool = false, interleave: (() throws -> Void)? = nil
        ) throws
            -> AuthorityStore.Result
        {
            let source = sender ?? self.source
            let target = receiver ?? self.target
            let outgoing = suppliedOutgoing ?? enrolled.material.sourceContext
            let incoming = suppliedIncoming ?? enrolled.material.targetContext
            let binding = suppliedBinding ?? enrolled.source.request.targetCredential.binding
            _ = try target.beginPeerIntake(context: incoming, manifestBytes: JSON.encode(manifest))
            var cursor: PeerPackage.ResumeCursor?
            var calls = 0
            repeat {
                calls += 1
                guard calls < 2048 else { throw TractandaError("fixture", "Tiny transfer work exhausted") }
                let page = try target.resumePeerIntake(
                    context: incoming, packageID: manifest.packageID,
                    cursor: cursor, limit: 8)
                for slot in page.objects where !slot.verifiedComplete {
                    var offset = slot.nextOffset
                    while offset < slot.descriptor.length {
                        let chunk = try source.readPeerExport(
                            context: outgoing, handle: handle,
                            object: slot.descriptor, offset: offset, maximumBytes: 16 * 1024)
                        guard !chunk.bytes.isEmpty else {
                            throw TractandaError("fixture", "Transfer did not advance")
                        }
                        _ = try target.appendPeerObject(
                            context: incoming, packageID: manifest.packageID,
                            object: slot.descriptor, offset: offset, bytes: chunk.bytes)
                        offset += chunk.bytes.count
                    }
                }
                if !page.blockedOnIndex { cursor = page.nextCursor }
                if !page.blockedOnIndex && cursor == nil { break }
            } while true
            let owner = manifest.packageID + ":intake"
            defer { target.releasePeerLogicalVerification(owner) }
            var interleaved = false
            for call in 0..<4096 {
                if call % 16 == 0 { try enrolled.source.capacity() }
                do {
                    return try target.withPeerLogicalVerification(owner) {
                        try target.withPeerExchange(
                            binding: binding,
                            progress: {}
                        ) { context, _ in
                            try target.commitPeerIntake(
                                context: context, packageID: manifest.packageID,
                                expectedContextToken: target.peerIntakeContextToken())
                        }
                    }
                } catch let error as TractandaError where error.code == "peerSyncYield" {
                    if !interleaved, let interleave,
                        interleaveWhenReady
                            ? target.atomicReceiveProgressForTesting.readyAdmissions > 0
                            : target.atomicReceiveProgressForTesting.privateAdmissions > 0
                    {
                        try interleave()
                        interleaved = true
                    }
                    continue
                }
            }
            throw TractandaError("fixture", "Tiny actual Store intake did not complete private windows")
        }
    }
    func testActualAtomicRevisionTransfersThroughNativeGatewayAndExactRetry() throws {
        let f = try Fixture()
        let revision = try f.revise(
            f.enrolled.revision, operation: "atomic-native-replication", subject: "atomic received revision")
        let (handle, manifest) = try f.packet(revision.revisionID)
        let result = try f.send(handle, manifest: manifest)
        XCTAssertEqual(result.missing, 0)
        XCTAssertEqual(result.held, 0)
        XCTAssertGreaterThanOrEqual(result.accepted, 1)
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(revision.itemID).revisionID
            }, revision.revisionID)
        let again = try f.send(handle, manifest: manifest)
        XCTAssertEqual(again, result)
        XCTAssertEqual(
            try f.source.withAccess(forUID: f.enrolled.source.uid) {
                try f.source.get(revision.itemID).revisionID
            }, revision.revisionID)
        // A new envelope is not a new admission decision. Exchange B's actual local opinion
        // back to A, then resend A's existing authored revision in another fresh envelope.
        func heads() throws -> (AuthorityBinding, AuthorityBinding) {
            let a = try ItemIndex(
                path: f.enrolled.source.sourceRoot.appendingPathComponent("index/items.sqlite").path,
                create: false)
            let b = try ItemIndex(
                path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
                create: false)
            defer {
                a.close()
                b.close()
            }
            return try (
                XCTUnwrap(a.authorityControlHead(originID: XCTUnwrap(f.source.replicaID))),
                XCTUnwrap(b.authorityControlHead(originID: XCTUnwrap(f.target.replicaID)))
            )
        }
        let before = try heads()
        let (opinion, opinionManifest) = try f.packet(
            before.1.recordID, from: f.target,
            context: f.enrolled.material.targetContext)
        let back = try f.send(
            opinion, manifest: opinionManifest, from: f.target, to: f.source,
            outgoing: f.enrolled.material.targetContext, incoming: f.enrolled.material.sourceContext,
            binding: f.enrolled.source.request.sourceCredential.binding)
        XCTAssertEqual(back.missing, 0)
        let (duplicate, duplicateManifest) = try f.packet(revision.revisionID)
        let duplicateResult = try f.send(duplicate, manifest: duplicateManifest)
        XCTAssertEqual(duplicateResult.missing, 0)
        let after = try heads()
        XCTAssertEqual(
            after.0, before.0, "Receiving a foreign opinion about known history cannot mint an A decision")
        XCTAssertEqual(after.1, before.1, "A fresh duplicate envelope cannot mint another B decision")
        try f.enrolled.source.capacity()
    }
    func testActualLocalWriteInterleavesWithPrivateAdmissionWithoutForkOrLostRevision() throws {
        let f = try Fixture()
        let incoming = try f.revise(
            f.enrolled.revision, operation: "atomic-interleaved-incoming",
            subject: "incoming survives local write")
        let (handle, manifest) = try f.packet(incoming.revisionID)
        var concurrent: Revision?
        let result = try f.send(handle, manifest: manifest) {
            let authored = try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text("local write during private receive")],
                        operationID: "atomic-interleaved-local"))
            }
            XCTAssertTrue(authored.isIndexReady, authored.warnings.joined(separator: "\n"))
            concurrent = authored.revision
        }
        XCTAssertEqual(result.missing, 0)
        let local = try XCTUnwrap(concurrent)
        try f.target.withAccess(forUID: f.enrolled.source.uid) {
            XCTAssertEqual(try f.target.get(incoming.itemID).revisionID, incoming.revisionID)
            XCTAssertEqual(try f.target.get(local.itemID).revisionID, local.revisionID)
        }
        let index = try ItemIndex(
            path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        defer { index.close() }
        let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.target.replicaID)))
        let localControl = try XCTUnwrap(index.localAuthorityAcceptanceControl(revisionID: local.revisionID))
        XCTAssertTrue(try index.authorityControlContains(localControl, in: head))
        XCTAssertNotNil(try index.localAuthorityAcceptanceControl(revisionID: incoming.revisionID))
        try f.enrolled.source.capacity()
    }

    func testForeignSourceDecisionDoesNotGrantReceiverMappingDeniedWriteOrHistory() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let parent = f.enrolled.revision
        let edited = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: parent.itemID,
                    expectedRevisionID: parent.revisionID,
                    changes: ["subject": .text("source authorized contributor")],
                    operationID: "atomic-current-denied-contributor"))
        }
        XCTAssertTrue(edited.isIndexReady, edited.warnings.joined(separator: "\n"))
        // One global username, with deliberately divergent local OS group mapping. This is
        // current receiver configuration drift, not a separate administrator/user domain.
        // Real source commit and the received root validator must prove its source-cut group
        // permission from bound evidence; receiver-current write permission remains separate.
        f.targetAccounts.contributorHasWriterGroup = false
        let (handle, manifest) = try f.packet(edited.revision.revisionID)
        let result = try f.send(handle, manifest: manifest)
        XCTAssertGreaterThanOrEqual(result.held, 1)
        XCTAssertEqual(result.missing, 0)
        let index = try ItemIndex(
            path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        defer { index.close() }
        let sourceHead = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        XCTAssertTrue(
            try index.isAcceptedAtomicControl(sourceHead),
            "Exact foreign historical source opinion is accepted")
        XCTAssertEqual(try index.authorityDisposition(id: edited.revision.revisionID)?.disposition, .held)
        XCTAssertNil(try index.revision(edited.revision.revisionID))
        XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: edited.revision.revisionID))
        XCTAssertNil(try index.localAuthorityAcceptanceControl(revisionID: edited.revision.revisionID))
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(parent.itemID).revisionID
            }, parent.revisionID)
        try f.enrolled.source.capacity()
    }

    func testOriginalActorGroupChangeAfterValidationReplansBeforeAcceptedSeal() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let parent = f.enrolled.revision
        let edited = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: parent.itemID,
                    expectedRevisionID: parent.revisionID,
                    changes: ["subject": .text("actor changes before final writer")],
                    operationID: "atomic-between-window-mapping-change"))
        }
        XCTAssertTrue(edited.isIndexReady, edited.warnings.joined(separator: "\n"))
        let (handle, manifest) = try f.packet(edited.revision.revisionID)
        var changed = false
        let result = try f.send(handle, manifest: manifest, interleaveWhenReady: true) {
            // Actual normal semantic validation has completed, but the receiver's proposed
            // local root is still PRIVATE. Its originating actor loses current group rights.
            f.targetAccounts.contributorHasWriterGroup = false
            changed = true
        }
        XCTAssertTrue(changed)
        XCTAssertGreaterThanOrEqual(result.held, 1)
        XCTAssertEqual(result.missing, 0)
        let index = try ItemIndex(
            path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        defer { index.close() }
        XCTAssertEqual(try index.authorityDisposition(id: edited.revision.revisionID)?.disposition, .held)
        XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: edited.revision.revisionID))
        XCTAssertNil(try index.localAuthorityAcceptanceControl(revisionID: edited.revision.revisionID))
        XCTAssertNil(try index.revision(edited.revision.revisionID))
        XCTAssertEqual(
            try f.target.withAccess(forUID: f.enrolled.source.uid) {
                try f.target.get(parent.itemID).revisionID
            }, parent.revisionID)
        try f.enrolled.source.capacity()
    }

    func testPolicyRevocationPublishesLocalNegativeThroughBoundedOutsidePeerSteps() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let revoked = try f.source.withAccess(forUID: f.enrolled.source.uid) {
            try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
                    "administration": .text("system"), "administratorGroup": .text("staff"),
                ]), operationID: "atomic-deferred-revoke-contributor")
        }
        XCTAssertTrue(revoked.isIndexReady, revoked.warnings.joined(separator: "\n"))
        // The disconnected receiver still has the old canonical policy. These UUIDv1
        // originals are genuinely later than the source revocation, not synthetic effects.
        let offline = try f.target.withAccess(forUID: f.targetAccounts.contributor) {
            try f.target.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("offline after revoke")],
                    operationID: "atomic-deferred-offline-create"))
        }
        XCTAssertTrue(offline.isIndexReady, offline.warnings.joined(separator: "\n"))
        var steps = 0
        f.target.afterDeferredAtomicLocalStepForTesting = { outside in
            XCTAssertTrue(outside)
            steps += 1
        }
        defer { f.target.afterDeferredAtomicLocalStepForTesting = nil }
        let (handle, manifest) = try f.packet(revoked.revision.revisionID)
        let received = try f.send(handle, manifest: manifest)
        XCTAssertEqual(received.missing, 0)
        XCTAssertGreaterThan(steps, 2, "A real pending negative must advance across separate local steps")
        let index = try ItemIndex(
            path: f.enrolled.source.targetRoot.appendingPathComponent("index/items.sqlite").path,
            create: false)
        defer { index.close() }
        XCTAssertEqual(try index.authorityDisposition(id: offline.revision.revisionID)?.disposition, .held)
        let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.target.replicaID)))
        XCTAssertTrue(try index.isAcceptedAtomicControl(head))
        XCTAssertEqual(try index.eligibilityAtCut(revisionID: offline.revision.revisionID, cut: head), .held)
        XCTAssertTrue(try index.atomicPendingEffectPage(limit: 1).isEmpty)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.enrolled.source.targetRoot))
        try f.enrolled.source.capacity()
    }

    func testSourceCutCannotTurnUnadmittedPositiveQueueEntryIntoLocalGrant() throws {
        let f = try Fixture(nonAdministratorWriter: true)
        let parent = f.enrolled.revision
        let edit = try f.source.withAccess(forUID: f.enrolled.source.accounts.contributor) {
            try f.source.commit(
                .init(
                    action: .revise, itemID: parent.itemID,
                    expectedRevisionID: parent.revisionID, changes: ["subject": .text("source only")],
                    operationID: "atomic-source-cut-positive-guard"))
        }
        XCTAssertTrue(edit.isIndexReady, edit.warnings.joined(separator: "\n"))
        f.targetAccounts.contributorHasWriterGroup = false
        let (packet, manifest) = try f.packet(edit.revision.revisionID)
        _ = try f.send(packet, manifest: manifest)
        let root = f.enrolled.source.targetRoot
        let index = try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
        defer { index.close() }
        let coordinator = PeerIntakeCoordinator(
            root: root, ownerUID: tractanda_uid(), storeID: f.enrolled.material.sourceContext.storeID)
        let origin = try XCTUnwrap(f.target.replicaID)
        let previous = try XCTUnwrap(index.authorityControlHead(originID: origin))
        let cause = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: edit.revision.revisionID))
        XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: raw.descriptor.id))
        // Deliberate invalid private queue input, not a claimed genuine effect or authority grant.
        // All canonical records and the held/current-denied original above are real native paths.
        let positive = try AuthorityStore.DispositionDelta(
            target: .init(
                itemID: edit.revision.itemID, revisionID: edit.revision.revisionID,
                sha256: raw.descriptor.sha256),
            eligible: true, actor: edit.revision.fields["actor"]!.string!, policyIDs: [], causes: [cause])
        try index.noteAuthorityDispositionEffect(positive)
        let pending = try index.atomicPendingEffectPage(limit: 128)
        let directory = f.enrolled.source.root.appendingPathComponent("private-positive-guard")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let archive = try AtomicAuthorityArchive(
            root: directory,
            limits: .init(maximumStoredBytes: 4 * 1024 * 1024, maximumParts: 1024))
        XCTAssertThrowsError(
            try coordinator.prepareAtomicSourceCut(
                index: index, archive: archive,
                reservation: .init(
                    rootID: UUID.makeVersion1().uuidString.lowercased(), storeID: coordinator.storeID,
                    origin: origin, actor: "replica:" + origin, createdAt: Timestamp.now(),
                    inputIdentity: String(repeating: "a", count: 64), previous: previous,
                    bootstrap: coordinator.logicalControlHeader(previous, index: index).bootstrap))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "authorityReviewRequired")
        }
        XCTAssertEqual(try index.atomicPendingEffectPage(limit: 128), pending)
        XCTAssertEqual(try index.authorityControlHead(originID: origin), previous)
        XCTAssertFalse(try index.authorityHasLocalHistoryAdmission(revisionID: raw.descriptor.id))
        XCTAssertEqual(try index.authorityDisposition(id: raw.descriptor.id)?.disposition, .held)
        try f.enrolled.source.capacity()
    }

}
