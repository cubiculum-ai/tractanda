import CTractandaPlatform
import TractandaClient
import XCTest

@testable import TractandaCore

final class ItemChangesPeerTests: XCTestCase {
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
        let inventory = try source.capturePersonalInventory(session: sourceBinding)
        let object = try XCTUnwrap(inventory.entries.first { $0.id == revision.revisionID })
        try transfer(
            object, from: source, to: target, sourceBinding: sourceBinding, targetBinding: targetBinding)
        return try target.applyPersonalRevision(session: targetBinding, descriptor: object)
    }
    private func nativeCall(_ store: ItemStore, uid: UInt32, method: String, arguments: [String: Any]) throws
        -> [String: Any]
    {
        let accountID = try store.personalSyncIdentity().storeID
        let request = try nativeFixtureEnvelope(calls: [[method, arguments, "c"]], accountID: accountID)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ItemService(store: store).handle(request, peerUID: uid))
                as? [String: Any])
        let calls = try XCTUnwrap(response["methodResponses"] as? [[Any]])
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.first as? String, method, "\(call)")
        return try XCTUnwrap(call[1] as? [String: Any])
    }
    private func nativeState(_ store: ItemStore, uid: UInt32) throws -> String {
        try XCTUnwrap(
            nativeCall(store, uid: uid, method: "TractandaItem/get", arguments: ["ids": []])["state"]
                as? String)
    }
    private func nativeChanges(_ store: ItemStore, uid: UInt32, since: String) throws -> ItemChangesResult {
        let response = try nativeCall(
            store, uid: uid, method: "TractandaItem/changes", arguments: ["sinceState": since])
        return try JSONDecoder().decode(
            ItemChangesResult.self, from: JSONSerialization.data(withJSONObject: response))
    }
    func testLatePeerArrivalAndReplayAreReflectedInChanges() throws {
        try fixture { pair, accounts in
            let base = try create(pair.a, accounts: accounts)
            let baseline = try nativeState(pair.b, uid: accounts.alice)
            XCTAssertEqual(
                try send(
                    base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA,
                    targetBinding: pair.bindingB
                ).status, .accepted)
            let first = try nativeChanges(pair.b, uid: accounts.alice, since: baseline)
            XCTAssertEqual(first.created, [base.itemID])
            XCTAssertTrue(first.updated.isEmpty)
            XCTAssertTrue(first.destroyed.isEmpty)
            XCTAssertFalse(first.hasMoreChanges)
            XCTAssertEqual(
                try pair.b.withAccess(forUID: accounts.alice) { try pair.b.get(base.itemID) }.revisionID,
                base.revisionID)

            let afterArrival = try nativeState(pair.b, uid: accounts.alice)
            XCTAssertEqual(
                try send(
                    base, from: pair.a, to: pair.b, sourceBinding: pair.bindingA,
                    targetBinding: pair.bindingB
                ).status, .known)
            let afterReplay = try nativeState(pair.b, uid: accounts.alice)
            XCTAssertEqual(afterReplay, afterArrival)
            let replay = try nativeChanges(pair.b, uid: accounts.alice, since: afterArrival)
            XCTAssertTrue(replay.created.isEmpty)
            XCTAssertTrue(replay.updated.isEmpty)
            XCTAssertTrue(replay.destroyed.isEmpty)
            XCTAssertEqual(replay.newState, afterArrival)

            let edit = try pair.a.withAccess(forUID: accounts.alice) {
                try pair.a.commit(
                    .init(
                        action: .revise, itemID: base.itemID,
                        expectedRevisionID: base.revisionID, changes: ["body": .text("updated")],
                        operationID: "peer-update")
                ).revision
            }
            XCTAssertEqual(
                try send(
                    edit, from: pair.a, to: pair.b, sourceBinding: pair.bindingA,
                    targetBinding: pair.bindingB
                ).status, .accepted)
            let changed = try nativeChanges(pair.b, uid: accounts.alice, since: afterReplay)
            XCTAssertEqual(changed.updated, [base.itemID])
            XCTAssertTrue(changed.created.isEmpty)
            XCTAssertTrue(changed.destroyed.isEmpty)
            XCTAssertEqual(
                try pair.b.withAccess(forUID: accounts.alice) { try pair.b.get(base.itemID) }.revisionID,
                edit.revisionID)
        }
    }
}
