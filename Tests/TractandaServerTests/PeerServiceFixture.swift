import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

/// A real fresh source and an explicitly approved, transferred, activated and registered target.
/// No cloned identity or direct trust-table writes. Two tiny stores are estimated below16MiB.
final class PeerServiceFixture {
    final class Accounts: AccountDirectory, @unchecked Sendable {
        let human: UInt32 = 51001
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [71002])
            }
            if uid == human {
                return .init(uid: uid, name: "human", primaryGroupName: "staff", groupIDs: [71001])
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "daemon" { return try user(forUID: tractanda_uid()) }
            if name == "human" { return try user(forUID: human) }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func groupID(named name: String) throws -> UInt32 {
            if ["staff", "admin", "sudo"].contains(name) { return 71001 }
            if name == "service" { return 71002 }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
        }
    }
    let root: URL
    let sourceRoot: URL
    let targetRoot: URL
    let accounts = Accounts()
    let request: PeerEnrollmentApproval.Request
    var source: ItemStore!
    static func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    init(root: URL) throws {
        self.root = root
        sourceRoot = root.appendingPathComponent("source")
        targetRoot = root.appendingPathComponent("target")
        try PeerFixtureCapacity.requireFree(at: root)
        try FileManager.default.createDirectory(
            at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        source = try ItemStore.initializeFresh(
            root: sourceRoot, accounts: accounts,
            initialAccessConfiguration: .object([
                "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
                "administration": .text("system"), "administratorGroup": .text("staff"),
            ]))
        let storeID = try CanonicalReaderRequirement.storeIdentity(
            root: sourceRoot, ownerUID: tractanda_uid())
        let sourceID = try XCTUnwrap(source.replicaID)
        let prepared = try PeerEnrollment.prepareTarget(
            root: targetRoot, commonStoreID: storeID, sourceReplicaID: sourceID)
        let sourceContext = try PeerPackage.Context(
            peerID: "target", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("service-source".utf8)),
            permittedOrigins: [prepared.targetReplicaID])
        let targetContext = try PeerPackage.Context(
            peerID: "source", storeID: storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("service-target".utf8)),
            permittedOrigins: [sourceID])
        let pairingID = try Self.id()
        request = try .init(
            operationID: Self.id(), preparationBytes: JSON.encode(prepared),
            sourceContext: sourceContext, targetContext: targetContext,
            sourceCredential: .init(
                binding: .init(
                    peerID: "target", storeID: storeID, localReplicaID: sourceID,
                    remoteReplicaID: prepared.targetReplicaID, pairingID: pairingID, localIsInitiator: true,
                    configurationDigest: sourceContext.configurationDigest), secret: Array(0..<32)),
            targetCredential: .init(
                binding: .init(
                    peerID: "source", storeID: storeID, localReplicaID: prepared.targetReplicaID,
                    remoteReplicaID: sourceID, pairingID: pairingID, localIsInitiator: false,
                    configurationDigest: targetContext.configurationDigest), secret: Array(0..<32)))
        let handle = try source.beginPeerEnrollment(request, forUID: accounts.human)
        var ready = false
        for _ in 0..<1024 {
            try capacity()
            if try source.stepPeerEnrollment(
                handle, forUID: accounts.human,
                window: .init(maximumUnits: 4, maximumEdges: 8)
            ).manifest != nil {
                ready = true
                break
            }
        }
        guard ready else { throw TractandaError("testTimeout", "Tiny enrollment did not close") }
        let accepted = try source.acceptPeerEnrollment(handle, forUID: accounts.human)
        let material = try source.peerEnrollmentActivationMaterial(handle, forUID: accounts.human)
        let bootstrap = try AuthorityRecord.list(
            AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
        let pin = try PeerEnrollmentActivation.Pin(
            sourceReplicaID: sourceID,
            bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)),
            approval: XCTUnwrap(accepted.approval))
        let session = try PeerEnrollmentActivation.open(
            root: targetRoot, material: material, pin: pin, accounts: accounts)
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
                    guard work <= 4096 else {
                        throw TractandaError("resourceLimit", "Tiny activation work cap")
                    }
                    let chunk = try source.readPeerEnrollment(
                        handle, object: object.descriptor, offset: offset, forUID: accounts.human)
                    _ = try session.append(
                        packageID: material.baseline.packageID, object: object.descriptor, offset: offset,
                        bytes: chunk.bytes)
                    offset += chunk.bytes.count
                }
            }
            if !page.blockedOnIndex { cursor = page.nextCursor }
            if !page.blockedOnIndex && cursor == nil { break }
        } while work <= 4096
        _ = try session.finish()
        try source.registerAcceptedPeerEnrollment(handle, forUID: accounts.human)
        try capacity()
    }
    func releaseWriter() { source = nil }
    func capacity() throws {
        try PeerFixtureCapacity.requireFree(at: root)
        var bytes: UInt64 = 0
        let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        while let url = scan.nextObject() as? URL {
            let metadata = try FileMetadata.read(at: url)
            if metadata.type == .regular {
                guard
                    metadata.size <= PeerFixtureCapacity.fixtureCapBytes
                        - min(bytes, PeerFixtureCapacity.fixtureCapBytes)
                else {
                    throw TractandaError("resourceLimit", "Tiny service fixture cap exceeded")
                }
                bytes += metadata.size
            }
        }
    }
}
