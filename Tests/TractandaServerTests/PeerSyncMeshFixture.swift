import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

/// Three independently provisioned replicas for peer-runtime convergence tests.
/// Each identity, approval, activation and origin admission is produced by the real Store APIs.
final class PeerSyncMeshFixture {
    let root: URL
    private(set) var accounts: [String: PeerServiceFixture.Accounts] = [:]
    private(set) var roots: [String: URL] = [:]
    var stores: [String: ItemStore] = [:]
    var a: ItemStore? { stores["a"] }
    var b: ItemStore? { stores["b"] }
    var c: ItemStore? { stores["c"] }
    private(set) var credentials: [String: PeerCredential] = [:]
    private(set) var bindings: [String: PeerExchangeBinding] = [:]
    private(set) var replicaIDs: [String: String] = [:]

    init(root: URL) throws {
        self.root = root
        try PeerFixtureCapacity.requireFree(at: FileManager.default.fileExists(atPath: root.path)
            ? root : root.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Existing fixture performs the real A→B baseline approval and activation.
        let abRoot = root.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: abRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let ab = try PeerServiceFixture(root: abRoot)
        accounts = ["a": ab.accounts, "b": PeerServiceFixture.Accounts(), "c": PeerServiceFixture.Accounts()]
        let nodeA = ab.source!
        let nodeB = try ItemStore.openInitialized(root: ab.targetRoot, accounts: accounts["b"]!)
        let storeID = ab.request.sourceContext.storeID
        let idA = try XCTUnwrap(nodeA.replicaID)
        let idB = try XCTUnwrap(nodeB.replicaID)
        guard idA != idB else { throw TractandaError("invalidReplicaIdentity", "Mesh replicas must have distinct identities.") }

        let rootC = root.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let idC = try enroll(source: nodeB, sourceAlias: "enrollment-b", targetRoot: rootC,
            targetAlias: "enrollment-c", storeID: storeID, knownOrigins: [idA, idB],
            sourceAccounts: accounts["b"]!, targetAccounts: accounts["c"]!)
        let nodeC = try ItemStore.openInitialized(root: rootC, accounts: accounts["c"]!)
        guard idC == nodeC.replicaID, Set([idA, idB, idC]).count == 3 else {
            throw TractandaError("invalidReplicaIdentity", "Mesh replicas must have three distinct identities.")
        }

        // Relay C's canonical enrollment publication over the already registered B→A pairing.
        // A must independently validate B's authority before C is admitted there.
        try relayCurrentInventory(from: nodeB, to: nodeA,
            exportContext: ab.request.targetContext, intakeContext: ab.request.sourceContext)
        guard try nodeA.peerOriginMembership(idC) != nil else {
            throw TractandaError("untrustedPeer", "A did not admit C from B's canonical publication.")
        }

        let ids = ["a": idA, "b": idB, "c": idC]
        var pairCredentials: [String: PeerCredential] = [:]
        var pairBindings: [String: PeerExchangeBinding] = [:]
        let links: [(String, String, String, UInt8)] = [("a", "b", "a-b", 0x31),
            ("b", "c", "b-c", 0x52), ("c", "a", "c-a", 0x73)]
        let allOrigins = [idA, idB, idC].sorted()
        let storesByName = ["a": nodeA, "b": nodeB, "c": nodeC]
        for (from, to, label, keyByte) in links {
            let pairingID = try PeerServiceFixture.id()
            let digest = AuthorityRecordCodec.sha256(Data(("mesh-" + label).utf8))
            let fromBinding = try PeerExchangeBinding(peerID: to, storeID: storeID,
                localReplicaID: ids[from]!, remoteReplicaID: ids[to]!, pairingID: pairingID,
                localIsInitiator: true, configurationDigest: digest)
            let toBinding = try PeerExchangeBinding(peerID: from, storeID: storeID,
                localReplicaID: ids[to]!, remoteReplicaID: ids[from]!, pairingID: pairingID,
                localIsInitiator: false, configurationDigest: digest)
            let fromCredential = try PeerCredential(binding: fromBinding,
                secret: [UInt8](repeating: keyByte, count: 32))
            let toCredential = try PeerCredential(binding: toBinding,
                secret: [UInt8](repeating: keyByte, count: 32))
            try register(fromCredential, permittedOrigins: allOrigins, in: storesByName[from]!, accounts: accounts[from]!)
            try register(toCredential, permittedOrigins: allOrigins, in: storesByName[to]!, accounts: accounts[to]!)
            pairCredentials[label] = fromCredential
            pairBindings[label] = fromBinding
        }
        roots = ["a": ab.sourceRoot, "b": ab.targetRoot, "c": rootC]
        stores = storesByName
        credentials = pairCredentials
        bindings = pairBindings
        replicaIDs = ids
        try capacity()
    }

    func releaseWriters() { stores.removeAll() }

    func capacity() throws {
        try PeerFixtureCapacity.requireFree(at: root)
        var total: UInt64 = 0
        guard let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Cannot measure mesh fixture storage.")
        }
        while let url = scan.nextObject() as? URL {
            let metadata = try FileMetadata.read(at: url)
            guard metadata.type == .regular else { continue }
            guard metadata.size <= PeerFixtureCapacity.fixtureCapBytes - min(total, PeerFixtureCapacity.fixtureCapBytes) else {
                throw TractandaError("resourceLimit", "Mesh fixture exceeded its 128MiB cap.")
            }
            total += metadata.size
        }
    }

    func accountDirectory(for node: String) throws -> PeerServiceFixture.Accounts {
        guard let account = accounts[node] else { throw TractandaError("unknownNode", "Mesh node is unavailable.") }
        return account
    }

    private func register(_ credential: PeerCredential, permittedOrigins: [String], in store: ItemStore,
        accounts: PeerServiceFixture.Accounts) throws {
        try store.withAccess(forUID: accounts.human) {
            let token = try store.peerIntakeContextToken()
            let binding = credential.binding
            let context = try PeerPackage.Context(peerID: binding.peerID, storeID: binding.storeID,
                configurationDigest: binding.configurationDigest, permittedOrigins: permittedOrigins)
            try store.registerPeerCredential(credential, context: context,
                expectedContextToken: token, operationID: try PeerServiceFixture.id())
        }
    }

    private func enroll(source: ItemStore, sourceAlias: String, targetRoot: URL, targetAlias: String,
        storeID: String, knownOrigins: [String], sourceAccounts: PeerServiceFixture.Accounts,
        targetAccounts: PeerServiceFixture.Accounts) throws -> String {
        try capacity()
        let sourceID = try XCTUnwrap(source.replicaID)
        let prepared = try PeerEnrollment.prepareTarget(root: targetRoot, commonStoreID: storeID,
            sourceReplicaID: sourceID)
        let targetID = prepared.targetReplicaID
        let sourceContext = try PeerPackage.Context(peerID: targetAlias, storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(("mesh-" + targetAlias).utf8)),
            permittedOrigins: [targetID])
        let targetContext = try PeerPackage.Context(peerID: sourceAlias, storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data(("mesh-" + sourceAlias).utf8)),
            permittedOrigins: knownOrigins.sorted())
        let pairingID = try PeerServiceFixture.id()
        let request = try PeerEnrollmentApproval.Request(operationID: PeerServiceFixture.id(),
            preparationBytes: JSON.encode(prepared), sourceContext: sourceContext, targetContext: targetContext,
            sourceCredential: PeerCredential(binding: .init(peerID: targetAlias, storeID: storeID,
                localReplicaID: sourceID, remoteReplicaID: targetID, pairingID: pairingID,
                localIsInitiator: true, configurationDigest: sourceContext.configurationDigest),
                secret: [UInt8](repeating: 0x24, count: 32)),
            targetCredential: PeerCredential(binding: .init(peerID: sourceAlias, storeID: storeID,
                localReplicaID: targetID, remoteReplicaID: sourceID, pairingID: pairingID,
                localIsInitiator: false, configurationDigest: targetContext.configurationDigest),
                secret: [UInt8](repeating: 0x24, count: 32)))
        let handle = try source.beginPeerEnrollment(request, forUID: sourceAccounts.human)
        var ready = false
        for _ in 0..<1024 {
            try capacity()
            if try source.stepPeerEnrollment(handle, forUID: sourceAccounts.human,
                window: .init(maximumUnits: 4, maximumEdges: 8)).manifest != nil { ready = true; break }
        }
        guard ready else { throw TractandaError("testTimeout", "Tiny mesh enrollment did not finish.") }
        let accepted = try source.acceptPeerEnrollment(handle, forUID: sourceAccounts.human)
        let material = try source.peerEnrollmentActivationMaterial(handle, forUID: sourceAccounts.human)
        let bootstrap = try AuthorityRecord.list(AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
        let pin = try PeerEnrollmentActivation.Pin(sourceReplicaID: sourceID,
            bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)), approval: XCTUnwrap(accepted.approval))
        let session = try PeerEnrollmentActivation.open(root: targetRoot, material: material, pin: pin, accounts: targetAccounts)
        defer { session.close() }
        var cursor: PeerPackage.ResumeCursor?
        var work = 0
        repeat {
            try capacity()
            let page = try session.resume(packageID: material.baseline.packageID, cursor: cursor, limit: 4)
            for object in page.objects where !object.verifiedComplete {
                var offset = object.nextOffset
                while offset < object.descriptor.length {
                    work += 1
                    guard work <= 4096 else { throw TractandaError("resourceLimit", "Mesh activation work cap exceeded.") }
                    try capacity()
                    let chunk = try source.readPeerEnrollment(handle, object: object.descriptor,
                        offset: offset, forUID: sourceAccounts.human)
                    _ = try session.append(packageID: material.baseline.packageID,
                        object: object.descriptor, offset: offset, bytes: chunk.bytes)
                    offset += chunk.bytes.count
                }
            }
            if !page.blockedOnIndex { cursor = page.nextCursor }
            if !page.blockedOnIndex && cursor == nil { break }
        } while work <= 4096
        _ = try session.finish()
        try source.registerAcceptedPeerEnrollment(handle, forUID: sourceAccounts.human)
        try capacity()
        return targetID
    }

    private func relayCurrentInventory(from source: ItemStore, to receiver: ItemStore,
        exportContext: PeerPackage.Context, intakeContext: PeerPackage.Context) throws {
        try capacity()
        let boundary = try source.capturePeerInventory(context: exportContext)
        let page = try source.peerInventoryPage(context: exportContext, boundary: boundary, limit: 128)
        guard page.nextCursor == nil, page.entries.count <= 128 else {
            throw TractandaError("resourceLimit", "Mesh relay inventory exceeded one bounded page.")
        }
        let planID = try PeerServiceFixture.id(), packageID = try PeerServiceFixture.id()
        let handle = try source.beginPeerExport(context: exportContext, planID: planID,
            packageID: packageID, boundary: boundary)
        _ = try source.selectPeerExport(context: exportContext, handle: handle, entries: page.entries, finish: true)
        var status = try source.stepPeerExport(context: exportContext, handle: handle,
            window: .init(maximumUnits: 4, maximumEdges: 8, maximumReadBytes: 2 * 1024 * 1024))
        for _ in 0..<1024 where status.manifest == nil {
            try capacity()
            status = try source.stepPeerExport(context: exportContext, handle: handle,
                window: .init(maximumUnits: 4, maximumEdges: 8, maximumReadBytes: 2 * 1024 * 1024))
        }
        guard let manifest = status.manifest else { throw TractandaError("testTimeout", "Mesh relay export did not seal.") }
        _ = try receiver.beginPeerIntake(context: intakeContext, manifestBytes: JSON.encode(manifest))
        var cursor: PeerPackage.ResumeCursor?, sentBytes = 0, resumePages = 0
        repeat {
            resumePages += 1
            guard resumePages <= 32 else { throw TractandaError("resourceLimit", "Mesh relay resume page cap exceeded.") }
            try capacity()
            let resumed = try receiver.resumePeerIntake(context: intakeContext,
                packageID: manifest.packageID, cursor: cursor, limit: 4)
            // Export object slots omit generated package index pages. Receiver traversal
            // names every missing index/metadata dependency and its exact acknowledged offset.
            for pending in resumed.objects where !pending.verifiedComplete {
                let object = pending.descriptor
                var offset = pending.nextOffset
                while offset < object.length {
                    try capacity()
                    let chunk = try source.readPeerExport(context: exportContext, handle: handle,
                        object: object, offset: offset, maximumBytes: object.chunkBytes)
                    guard !chunk.bytes.isEmpty else { throw TractandaError("fixture", "Relay made no byte progress.") }
                    _ = try receiver.appendPeerObject(context: intakeContext, packageID: manifest.packageID,
                        object: object, offset: offset, bytes: chunk.bytes)
                    offset += chunk.bytes.count; sentBytes += chunk.bytes.count
                    guard sentBytes <= 8 * 1024 * 1024 else {
                        throw TractandaError("resourceLimit", "Tiny mesh relay byte cap exceeded.")
                    }
                }
            }
            if !resumed.blockedOnIndex { cursor = resumed.nextCursor }
            if !resumed.blockedOnIndex && cursor == nil { break }
        } while true
        _ = try receiver.commitPeerIntake(context: intakeContext, packageID: manifest.packageID,
            expectedContextToken: receiver.peerIntakeContextToken())
        try capacity()
    }
}
