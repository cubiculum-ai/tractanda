import CTractandaPlatform
import Crypto
import XCTest

@testable import TractandaCore

final class PersonalSyncTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 54001, bob: UInt32 = 54002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case tractanda_uid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture account")
            }
            return .init(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: tractanda_uid())
            case "alice": return try user(forUID: alice)
            case "bob": return try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture account")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 74001
        }
    }
    private final class Node {
        let root: URL
        var store: ItemStore?
        init(root: URL, store: ItemStore) {
            self.root = root
            self.store = store
        }
    }
    private struct Pair {
        let first: Node, second: Node
        let configuration: PersonalMembershipConfiguration
        let preparationA: PersonalMembershipPreparation, preparationB: PersonalMembershipPreparation
        let bindingA: PeerExchangeBinding, bindingB: PeerExchangeBinding
        var a: ItemStore { first.store! }
        var b: ItemStore { second.store! }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func policy() -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("alice"), .text("bob")]),
        ])
    }
    private func permissions(_ mode: Int64 = 0o666, owner: String = "alice") -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, "\($0)", file: file, line: line)
        }
    }
    private func fixture(commit: Bool = true, _ body: (Pair, Accounts) throws -> Void) throws {
        // Estimate <24MiB for two native indexes, tiny histories and one600KiB original.
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-sync-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        let accounts = Accounts()
        let aRoot = root.appendingPathComponent("a")
        let bRoot = root.appendingPathComponent("b")
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        var a: ItemStore? = try ItemStore(
            personalRoot: aRoot, opening: .fresh(policy()), accounts: accounts, recoveryLimits: limits)
        let identityA = try a!.personalSyncIdentity()
        var b: ItemStore? = try ItemStore.createPersonalSyncReplica(
            root: bRoot, storeID: identityA.storeID,
            accessConfiguration: policy(), accounts: accounts)
        let identityB = try b!.personalSyncIdentity()
        let configuration = try PersonalMembershipConfiguration(
            storeID: identityA.storeID, configurationID: id(),
            members: [
                .init(replicaID: identityA.replicaID, hostname: "raven.fixture"),
                .init(replicaID: identityB.replicaID, hostname: "stash.fixture"),
            ])
        let nonce = try id()
        let pa = try a!.preparePersonalMembershipChange(
            configuration: configuration, expectedDigest: nil, nonce: nonce)
        let pb = try b!.preparePersonalMembershipChange(
            configuration: configuration, expectedDigest: nil, nonce: nonce)
        let pairing = try id()
        let digest = try configuration.digest
        let bindingA = try PeerExchangeBinding(
            peerID: "other", storeID: identityA.storeID,
            localReplicaID: identityA.replicaID, remoteReplicaID: identityB.replicaID,
            pairingID: pairing, localIsInitiator: true, configurationDigest: digest)
        let bindingB = try PeerExchangeBinding(
            peerID: "other", storeID: identityA.storeID,
            localReplicaID: identityB.replicaID, remoteReplicaID: identityA.replicaID,
            pairingID: pairing, localIsInitiator: false, configurationDigest: digest)
        try a!.registerPersonalPeerCredentials(
            [PeerCredential(binding: bindingA, secret: [UInt8](repeating: 42, count: 32))],
            configuration: configuration)
        try b!.registerPersonalPeerCredentials(
            [PeerCredential(binding: bindingB, secret: [UInt8](repeating: 42, count: 32))],
            configuration: configuration)
        let pair = Pair(
            first: Node(root: aRoot, store: a!), second: Node(root: bRoot, store: b!),
            configuration: configuration, preparationA: pa, preparationB: pb, bindingA: bindingA,
            bindingB: bindingB)
        a = nil
        b = nil
        defer {
            pair.first.store = nil
            pair.second.store = nil
            try? FileManager.default.removeItem(at: root)
        }
        if commit { try commitPair(pair) }
        try body(pair, accounts)
        var bytes: UInt64 = 0
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            let value = try FileMetadata.read(at: url)
            if value.type == .regular { bytes += value.size }
        }
        XCTAssertLessThan(bytes, UInt64(128 * 1024 * 1024))
    }
    private func commitPair(_ pair: Pair) throws {
        let readyB = try pair.b.personalMembershipReady(
            session: pair.bindingB, preparation: pair.preparationA)
        let ackB = try PersonalMembershipOnlineAcknowledgement(
            binding: pair.bindingA, response: readyB,
            control: .commitCompletion())
        _ = try pair.a.commitPersonalMembershipChange(
            preparation: pair.preparationA, acknowledgements: [ackB])
        // First node is already committed and has removed pending; second still receives fresh readiness.
        let readyA = try pair.a.personalMembershipReady(
            session: pair.bindingA, preparation: pair.preparationB)
        let ackA = try PersonalMembershipOnlineAcknowledgement(
            binding: pair.bindingB, response: readyA,
            control: .commitCompletion())
        _ = try pair.b.commitPersonalMembershipChange(
            preparation: pair.preparationB, acknowledgements: [ackA])
    }
    private func create(
        _ store: ItemStore, accounts: Accounts, subject: String = "base", operation: String = "create",
        permission: ItemValue? = nil
    ) throws -> Revision {
        try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                .init(
                    classID: "Item",
                    changes: ["subject": .text(subject), "permissions": permission ?? permissions()],
                    operationID: operation)
            ).revision
        }
    }
    private func descriptor(_ store: ItemStore, revision: Revision) throws -> PersonalObjectDescriptor {
        let row = try XCTUnwrap(
            store.exportCatalogueForVerification().first { $0.revisionID == revision.revisionID })
        return try .init(
            kind: .revision, id: row.revisionID, byteCount: Int64(row.size),
            sha256: row.digest.map { String(format: "%02x", $0) }.joined(), itemID: row.itemID,
            parentRevisionIDs: row.provenance?.parents ?? row.parentID.map { [$0] } ?? [])
    }
    private func transfer(
        _ object: PersonalObjectDescriptor, from source: ItemStore, to target: ItemStore,
        sourceBinding: PeerExchangeBinding, targetBinding: PeerExchangeBinding
    ) throws {
        let start = try target.preparePersonalObject(session: targetBinding, descriptor: object)
        if start.complete { return }
        var offset = start.nextOffset
        while offset < object.byteCount {
            try AttachmentFixtureCapacity.requireFree(at: target.root)
            let bytes = try source.readPersonalObject(
                session: sourceBinding, descriptor: object, offset: offset)
            let progress = try target.appendPersonalObject(
                session: targetBinding, descriptor: object, offset: offset, data: bytes)
            XCTAssertEqual(progress.nextOffset, offset + Int64(bytes.count))
            offset = progress.nextOffset
        }
        var pageOffset = 0
        while true {
            let page = try source.personalDependencies(
                session: sourceBinding, descriptor: object, offset: pageOffset)
            for dependency in page.entries {
                try transfer(
                    dependency, from: source, to: target, sourceBinding: sourceBinding,
                    targetBinding: targetBinding)
                if dependency.kind == .revision {
                    _ = try target.applyPersonalRevision(session: targetBinding, descriptor: dependency)
                }
            }
            if page.complete { break }
            pageOffset = try XCTUnwrap(page.nextOffset)
        }
        let progress = try target.finishPersonalObject(session: targetBinding, descriptor: object)
        XCTAssertTrue(progress.complete)
        if object.kind == .revision { XCTAssertFalse(progress.knownRevision) }
    }
    @discardableResult
    private func send(
        _ revision: Revision, from source: ItemStore, to target: ItemStore,
        sourceBinding: PeerExchangeBinding, targetBinding: PeerExchangeBinding
    ) throws -> PersonalApplyResult {
        let object = try descriptor(source, revision: revision)
        try transfer(
            object, from: source, to: target, sourceBinding: sourceBinding, targetBinding: targetBinding)
        return try target.applyPersonalRevision(session: targetBinding, descriptor: object)
    }
    private func raw(
        parent: Revision? = nil, actor: String = "user:alice", permission: ItemValue? = nil,
        changes: [String: ItemValue] = [:]
    ) throws -> Revision {
        var fields =
            try parent?.fields ?? [
                "itemID": .text(id()), "createdAt": .date("2026-10-25T10:00:00Z"),
                "classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("raw"),
            ]
        fields["revisionID"] = .text(try id())
        fields["actor"] = .text(actor)
        fields["modifiedAt"] = .date(parent == nil ? "2026-10-25T10:00:00Z" : "2026-10-25T10:00:01Z")
        fields["operationID"] = .text(try id())
        fields["requestIdentity"] = .text("raw fixture")
        fields["permissions"] = permission ?? permissions()
        if let parent { fields["supersedes"] = .text(parent.revisionID) }
        fields.merge(changes) { _, value in value }
        fields.removeValue(forKey: "revisionAncestry")
        return try Revision(fields: fields)
    }
    private func save(_ revision: Revision, root: URL) throws {
        try AttachmentFixtureCapacity.requireFree(at: root)
        let bytes = try RecordCodec.encode(revision)
        XCTAssertLessThan(bytes.count, 1024 * 1024)
        try DocumentContentFiles(
            root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024
        )
        .writeImmutable(
            bytes,
            path: [
                "items", "2026", "10", "25", "10", "00", revision.itemID, revision.revisionID + ".tractanda",
            ], maximumBytes: 1024 * 1024)
    }

    func testPendingMembershipCannotServeDataAndNeedsEveryLiveAcknowledgement() throws {
        try fixture(commit: false) { pair, _ in
            try pair.a.validatePersonalPeerBinding(pair.bindingA, controlOnly: true)
            assertCode("untrustedPeer") { _ = try pair.a.capturePersonalInventory(session: pair.bindingA) }
            assertCode("membersOffline") {
                _ = try pair.a.commitPersonalMembershipChange(
                    preparation: pair.preparationA, acknowledgements: [])
            }
            let response = try pair.b.personalMembershipReady(
                session: pair.bindingB, preparation: pair.preparationA)
            let control = PeerExchangeControl.commitCompletion()
            control.cancel()
            let ack = try PersonalMembershipOnlineAcknowledgement(
                binding: pair.bindingA, response: response, control: control)
            assertCode("cancelled") {
                _ = try pair.a.commitPersonalMembershipChange(
                    preparation: pair.preparationA, acknowledgements: [ack])
            }
            XCTAssertNil(try pair.a.personalSyncIdentity().membership)
            try commitPair(pair)
            XCTAssertEqual(try pair.a.personalSyncIdentity().membership, pair.configuration)
            XCTAssertEqual(try pair.b.personalSyncIdentity().membership, pair.configuration)
            XCTAssertTrue(try pair.a.capturePersonalInventory(session: pair.bindingA).complete)
        }
    }
    func testFiniteCutUsesLocalRowsWithConcurrentBackdatedUUIDAndRebuildRescan() throws {
        try fixture { pair, accounts in
            for index in 0..<3 {
                _ = try create(pair.a, accounts: accounts, subject: "item\(index)", operation: "item\(index)")
            }
            let first = try pair.a.capturePersonalInventory(session: pair.bindingA, pageSize: 1)
            var node: UInt64 = 100
            pair.a.makePersistentUUID = {
                node += 1
                return try UUIDVersion1Components(
                    timestamp: 0x1E0_0000_0000_0000, clockSequence: 3, node: node
                ).uuid
            }
            let later = try create(pair.a, accounts: accounts, operation: "after-cut")
            var ids = first.entries.map(\.id)
            var cursor = first.nextOffset
            while let offset = cursor {
                let page = try pair.a.continuePersonalInventory(
                    session: pair.bindingA, snapshotID: first.snapshotID, offset: offset, pageSize: 1)
                ids += page.entries.map(\.id)
                cursor = page.nextOffset
            }
            XCTAssertEqual(ids.count, 3)
            XCTAssertFalse(ids.contains(later.revisionID))
            let suffix = try pair.a.capturePersonalInventory(
                session: pair.bindingA,
                knownGeneration: first.generationID, afterRowID: first.cutRowID)
            XCTAssertEqual(suffix.entries.map(\.id), [later.revisionID])
            let unchanged = try pair.a.capturePersonalInventory(
                session: pair.bindingA,
                knownGeneration: suffix.generationID, afterRowID: suffix.cutRowID)
            XCTAssertTrue(unchanged.complete)
            XCTAssertTrue(unchanged.entries.isEmpty)
            try pair.a.rebuildIndex()
            assertCode("inventoryExpired") {
                _ = try pair.a.continuePersonalInventory(
                    session: pair.bindingA, snapshotID: first.snapshotID, offset: 0)
            }
            let fresh = try pair.a.capturePersonalInventory(
                session: pair.bindingA,
                knownGeneration: suffix.generationID, afterRowID: suffix.cutRowID)
            XCTAssertNotEqual(fresh.generationID, suffix.generationID)
            XCTAssertEqual(fresh.entries.count, 4)
            XCTAssertTrue(fresh.entries.contains { $0.id == later.revisionID })
        }
    }
    func testRawRoundTripIsKnownAcrossRoutesAndCollisionNeverOverwrites() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            XCTAssertEqual(
                try send(
                    base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB
                ).status, .accepted)
            let edit = try pair.b.withAccess(forUID: accounts.alice) {
                try pair.b.commit(
                    .init(
                        action: .revise, itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["body": .text("from B")], operationID: "B-edit")
                ).revision
            }
            _ = try send(
                edit, from: pair.b, to: pair.a, sourceBinding: pair.bindingB, targetBinding: pair.bindingA)
            XCTAssertEqual(
                try send(
                    edit, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB
                ).status, .known)
            var fields = edit.fields
            fields["body"] = .text("collision")
            let changed = try Revision(fields: fields, formatVersion: edit.formatVersion)
            let bytes = try RecordCodec.encode(changed)
            let collision = try PersonalObjectDescriptor(
                kind: .revision, id: edit.revisionID, byteCount: Int64(bytes.count),
                sha256: PersonalSyncValidation.digest(bytes), itemID: edit.itemID,
                parentRevisionIDs: try edit.provenance!.parents)
            assertCode("peerObjectCollision") {
                _ = try pair.b.preparePersonalObject(session: pair.bindingB, descriptor: collision)
            }
            XCTAssertEqual(try pair.a.history(base.itemID).count, 2)
            XCTAssertEqual(try pair.b.get(base.itemID), edit)
            let completedStages = pair.second.root.appendingPathComponent(".personal-sync/stages")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: completedStages.path).isEmpty)
            let changedCreation = try raw(parent: edit, changes: ["createdAt": .date("2020-01-01T00:00:00Z")])
            try save(changedCreation, root: pair.first.root)
            try pair.a.rebuildIndex()
            assertCode("invalidRevisionGraph") {
                _ = try send(
                    changedCreation, from: pair.a, to: pair.b,
                    sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            }
            XCTAssertEqual(try pair.b.get(base.itemID), edit)
        }
    }
    func testDisjointOfflineEditsMergeAndTrueConflictResolvesWithFrontierCAS() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let left = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["body": .text("A")], operationID: "left")
                ).revision
            }
            let right = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["summary": .text("B")], operationID: "right")
                ).revision
            }
            XCTAssertEqual(
                try send(
                    right, from: pair.b, to: pair.a, sourceBinding: pair.bindingB,
                    targetBinding: pair.bindingA
                ).status, .merged)
            XCTAssertEqual(try pair.a.get(base.itemID).fields["body"], .text("A"))
            _ = try send(
                left, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            // Independent equivalent merges remain physical history; choose and replicate one causal base.
            let common = try pair.a.get(base.itemID)
            _ = try send(
                common, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let a = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: common.revisionID,
                        changes: ["body": .text("conflict A")], operationID: "conflict-A")
                ).revision
            }
            let bParent = try pair.b.get(base.itemID)
            let b = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: bParent.revisionID,
                        changes: ["body": .text("conflict B")], operationID: "conflict-B")
                ).revision
            }
            XCTAssertEqual(
                try send(
                    b, from: pair.b, to: pair.a, sourceBinding: pair.bindingB, targetBinding: pair.bindingA
                ).status, .conflicted)
            let state = try pair.a.itemState(base.itemID)
            let request = ResolveConflictRequest(
                itemID: base.itemID, expectedStateToken: state.stateToken,
                reviewedFrontier: try XCTUnwrap(state.frontier), changes: ["body": .text("chosen")],
                unset: [],
                operationID: "resolve")
            let resolved = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.resolveConflict(request)
            }
            XCTAssertEqual(resolved.revision.fields["body"], .text("chosen"))
            XCTAssertGreaterThan(
                try RevisionTimestamp(resolved.revision.modifiedAt), try RevisionTimestamp(a.modifiedAt))
            XCTAssertGreaterThan(
                try RevisionTimestamp(resolved.revision.modifiedAt), try RevisionTimestamp(b.modifiedAt))
            XCTAssertTrue(
                try pair.a.withAccess(forUID: accounts.alice) {
                    try pair.a.resolveConflict(request).wasReplayed
                })
            let stale = ResolveConflictRequest(
                itemID: base.itemID, expectedStateToken: state.stateToken,
                reviewedFrontier: request.reviewedFrontier, changes: ["body": .text("stale")], unset: [],
                operationID: "stale")
            assertCode("stateConflict") { _ = try pair.a.resolveConflict(stale) }
        }
    }
    func testRevokedOfflineAuthorStaysPrivateWhileCommittedOriginBranchSurvivesRestriction() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let offline = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["body": .text("offline Bob")], operationID: "offline")
                ).revision
            }
            let offlineChild = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: offline.revisionID, changes: ["subject": .text("offline child")],
                        operationID: "offline-child")
                ).revision
            }
            let restricted = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["permissions": permissions(0o600)], operationID: "restrict")
                ).revision
            }
            let proposed = try send(
                offline, from: pair.b, to: pair.a, sourceBinding: pair.bindingB, targetBinding: pair.bindingA)
            XCTAssertEqual(proposed.status, .reviewRequired)
            XCTAssertEqual(
                try pair.a.history(base.itemID).map(\.revisionID), [restricted.revisionID, base.revisionID])
            let blockedChild = try send(
                offlineChild, from: pair.b, to: pair.a,
                sourceBinding: pair.bindingB, targetBinding: pair.bindingA)
            XCTAssertEqual(blockedChild.status, .reviewRequired)
            XCTAssertEqual(try pair.a.personalIncomingReviews().count, 2)
            XCTAssertTrue(
                try pair.a.personalIncomingReviews().contains {
                    $0.descriptor.id == offlineChild.revisionID && $0.reason == "parentReviewRequired"
                        && $0.baseRevisionIDs == [offline.revisionID]
                })
            let unrelated = try create(
                pair.b, accounts: accounts, subject: "unrelated", operation: "unrelated")
            XCTAssertEqual(
                try send(
                    unrelated, from: pair.b, to: pair.a,
                    sourceBinding: pair.bindingB, targetBinding: pair.bindingA
                ).status, .accepted)
            XCTAssertEqual(try pair.a.get(unrelated.itemID), unrelated)
            _ = try send(
                restricted, from: pair.a, to: pair.b, sourceBinding: pair.bindingA,
                targetBinding: pair.bindingB)
            XCTAssertTrue(try pair.b.history(base.itemID).contains { $0.revisionID == offline.revisionID })
            try pair.b.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try pair.b.history(base.itemID) }
            }
            pair.first.store = nil
            pair.first.store = try ItemStore(
                personalRoot: pair.first.root, opening: .existing, accounts: accounts)
            XCTAssertTrue(
                try pair.a.personalIncomingReviews().contains { $0.reviewID == proposed.reviewItemID })
            XCTAssertEqual(try pair.a.history(base.itemID).count, 2)
            let beforeReview = try pair.a.get(base.itemID)
            _ = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: beforeReview.revisionID,
                        changes: ["subject": .text("later current edit")],
                        operationID: "later-current")
                ).revision
            }
            assertCode("stateConflict") {
                _ = try pair.a.acceptPersonalIncomingReview(try XCTUnwrap(proposed.reviewItemID))
            }
            let currentToken = try pair.a.itemState(base.itemID).stateToken
            let accepted = try pair.a.acceptPersonalIncomingReview(
                try XCTUnwrap(proposed.reviewItemID), expectedStateToken: currentToken)
            XCTAssertEqual(accepted.revision.fields["subject"], .text("later current edit"))
            XCTAssertEqual(accepted.revision.fields["body"], .text("offline Bob"))
            XCTAssertEqual(
                try ItemPermissions(XCTUnwrap(accepted.revision.fields["permissions"])).mode, 0o600)
            XCTAssertTrue(try pair.a.history(base.itemID).contains { $0.revisionID == offline.revisionID })
        }
    }
    func testOwnerWithZeroContentRightsCanManageSharingWithoutLeakingBody() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts, subject: "private secret body")
            let zero = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.changePersonalSharing(
                    itemID: base.itemID, expectedRevisionID: base.revisionID,
                    permissions: permissions(0), operationID: "zero")
            }
            try pair.a.withAccess(forUID: accounts.alice) {
                assertCode("forbidden") { _ = try pair.a.get(base.itemID) }
                let metadata = try pair.a.personalSharingMetadata(base.itemID)
                XCTAssertEqual(metadata.revisionID, zero.revisionID)
                XCTAssertFalse(
                    String(decoding: try JSON.encode(metadata), as: UTF8.self).contains("private secret"))
                _ = try pair.a.changePersonalSharing(
                    itemID: base.itemID, expectedRevisionID: zero.revisionID,
                    permissions: permissions(0o644), operationID: "relax")
                XCTAssertEqual(try pair.a.get(base.itemID).fields["subject"], base.fields["subject"])
            }
            try pair.a.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try pair.a.personalSharingMetadata(base.itemID) }
            }
            let service = ItemService(store: pair.a)
            let request = try nativeFixtureEnvelope(
                calls: [["TractandaItem/sharing", ["itemID": base.itemID], "c"]],
                accountID: pair.a.nativeProtocolSessionBasis.identity)
            let result =
                try JSONSerialization.jsonObject(with: service.handle(request, peerUID: accounts.alice))
                as? [String: Any]
            XCTAssertNotNil(result?["methodResponses"])
        }
    }
    func testExplicitBaselineSkipsHistoricalAuthorAndTransientUnmappedOwnerThenRestarts() throws {
        try fixture { pair, accounts in
            let first = try raw(actor: "uid:999999", permission: permissions(0o600, owner: "departed"))
            let current = try raw(parent: first, changes: ["subject": .text("current selected")])
            try save(first, root: pair.first.root)
            try save(current, root: pair.first.root)
            try pair.a.rebuildIndex()
            let token = try pair.b.startPersonalBaseline(sourceReplicaID: pair.bindingA.localReplicaID)
            _ = try send(
                first, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            assertCode("baselinePending") { _ = try pair.b.get(first.itemID) }
            pair.second.store = nil
            pair.second.store = try ItemStore(
                personalRoot: pair.second.root, opening: .existing, accounts: accounts)
            XCTAssertTrue(pair.b.isPersonalBaselinePending)
            _ = try send(
                current, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            try pair.b.finishPersonalBaseline(selectionID: token)
            XCTAssertFalse(pair.b.isPersonalBaselinePending)
            XCTAssertEqual(try pair.b.get(first.itemID), current)
            XCTAssertEqual(
                Set(try pair.b.history(first.itemID).map(\.revisionID)),
                [first.revisionID, current.revisionID])
            XCTAssertEqual(
                try pair.b.personalSyncIdentity().storeID, try pair.a.personalSyncIdentity().storeID)
            XCTAssertNotEqual(
                try pair.b.personalSyncIdentity().replicaID, try pair.a.personalSyncIdentity().replicaID)
        }
    }
    func testOriginalChunksResumeFromPhysicalPrefixAndStayUnreferencedUntilRevisionApply() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let bytes = Data((0..<(600 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
            let (attached, attachment) = try pair.a.withAccess(forUID: accounts.alice) {
                let upload = try pair.a.beginAttachment(
                    .init(
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        operationID: "original", filename: "tiny-original.bin",
                        mediaType: "application/octet-stream",
                        byteCount: Int64(bytes.count), sha256: PersonalSyncValidation.digest(bytes)))
                let uploadID = try XCTUnwrap(upload.uploadID)
                var offset = 0
                while offset < bytes.count {
                    let end = min(bytes.count, offset + 262_144)
                    _ = try pair.a.appendAttachment(
                        uploadID: uploadID, offset: Int64(offset), data: bytes.subdata(in: offset..<end))
                    offset = end
                }
                return (try pair.a.finishAttachment(uploadID: uploadID).revision, upload.attachment)
            }
            let object = try PersonalObjectDescriptor(
                kind: .original, id: attachment.attachmentID,
                byteCount: attachment.byteCount, sha256: attachment.sha256, attachment: attachment)
            _ = try pair.b.preparePersonalObject(session: pair.bindingB, descriptor: object)
            let prefix = bytes.subdata(in: 0..<262_144)
            _ = try pair.b.appendPersonalObject(
                session: pair.bindingB, descriptor: object, offset: 0, data: prefix)
            pair.second.store = nil
            pair.second.store = try ItemStore(
                personalRoot: pair.second.root, opening: .existing, accounts: accounts)
            let resumed = try pair.b.preparePersonalObject(session: pair.bindingB, descriptor: object)
            XCTAssertEqual(resumed.nextOffset, 262_144)
            XCTAssertFalse(resumed.complete)
            XCTAssertEqual(try pair.b.history(base.itemID).count, 1)
            try transfer(
                object, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            XCTAssertEqual(try pair.b.history(base.itemID).count, 1)
            let privatePayloadStore = try AttachmentPayloadStore(
                root: pair.second.root,
                ownerUID: tractanda_uid(), reserveBytes: 0)
            XCTAssertNil(try privatePayloadStore.resolvedPayloadPath(attachment.attachmentID))
            _ = try send(
                attached, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB
            )
            var received = Data()
            var readOffset: Int64 = 0
            while readOffset < attachment.byteCount {
                let chunk = try pair.b.attachmentContent(
                    itemID: base.itemID,
                    attachmentID: attachment.attachmentID, offset: readOffset)
                XCTAssertLessThanOrEqual(chunk.data.count, 262_144)
                XCTAssertEqual(chunk.offset, readOffset)
                received.append(chunk.data)
                readOffset = chunk.nextOffset
            }
            XCTAssertEqual(received, bytes)
            XCTAssertEqual(PersonalSyncValidation.digest(received), attachment.sha256)
        }
    }
    func testPublishedBranchSurvivesPowerFailureBeforeMergeAndRetryIsKnown() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let left = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["body": .text("incoming")], operationID: "incoming")
                ).revision
            }
            let local = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise,
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        changes: ["summary": .text("local")], operationID: "local")
                ).revision
            }
            let object = try descriptor(pair.a, revision: left)
            try transfer(
                object, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            pair.b.personalSyncAfterRevisionPublicationForTesting = {
                throw TractandaError("injected", "Power-loss boundary")
            }
            assertCode("injected") {
                _ = try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: object)
            }
            pair.second.store = nil
            pair.second.store = try ItemStore(
                personalRoot: pair.second.root, opening: .existing, accounts: accounts)
            let current = try pair.b.get(base.itemID)
            XCTAssertEqual(current.fields["body"], .text("incoming"))
            XCTAssertEqual(current.fields["summary"], .text("local"))
            let ids = Set(try pair.b.history(base.itemID).map(\.revisionID))
            XCTAssertTrue(ids.contains(local.revisionID))
            XCTAssertTrue(ids.contains(left.revisionID))
            XCTAssertEqual(ids.count, 4)
            XCTAssertEqual(
                try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: object).status, .known)
        }
    }

    func testInterruptedIncomingPublicationAutomaticallyRecoversWithoutAdmittingAnotherStage() throws {
        try fixture { pair, accounts in
            let accepted = try create(pair.a, accounts: accounts, operation: "recover-accepted")
            let privateRevision = try create(pair.a, accounts: accounts, operation: "remain-private")
            let acceptedObject = try descriptor(pair.a, revision: accepted)
            let privateObject = try descriptor(pair.a, revision: privateRevision)
            for object in [acceptedObject, privateObject] {
                try transfer(
                    object, from: pair.a, to: pair.b,
                    sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            }
            pair.b.personalSyncAfterRevisionPublicationForTesting = {
                throw TractandaError("injected", "Interrupted accepted publication")
            }
            assertCode("injected") {
                _ = try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: acceptedObject)
            }
            XCTAssertFalse(pair.b.isCanonicalTrusted)
            pair.b.personalSyncAfterRevisionPublicationForTesting = nil
            var recoveryAttempts = 0
            pair.b.beforeCanonicalDurabilitySync = { recoveryAttempts += 1 }
            let diagnostic = try pair.b.withAccess(forUID: pair.b.ownerUID, recoverPublication: false) {
                try pair.b.personalPeerCanonicalStatus()
            }
            XCTAssertEqual(diagnostic.readiness, .recoveryRequired)
            XCTAssertEqual(recoveryAttempts, 0, "Status cannot implicitly reconstruct canonical publication")
            XCTAssertFalse(pair.b.isCanonicalTrusted)
            let rejected = try PeerExchangeBinding(
                peerID: pair.bindingB.peerID, storeID: pair.bindingB.storeID,
                localReplicaID: pair.bindingB.localReplicaID,
                remoteReplicaID: try UUID.makeVersion1().uuidString.lowercased(),
                pairingID: pair.bindingB.pairingID, localIsInitiator: pair.bindingB.localIsInitiator,
                configurationDigest: pair.bindingB.configurationDigest)
            assertCode("untrustedPeer") { try pair.b.validatePersonalPeerBinding(rejected) }
            XCTAssertEqual(recoveryAttempts, 0, "Rejected membership cannot trigger reconstruction")
            // Binding validation triggers a canonical-only rebuild on the same live Store.
            XCTAssertEqual(
                try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: acceptedObject).status,
                .known)
            XCTAssertEqual(recoveryAttempts, 1)
            XCTAssertTrue(pair.b.isCanonicalTrusted)
            XCTAssertEqual(try pair.b.history(accepted.itemID), [accepted])
            XCTAssertThrowsError(try pair.b.get(privateRevision.itemID))
            let staged = try pair.b.preparePersonalObject(session: pair.bindingB, descriptor: privateObject)
            XCTAssertFalse(staged.knownRevision)
            XCTAssertEqual(staged.nextOffset, privateObject.byteCount)
            XCTAssertEqual(
                try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: privateObject).status,
                .accepted)
            XCTAssertEqual(try pair.b.history(privateRevision.itemID), [privateRevision])
        }
    }

    func testLostOrMalformedCompletedCursorRescansWithoutDuplicateHistory() throws {
        try fixture { pair, accounts in
            let original = try create(pair.a, accounts: accounts, operation: "cursor-content")
            _ = try send(
                original, from: pair.a, to: pair.b,
                sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let remote = try pair.a.capturePersonalInventory(session: pair.bindingA)
            var cursor = try PersonalPeerBridge.loadCursor(store: pair.b, binding: pair.bindingB)
            cursor.remoteGenerationID = remote.generationID
            cursor.consumedRowID = remote.cutRowID
            try PersonalPeerBridge.saveCursor(cursor, store: pair.b, binding: pair.bindingB)
            XCTAssertEqual(
                try PersonalPeerBridge.loadCursor(store: pair.b, binding: pair.bindingB).consumedRowID,
                remote.cutRowID)
            let cursorDirectory = pair.second.root.appendingPathComponent(".personal-sync/cursors")
            let paths = try FileManager.default.contentsOfDirectory(
                at: cursorDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            XCTAssertEqual(paths.count, 1)
            let path = try XCTUnwrap(paths.first)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try Data("interrupted cursor JSON".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            XCTAssertEqual(
                try PersonalPeerBridge.loadCursor(store: pair.b, binding: pair.bindingB).consumedRowID, 0)
            try FileManager.default.removeItem(at: cursorDirectory)
            pair.second.store = nil
            try FileManager.default.removeItem(at: pair.second.root.appendingPathComponent("index"))
            pair.second.store = try ItemStore(
                personalRoot: pair.second.root, opening: .existing, accounts: accounts)
            let rescanning = try PersonalPeerBridge.loadCursor(store: pair.b, binding: pair.bindingB)
            XCTAssertEqual(rescanning.consumedRowID, 0)
            XCTAssertNil(rescanning.remoteGenerationID)
            XCTAssertEqual(
                try send(
                    original, from: pair.a, to: pair.b,
                    sourceBinding: pair.bindingA, targetBinding: pair.bindingB
                ).status, .known)
            XCTAssertEqual(try pair.b.history(original.itemID), [original])
            XCTAssertEqual(try pair.b.personalSyncIdentity().membership, pair.configuration)
        }
    }

    func testCommittedMembershipCleanupRetriesAbsentLeafAndPreservesLaterPreparation() throws {
        try fixture { pair, _ in
            try PersonalSyncConfiguration.write(
                pair.preparationA, root: pair.first.root, name: PersonalSyncConfiguration.pendingName)
            var barriers = 0
            pair.a.personalSyncAfterConfigurationUnlinkForTesting = {
                barriers += 1
                throw TractandaError("injected", "Interrupted cleanup acknowledgement")
            }
            for _ in 0..<2 {
                assertCode("injected") {
                    _ = try pair.a.commitPersonalMembershipChange(
                        preparation: pair.preparationA, acknowledgements: [])
                }
                XCTAssertNil(
                    try PersonalSyncConfiguration.read(
                        PersonalMembershipPreparation.self,
                        root: pair.first.root, name: PersonalSyncConfiguration.pendingName,
                        ownerUID: tractanda_uid()))
            }
            XCTAssertEqual(barriers, 2, "An absent leaf must not skip a prior uncertain cleanup barrier")
            pair.a.personalSyncAfterConfigurationUnlinkForTesting = nil
            XCTAssertEqual(
                try pair.a.commitPersonalMembershipChange(
                    preparation: pair.preparationA, acknowledgements: []),
                pair.configuration)
            let laterConfiguration = try PersonalMembershipConfiguration(
                storeID: pair.configuration.storeID, configurationID: id(),
                members: pair.configuration.members)
            let later = try pair.a.preparePersonalMembershipChange(
                configuration: laterConfiguration, expectedDigest: pair.configuration.digest)
            _ = try pair.a.commitPersonalMembershipChange(
                preparation: pair.preparationA, acknowledgements: [])
            XCTAssertEqual(
                try PersonalSyncConfiguration.read(
                    PersonalMembershipPreparation.self,
                    root: pair.first.root, name: PersonalSyncConfiguration.pendingName,
                    ownerUID: tractanda_uid()), later)
        }
    }

    func testBaselineCleanupUncertaintyRetriesExactTokenWithoutManualReopen() throws {
        try fixture { pair, accounts in
            let revision = try create(pair.a, accounts: accounts, operation: "baseline-cleanup")
            let token = try pair.b.startPersonalBaseline(sourceReplicaID: pair.bindingA.localReplicaID)
            _ = try send(
                revision, from: pair.a, to: pair.b,
                sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            pair.b.personalSyncAfterConfigurationUnlinkForTesting = {
                throw TractandaError("injected", "Interrupted baseline cleanup acknowledgement")
            }
            assertCode("injected") { try pair.b.finishPersonalBaseline(selectionID: token) }
            XCTAssertTrue(pair.b.isPersonalBaselinePending)
            XCTAssertNil(
                try PersonalSyncConfiguration.read(
                    PersonalBaselineSelection.self,
                    root: pair.second.root, name: PersonalSyncConfiguration.baselineName,
                    ownerUID: tractanda_uid()))
            assertCode("baselineConflict") { try pair.b.finishPersonalBaseline(selectionID: id()) }
            assertCode("injected") { try pair.b.finishPersonalBaseline(selectionID: token) }
            pair.b.personalSyncAfterConfigurationUnlinkForTesting = nil
            try pair.b.finishPersonalBaseline(selectionID: token)
            XCTAssertFalse(pair.b.isPersonalBaselinePending)
            XCTAssertEqual(try pair.b.get(revision.itemID), revision)
            XCTAssertEqual(try pair.b.history(revision.itemID), [revision])
            pair.second.store = nil
            pair.second.store = try ItemStore(
                personalRoot: pair.second.root, opening: .existing, accounts: accounts)
            XCTAssertFalse(pair.b.isPersonalBaselinePending)
            XCTAssertEqual(try pair.b.history(revision.itemID), [revision])
        }
    }

    func testIncomingPostCommitCleanupFailureKeepsHealthyIndexAndKnownRetry() throws {
        try fixture { pair, accounts in
            let accepted = try create(pair.a, accounts: accounts, operation: "post-commit-accepted")
            let privateRevision = try create(pair.a, accounts: accounts, operation: "post-commit-private")
            let acceptedObject = try descriptor(pair.a, revision: accepted)
            let privateObject = try descriptor(pair.a, revision: privateRevision)
            for object in [acceptedObject, privateObject] {
                try transfer(
                    object, from: pair.a, to: pair.b,
                    sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            }
            pair.b.personalSyncAfterIndexCommitForTesting = {
                throw TractandaError("injected", "Cleanup failed after successful SQLite COMMIT")
            }
            assertCode("injected") {
                _ = try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: acceptedObject)
            }
            XCTAssertTrue(
                pair.b.isCanonicalTrusted,
                "A cleanup error must not roll back/quarantine an already committed healthy index")
            XCTAssertFalse(StoreCheckpoint.isDirty(root: pair.second.root))
            XCTAssertEqual(try pair.b.history(accepted.itemID), [accepted])
            pair.b.personalSyncAfterIndexCommitForTesting = nil
            XCTAssertEqual(
                try pair.b.applyPersonalRevision(session: pair.bindingB, descriptor: acceptedObject).status,
                .known)
            XCTAssertThrowsError(try pair.b.get(privateRevision.itemID))
            let retained = try pair.b.preparePersonalObject(session: pair.bindingB, descriptor: privateObject)
            XCTAssertFalse(retained.knownRevision)
            XCTAssertEqual(retained.nextOffset, privateObject.byteCount)
            XCTAssertEqual(try pair.b.history(accepted.itemID).count, 1)
        }
    }
    func testRemovalNeedsRetainedMembersOnlyAndOmittedPeerCannotUseOldCredentials() throws {
        try fixture { pair, _ in
            let next = try PersonalMembershipConfiguration(
                storeID: pair.configuration.storeID, configurationID: id(),
                members: pair.configuration.members.filter { $0.replicaID == pair.bindingA.localReplicaID })
            let plan = try pair.a.preparePersonalMembershipChange(
                configuration: next, expectedDigest: pair.configuration.digest)
            XCTAssertEqual(plan.requiredOnlineReplicaIDs, [pair.bindingA.localReplicaID])
            _ = try pair.a.commitPersonalMembershipChange(preparation: plan, acknowledgements: [])
            assertCode("untrustedPeer") { try pair.a.validatePersonalPeerBinding(pair.bindingA) }
            XCTAssertEqual(try pair.a.personalSyncIdentity().membership?.members.count, 1)
        }
    }
    func testNativeReviewSecondPublicationFailureIsPartialAndExactRetryAcknowledges() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let offline = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: base.revisionID,
                        changes: ["body": .text("reviewed offline edit")],
                        operationID: "native-offline")
                ).revision
            }
            _ = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: base.revisionID, changes: ["permissions": permissions(0o600)],
                        operationID: "native-restrict"))
            }
            let proposal = try send(
                offline, from: pair.b, to: pair.a,
                sourceBinding: pair.bindingB, targetBinding: pair.bindingA)
            XCTAssertEqual(proposal.status, .reviewRequired)
            let reviewID = try XCTUnwrap(proposal.reviewItemID)
            let stateToken = try pair.a.itemState(base.itemID).stateToken
            let request = try nativeFixtureEnvelope(
                calls: [
                    [
                        "TractandaSync/acceptReview",
                        ["reviewID": reviewID, "expectedStateToken": stateToken], "review",
                    ]
                ], accountID: pair.a.nativeProtocolSessionBasis.identity)
            var publications = 0
            pair.a.personalSyncAfterRevisionPublicationForTesting = {
                publications += 1
                if publications == 2 {
                    throw TractandaError("stateMismatch", "injected after resolution publication")
                }
            }
            let service = ItemService(store: pair.a)
            let failed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: service.handle(request, peerUID: tractanda_uid()))
                    as? [String: Any])
            let replies = try XCTUnwrap(failed["methodResponses"] as? [[Any]])
            XCTAssertEqual(publications, 2)
            XCTAssertEqual(replies[0][0] as? String, "error")
            XCTAssertEqual((replies[0][1] as? [String: Any])?["type"] as? String, "serverPartialFail")
            pair.a.personalSyncAfterRevisionPublicationForTesting = nil
            try pair.a.rebuildIndex()
            let replay = try JSON.decode(
                MutationReceipt.self,
                NativeMethodResult.unwrap(
                    service.handle(request, peerUID: tractanda_uid()), method: "TractandaSync/acceptReview",
                    callID: "review"))
            XCTAssertTrue(replay.wasReplayed)
            XCTAssertEqual(replay.operationID, "personal-review:" + reviewID)
            XCTAssertEqual(
                try pair.a.history(base.itemID).filter {
                    $0.fields["operationID"]?.string == replay.operationID
                }.count, 1)
            let exact = try pair.a.get(replay.itemID, revisionID: replay.revisionID)
            XCTAssertEqual(exact.fields["body"], .text("reviewed offline edit"))
            XCTAssertEqual(try ItemPermissions(XCTUnwrap(exact.fields["permissions"])).mode, 0o600)
        }
    }

    func testNativeReaderFenceFailureIsPartialBeforeAnyItemPublication() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            _ = try send(
                base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA, targetBinding: pair.bindingB)
            let offline = try pair.b.withAccess(forUID: accounts.bob) {
                try pair.b.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: base.revisionID, changes: ["body": .text("fence review")],
                        operationID: "fence-offline")
                ).revision
            }
            _ = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: base.revisionID, changes: ["permissions": permissions(0o600)],
                        operationID: "fence-restrict"))
            }
            let proposal = try send(
                offline, from: pair.b, to: pair.a,
                sourceBinding: pair.bindingB, targetBinding: pair.bindingA)
            let reviewID = try XCTUnwrap(proposal.reviewItemID)
            let root = pair.first.root
            let current = try XCTUnwrap(
                CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
            // Isolated fault-injection metadata only: exercise the first sync-fence raise again.
            let prior = CanonicalReaderRequirement(
                storeID: current.storeID, minimumReaderLevel: 16,
                recordFormats: current.recordFormats,
                capabilities: current.capabilities.filter {
                    $0 != PersonalSyncValidation.capability && $0 != RevisionProvenance.personalMergeProfile
                })
            let fenceFile = root.appendingPathComponent(CanonicalReaderRequirement.fileName)
            try JSON.encode(prior).write(to: fenceFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fenceFile.path)
            var publications = 0
            pair.a.personalSyncAfterRevisionPublicationForTesting = { publications += 1 }
            pair.a.afterCanonicalReaderRequirementForTesting = {
                throw TractandaError("stateMismatch", "injected after durable fence update")
            }
            let request = try nativeFixtureEnvelope(
                calls: [
                    [
                        "TractandaSync/acceptReview",
                        [
                            "reviewID": reviewID,
                            "expectedStateToken": try pair.a.itemState(base.itemID).stateToken,
                        ], "fence",
                    ]
                ], accountID: pair.a.nativeProtocolSessionBasis.identity)
            let response = ItemService(store: pair.a).handle(request, peerUID: tractanda_uid())
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let replies = try XCTUnwrap(body["methodResponses"] as? [[Any]])
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(replies[0][0] as? String, "error")
            XCTAssertEqual((replies[0][1] as? [String: Any])?["type"] as? String, "serverPartialFail")
            let raised = try XCTUnwrap(CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid()))
            XCTAssertTrue(raised.capabilities.contains(PersonalSyncValidation.capability))
            XCTAssertGreaterThanOrEqual(raised.minimumReaderLevel, 18)
            pair.a.afterCanonicalReaderRequirementForTesting = nil
            pair.a.personalSyncAfterRevisionPublicationForTesting = nil
        }
    }

    func testClusterStatusSeparatesPendingMembershipAndBaselineWithoutLoadingKeys() throws {
        try fixture(commit: false) { pair, _ in
            let before = try pair.b.withAccess(forUID: pair.b.ownerUID, recoverPublication: false) {
                try pair.b.personalPeerCanonicalStatus()
            }
            XCTAssertNil(before.personal?.currentMembership)
            XCTAssertEqual(before.personal?.pendingMembership, pair.configuration)
            XCTAssertEqual(
                before.personal?.requiredOnlineReplicaIDs, pair.preparationB.requiredOnlineReplicaIDs.sorted()
            )
            XCTAssertNil(before.personal?.baselineSourceReplicaID)
            try commitPair(pair)
            let source = try XCTUnwrap(pair.a.replicaID)
            _ = try pair.b.startPersonalBaseline(sourceReplicaID: source)
            // No private credential is loaded by diagnostics, even after the key directory is removed.
            let keys = pair.second.root.appendingPathComponent(".peer-credentials")
            if FileManager.default.fileExists(atPath: keys.path) {
                try FileManager.default.removeItem(at: keys)
            }
            let after = try pair.b.withAccess(forUID: pair.b.ownerUID, recoverPublication: false) {
                try pair.b.personalPeerCanonicalStatus()
            }
            XCTAssertEqual(after.readiness, .pendingActivation)
            XCTAssertEqual(after.personal?.currentMembership, pair.configuration)
            XCTAssertNil(after.personal?.pendingMembership)
            XCTAssertEqual(after.personal?.baselineSourceReplicaID, source)
            let json = String(decoding: try JSON.encode(after), as: UTF8.self)
            for field in ["selectionID", "nonce", "administrator", "secret"] {
                XCTAssertFalse(json.contains(field))
            }
            XCTAssertTrue(pair.b.isPersonalBaselinePending)
        }
    }

    func testReplyCapturedBeforeRemovalCannotAppendFinishOrApplyAfterCurrentMembershipChanges() throws {
        try fixture { pair, accounts in
            let staged = try create(
                pair.b, accounts: accounts, subject: "staged before removal", operation: "late-staged")
            let stagedObject = try descriptor(pair.b, revision: staged)
            try transfer(
                stagedObject, from: pair.b, to: pair.a, sourceBinding: pair.bindingB,
                targetBinding: pair.bindingA)
            let delayed = try create(
                pair.b, accounts: accounts, subject: "delayed reply bytes", operation: "late-reply")
            let delayedObject = try descriptor(pair.b, revision: delayed)
            _ = try pair.a.preparePersonalObject(session: pair.bindingA, descriptor: delayedObject)
            let capturedReply = try pair.b.readPersonalObject(
                session: pair.bindingB, descriptor: delayedObject, offset: 0)
            XCTAssertEqual(Int64(capturedReply.count), delayedObject.byteCount)
            let next = try PersonalMembershipConfiguration(
                storeID: pair.configuration.storeID, configurationID: id(),
                members: pair.configuration.members.filter { $0.replicaID == pair.bindingA.localReplicaID })
            let removal = try pair.a.preparePersonalMembershipChange(
                configuration: next, expectedDigest: pair.configuration.digest)
            _ = try pair.a.commitPersonalMembershipChange(preparation: removal, acknowledgements: [])
            let before = try RetiredAuthorityEntryPointTests.Fixture.fingerprint(pair.first.root)
            assertCode("untrustedPeer") {
                _ = try pair.a.appendPersonalObject(
                    session: pair.bindingA, descriptor: delayedObject, offset: 0, data: capturedReply)
            }
            assertCode("untrustedPeer") {
                _ = try pair.a.finishPersonalObject(session: pair.bindingA, descriptor: stagedObject)
            }
            assertCode("untrustedPeer") {
                _ = try pair.a.applyPersonalRevision(session: pair.bindingA, descriptor: stagedObject)
            }
            XCTAssertEqual(try RetiredAuthorityEntryPointTests.Fixture.fingerprint(pair.first.root), before)
            assertCode("notFound") { _ = try pair.a.get(staged.itemID) }
            assertCode("notFound") { _ = try pair.a.get(delayed.itemID) }
            XCTAssertEqual(try pair.a.personalSyncIdentity().membership, next)
        }
    }

}
