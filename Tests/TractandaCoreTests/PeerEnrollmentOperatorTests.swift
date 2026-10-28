import CTractandaPlatform
import Foundation
import Synchronization
import XCTest

@testable import TractandaCore

final class PeerEnrollmentOperatorTests: XCTestCase {
    final class Accounts: AccountDirectory, @unchecked Sendable {
        let author = tractanda_uid(), outsider: UInt32 = 51002, administrator: UInt32 = 51003
        let demoted = Mutex(false)
        let renamed = Mutex(false)
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            switch uid {
            case author:
                return .init(
                    uid: uid, name: renamed.withLock { $0 } ? "renamed" : "human",
                    primaryGroupName: "staff", groupIDs: demoted.withLock { $0 } ? [] : [71001])
            case outsider:
                return .init(uid: uid, name: "ordinary", primaryGroupName: "users", groupIDs: [71002])
            case administrator:
                return .init(uid: uid, name: "second", primaryGroupName: "staff", groupIDs: [71001])
            default: throw TractandaError("unresolvedPrincipal", "Unknown isolated operator account.")
            }
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "human", "renamed": return try user(forUID: author)
            case "ordinary": return try user(forUID: outsider)
            case "second": return try user(forUID: administrator)
            default: throw TractandaError("unresolvedPrincipal", "Unknown isolated operator account.")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            if ["staff", "admin", "sudo"].contains(name) { return 71001 }
            if name == "users" { return 71002 }
            throw TractandaError("unresolvedPrincipal", "Unknown isolated operator group.")
        }
    }
    final class Fixture {
        let root: URL, sourceRoot: URL, targetRoot: URL
        let accounts = Accounts()
        var source: ItemStore!
        let input: PeerEnrollmentPairInput
        let operation: String
        init(test: String) throws {
            try AttachmentFixtureCapacity.requireFree()
            root = try GuardedFixtureDirectory.create(
                prefix: "e", source: "PeerEnrollmentOperatorTests", test: test)
            sourceRoot = root.appendingPathComponent("source")
            targetRoot = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(
                at: targetRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            source = try ItemStore.initializeFresh(
                root: sourceRoot, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("human"), .text("ordinary"), .text("second")]),
                    "administration": .text("system"), "administratorGroup": .text("staff"),
                ]))
            let storeID = try CanonicalReaderRequirement.storeIdentity(
                root: sourceRoot, ownerUID: tractanda_uid())
            let prep = try PeerEnrollment.prepareTarget(
                root: targetRoot, commonStoreID: storeID,
                sourceReplicaID: XCTUnwrap(source.replicaID))
            let preparation = root.appendingPathComponent("preparation")
            try JSON.encode(prep).write(to: preparation)
            let file = root.appendingPathComponent("pair")
            _ = try NativePeerEnrollment.createPair(
                preparationPath: preparation.path, outputPath: file.path,
                sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true)
            input = try .capture(path: file.path)
            operation = try input.operationID
            try capacity()
        }
        deinit {
            source = nil
            try? FileManager.default.removeItem(at: root)
        }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            _ = try snapshot(root: root)
        }
        func snapshot(root supplied: URL? = nil) throws -> [String: String] {
            let base = supplied ?? sourceRoot
            var result: [String: String] = [:]
            var bytes: UInt64 = 0
            var count = 0
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            while let url = scan.nextObject() as? URL {
                count += 1
                guard count <= 2048 else {
                    throw TractandaError("resourceLimit", "Operator fixture file cap.")
                }
                let relative = try GuardedFixtureDirectory.relativePath(url, beneath: base)
                if relative == "index" {
                    scan.skipDescendants()
                    continue
                }
                let metadata = try FileMetadata.read(at: url)
                guard metadata.type == .regular else { continue }
                guard
                    metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                        - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                else { throw TractandaError("resourceLimit", "Operator fixture byte cap.") }
                bytes += metadata.size
                result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: url))
            }
            return result
        }
        func begin() throws -> PeerEnrollmentOperatorStatus {
            try source.nativeEnrollmentBegin(input, forUID: accounts.author)
        }
        func ready() throws -> PeerEnrollmentOperatorStatus {
            for _ in 0..<1024 {
                try capacity()
                let result = try source.nativeEnrollmentCall(
                    .init(action: "step", operationID: operation), forUID: accounts.author)
                let status = try JSON.decode(PeerEnrollmentOperatorStatus.self, result)
                if status.phase == "ready" { return status }
            }
            throw TractandaError("testTimeout", "Finite enrollment fixture did not finish.")
        }
        func accept() throws -> Data {
            try source.nativeEnrollmentCall(
                .init(action: "accept", operationID: operation), forUID: accounts.author)
        }
    }

    private var livenessPageLimit: Int { 8 }
    private struct LivenessEnrollment {
        let handle: PeerEnrollmentApproval.Handle
        let material: PeerEnrollmentActivation.Material
        let pin: PeerEnrollmentActivation.Pin
    }
    private struct LivenessBarrier {
        let object: PeerPackage.Object
        let offset: Int
        let bytes: Data
        let afterFirstPage: Bool
    }
    private final class LivenessPhases {
        var values: [String] = []
        func record(_ value: String) throws {
            guard values.count < 32 else {
                throw TractandaError("resourceLimit", "Probe phase evidence bound.")
            }
            values.append(value)
        }
    }
    private func livenessApprove(_ f: Fixture, input: PeerEnrollmentPairInput) throws -> LivenessEnrollment {
        let operation = try input.operationID
        try f.capacity()
        _ = try f.source.nativeEnrollmentBegin(input, forUID: f.accounts.author)
        var ready = false
        for _ in 0..<256 {
            try f.capacity()
            let status = try f.source.stepPeerEnrollment(
                .init(operationID: operation), forUID: f.accounts.author,
                window: .init(maximumUnits: 16, maximumEdges: 64))
            if status.manifest != nil {
                ready = true
                break
            }
        }
        guard ready else {
            throw TractandaError("testTimeout", "Small admitted liveness export did not seal.")
        }
        try f.capacity()
        let accepted = try f.source.acceptPeerEnrollment(
            .init(operationID: operation), forUID: f.accounts.author)
        let material = try f.source.peerEnrollmentActivationMaterial(
            .init(operationID: operation), forUID: f.accounts.author)
        let original = try AuthorityRecordCodec.decode(material.proof.approvalBytes)
        let bootstrap = try AuthorityRecord.list(original.record.payload["bootstrap"]).map(
            AuthorityBinding.init(value:))
        let pin = try PeerEnrollmentActivation.Pin(
            sourceReplicaID: PeerEnrollmentApproval.preparation(material.preparationBytes).sourceReplicaID,
            bootstrap: XCTUnwrap(bootstrap.first), approval: XCTUnwrap(accepted.approval))
        try f.capacity()
        return .init(handle: .init(operationID: operation), material: material, pin: pin)
    }
    private func livenessSeed(_ f: Fixture) throws -> Set<String> {
        var revisions: Set<String> = []
        // Less than1MiB of real authored bodies. Existing source plan/staging limits admit it.
        for n in 0..<4 {
            if n % 8 == 0 { try f.capacity() }
            let result = try f.source.withAccess(forUID: f.accounts.author) {
                try f.source.commit(
                    .init(
                        classID: "Item",
                        changes: [
                            "subject": .text("activation probe \(n)"),
                            "body": .text(String(repeating: "x", count: 128 * 1024)),
                        ], operationID: "activation-probe-\(n)"))
            }
            revisions.insert(result.revision.revisionID)
        }
        try f.capacity()
        return revisions
    }
    private func livenessTransfer(
        _ f: Fixture, enrollment e: LivenessEnrollment,
        session: PeerEnrollmentActivation.Session, budget: UInt64? = nil, successes: inout Int,
        afterAppend: ((PeerPackage.Object, Int, Data, UInt64) -> Void)? = nil
    ) throws -> LivenessBarrier? {
        var cursor: PeerPackage.ResumeCursor?
        var pages = 0
        var units = 0
        repeat {
            pages += 1
            guard pages <= 128 else { throw TractandaError("resourceLimit", "Probe page bound.") }
            let page = try session.resume(
                packageID: e.material.baseline.packageID, cursor: cursor, limit: livenessPageLimit)
            for value in page.objects where !value.verifiedComplete {
                var offset = value.nextOffset
                while offset < value.descriptor.length {
                    units += 1
                    guard units <= 2048 else { throw TractandaError("resourceLimit", "Probe chunk bound.") }
                    if (units - 1) % 8 == 0 { try f.capacity() }
                    let chunk = try f.source.readPeerEnrollment(
                        e.handle, object: value.descriptor,
                        offset: offset, maximumBytes: value.descriptor.chunkBytes, forUID: f.accounts.author)
                    var charged: UInt64 = 0
                    do {
                        _ = try session.withReadBudgetForTesting(
                            budget ?? PeerPackage.Limits().maximumReadBytes,
                            pageLimit: livenessPageLimit, consumed: { charged = $0 },
                            body: {
                                try session.append(
                                    packageID: e.material.baseline.packageID, object: value.descriptor,
                                    offset: offset, bytes: chunk.bytes)
                            }
                        )
                    } catch let error as TractandaError where error.code == "resourceLimit" && budget != nil {
                        return .init(
                            object: value.descriptor, offset: offset, bytes: chunk.bytes,
                            afterFirstPage: cursor != nil)
                    }
                    successes += 1
                    afterAppend?(value.descriptor, offset, chunk.bytes, charged)
                    offset += chunk.bytes.count
                }
            }
            if !page.blockedOnIndex { cursor = page.nextCursor }
            if !page.blockedOnIndex && cursor == nil {
                try f.capacity()
                return nil
            }
        } while pages < 128
        throw TractandaError("testTimeout", "Probe traversal did not complete.")
    }
    private func livenessCritical(_ root: URL, record: PeerEnrollmentActivation.Record) throws -> [String:
        String]
    {
        let files = DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
        let actual = try XCTUnwrap(PeerEnrollmentActivation.loadRecord(files))
        XCTAssertEqual(actual, record)
        let key = try PeerCredentialStore(files: files).load(
            peerID: record.targetContext.peerID,
            configurationDigest: record.targetContext.configurationDigest)
        XCTAssertEqual(try key.privateBytesDigest, record.targetPrivateBytesDigest)
        let prep = try record.preparation
        XCTAssertEqual(
            try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid()),
            prep.commonStoreID)
        XCTAssertEqual(
            try ReplicaIdentity.load(root: root, storeID: prep.commonStoreID, ownerUID: tractanda_uid())?
                .replicaID, prep.targetReplicaID)
        return [
            "request": try record.digest, "private": try key.privateBytesDigest,
            "preparation": AuthorityRecordCodec.sha256(
                try files.read(path: [PeerEnrollment.intentName], maximumBytes: 4096)),
        ]
    }
    private func livenessPackageSnapshot(_ root: URL, package: String) throws -> [String: String] {
        let base = root.appendingPathComponent("authority/intake").appendingPathComponent(package)
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        var count = 0
        var bytes: UInt64 = 0
        while let file = entries.nextObject() as? URL {
            count += 1
            guard count <= 4096 else {
                throw TractandaError("resourceLimit", "Probe package evidence bound.")
            }
            let metadata = try FileMetadata.read(at: file)
            if metadata.type == .directory { continue }
            guard metadata.type == .regular, metadata.size <= 16 * 1024 * 1024 - min(bytes, 16 * 1024 * 1024)
            else { throw TractandaError("resourceLimit", "Probe package bytes bound.") }
            bytes += metadata.size
            result[String(file.path.dropFirst(base.path.count))] = AuthorityRecordCodec.sha256(
                try Data(contentsOf: file))
        }
        return result
    }
    private func livenessPending(_ root: URL) {
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(root)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
    }
}
