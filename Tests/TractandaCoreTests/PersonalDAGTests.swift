import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PersonalDAGTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name = uid == tractanda_uid() ? "admin" : uid == 51001 ? "alice" : "bob"
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [71001])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard ["admin", "alice", "bob"].contains(name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return try user(forUID: name == "admin" ? tractanda_uid() : name == "alice" ? 51001 : 51002)
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71001
        }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func policy() -> ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob")]),
        ])
    }
    private func permissions(owner: String = "alice", mode: Int64 = 0o666) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner),
            "group": .text("staff"), "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func revision(
        parent: Revision? = nil, changes: [String: ItemValue] = [:],
        revisionID: String? = nil, time: String = "2026-10-25T10:00:00Z"
    ) throws -> Revision {
        var fields =
            try parent?.fields ?? [
                "itemID": .text(try id()), "createdAt": .date("2026-10-25T10:00:00Z"),
                "classID": .text("Item"), "schemaVersion": .integer(1), "subject": .text("same"),
                "permissions": permissions(), "isDeleted": .boolean(false),
            ]
        let next = try revisionID ?? id()
        fields["revisionID"] = .text(next)
        fields["modifiedAt"] = .date(time)
        fields["actor"] = .text("user:alice")
        fields["operationID"] = .text(next)
        fields["requestIdentity"] = .text("private fixture")
        if let parent { fields["supersedes"] = .text(parent.revisionID) }
        fields.merge(changes) { _, value in value }
        let modern = try parent?.provenance != nil
        if modern, let parent {
            fields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: id(), parents: [parent.revisionID],
                writtenFields: changes.keys.sorted(), unsetFields: [], frontier: []
            ).itemValue
        }
        return try Revision(fields: fields, formatVersion: modern ? 2 : 1)
    }
    private func graph(_ revisions: [Revision], profile: String = RevisionMerge.personalProfile) throws
        -> RevisionGraph
    {
        let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.revisionID, $0) })
        return try RevisionGraph(
            nodes: revisions.map {
                try RevisionMerge.node($0, parent: $0.supersedes.flatMap { byID[$0] })
            }, profile: profile)
    }
    private func merge(_ graph: RevisionGraph, root: Revision, origin: String) throws -> Revision {
        let draft = try XCTUnwrap(graph.draft(now: { "2026-10-25T11:00:00Z" }, allocateRevisionID: id))
        var fields = draft.fields
        fields["itemID"] = .text(draft.itemID)
        fields["revisionID"] = .text(draft.revisionID)
        fields["createdAt"] = root.fields["createdAt"]
        fields["modifiedAt"] = .date(draft.modifiedAt)
        fields["actor"] = .text("replica:" + origin)
        fields["operationID"] = .text(draft.revisionID)
        fields["requestIdentity"] = .text("private merge")
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .automaticMerge, originReplicaID: origin, parents: draft.parents,
            writtenFields: [], unsetFields: [], frontier: draft.frontier, mergeProfile: draft.profile
        ).itemValue
        return try Revision(fields: fields, formatVersion: 2)
    }
    func testActualOwnershipChangesBeatLaterUnrelatedChmodAndPreserveOriginalComponents() throws {
        let root = try revision()
        let owner = try revision(parent: root, changes: ["permissions": permissions(owner: "bob")])
        let mode = try revision(parent: root, changes: ["permissions": permissions(mode: 0o644)])
        let laterMode = try revision(parent: mode, changes: ["permissions": permissions(mode: 0o600)])
        let current = try graph([root, owner, mode, laterMode])
        let analysis = try current.analyze()
        XCTAssertTrue(analysis.isResolved)
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(analysis.fields["permissions"])).owner, "bob")
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(analysis.fields["permissions"])).mode, 0o600)
        XCTAssertEqual(current.personalPermissionPlan?.components.count, 2)
    }
    func testOwnershipUsesUUIDTicksAndExactTieBreakWhileCausalSuccessorsWin() throws {
        let root = try revision()
        let tick: UInt64 = 0x1F1_D000_0000_0000
        let aID = try UUIDVersion1Components(timestamp: tick, clockSequence: 1, node: 1).uuid.uuidString
            .lowercased()
        let bID = try UUIDVersion1Components(timestamp: tick, clockSequence: 1, node: 2).uuid.uuidString
            .lowercased()
        let a = try revision(
            parent: root, changes: ["permissions": permissions(owner: "bob")], revisionID: aID)
        let b = try revision(
            parent: root, changes: ["permissions": permissions(owner: "admin")], revisionID: bID,
            time: "2020-01-01T00:00:00Z")
        let fork = try graph([root, a, b]).analyze()
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(fork.fields["permissions"])).owner, "admin")
        let nextID = try UUIDVersion1Components(timestamp: tick - 1, clockSequence: 1, node: 3).uuid
            .uuidString.lowercased()
        let next = try revision(
            parent: b, changes: ["permissions": permissions(owner: "alice")], revisionID: nextID)
        let causal = try graph([root, b, next]).analyze()
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(causal.fields["permissions"])).owner, "alice")
    }
    func testPermissionMergeCanBeRelaxedByCausalOwnerEdit() throws {
        let root = try revision()
        let left = try revision(parent: root, changes: ["permissions": permissions(mode: 0o640)])
        let right = try revision(parent: root, changes: ["permissions": permissions(mode: 0o604)])
        let first = try merge(graph([root, left, right]), root: root, origin: id())
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(first.fields["permissions"])).mode, 0o600)
        let relax = try revision(parent: first, changes: ["permissions": permissions(mode: 0o644)])
        let state = try graph([root, left, right, first, relax]).analyze()
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(state.fields["permissions"])).mode, 0o644)
        XCTAssertEqual(state.representativeRevisionID, relax.revisionID)
    }
    func testIndependentMergesOnThirdNodeAndRestartDoNotChurnOrReFoldLossyACL() throws {
        let root = try revision()
        let left = try revision(
            parent: root, changes: ["body": .text("left"), "permissions": permissions(mode: 0o640)])
        let right = try revision(
            parent: root, changes: ["summary": .text("right"), "permissions": permissions(mode: 0o604)])
        let originA = try id()
        let originB = try id()
        let m1 = try merge(graph([root, left, right]), root: root, origin: originA)
        let m2 = try merge(graph([right, root, left]), root: root, origin: originB)
        XCTAssertNotEqual(m1.revisionID, m2.revisionID)
        for parent in [left, right] {
            XCTAssertGreaterThan(
                try RevisionTimestamp(m1.modifiedAt), try RevisionTimestamp(parent.modifiedAt))
            XCTAssertGreaterThan(
                try UUIDVersion1Components(UUID(uuidString: m1.revisionID)!).timestamp,
                try UUIDVersion1Components(UUID(uuidString: parent.revisionID)!).timestamp)
        }
        let all = [root, left, right, m1, m2]
        for order in [all, Array(all.reversed())] {
            let restart = try graph(Array(order))
            let state = try restart.analyze()
            XCTAssertTrue(state.isResolved)
            XCTAssertFalse(state.needsMaterialization)
            XCTAssertEqual(state.fields["body"], .text("left"))
            XCTAssertEqual(state.fields["summary"], .text("right"))
            XCTAssertEqual(restart.personalPermissionPlan?.components.count, 2)
            XCTAssertNil(
                try restart.draft(
                    now: { "bad" },
                    allocateRevisionID: {
                        XCTFail("Equivalent automatic merges must allocate nothing")
                        return try self.id()
                    }))
        }
    }
    func testOldMergeProfileKeepsItsPermissionProtectionAndCannotValidateNewMeaning() throws {
        let root = try revision()
        let left = try revision(parent: root, changes: ["permissions": permissions(mode: 0o600)])
        let right = try revision(parent: root, changes: ["body": .text("other")])
        XCTAssertFalse(try graph([root, left, right], profile: RevisionMerge.profile).analyze().isResolved)
        let current = try merge(graph([root, left, right]), root: root, origin: id())
        var fields = current.fields
        var metadata = try XCTUnwrap(fields["revisionAncestry"]?.map)
        metadata["mergeProfile"] = .text(RevisionMerge.profile)
        fields["revisionAncestry"] = .object(metadata)
        let relabeled = try Revision(fields: fields, formatVersion: 2)
        XCTAssertThrowsError(try graph([root, left, right, relabeled]))
        let oldA = try revision(parent: root, changes: ["body": .text("historical A")])
        let oldB = try revision(parent: root, changes: ["summary": .text("historical B")])
        let oldMerge = try merge(
            graph([root, oldA, oldB], profile: RevisionMerge.profile), root: root, origin: id())
        let child = try revision(parent: oldMerge, changes: ["subject": .text("later ordinary edit")])
        XCTAssertEqual(
            try graph([root, oldA, oldB, oldMerge, child]).analyze().representativeRevisionID,
            child.revisionID)
    }
    private func save(_ revision: Revision, root: URL) throws {
        let bytes = try RecordCodec.encode(revision)
        XCTAssertLessThan(bytes.count, 1024 * 1024)
        try AttachmentFixtureCapacity.requireFree(at: root)
        let path = [
            "items", "2026", "10", "25", "10", "00", revision.itemID, revision.revisionID + ".tractanda",
        ]
        try DocumentContentFiles(
            root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024
        )
        .writeImmutable(bytes, path: path, maximumBytes: 1024 * 1024)
    }
    private func fixture(_ body: (URL, Accounts) throws -> Void) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-dag-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Accounts())
    }
    private func open(
        _ root: URL, _ accounts: Accounts,
        _ opening: PersonalWorkgroupProfile.Opening
    ) throws -> ItemStore {
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        return try ItemStore(personalRoot: root, opening: opening, accounts: accounts, recoveryLimits: limits)
    }
    func testCommittedContentConflictRebuildsWithCurrentACLAndEveryBranchAfterIndexLoss() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(parent: base, changes: ["body": .text("left")])
            let right = try revision(
                parent: base, changes: ["body": .text("right"), "permissions": permissions(mode: 0o600)])
            let other = try revision(changes: ["subject": .text("unaffected")])
            for value in [base, left, right, other] { try save(value, root: root) }
            for opening in [PersonalWorkgroupProfile.Opening.selectedContent(policy()), .existing] {
                var store: ItemStore? = try open(root, accounts, opening)
                XCTAssertEqual(try store!.itemState(base.itemID).status, .conflicted)
                XCTAssertThrowsError(try store!.get(base.itemID)) {
                    XCTAssertEqual(($0 as? TractandaError)?.code, "itemUnresolved")
                }
                XCTAssertEqual(
                    Set(try store!.history(base.itemID).map(\.revisionID)),
                    Set([base, left, right].map(\.revisionID)))
                try store!.withAccess(forUID: 51002) {
                    XCTAssertThrowsError(try store!.history(base.itemID)) {
                        XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
                    }
                    XCTAssertThrowsError(try store!.get(base.itemID, revisionID: left.revisionID)) {
                        XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
                    }
                }
                XCTAssertEqual(try store!.get(other.itemID), other)
                store = nil
                try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            }
        }
    }
    func testCrashShapedRawForkMaterializesOnNativeOpenThenRestartIsIdempotent() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(
                parent: base, changes: ["body": .text("left"), "permissions": permissions(mode: 0o640)])
            let right = try revision(
                parent: base, changes: ["summary": .text("right"), "permissions": permissions(mode: 0o604)])
            for value in [base, left, right] { try save(value, root: root) }
            var store: ItemStore? = try open(root, accounts, .selectedContent(policy()))
            let first = try store!.get(base.itemID)
            XCTAssertEqual(try store!.itemState(base.itemID).status, .ready)
            XCTAssertEqual(try first.provenance?.mergeProfile, RevisionMerge.personalProfile)
            XCTAssertEqual(Set(try store!.history(base.itemID).map(\.revisionID)).count, 4)
            XCTAssertEqual(try ItemPermissions(XCTUnwrap(first.fields["permissions"])).mode, 0o600)
            XCTAssertEqual(
                try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid())?
                    .minimumReaderLevel, 17)
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try open(root, accounts, .existing)
            XCTAssertEqual(try store!.get(base.itemID), first)
            XCTAssertEqual(try store!.history(base.itemID).count, 4)
            store = nil
        }
    }
    func testPermissionOnlyForkBecomesReadyAndRawMergedCopyRestoresItsReaderFence() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(parent: base, changes: ["permissions": permissions(mode: 0o640)])
            let right = try revision(parent: base, changes: ["permissions": permissions(mode: 0o604)])
            for value in [base, left, right] { try save(value, root: root) }
            var store: ItemStore? = try open(root, accounts, .selectedContent(policy()))
            let merged = try store!.get(base.itemID)
            XCTAssertEqual(try store!.itemState(base.itemID).status, .ready)
            let frontier = try store!.itemState(base.itemID).frontier
            store = nil
            // New raw-only activation has no profile, requirement, identities or index.
            let copy = root.appendingPathComponent("raw-copy")
            try PrivateConfiguration.makeDirectory(copy)
            for value in [base, left, right, merged] { try save(value, root: copy) }
            store = try open(copy, accounts, .selectedContent(policy()))
            XCTAssertEqual(try store!.itemState(base.itemID).frontier, frontier)
            XCTAssertEqual(try store!.get(base.itemID), merged)
            let fence = try XCTUnwrap(CanonicalReaderRequirement.load(root: copy, ownerUID: tractanda_uid()))
            XCTAssertEqual(fence.minimumReaderLevel, 17)
            XCTAssertTrue(fence.capabilities.contains(RevisionMerge.personalProfile))
            let old = CanonicalFormatSupport(
                readerLevel: 16, writerLevel: 16, read: [1, 2], write: [2],
                capabilities: [PersonalWorkgroupProfile.capability])
            XCTAssertThrowsError(try old.require(fence))
            store = nil
        }
    }
    func testIndependentPhysicalMaterializationsSurviveNativeThirdNodeAndRestart() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(parent: base, changes: ["body": .text("A")])
            let right = try revision(parent: base, changes: ["summary": .text("B")])
            let m1 = try merge(graph([base, left, right]), root: base, origin: id())
            let m2 = try merge(graph([base, left, right]), root: base, origin: id())
            for value in [base, left, right, m1, m2] { try save(value, root: root) }
            var representative: Revision?
            for opening in [PersonalWorkgroupProfile.Opening.selectedContent(policy()), .existing] {
                var store: ItemStore? = try open(root, accounts, opening)
                XCTAssertEqual(try store!.itemState(base.itemID).status, .ready)
                XCTAssertEqual(try store!.history(base.itemID).count, 5)
                let current = try store!.get(base.itemID)
                if let representative { XCTAssertEqual(current, representative) }
                representative = current
                store = nil
                try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            }
        }
    }
    func testForkAnalysisBudgetIsItemLocalAndKeepsRawHistory() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(parent: base, changes: ["body": .text("A")])
            let right = try revision(parent: base, changes: ["body": .text("B")])
            let other = try revision()
            for value in [base, left, right, other] { try save(value, root: root) }
            var limits = PersonalRecoveryIndex.Limits()
            limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
            limits.graph = .init(maximumNodes: 2)
            var store: ItemStore? = try ItemStore(
                personalRoot: root,
                opening: .selectedContent(policy()), accounts: accounts, recoveryLimits: limits)
            XCTAssertEqual(try store!.itemState(base.itemID).status, .unmaterializable)
            XCTAssertEqual(try store!.itemState(base.itemID).resource?.code, "personalGraphWindowExceeded")
            XCTAssertEqual(try store!.history(base.itemID).count, 3)
            XCTAssertEqual(try store!.get(other.itemID), other)
            store = nil
        }
    }

    func testPersonalServiceExposesReadOnlyStateAndConflictsWithoutDisclosingRevokedHistory() throws {
        try fixture { root, accounts in
            let base = try revision()
            let left = try revision(parent: base, changes: ["body": .text("A")])
            let right = try revision(
                parent: base,
                changes: ["body": .text("B"), "permissions": permissions(mode: 0o600)])
            for value in [base, left, right] { try save(value, root: root) }
            let store = try open(root, accounts, .selectedContent(policy()))
            XCTAssertFalse(store.revisionProjectionEnabled)
            let service = ItemService(store: store)
            func call(_ method: String, _ arguments: [String: Any] = [:], uid: UInt32 = 51001) throws
                -> [String: Any]
            {
                let request = try JSONSerialization.data(withJSONObject: [
                    "using": [ItemService.capability], "methodCalls": [[method, arguments, "c"]],
                ])
                let response = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: service.handle(request, peerUID: uid)) as? [String: Any])
                let methods = try XCTUnwrap(response["methodResponses"] as? [[Any]])
                return try XCTUnwrap(methods.first?[1] as? [String: Any])
            }
            let info = try call("TractandaStore/info")
            let features = try XCTUnwrap(info["features"] as? [String])
            XCTAssertTrue(features.contains(ServerFeature.personalItemState.rawValue))
            XCTAssertFalse(features.contains(ServerFeature.revisionProjection.rawValue))
            let state = try call("TractandaItem/state", ["ids": [base.itemID]])
            XCTAssertEqual((state["list"] as? [[String: Any]])?.first?["status"] as? String, "conflicted")
            let conflicts = try call("TractandaItem/conflicts")
            XCTAssertEqual((conflicts["list"] as? [[String: Any]])?.first?["itemID"] as? String, base.itemID)
            let hidden = try call("TractandaItem/state", ["ids": [base.itemID]], uid: 51002)
            XCTAssertEqual((hidden["list"] as? [Any])?.count, 0)
            XCTAssertEqual(hidden["notFound"] as? [String], [base.itemID])
            let hiddenConflicts = try call("TractandaItem/conflicts", uid: 51002)
            XCTAssertEqual((hiddenConflicts["list"] as? [Any])?.count, 0)
            let unsupported = try call("TractandaItem/resolveConflict", uid: tractanda_uid())
            XCTAssertEqual(unsupported["type"] as? String, "invalidArguments")
        }
    }

}
