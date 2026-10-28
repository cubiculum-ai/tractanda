import CTractandaPlatform
import Foundation
import Synchronization
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerTargetEnrollmentTests: XCTestCase {
    final class Fixture {
        let root: URL, sourceRoot: URL, targetRoot: URL
        let accounts = SystemAccountDirectory()
        let uid = tractanda_uid()
        var source: ItemStore!
        let operation: String
        let material: PeerEnrollmentActivation.Material
        let pin: PeerTargetEnrollmentPin
        let bytes: Data
        init(test: String, attachment: Bool = false, proofSource: String = "PeerTargetEnrollmentTests") throws
        {
            try AttachmentFixtureCapacity.requireFree()
            guard AttachmentFixtureCapacity.fixtureCapBytes >= 16 * 1024 * 1024 else {
                throw TractandaError(
                    "resourceLimit", "Tiny target fixture setup estimate exceeds its existing cap")
            }
            root = try GuardedFixtureDirectory.create(prefix: "e", source: proofSource, test: test)
            sourceRoot = root.appendingPathComponent("source")
            targetRoot = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(
                at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let account = try accounts.user(forUID: uid)
            source = try ItemStore.initializeFresh(
                root: sourceRoot, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text(account.name)]),
                    "administration": .text("system"), "administratorGroup": .text(account.primaryGroupName),
                ]))
            if attachment {
                let store = source!
                try store.withAccess(forUID: uid) {
                    let base = try store.commit(
                        .init(
                            classID: "Item", changes: ["subject": .text("finite target pipe")],
                            operationID: "target-pipe-base")
                    ).revision
                    let data = Data(repeating: 0x71, count: 300 * 1024)
                    let upload = try store.beginAttachment(
                        .init(
                            itemID: base.itemID, expectedRevisionID: base.revisionID,
                            operationID: "target-pipe-attachment", filename: "tiny.bin",
                            mediaType: "application/octet-stream",
                            byteCount: Int64(data.count), sha256: AuthorityRecordCodec.sha256(data)))
                    let id = try XCTUnwrap(upload.uploadID)
                    _ = try store.appendAttachment(uploadID: id, offset: 0, data: data.prefix(256 * 1024))
                    _ = try store.appendAttachment(
                        uploadID: id, offset: 256 * 1024, data: data.dropFirst(256 * 1024))
                    _ = try store.finishAttachment(uploadID: id)
                }
            }
            let store = try CanonicalReaderRequirement.storeIdentity(root: sourceRoot, ownerUID: uid)
            let prep = try PeerEnrollment.prepareTarget(
                root: targetRoot, commonStoreID: store, sourceReplicaID: XCTUnwrap(source.replicaID))
            let prepPath = root.appendingPathComponent("preparation")
            let pair = root.appendingPathComponent("pair")
            try JSON.encode(prep).write(to: prepPath)
            _ = try NativePeerEnrollment.createPair(
                preparationPath: prepPath.path, outputPath: pair.path,
                sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true)
            let input = try PeerEnrollmentPairInput.capture(path: pair.path)
            operation = try input.operationID
            _ = try source.nativeEnrollmentBegin(input, forUID: uid)
            var ready = false
            for _ in 0..<256 {
                try Self.capacity(root)
                let status = try source.stepPeerEnrollment(
                    .init(operationID: operation), forUID: uid,
                    window: .init(maximumUnits: 16, maximumEdges: 64))
                if status.manifest != nil {
                    ready = true
                    break
                }
            }
            guard ready else { throw TractandaError("testTimeout", "Small actual source did not seal") }
            _ = try source.acceptPeerEnrollment(.init(operationID: operation), forUID: uid)
            material = try source.peerEnrollmentActivationMaterial(.init(operationID: operation), forUID: uid)
            let output = try PeerEnrollmentTargetOutput(material: material)
            bytes = output.withBytes { $0 }
            let record = try PeerEnrollmentTargetOutput.decode(bytes).0
            pin = try .init(
                sourceReplicaID: record.pin.sourceReplicaID, bootstrapID: record.pin.bootstrap.recordID,
                bootstrapSHA256: record.pin.bootstrap.sha256, approvalID: record.pin.approval.recordID,
                approvalSHA256: record.pin.approval.sha256)
            try capacity()
        }
        deinit {
            source = nil
            try? FileManager.default.removeItem(at: root)
        }
        func capacity() throws { try Self.capacity(root) }
        static func capacity(_ root: URL) throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var total: UInt64 = 0
            var count = 0
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            while let path = scan.nextObject() as? URL {
                count += 1
                guard count <= 2048 else {
                    throw TractandaError("resourceLimit", "Target pipe fixture file bound")
                }
                let info = try FileMetadata.read(at: path)
                if info.type == .regular {
                    guard
                        info.size <= AttachmentFixtureCapacity.fixtureCapBytes
                            - min(total, AttachmentFixtureCapacity.fixtureCapBytes)
                    else {
                        throw TractandaError("resourceLimit", "Target pipe fixture byte bound")
                    }
                    total += info.size
                }
            }
        }
        func pending() {
            XCTAssertThrowsError(try ItemStore.requireInitializedRoot(targetRoot)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
            }
        }
        var arguments: [String] {
            [
                "--activate-peer-target-stdio", targetRoot.path, pin.sourceReplicaID,
                pin.bootstrapID, pin.bootstrapSHA256, pin.approvalID, pin.approvalSHA256,
            ]
        }
    }
    final class Owner: @unchecked Sendable {
        let input = Pipe(), output = Pipe(), group = DispatchGroup()
        let cancelled = Mutex(false), result = Mutex<String?>(nil)
        var client: PeerTargetEnrollment.IO!
        private var inputClosed = false
        init(
            _ f: Fixture, pin: PeerTargetEnrollmentPin? = nil, seconds: Double = 20,
            before: (@Sendable (String) throws -> Void)? = nil,
            cancelledCallback: (@Sendable () -> Bool)? = nil, pageLimit: Int = 128,
            afterRelease: (@Sendable () throws -> Void)? = nil
        ) throws {
            let root = f.targetRoot
            let actualPin = pin ?? f.pin
            client = try PeerTargetEnrollment.IO(
                input: output.fileHandleForReading.fileDescriptor,
                output: input.fileHandleForWriting.fileDescriptor,
                control: PeerTargetEnrollment.Control(seconds: 25, cancelled: { false }))
            group.enter()
            DispatchQueue.global().async { [self] in
                defer {
                    try? input.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    group.leave()
                }
                do {
                    try PeerTargetEnrollment.run(
                        root: root, pin: actualPin, inputFD: input.fileHandleForReading.fileDescriptor,
                        outputFD: output.fileHandleForWriting.fileDescriptor,
                        accounts: SystemAccountDirectory(), maximumSeconds: seconds,
                        cancelled: { self.cancelled.withLock { $0 } || (cancelledCallback?() ?? false) },
                        beforeOperation: before, pageLimitForTesting: pageLimit,
                        afterReleaseBeforeReply: afterRelease)
                    result.withLock { $0 = "closed" }
                } catch { result.withLock { $0 = (error as? TractandaError)?.code ?? "unexpected" } }
            }
        }
        func reply() throws -> PeerTargetEnrollment.Reply {
            try JSON.decode(PeerTargetEnrollment.Reply.self, XCTUnwrap(client.receive(maximum: 128 * 1024)))
        }
        func send(_ fields: [String: Any]) throws {
            try client.send(JSONSerialization.data(withJSONObject: fields))
        }
        func opened(_ f: Fixture) throws {
            XCTAssertEqual(try reply().operation, "ready")
            try client.send(f.bytes)
            XCTAssertEqual(try reply().operation, "opened")
        }
        func closeInput() {
            guard !inputClosed else { return }
            inputClosed = true
            client?.restoreBeforeClosing(input.fileHandleForWriting.fileDescriptor)
            try? input.fileHandleForWriting.close()
        }
        func wait(_ expected: String = "closed") {
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(result.withLock { $0 }, expected)
        }
        deinit {
            cancelled.withLock { $0 = true }
            closeInput()
            _ = group.wait(timeout: .now() + 10)
            client = nil
        }
    }
    func testPipeBackpressureDeadlineRestoresDescriptorFlags() throws {
        let input = Pipe()
        let output = Pipe()
        let fd = input.fileHandleForReading.fileDescriptor
        let out = output.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        let outFlags = fcntl(out, F_GETFL)
        let descriptorFlags = fcntl(fd, F_GETFD)
        let outDescriptorFlags = fcntl(out, F_GETFD)
        do {
            let io = try PeerTargetEnrollment.IO(
                input: fd, output: out,
                control: PeerTargetEnrollment.Control(seconds: 0.1, cancelled: { false }))
            XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
            // No consumer drains output: the bounded frame fills the pipe and poll must time out.
            XCTAssertThrowsError(try io.send(Data(repeating: 0x61, count: 128 * 1024))) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "deadlineExceeded")
            }
        }
        XCTAssertEqual(fcntl(fd, F_GETFL), flags)
        #if os(macOS)
            // XNU FWASWRITTEN is immutable kernel bookkeeping, outside FCNTLFLAGS.
            // Compare every other status bit; F_SETFL cannot reset this after actual pipe writes.
            let written: Int32 = 0x0001_0000
            XCTAssertEqual(fcntl(out, F_GETFL) & ~written, outFlags & ~written)
        #else
            XCTAssertEqual(fcntl(out, F_GETFL), outFlags)
        #endif
        XCTAssertEqual(fcntl(fd, F_GETFD), descriptorFlags)
        XCTAssertEqual(fcntl(out, F_GETFD), outDescriptorFlags)
    }
    func testMaximalReplySchemaAndStrictRequestsNeverExposeCursorOrEvaluation() throws {
        let id = "00000001-0000-1000-8000-000000000001"
        let digest = String(repeating: "f", count: 64)
        let descriptor = PeerPackage.Object(
            kind: .document, id: id, length: DocumentContentStore.maximumPageBytes,
            sha256: digest, part: .init(role: .page, level: 0, ordinal: Int64.max))
        try descriptor.validate()
        let objects = (0..<128).map { _ in
            PeerPackage.ObjectResume(
                descriptor: descriptor, nextOffset: descriptor.length,
                source: .staged, verifiedComplete: true,
                evaluation: .init(disposition: .held, reason: String(repeating: "x", count: 4096)))
        }
        let page = PeerPackage.ResumePage(
            state: .init(packageID: id, manifestDigest: digest, phase: .staged, recoveryRequired: false),
            objects: objects, nextCursor: nil, blockedOnIndex: false)
        let bytes = try JSON.encode(PeerTargetEnrollment.pageReply(page, packageID: id))
        XCTAssertLessThan(bytes.count, 128 * 1024)
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in ["cursor", "evaluation", "reason", "secret", "credential"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        for fields: [String: Any] in [
            ["operation": "close", "uid": 0], ["operation": "resume", "packageID": id, "advance": 1],
            ["operation": "append", "packageID": id, "ordinal": true, "offset": 0],
            ["operation": "finish", "cursor": [:]],
        ] {
            XCTAssertThrowsError(
                try PeerTargetEnrollment.Request.decode(JSONSerialization.data(withJSONObject: fields)))
        }
        XCTAssertThrowsError(try PeerTargetEnrollment.Request.decode(Data("{secret parser payload".utf8))) {
            XCTAssertFalse(String(describing: $0).contains("secret parser payload"))
        }
    }
}
