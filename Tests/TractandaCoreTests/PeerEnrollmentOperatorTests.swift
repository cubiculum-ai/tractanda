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
                let relative = String(url.path.dropFirst(base.path.count + 1))
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
    func testReadOnlyStatusPreservesCanonicalAndPrivateJournalsAtEveryPhase() throws {
        let f = try Fixture(test: name)
        XCTAssertEqual(try f.begin().phase, "pending")
        for expected in ["pending", "ready", "accepted"] {
            if expected == "ready" { _ = try f.ready() }
            if expected == "accepted" { _ = try f.accept() }
            let before = try f.snapshot()
            for _ in 0..<2 {
                let status = try f.source.nativeEnrollmentStatus(f.operation, forUID: f.accounts.author)
                XCTAssertEqual(status.phase, expected)
                try status.validate()
                XCTAssertThrowsError(
                    try f.source.nativeEnrollmentStatus(f.operation, forUID: f.accounts.outsider))
            }
            XCTAssertEqual(
                try f.snapshot(), before,
                "Status must inspect actual proof without selecting, repairing or finishing work.")
        }
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(f.targetRoot))
        let operation = try JSON.decode(
            PeerEnrollmentApproval.Operation.self,
            Data(
                contentsOf:
                    f.sourceRoot.appendingPathComponent(PeerEnrollmentApproval.directory)
                    .appendingPathComponent(f.operation).appendingPathComponent("request.json")))
        let seal = f.sourceRoot.appendingPathComponent("authority/intake").appendingPathComponent(
            operation.publicationID
        ).appendingPathComponent("sealed.json")
        // Only this isolated fixture; keep applied/locator/private accepted evidence.
        try FileManager.default.removeItem(at: seal)
        let afterIntentionalLoss = try f.snapshot()
        XCTAssertThrowsError(try f.source.nativeEnrollmentStatus(f.operation, forUID: f.accounts.author)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerRepairRequired")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path))
        XCTAssertEqual(
            try f.snapshot(), afterIntentionalLoss,
            "Status cannot recreate lost admitted receipt proof from private markers or retained bytes.")
        try f.capacity()
    }
    func testAcceptedNativeAcknowledgmentAllowsExactHistoricalAuthorOrCurrentAdminOnly() throws {
        let f = try Fixture(test: name)
        _ = try f.begin()
        _ = try f.ready()
        let accepted = try f.accept()
        let call = PeerEnrollmentNativeCall(action: "accept", operationID: f.operation)
        XCTAssertThrowsError(try f.source.nativeEnrollmentCall(call, forUID: f.accounts.outsider)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        f.accounts.demoted.withLock { $0 = true }
        XCTAssertEqual(try f.source.nativeEnrollmentCall(call, forUID: f.accounts.author), accepted)
        XCTAssertEqual(try f.source.nativeEnrollmentCall(call, forUID: f.accounts.administrator), accepted)
        XCTAssertThrowsError(try f.source.nativeEnrollmentExport(f.operation, forUID: f.accounts.author))
        XCTAssertThrowsError(
            try f.source.nativeEnrollmentExport(f.operation, forUID: f.accounts.administrator),
            "A completion administrator does not become the original current export author.")
        f.accounts.renamed.withLock { $0 = true }
        XCTAssertThrowsError(try f.source.nativeEnrollmentCall(call, forUID: f.accounts.author))
        f.accounts.renamed.withLock { $0 = false }
        _ = try f.source.nativeEnrollmentCall(
            .init(action: "register", operationID: f.operation), forUID: f.accounts.author)
        try f.capacity()
    }
    func testRealTargetOnlyOutputPreservesExactPrivateWitnessAndRejectsSourceOrientation() throws {
        let f = try Fixture(test: name)
        _ = try f.begin()
        _ = try f.ready()
        _ = try f.accept()
        let output = try f.source.nativeEnrollmentExport(f.operation, forUID: f.accounts.author)
        let bytes = output.withBytes { $0 }
        let pair = try f.input.withBytes { try PeerEnrollmentPairInput.decode($0) }
        let (record, credential) = try PeerEnrollmentTargetOutput.decode(bytes)
        XCTAssertEqual(try credential.privateBytesDigest, try pair.targetCredential.privateBytesDigest)
        XCTAssertNotEqual(try credential.privateBytesDigest, try pair.sourceCredential.privateBytesDigest)
        XCTAssertEqual(
            try JSON.encode(record),
            try JSON.encode(
                PeerEnrollmentActivation.makeRecord(
                    f.source.peerEnrollmentActivationMaterial(
                        .init(operationID: f.operation), forUID: f.accounts.author), pin: record.pin)))
        XCTAssertEqual(PeerEnrollmentTargetOutput.maximumBytes, 135184)
        XCTAssertEqual(Mirror(reflecting: output).children.count, 0)
        XCTAssertEqual(String(reflecting: output), "PeerEnrollmentTargetOutput(<redacted>)")
        var sourceOriented = Data("TPTARG01".utf8)
        let recordBytes = try JSON.encode(record)
        let sourceBytes = try pair.sourceCredential.privateEncodedBytes()
        for n in [recordBytes.count, sourceBytes.count] {
            let x = UInt32(n)
            sourceOriented.append(contentsOf: [
                UInt8(x >> 24), UInt8((x >> 16) & 255), UInt8((x >> 8) & 255), UInt8(x & 255),
            ])
        }
        sourceOriented.append(recordBytes)
        sourceOriented.append(sourceBytes)
        XCTAssertThrowsError(try PeerEnrollmentTargetOutput(bytes: sourceOriented))
        XCTAssertThrowsError(try PeerEnrollmentTargetOutput(bytes: bytes + Data([0])))
        // Synthetic structural boundary, not admitted source authority: enlarge the opaque
        // publication timestamp in both equal proof copies. Production export still constructs
        // its Record from actual retained accepted proof, exercised above.
        func paddedRecord(_ extra: Int) -> PeerEnrollmentActivation.Record {
            var publication = record.proof.publication
            publication = .init(
                packageID: publication.packageID, manifestDigest: publication.manifestDigest,
                context: publication.context, contextToken: publication.contextToken,
                arrivalMinute: publication.arrivalMinute + String(repeating: "x", count: extra),
                controlParents: publication.controlParents, localItemPath: publication.localItemPath)
            let proof = PeerEnrollmentActivation.Proof(
                manifest: record.proof.manifest, framingBytes: record.proof.framingBytes,
                approvalBytes: record.proof.approvalBytes, prepared: publication, publication: publication)
            return .init(
                profile: record.profile, preparationBytes: record.preparationBytes, pin: record.pin,
                baseline: record.baseline, proof: proof, sourceContext: record.sourceContext,
                targetContext: record.targetContext,
                targetCredentialCommitment: record.targetCredentialCommitment,
                targetPrivateBytesDigest: record.targetPrivateBytesDigest)
        }
        func envelope(_ r: Data) throws -> Data {
            let c = try credential.privateEncodedBytes()
            var data = Data("TPTARG01".utf8)
            for n in [r.count, c.count] {
                let x = UInt32(n)
                data.append(contentsOf: [
                    UInt8(x >> 24), UInt8((x >> 16) & 255), UInt8((x >> 8) & 255), UInt8(x & 255),
                ])
            }
            data.append(r)
            data.append(c)
            return data
        }
        let padding = (PeerEnrollmentActivation.maximumBytes - recordBytes.count) / 2
        let nearLimit = try JSON.encode(paddedRecord(padding))
        XCTAssertGreaterThanOrEqual(nearLimit.count, 131071)
        XCTAssertLessThanOrEqual(nearLimit.count, 131072)
        _ = try PeerEnrollmentTargetOutput(bytes: envelope(nearLimit))
        XCTAssertThrowsError(
            try PeerEnrollmentTargetOutput(bytes: envelope(JSON.encode(paddedRecord(padding + 1)))))
        let folder = f.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = folder.appendingPathComponent("target").path
        try PeerEnrollmentFiles.writeExact(bytes, path: path, maximum: 135184)
        try PeerEnrollmentFiles.writeExact(bytes, path: path, maximum: 135184)
        XCTAssertEqual(try PeerEnrollmentFiles.readPrivate(path, maximum: 135184), bytes)
        try f.capacity()
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
    func testReducedAppendBudgetMeasuresTailProgressAcrossReopen() throws {
        try AttachmentFixtureCapacity.requireFree()
        let f = try Fixture(test: name)
        let authored = try livenessSeed(f)
        let e = try livenessApprove(f, input: f.input)
        var session = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: e.material, pin: e.pin, accounts: f.accounts)
        defer { session.close() }
        // Fixed diagnostic window, not a threshold tuned to force a tail failure.
        let budget: UInt64 = 8 * 1024 * 1024
        var head: LivenessBarrier?
        var maximumCharged: UInt64 = 0
        var successes = 0
        var newLargeUnits = 0
        var repeated = 0
        var outcome = "completed"
        let barrier = try livenessTransfer(
            f, enrollment: e, session: session, budget: budget, successes: &successes
        ) { object, offset, bytes, charged in
            maximumCharged = max(maximumCharged, charged)
            if authored.contains(object.id), offset == 0, bytes.count == object.length {
                newLargeUnits += 1
                if head == nil {
                    head = .init(object: object, offset: offset, bytes: bytes, afterFirstPage: false)
                }
            }
        }
        guard newLargeUnits >= 2 else {
            throw TractandaError(
                "invalidProbe",
                "Fixed allowance did not admit two new representative revisions; no tail inference is valid.")
        }
        let first = try XCTUnwrap(head)
        XCTAssertGreaterThan(first.bytes.count, 128 * 1024)
        _ = try session.withReadBudgetForTesting(
            budget, pageLimit: livenessPageLimit, consumed: { XCTAssertLessThanOrEqual($0, budget) },
            body: {
                try session.append(
                    packageID: e.material.baseline.packageID, object: first.object, offset: first.offset,
                    bytes: first.bytes)
            }
        )
        if let barrier {
            XCTAssertTrue(
                barrier.afterFirstPage,
                "The selected tail must follow the first genuine8-entry page in this reduced-page characterization."
            )
            let critical = try livenessCritical(f.targetRoot, record: session.record)
            outcome = "repeated-barrier"
            for attempt in 0..<4 {
                if attempt == 0 || attempt == 2 {
                    let beforeReopen = try livenessPackageSnapshot(
                        f.targetRoot, package: e.material.baseline.packageID)
                    session.close()
                    session = try PeerEnrollmentActivation.open(
                        root: f.targetRoot, material: e.material, pin: e.pin, accounts: f.accounts)
                    XCTAssertEqual(try livenessCritical(f.targetRoot, record: session.record), critical)
                    XCTAssertEqual(
                        try livenessPackageSnapshot(f.targetRoot, package: e.material.baseline.packageID),
                        beforeReopen)
                }
                let before = try livenessPackageSnapshot(f.targetRoot, package: e.material.baseline.packageID)
                do {
                    _ = try session.withReadBudgetForTesting(
                        budget, pageLimit: livenessPageLimit,
                        consumed: { XCTAssertLessThanOrEqual($0, budget) },
                        body: {
                            try session.append(
                                packageID: e.material.baseline.packageID, object: barrier.object,
                                offset: barrier.offset, bytes: barrier.bytes)
                        }
                    )
                    outcome = "retry-progress"
                    break
                } catch let error as TractandaError where error.code == "resourceLimit" {
                    repeated += 1
                    XCTAssertEqual(
                        try livenessPackageSnapshot(f.targetRoot, package: e.material.baseline.packageID),
                        before)
                    livenessPending(f.targetRoot)
                }
            }
            // Same actual object/offset/bytes, without a persistent testing cap or proof repair.
            _ = try session.withReadBudgetForTesting(
                PeerPackage.Limits().maximumReadBytes,
                pageLimit: livenessPageLimit, consumed: { _ in },
                body: {
                    try session.append(
                        packageID: e.material.baseline.packageID, object: barrier.object,
                        offset: barrier.offset, bytes: barrier.bytes)
                }
            )
        } else {
            let critical = try livenessCritical(f.targetRoot, record: session.record)
            let beforeReopen = try livenessPackageSnapshot(
                f.targetRoot, package: e.material.baseline.packageID)
            session.close()
            session = try PeerEnrollmentActivation.open(
                root: f.targetRoot, material: e.material, pin: e.pin, accounts: f.accounts)
            XCTAssertEqual(try livenessCritical(f.targetRoot, record: session.record), critical)
            XCTAssertEqual(
                try livenessPackageSnapshot(f.targetRoot, package: e.material.baseline.packageID),
                beforeReopen)
        }
        var defaultUnits = 0
        XCTAssertNil(try livenessTransfer(f, enrollment: e, session: session, successes: &defaultUnits))
        let receipt = try session.withReadBudgetForTesting(
            PeerPackage.Limits().maximumReadBytes,
            pageLimit: livenessPageLimit, consumed: { _ in },
            body: { try session.finish() })
        XCTAssertEqual(receipt.requestDigest, try session.record.digest)
        // Outside the scoped seam: production geometry128 is restored.
        XCTAssertEqual(try session.finish(), receipt)
        session.close()
        XCTAssertNoThrow(try ItemStore.requireInitializedRoot(f.targetRoot))
        try f.capacity()
        print(
            "ACTIVATION-LIVENESS append outcome=\(outcome) pageLimit=\(livenessPageLimit) budget=\(budget) maximumCharged=\(maximumCharged) newRepresentativeUnits=\(newLargeUnits) newLimitedUnits=\(successes) repeated=\(repeated) reopened=true defaultComplete=true"
        )
    }
    func testReducedFinishBudgetMeasuresProgressAcrossReopen() throws {
        try AttachmentFixtureCapacity.requireFree()
        let f = try Fixture(test: name)
        let small = try livenessApprove(f, input: f.input)
        let calibration = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: small.material, pin: small.pin, accounts: f.accounts)
        defer { calibration.close() }
        var units = 0
        XCTAssertNil(try livenessTransfer(f, enrollment: small, session: calibration, successes: &units))
        var charged: UInt64 = 0
        let first = try calibration.withReadBudgetForTesting(
            PeerPackage.Limits().maximumReadBytes, pageLimit: livenessPageLimit, consumed: { charged = $0 },
            body: {
                try calibration.finish()
            }
        )
        XCTAssertGreaterThan(charged, 0)
        calibration.close()
        try f.capacity()
        XCTAssertNoThrow(try ItemStore.requireInitializedRoot(f.targetRoot))
        _ = try livenessSeed(f)
        let target = f.root.appendingPathComponent("bulk-target")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let prep = try PeerEnrollment.prepareTarget(
            root: target, commonStoreID: small.material.sourceContext.storeID,
            sourceReplicaID: small.pin.sourceReplicaID)
        let prepFile = f.root.appendingPathComponent("bulk-preparation")
        let pair = f.root.appendingPathComponent("bulk-pair")
        try JSON.encode(prep).write(to: prepFile)
        _ = try NativePeerEnrollment.createPair(
            preparationPath: prepFile.path, outputPath: pair.path,
            sourcePeerID: "bulk-target", targetPeerID: "source", sourceIsInitiator: true)
        let e = try livenessApprove(f, input: PeerEnrollmentPairInput.capture(path: pair.path))
        let phases = LivenessPhases()
        var session = try PeerEnrollmentActivation.open(
            root: target, material: e.material, pin: e.pin,
            accounts: f.accounts, progress: phases.record)
        defer { session.close() }
        units = 0
        XCTAssertNil(try livenessTransfer(f, enrollment: e, session: session, successes: &units))
        let budget = charged + max(4096, charged / 4)
        XCTAssertLessThan(budget, PeerPackage.Limits().maximumReadBytes)
        let critical = try livenessCritical(target, record: session.record)
        var codes: [String] = []
        var phaseCounts: [Int] = []
        var phaseTrace: [String] = []
        var completed = false
        for attempt in 0..<4 {
            if attempt > 0 {
                session.close()
                session = try PeerEnrollmentActivation.open(
                    root: target, material: e.material, pin: e.pin,
                    accounts: f.accounts, progress: phases.record)
                XCTAssertEqual(try livenessCritical(target, record: session.record), critical)
            }
            phases.values.removeAll()
            do {
                let receipt = try session.withReadBudgetForTesting(
                    budget, pageLimit: livenessPageLimit, consumed: { XCTAssertLessThanOrEqual($0, budget) },
                    body: {
                        try session.finish()
                    }
                )
                XCTAssertEqual(receipt.requestDigest, try session.record.digest)
                completed = true
                codes.append("complete")
                phaseCounts.append(phases.values.count)
                phaseTrace.append(phases.values.joined(separator: "+"))
            } catch let error as TractandaError
                where ["resourceLimit", "recoveryRequired"].contains(error.code)
            {
                codes.append(error.code)
                phaseCounts.append(phases.values.count)
                phaseTrace.append(phases.values.joined(separator: "+"))
                XCTAssertEqual(try livenessCritical(target, record: session.record), critical)
                let files = DocumentContentFiles(root: target, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
                if try PeerEnrollmentActivation.loadReceipt(files) == nil { livenessPending(target) }
            }
            // Outside the operation-error catch: fixture rejection is not a liveness outcome.
            try f.capacity()
            if completed { break }
        }
        // The existing default envelope must complete this admitted fixture after the probe.
        session.close()
        session = try PeerEnrollmentActivation.open(
            root: target, material: e.material, pin: e.pin, accounts: f.accounts)
        let receipt = try session.withReadBudgetForTesting(
            PeerPackage.Limits().maximumReadBytes,
            pageLimit: livenessPageLimit, consumed: { _ in },
            body: { try session.finish() })
        XCTAssertEqual(receipt.requestDigest, try session.record.digest)
        // Production geometry128/default read allowance, exact completion retry.
        XCTAssertEqual(try session.finish(), receipt)
        XCTAssertEqual(first.profile, receipt.profile)
        session.close()
        XCTAssertNoThrow(try ItemStore.requireInitializedRoot(target))
        try f.capacity()
        print(
            "ACTIVATION-LIVENESS finish outcome=\(completed ? "completed" : "bounded-barrier") pageLimit=\(livenessPageLimit) budget=\(budget) minimalFinishCharged=\(charged) attempts=\(codes.count) codes=\(codes.joined(separator: ",")) phaseCounts=\(phaseCounts) phases=\(phaseTrace) reopened=true defaultComplete=true"
        )
    }
}
