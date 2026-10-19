import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerIntakeStoreTests: XCTestCase {
    final class Accounts: AccountDirectory {
        let alice: UInt32 = 51001
        let bob: UInt32 = 51002
        let group: UInt32 = 71001
        var bobHasGroup = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            if uid == tractanda_uid() {
                name = "admin"
            } else if uid == alice {
                name = "alice"
            } else if uid == bob {
                name = "bob"
            } else {
                throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
            return .init(
                uid: uid, name: name, primaryGroupName: "staff",
                groupIDs: uid == bob && !bobHasGroup ? [] : [group])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": try user(forUID: tractanda_uid())
            case "alice": try user(forUID: alice)
            case "bob": try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown test account")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return group
        }
    }
    struct Packet {
        let manifest: PeerPackage.Manifest
        let objects: [(PeerPackage.Object, Data)]
    }
    final class Fixture {
        let directory: URL
        let sourceRoot: URL
        let receiverRoot: URL
        let sourceAccounts = Accounts()
        let receiverAccounts = Accounts()
        var source: ItemStore!
        var receiver: ItemStore!
        var base: Revision!
        var configuration: Revision!
        var context: PeerPackage.Context!
        var storeID = ""
        var origin = ""
        init(directory providedDirectory: URL? = nil) throws {
            try AttachmentFixtureCapacity.requireFree()
            // Two ordinary tiny stores plus their WALs are expected below 16 MiB.
            guard UInt64(16 * 1024 * 1024) <= AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Fixture estimate")
            }
            directory = try providedDirectory ?? GuardedFixtureDirectory.parent().appendingPathComponent(
                "tractanda-peer-store-" + (try Self.id()))
            sourceRoot = directory.appendingPathComponent("source")
            receiverRoot = directory.appendingPathComponent("receiver")
            source = try Self.open(sourceRoot, sourceAccounts)
            configuration = try source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice"), .text("bob")]),
                ]), operationID: "configure"
            ).revision
            base = try source.withAccess(forUID: sourceAccounts.alice) {
                try source.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "subject": .text("base"),
                            "permissions": .object([
                                "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                                "group": .text("staff"),
                                "mode": .integer(0o660), "acl": .object([:]),
                            ]),
                        ], operationID: "create")
                ).revision
            }
            origin = try XCTUnwrap(base.provenance).originReplicaID
            let identityName = ".tractanda-store-identity.json"
            let identity = try Data(contentsOf: sourceRoot.appendingPathComponent(identityName))
            let value = try JSONSerialization.jsonObject(with: identity) as! [String: Any]
            storeID = try XCTUnwrap(value["storeID"] as? String)
            // Explicit fixture clone joins with the same logical StoreID and a fresh local
            // ReplicaID. No existing receiver content or identity is discarded.
            receiver = try ItemStore(
                root: receiverRoot, accounts: receiverAccounts, revisionProjectionEnabled: true)
            guard try receiver.exportCatalogueForVerification().isEmpty else {
                throw TractandaError("fixture", "Join requires an empty fixture")
            }
            receiver = nil
            try identity.write(to: receiverRoot.appendingPathComponent(identityName), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiverRoot.appendingPathComponent(identityName).path)
            try FileManager.default.removeItem(at: receiverRoot.appendingPathComponent("index"))
            receiver = try Self.open(receiverRoot, receiverAccounts)
            context = try PeerPackage.Context(
                peerID: "raven", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("raven-config-1".utf8)),
                permittedOrigins: [origin])
            try receiver.configurePeerIntake(peers: [context])
            try capacity()
        }
        deinit {
            receiver = nil
            source = nil
            try? FileManager.default.removeItem(at: directory)
        }
        static func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        static func isEvidence(_ value: (PeerPackage.Object, Data), for revisionID: String) -> Bool {
            guard value.0.kind == .authority, let record = try? AuthorityRecordCodec.decode(value.1).record,
                record.kind == .authoredEvidence,
                let target = try? AuthorityRecord.binding(record.payload["target"])
            else { return false }
            return target.revisionID == revisionID
        }
        static func open(_ root: URL, _ accounts: Accounts) throws -> ItemStore {
            try AttachmentFixtureCapacity.requireFree()
            return try ItemStore(
                root: root, accounts: accounts, revisionProjectionEnabled: true, authorityIntakeEnabled: true)
        }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: directory)
            var bytes: UInt64 = 0
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            while let file = enumerator.nextObject() as? URL {
                let metadata = try FileMetadata.read(at: file)
                if metadata.type == .regular {
                    guard
                        metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                            - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                    else { throw TractandaError("resourceLimit", "Fixture cap") }
                    bytes += metadata.size
                }
            }
        }
        func packet(_ objects: [(PeerPackage.Object, Data)]) throws -> Packet {
            let page = try JSON.encode(PeerPackage.Page(objects: objects.map(\.0), children: []))
            let descriptor = PeerPackage.Object(
                kind: .index, id: try Self.id(), length: page.count, sha256: AuthorityRecordCodec.sha256(page)
            )
            return .init(
                manifest: .init(packageID: try Self.id(), storeID: storeID, root: descriptor),
                objects: [(descriptor, page)] + objects)
        }
        func send(_ packet: Packet, context supplied: PeerPackage.Context? = nil, to target: ItemStore? = nil)
            throws
            -> AuthorityStore.Result
        {
            let receiver = target ?? self.receiver!
            let current = supplied ?? context!
            try capacity()
            _ = try receiver.beginPeerIntake(context: current, manifestBytes: JSON.encode(packet.manifest))
            for (object, data) in packet.objects {
                for offset in stride(from: 0, to: data.count, by: object.chunkBytes) {
                    try capacity()
                    _ = try receiver.appendPeerObject(
                        context: current, packageID: packet.manifest.packageID, object: object,
                        offset: offset,
                        bytes: Data(data[offset..<min(data.count, offset + object.chunkBytes)]))
                }
            }
            let result = try receiver.commitPeerIntake(
                context: current, packageID: packet.manifest.packageID,
                expectedContextToken: receiver.peerIntakeContextToken())
            try capacity()
            return result
        }
        func bootstrap(extra: [(PeerPackage.Object, Data)] = [], to target: ItemStore? = nil) throws {
            let receiver = target ?? self.receiver!
            var unique: [String: (PeerPackage.Object, Data)] = [:]
            for row in try source.exportCatalogueForVerification() {
                for value in try source.peerMetadataObjects(revisionID: row.revisionID) {
                    unique[value.0.id] = value
                }
                try capacity()
            }
            var originals = unique.values.sorted { $0.0.id < $1.0.id }
            originals += extra
            let rootID = try Self.id()
            let pageID = try Self.id()
            let entries = try originals.filter { $0.0.kind == .item }.sorted { $0.0.id < $1.0.id }.map {
                object, bytes -> ItemValue in
                let revision = try RecordCodec.decode(bytes)
                return .object([
                    "target": .object([
                        "itemID": .text(revision.itemID), "revisionID": .text(revision.revisionID),
                        "sha256": .text(object.sha256),
                    ]),
                    "frontier": .list(
                        try
                            (revision.provenance?.kind == .automaticMerge
                            ? revision.provenance!.frontier : [revision.revisionID]).map(ItemValue.text)),
                ])
            }
            let page = try AuthorityRecord(
                recordID: pageID, storeID: storeID, originReplicaID: origin,
                kind: .bootstrapPage, actorPrincipal: "admin", createdAt: Timestamp.now(),
                payload: ["manifestID": .text(rootID), "entries": .list(entries)])
            let pageBytes = try AuthorityRecordCodec.encode(page)
            let indexID = try Self.id()
            let index = try AuthorityRecord(
                recordID: indexID, storeID: storeID, originReplicaID: origin,
                kind: .bootstrapIndex, parentAuthorityIDs: [pageID], actorPrincipal: "admin",
                createdAt: Timestamp.now(),
                payload: [
                    "manifestID": .text(rootID),
                    "children": .list([
                        .object([
                            "recordID": .text(pageID),
                            "sha256": .text(AuthorityRecordCodec.sha256(pageBytes)),
                        ])
                    ]),
                ])
            let indexBytes = try AuthorityRecordCodec.encode(index)
            let root = try AuthorityRecord(
                recordID: rootID, storeID: storeID, originReplicaID: origin, kind: .bootstrap,
                parentAuthorityIDs: [indexID], actorPrincipal: "admin", createdAt: Timestamp.now(),
                payload: [
                    "pages": .list([
                        .object([
                            "recordID": .text(indexID),
                            "sha256": .text(AuthorityRecordCodec.sha256(indexBytes)),
                        ])
                    ]),
                    "initial": .boolean(true), "administrationPolicies": .list([]),
                ])
            let rootBytes = try AuthorityRecordCodec.encode(root)
            originals += [
                (
                    .init(
                        kind: .authority, id: indexID, length: indexBytes.count,
                        sha256: AuthorityRecordCodec.sha256(indexBytes)), indexBytes
                ),
                (
                    .init(
                        kind: .authority, id: pageID, length: pageBytes.count,
                        sha256: AuthorityRecordCodec.sha256(pageBytes)), pageBytes
                ),
                (
                    .init(
                        kind: .authority, id: rootID, length: rootBytes.count,
                        sha256: AuthorityRecordCodec.sha256(rootBytes)), rootBytes
                ),
            ]
            _ = try send(packet(originals), to: receiver)
            try receiver.pinAuthorityBootstrap(
                rootID: rootID, sha256: AuthorityRecordCodec.sha256(rootBytes),
                expectedContextToken: receiver.peerIntakeContextToken())
            try capacity()
        }
        func edit(uid: UInt32? = nil, subject: String = "incoming") throws -> Revision {
            try capacity()
            return try source.withAccess(forUID: uid ?? sourceAccounts.alice) {
                let current = try source.get(base.itemID)
                return try source.commit(
                    CommitRequest(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: current.revisionID, changes: ["subject": .text(subject)],
                        operationID: "edit-" + (try Self.id()))
                ).revision
            }
        }
    }
    func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    private func legacy(_ request: CommitRequest, actor: String = "user:alice") throws -> (
        PeerPackage.Object, Data, Revision
    ) {
        let itemID = try Fixture.id()
        let revisionID = try Fixture.id()
        var fields: [String: ItemValue] = [
            "itemID": .text(itemID), "revisionID": .text(revisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2001-01-01T00:00:00Z"),
            "modifiedAt": .date("2001-01-01T00:00:00Z"), "actor": .text(actor),
            "operationID": .text(request.operationID),
            "requestIdentity": .text(try JSON.encode(request).base64EncodedString()),
            "permissions": .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("alice"), "group": .text("staff"),
                "mode": .integer(0o660), "acl": .object([:]),
            ]),
        ]
        fields.merge(request.changes) { _, new in new }
        let revision = try Revision(fields: fields)
        let bytes = try RecordCodec.encode(revision)
        return (
            .init(
                kind: .item, id: revisionID, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes)),
            bytes, revision
        )
    }
    func testExistingHistoryRemainsUnpinnedAcrossReopenAndRebuildAndLocalLegacyReplayIsScoped() throws {
        let f = try Fixture()
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("local prehistory")],
            operationID: "local-legacy-replay")
        let (descriptor, bytes, old) = try legacy(request)
        f.receiver = nil
        let existing = f.directory.appendingPathComponent("existing")
        var seed: ItemStore? = try ItemStore(
            root: existing, accounts: f.receiverAccounts, revisionProjectionEnabled: true)
        guard try XCTUnwrap(seed).exportCatalogueForVerification().isEmpty else {
            throw TractandaError("fixture", "Join requires an empty fixture")
        }
        seed = nil
        _ = seed
        let identityName = ".tractanda-store-identity.json"
        try Data(contentsOf: f.sourceRoot.appendingPathComponent(identityName)).write(
            to: existing.appendingPathComponent(identityName))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: existing.appendingPathComponent(identityName).path)
        // Explicitly joining this empty fixture invalidates both disposable StoreID-bound indexes.
        try FileManager.default.removeItem(at: existing.appendingPathComponent("index"))
        let files = DocumentContentFiles(
            root: existing, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        try files.writeImmutable(
            bytes,
            path: ["items", "2001", "01", "01", "00", "00", old.itemID, old.revisionID + ".tractanda"],
            maximumBytes: 8 * 1024 * 1024)
        f.receiver = try Fixture.open(existing, f.receiverAccounts)
        code("authorityBootstrapRequired") {
            _ = try f.receiver.commit(CommitRequest(classID: "Item", operationID: "must-not-publish"))
        }
        f.receiver = nil
        f.receiver = try Fixture.open(existing, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        code("authorityBootstrapRequired") {
            _ = try f.receiver.commit(CommitRequest(classID: "Item", operationID: "still-unpinned"))
        }
        try f.receiver.configurePeerIntake(peers: [f.context])
        // A sealed-but-withheld observation must not erase the durable initial coverage duty.
        _ = try f.send(f.packet([(descriptor, bytes)]))
        try f.receiver.rebuildIndex()
        // A cut omitting pre-existing history must fail without persisting an unusable pin.
        code("authorityBootstrapRequired") { try f.bootstrap() }
        try f.bootstrap(extra: [(descriptor, bytes)])
        let replay = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(request)
        }
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revision, old)
        // The same actor/operation retained from another peer is history, never a local receipt.
        let importedRequest = CommitRequest(
            classID: "Item", changes: ["subject": .text("imported")], operationID: "foreign-legacy-collision")
        // Bootstrap is immutable: use another fresh receiver to exercise an imported baseline.
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        let imported = try legacy(importedRequest)
        try f.bootstrap(extra: [(imported.0, imported.1)])
        code("operationOriginRequired") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
                try f.receiver.commit(importedRequest)
            }
        }
        XCTAssertEqual(try f.receiver.get(imported.2.itemID), imported.2)
        try f.capacity()
    }
    func testForeignOrdinaryEditPreservesUnchangedLearningFeedbackReferences() throws {
        let f = try Fixture()
        let feedback = ItemValue.object([
            try Fixture.id(): .object(["action": .text("dismiss"), "revisionID": .text(f.base.revisionID)])
        ])
        f.base = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                CommitRequest(
                    action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    changes: ["learningFeedback": feedback], operationID: "feedback-baseline")
            ).revision
        }
        try f.bootstrap()
        let next = try f.edit()
        let result = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID)))
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(try f.receiver.get(next.itemID).fields["learningFeedback"], feedback)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
    }
    func testPinnedBaselineAndFreshMetadataPreserveOriginalBytesActorsAndCurrentReadPolicy() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit()
        let objects = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        let packet = try f.packet(objects)
        XCTAssertEqual(try f.send(packet).accepted, 1)
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
        XCTAssertEqual(try f.receiver.get(next.itemID).fields["actor"], .text("user:alice"))
        XCTAssertEqual(try f.send(packet).accepted, 1)
        let retained = try f.receiver.peerMetadataObjects(revisionID: next.revisionID)
        XCTAssertEqual(retained.first?.1, objects.first?.1)
        XCTAssertEqual(
            try CanonicalReaderRequirement.load(root: f.receiverRoot, ownerUID: tractanda_uid())?
                .minimumReaderLevel, 11)
        f.receiver = nil
        code("authorityModeRequired") {
            _ = try ItemStore(root: f.receiverRoot, accounts: f.receiverAccounts)
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
        try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            XCTAssertEqual(try f.receiver.get(next.itemID).revisionID, next.revisionID)
        }
        f.receiverAccounts.bobHasGroup = false
        code("forbidden") {
            _ = try f.receiver.withAccess(forUID: f.receiverAccounts.bob) { try f.receiver.get(next.itemID) }
        }
    }
    func testStaleMembershipIsHeldWithoutFreezingAcceptedLocalEditsOrRetroactiveGrant() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(uid: f.sourceAccounts.bob)
        f.receiverAccounts.bobHasGroup = false
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID))
        let result = try f.send(packet)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.held, 1)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        let local = try f.receiver.withAccess(forUID: f.receiverAccounts.alice) {
            try f.receiver.commit(
                CommitRequest(
                    action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    changes: ["body": .text("accepted local")], operationID: "local-beside-held")
            ).revision
        }
        XCTAssertEqual(try f.receiver.get(local.itemID), local)
        XCTAssertFalse(try f.receiver.history(local.itemID).contains { $0.revisionID == next.revisionID })
        f.receiverAccounts.bobHasGroup = true
        XCTAssertEqual(try f.send(packet).accepted, 0)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        try f.receiver.rebuildIndex()
        XCTAssertEqual(try f.receiver.get(local.itemID), local)
    }
    func testCollisionIsRejectedBeforeSealingAndDoesNotInvalidateAcceptedQueries() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit()
        XCTAssertEqual(
            try f.send(f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID))).accepted, 1)
        var fields = next.fields
        fields["subject"] = .text("different original with same ID")
        let forged = try RecordCodec.encode(Revision(fields: fields, formatVersion: 2))
        let packet = try f.packet([
            (
                .init(
                    kind: .item, id: next.revisionID, length: forged.count,
                    sha256: AuthorityRecordCodec.sha256(forged)), forged
            )
        ])
        code("peerObjectCollision") { _ = try f.send(packet) }
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
        XCTAssertEqual(
            try f.receiver.inspectPeerIntake(context: f.context, packageID: packet.manifest.packageID).phase,
            .staged)
    }
    func testCurrentConfigurationIsRecheckedAndOriginRemovalNeedsReconciliation() throws {
        let f = try Fixture()
        try f.bootstrap()
        let old = f.context!
        let replacement = try PeerPackage.Context(
            peerID: "raven", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("raven-config-2".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.rotatePeerIntakeCredential(
            peerID: "raven", replacement: replacement, operationID: Fixture.id())
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: f.base.revisionID))
        code("peerConfigurationChanged") {
            _ = try f.receiver.beginPeerIntake(context: old, manifestBytes: JSON.encode(packet.manifest))
        }
        code("managedPeerLifecycleRequired") { try f.receiver.configurePeerIntake(peers: []) }
        _ = try f.receiver.configureAccess(
            .object(["profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")])]),
            operationID: "revocation-with-cut")
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
    }
    func testRelayVouchesOnlyForExplicitKnownOriginsAndReusesTheOriginalLocator() throws {
        let f = try Fixture()
        try f.bootstrap()
        let sourceEdit = try f.edit()
        let sourceObjects = try f.source.peerMetadataObjects(revisionID: sourceEdit.revisionID)
        let oldEvidence = try AuthorityRecordCodec.decode(
            XCTUnwrap(
                sourceObjects.first {
                    Fixture.isEvidence($0, for: sourceEdit.revisionID)
                }
            ).1
        ).record
        let relayedOrigin = try Fixture.id()
        let revisionID = try Fixture.id()
        var fields = sourceEdit.fields
        fields["revisionID"] = .text(revisionID)
        fields["operationID"] = .text("relayed-intent")
        fields["requestIdentity"] = .text(
            try JSON.encode(
                CommitRequest(
                    action: .revise, itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID, changes: ["subject": fields["subject"]!],
                    operationID: "relayed-intent")
            ).base64EncodedString())
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: .authored, originReplicaID: relayedOrigin,
            parents: [f.base.revisionID], writtenFields: ["subject"], unsetFields: [], frontier: []
        ).itemValue
        let revision = try Revision(fields: fields, formatVersion: 2)
        let original = try RecordCodec.encode(revision)
        var payload = oldEvidence.payload
        payload["target"] = .object([
            "itemID": .text(revision.itemID), "revisionID": .text(revisionID),
            "sha256": .text(AuthorityRecordCodec.sha256(original)),
        ])
        let sourceCut = try AuthorityBinding(
            value: AuthorityRecord.list(oldEvidence.payload["sourceControl"]).first!)
        let relayCut = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: relayedOrigin,
            kind: .controlCommit, parentAuthorityIDs: [sourceCut.recordID],
            actorPrincipal: "alice", createdAt: Timestamp.now(),
            payload: [
                "controls": .list([sourceCut.itemValue]), "localParent": .list([]),
                "deltas": .list([]), "bootstrap": .list([]),
            ])
        let relayCutBytes = try AuthorityRecordCodec.encode(relayCut)
        payload["sourceControl"] = .list([
            try AuthorityBinding(
                recordID: relayCut.recordID,
                sha256: AuthorityRecordCodec.sha256(relayCutBytes)
            ).itemValue
        ])
        let evidence = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: relayedOrigin,
            kind: .authoredEvidence, parentAuthorityIDs: [relayCut.recordID],
            actorPrincipal: "alice", createdAt: Timestamp.now(), payload: payload)
        let evidenceBytes = try AuthorityRecordCodec.encode(evidence)
        let objects: [(PeerPackage.Object, Data)] =
            sourceObjects.filter { pair in
                pair.0.kind == .authority && pair.0.id != oldEvidence.recordID
                    && (try? AuthorityRecordCodec.decode(pair.1).record.kind) != .visibilityWitness
            } + [
                (
                    .init(
                        kind: .authority, id: relayCut.recordID, length: relayCutBytes.count,
                        sha256: AuthorityRecordCodec.sha256(relayCutBytes)), relayCutBytes
                ),
                (
                    .init(
                        kind: .item, id: revisionID, length: original.count,
                        sha256: AuthorityRecordCodec.sha256(original)), original
                ),
                (
                    .init(
                        kind: .authority, id: evidence.recordID, length: evidenceBytes.count,
                        sha256: AuthorityRecordCodec.sha256(evidenceBytes)), evidenceBytes
                ),
            ]
        XCTAssertEqual(try f.send(f.packet(objects)).held, 1)
        XCTAssertEqual(try f.receiver.get(revision.itemID).revisionID, f.base.revisionID)
        let previous = f.context!
        f.context = try PeerPackage.Context(
            peerID: "raven-relay", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("raven-allows-known-relay".utf8)),
            permittedOrigins: [f.origin, relayedOrigin].sorted())
        try f.receiver.configurePeerIntake(peers: [previous, f.context])
        XCTAssertEqual(try f.send(f.packet(objects)).accepted, 1)
        XCTAssertEqual(try f.receiver.get(revision.itemID), revision)
        let files = FileManager.default.enumerator(
            at: f.receiverRoot.appendingPathComponent("items"), includingPropertiesForKeys: nil)!
        var matches = 0
        while let file = files.nextObject() as? URL {
            if file.lastPathComponent == revisionID + ".tractanda" {
                matches += 1
                XCTAssertEqual(try Data(contentsOf: file), original)
            }
        }
        XCTAssertEqual(matches, 1, "Relays share one immutable original rather than arrival-path copies.")
    }
    func testHeldOriginalsAreVerifiedWithoutBecomingUnexpectedAcceptedHistory() async throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(uid: f.sourceAccounts.bob)
        f.receiverAccounts.bobHasGroup = false
        _ = try f.send(f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID)))
        let result = await CanonicalVerifier.scan(
            try f.receiver.verificationSnapshot(),
            onFindings: { findings in
                XCTAssertTrue(findings.isEmpty, "A retained held original is part of raw inventory.")
            })
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.exactFindingCount, 0)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
    }
    func testLegacyOriginalWithRetiredActorNeedsOnlyTheExplicitPinnedInitialCut() throws {
        let f = try Fixture()
        let itemID = try Fixture.id()
        let revisionID = try Fixture.id()
        let legacy = try Revision(fields: [
            "itemID": .text(itemID), "revisionID": .text(revisionID), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2001-01-01T00:00:00Z"),
            "modifiedAt": .date("2001-01-01T00:00:00Z"), "actor": .text("user:retired"),
            "operationID": .text("old-retained-intent"), "requestIdentity": .text("old-original"),
            "subject": .text("old baseline"),
        ])
        let bytes = try RecordCodec.encode(legacy)
        let descriptor = PeerPackage.Object(
            kind: .item, id: revisionID, length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        try f.bootstrap(extra: [(descriptor, bytes)])
        XCTAssertEqual(try f.receiver.get(itemID), legacy)
        XCTAssertEqual(try f.receiver.peerMetadataObjects(revisionID: revisionID).first?.1, bytes)
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.history(itemID).first?.fields["actor"], .text("user:retired"))
    }
    func testSealedIntentRechecksFreshPolicyAfterAProcessBoundary() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(uid: f.sourceAccounts.bob)
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID))
        f.receiver.peerIntakeBoundaryForTesting = { boundary in
            if boundary == .sealed { throw TractandaError("injectedCrash", "after durable seal") }
        }
        code("injectedCrash") { _ = try f.send(packet) }
        f.receiverAccounts.bobHasGroup = false
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        XCTAssertTrue(
            [.sealed, .applied].contains(
                try f.receiver.inspectPeerIntake(context: f.context, packageID: packet.manifest.packageID)
                    .phase))
        XCTAssertFalse(try f.receiver.history(f.base.itemID).contains { $0.revisionID == next.revisionID })
    }
    func testPostOriginalResourceFailureKeepsDirtyGateAndRecoversWithoutDuplicateCopies() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit()
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID))
        f.receiver.peerIntakeOriginalPublicationForTesting = {
            throw TractandaError("resourceLimit", "injected after original fsync")
        }
        code("resourceLimit") { _ = try f.send(packet) }
        XCTAssertTrue(StoreCheckpoint.isDirty(root: f.receiverRoot))
        code("recoveryRequired") { _ = try f.receiver.get(f.base.itemID) }
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
        XCTAssertEqual(
            try f.receiver.peerMetadataObjects(revisionID: next.revisionID).first?.1,
            try f.source.peerMetadataObjects(revisionID: next.revisionID).first?.1)
    }
    func testOutOfOrderParentRemainsMissingUntilExplicitResumableCommitRetry() throws {
        let f = try Fixture()
        try f.bootstrap()
        let parent = try f.edit(subject: "parent")
        let child = try f.edit(subject: "child")
        let childPacket = try f.packet(f.source.peerMetadataObjects(revisionID: child.revisionID))
        XCTAssertEqual(try f.send(childPacket).missing, 1)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        XCTAssertEqual(
            try f.send(f.packet(f.source.peerMetadataObjects(revisionID: parent.revisionID))).accepted, 1)
        XCTAssertEqual(try f.send(childPacket).accepted, 1)
        XCTAssertEqual(try f.receiver.get(child.itemID), child)
        XCTAssertEqual(try f.receiver.history(child.itemID).count, 3)
    }
    func testUnknownRawEvidenceCannotReserveTheLaterValidAuthorityBinding() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit()
        let originals = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        let good = try AuthorityRecordCodec.decode(
            XCTUnwrap(
                originals.first {
                    Fixture.isEvidence($0, for: next.revisionID)
                }
            ).1)
        let bad = try AuthorityRecord(
            recordID: Fixture.id(), storeID: f.storeID, originReplicaID: Fixture.id(),
            kind: .authoredEvidence, parentAuthorityIDs: good.record.parentAuthorityIDs,
            actorPrincipal: good.record.actorPrincipal, createdAt: Timestamp.now(),
            payload: good.record.payload)
        let badBytes = try AuthorityRecordCodec.encode(bad)
        _ = try f.send(
            f.packet([
                (
                    .init(
                        kind: .authority, id: bad.recordID, length: badBytes.count,
                        sha256: AuthorityRecordCodec.sha256(badBytes)), badBytes
                )
            ]))
        XCTAssertEqual(try f.send(f.packet(originals)).accepted, 1)
        let exported = try f.receiver.peerMetadataObjects(revisionID: next.revisionID)
        XCTAssertEqual(
            exported.first {
                Fixture.isEvidence($0, for: next.revisionID)
            }?.0.id, good.record.recordID)
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
    }
    func testPreviouslySealedFreshEvidenceAndExplicitKnownByteAdoptionNeedNoRetransmission() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit()
        let objects = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        let evidence = try XCTUnwrap(
            objects.first {
                Fixture.isEvidence($0, for: next.revisionID)
            })
        let item = try XCTUnwrap(objects.first { $0.0.kind == .item })
        _ = evidence  // Metadata may arrive earlier, independently of its item bytes.
        _ = try f.send(f.packet(objects.filter { $0.0.kind != .item }))
        XCTAssertEqual(try f.send(f.packet([item])).accepted, 1)
        let stash = try PeerPackage.Context(
            peerID: "stash", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("stash-config".utf8)),
            permittedOrigins: [f.origin])
        try f.receiver.configurePeerIntake(peers: [f.context, stash])
        let framed = try f.packet(objects)
        let adoption = Packet(
            manifest: framed.manifest, objects: framed.objects.filter { $0.0.kind == .index })
        XCTAssertEqual(try f.send(adoption, context: stash).accepted, 1)
        XCTAssertEqual(try f.receiver.get(next.itemID), next)
        XCTAssertEqual(try f.receiver.peerMetadataObjects(revisionID: next.revisionID).first?.1, item.1)
    }
}
