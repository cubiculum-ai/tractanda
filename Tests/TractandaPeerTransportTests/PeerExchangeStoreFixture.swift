// Tiny fixture adapted from the existing Core intake tests; no production enrollment.
import CTractandaPlatform
import XCTest

@testable import TractandaCore

enum PeerTransportStoreFixtures {
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
            directory =
                try providedDirectory
                ?? GuardedFixtureDirectory.parent().appendingPathComponent(
                    "tractanda-peer-store-" + (try Self.id()))
            sourceRoot = directory.appendingPathComponent("source")
            receiverRoot = directory.appendingPathComponent("receiver")
            source = try ItemStore.initializeFresh(
                root: sourceRoot, accounts: sourceAccounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice"), .text("bob")]),
                ]))
            configuration = try XCTUnwrap(
                source.candidates().first { $0.classID == AccessConfiguration.classID })
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
                permittedOrigins: [origin, try XCTUnwrap(receiver.replicaID)].sorted())
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
                for offset in stride(from: 0, to: data.count, by: PeerPackage.maximumChunkBytes) {
                    try capacity()
                    _ = try receiver.appendPeerObject(
                        context: current, packageID: packet.manifest.packageID, object: object,
                        offset: offset,
                        bytes: Data(data[offset..<min(data.count, offset + PeerPackage.maximumChunkBytes)]))
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
}
