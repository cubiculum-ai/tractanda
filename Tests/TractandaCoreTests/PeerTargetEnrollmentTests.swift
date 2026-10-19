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
    func testStrongClosedReleasesWriterBeforeAcknowledgement() throws {
        let f = try Fixture(test: name)
        let closing = DispatchSemaphore(value: 0)
        let allowRelease = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let allowReply = DispatchSemaphore(value: 0)
        let owner = try Owner(
            f,
            before: { operation in
                if operation == "close" {
                    closing.signal()
                    _ = allowRelease.wait(timeout: .now() + 10)
                }
            },
            afterRelease: {
                released.signal()
                _ = allowReply.wait(timeout: .now() + 10)
            })
        defer {
            allowRelease.signal()
            allowReply.signal()
        }
        try owner.opened(f)
        try owner.send(["operation": "close"])
        XCTAssertEqual(closing.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(
            try PeerEnrollmentActivation.open(root: f.targetRoot, material: f.material, pin: f.pin.value)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "storeBusy")
        }
        var event = pollfd(
            fd: owner.output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 0), 0, "No CLOSED while the first writer remains held")
        allowRelease.signal()
        XCTAssertEqual(released.wait(timeout: .now() + 5), .success)
        let second = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: f.material, pin: f.pin.value)
        defer { second.close() }
        XCTAssertEqual(poll(&event, 1, 0), 0)
        allowReply.signal()
        XCTAssertEqual(try owner.reply().operation, "closed")
        owner.wait()
        second.close()
        f.pending()
        try f.capacity()
    }
    func testMalformedHeadersWrongPinsAndAbsoluteDeadlineFailBeforeOpening() throws {
        let f = try Fixture(test: name)
        let wrong = try PeerTargetEnrollmentPin(
            sourceReplicaID: f.pin.sourceReplicaID, bootstrapID: f.pin.bootstrapID,
            bootstrapSHA256: String(repeating: "f", count: 64), approvalID: f.pin.approvalID,
            approvalSHA256: f.pin.approvalSHA256)
        do {
            let owner = try Owner(f, pin: wrong)
            XCTAssertEqual(try owner.reply().operation, "ready")
            try owner.client.send(f.bytes)
            XCTAssertEqual(try owner.reply().code, "invalidTargetPin")
            owner.wait("invalidTargetPin")
        }
        // 135185 or a partial header, with no large body allocation.
        for header in [Data([0, 2, 16, 17]), Data([0, 0])] {
            let owner = try Owner(f)
            XCTAssertEqual(try owner.reply().operation, "ready")
            try owner.input.fileHandleForWriting.write(contentsOf: header)
            owner.closeInput()
            XCTAssertEqual(try owner.reply().operation, "error")
            owner.wait("invalidTargetProtocol")
        }
        do {
            let owner = try Owner(f, seconds: 0.1)
            XCTAssertEqual(try owner.reply().operation, "ready")
            owner.wait("deadlineExceeded")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: f.targetRoot.appendingPathComponent("index").path))
        f.pending()
        try f.capacity()
    }
    func testPageAdvanceForgedSelectionAndWriterContentionStayClosed() throws {
        let f = try Fixture(test: name)
        let owner = try Owner(f)
        try owner.opened(f)
        f.pending()
        XCTAssertThrowsError(
            try PeerEnrollmentActivation.open(root: f.targetRoot, material: f.material, pin: f.pin.value)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "storeBusy")
        }
        try owner.send(["operation": "resume", "packageID": f.material.baseline.packageID, "advance": false])
        let page = try owner.reply()
        XCTAssertEqual(page.operation, "page")
        XCTAssertFalse(page.entries?.isEmpty ?? true)
        try owner.send(["operation": "resume", "packageID": f.material.baseline.packageID, "advance": true])
        XCTAssertEqual(try owner.reply().operation, "error")
        owner.wait("invalidTargetProtocol")
        let second = try Owner(f)
        try second.opened(f)
        try second.send([
            "operation": "append", "packageID": f.material.proof.manifest.packageID, "ordinal": 127,
            "offset": 0,
        ])
        XCTAssertEqual(try second.reply().operation, "error")
        second.wait("invalidTargetProtocol")
        let tail = try Owner(f, pageLimit: 3)
        try tail.opened(f)
        var advance = false
        var advances = 0
        var visited: Set<String> = []
        var tailIDs: Set<String> = []
        var complete = false
        for round in 0..<128 {
            if round % 8 == 0 { try f.capacity() }
            try tail.send([
                "operation": "resume", "packageID": f.material.baseline.packageID, "advance": advance,
            ])
            let reply = try tail.reply()
            XCTAssertEqual(reply.operation, "page")
            let entries = try XCTUnwrap(reply.entries)
            if advance {
                advances += 1
                tailIDs.formUnion(entries.map { $0.descriptor.id })
            }
            visited.formUnion(entries.map { $0.descriptor.id })
            if reply.complete == true {
                complete = true
                break
            }
            if let entry = entries.first(where: { !$0.verifiedComplete }) {
                let chunk = try f.source.readPeerEnrollment(
                    .init(operationID: f.operation), object: entry.descriptor,
                    offset: entry.nextOffset, maximumBytes: entry.descriptor.chunkBytes, forUID: f.uid)
                try tail.send([
                    "operation": "append", "packageID": f.material.baseline.packageID,
                    "ordinal": entry.ordinal, "offset": entry.nextOffset,
                ])
                try tail.client.send(chunk.bytes, maximum: entry.descriptor.chunkBytes)
                XCTAssertEqual(try tail.reply().operation, "appended")
                advance = false
            } else {
                advance = true
            }
        }
        XCTAssertTrue(complete)
        XCTAssertGreaterThan(advances, 0)
        XCTAssertFalse(tailIDs.isEmpty)
        tail.closeInput()
        tail.wait()
        let check = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: f.material, pin: f.pin.value)
        let canonical = try check.resume(packageID: f.material.baseline.packageID, limit: 128)
        XCTAssertNil(canonical.nextCursor)
        XCTAssertTrue(canonical.objects.allSatisfy(\.verifiedComplete))
        XCTAssertEqual(visited, Set(canonical.objects.map { $0.descriptor.id }))
        check.close()
        f.pending()
        try f.capacity()
    }
    func testHeldAppendCancellationKeepsWriterUntilSynchronousOwnerDrains() throws {
        let f = try Fixture(test: name)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = try Owner(
            f,
            before: { operation in
                if operation == "append" {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
            })
        defer { release.signal() }
        try owner.opened(f)
        try owner.send(["operation": "resume", "packageID": f.material.baseline.packageID, "advance": false])
        let first = try XCTUnwrap(owner.reply().entries?.first)
        let chunk = try f.source.readPeerEnrollment(
            .init(operationID: f.operation), object: first.descriptor, offset: first.nextOffset, forUID: f.uid
        )
        try owner.send([
            "operation": "append", "packageID": f.material.baseline.packageID, "ordinal": first.ordinal,
            "offset": first.nextOffset,
        ])
        try owner.client.send(chunk.bytes, maximum: first.descriptor.chunkBytes)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        owner.closeInput()
        owner.cancelled.withLock { $0 = true }
        XCTAssertEqual(owner.group.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertThrowsError(
            try PeerEnrollmentActivation.open(root: f.targetRoot, material: f.material, pin: f.pin.value)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "storeBusy")
        }
        release.signal()
        owner.wait("cancelled")
        let reopened = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: f.material, pin: f.pin.value)
        reopened.close()
        f.pending()
        try f.capacity()
    }
    func testOpeningCancellationRetainsWriterAndDrainsBeforeReturning() throws {
        let f = try Fixture(test: name)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let held = Mutex(false)
        let stop = Mutex(false)
        let target = f.targetRoot
        let owner = try Owner(
            f,
            cancelledCallback: {
                let fd = tractanda_lock(target.appendingPathComponent(".writer.lock").path)
                if fd >= 0 {
                    tractanda_unlock(fd)
                } else if held.withLock({
                    if $0 { return false }
                    $0 = true
                    return true
                }) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
                return stop.withLock { $0 }
            })
        defer { release.signal() }
        XCTAssertEqual(try owner.reply().operation, "ready")
        try owner.client.send(f.bytes)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent(PeerEnrollmentActivation.directory)
                    .appendingPathComponent("request.json").path),
            "The held check must precede request publication, not merely run after open.")
        owner.closeInput()
        stop.withLock { $0 = true }
        XCTAssertEqual(owner.group.wait(timeout: .now() + 0.05), .timedOut)
        let lock = tractanda_lock(target.appendingPathComponent(".writer.lock").path)
        if lock >= 0 { tractanda_unlock(lock) }
        XCTAssertLessThan(lock, 0)
        release.signal()
        owner.wait("cancelled")
        let session = try PeerEnrollmentActivation.open(root: target, material: f.material, pin: f.pin.value)
        session.close()
        f.pending()
        try f.capacity()
    }
    func testScopedControlRestoresAfterThrowCancellationAndRejectsNestedOwner() throws {
        let f = try Fixture(test: name)
        let session = try PeerEnrollmentActivation.open(
            root: f.targetRoot, material: f.material, pin: f.pin.value)
        defer { session.close() }
        var calls = 0
        try session.withControl(
            { calls += 1 },
            body: {
                XCTAssertThrowsError(
                    try session.withControl(
                        { throw PeerTargetEnrollment.failure("cancelled") }, body: {})
                )
                _ = try session.resume(packageID: f.material.baseline.packageID)
            })
        XCTAssertGreaterThan(calls, 1)
        let before = calls
        _ = try session.resume(packageID: f.material.baseline.packageID)
        XCTAssertEqual(calls, before)
        XCTAssertThrowsError(
            try session.withControl({ throw PeerTargetEnrollment.failure("cancelled") }, body: {})
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "cancelled")
        }
        XCTAssertNoThrow(
            try session.withControl(
                {}, body: { _ = try session.resume(packageID: f.material.baseline.packageID) }))
        try f.capacity()
    }
    func testActualBuiltHelperResumesPartialOriginalAndLostFinishReply() throws {
        let f = try Fixture(test: name, attachment: true)
        #if os(macOS)
            let executable = Bundle(for: PeerTargetEnrollmentTests.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("tractanda-setup")
        #else
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("tractanda-setup")
        #endif
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "Only the just-built sibling helper is admissible.")
        final class Child {
            var pid: Int32 = -1, input: Int32 = -1, output: Int32 = -1, diagnostics: Int32 = -1
            var io: PeerTargetEnrollment.IO!
            init(executable: URL, arguments: [String]) throws {
                let strings = ([executable.path] + arguments).map { strdup($0) }
                defer {
                    for string in strings {
                        free(string)
                    }
                }
                guard strings.allSatisfy({ $0 != nil }) else {
                    throw TractandaError("fixtureProcess", "Cannot allocate public helper arguments")
                }
                let argv: [UnsafePointer<CChar>?] =
                    strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
                guard
                    argv.withUnsafeBufferPointer({
                        tractanda_document_spawn(
                            executable.path, $0.baseAddress,
                            &pid, &input, &output, &diagnostics)
                    }) == 0
                else {
                    throw TractandaError("fixtureProcess", "Cannot spawn the just-built helper")
                }
                do {
                    io = try PeerTargetEnrollment.IO(
                        input: output, output: input,
                        control: PeerTargetEnrollment.Control(seconds: 25, cancelled: { false }))
                } catch {
                    cleanup()
                    throw error
                }
            }
            func reply() throws -> PeerTargetEnrollment.Reply {
                try JSON.decode(PeerTargetEnrollment.Reply.self, XCTUnwrap(io.receive(maximum: 128 * 1024)))
            }
            func send(_ object: [String: Any]) throws {
                try io.send(JSONSerialization.data(withJSONObject: object))
            }
            private func waitForExit(_ seconds: Double) -> Bool {
                let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                repeat {
                    let result = tractanda_document_exited(pid)  // WNOWAIT preserves PID/group ownership.
                    if result == 1 { return true }
                    if result < 0 { return false }
                    Thread.sleep(forTimeInterval: 0.01)
                } while DispatchTime.now().uptimeNanoseconds < deadline
                return false
            }
            func finishInputAndReap(expectedExit: Int32 = 0, closeInput: Bool = true) throws {
                if closeInput {
                    io.restoreBeforeClosing(input)
                    tractanda_close(input)
                    input = -1
                }
                guard waitForExit(25) else {
                    cleanup()
                    throw TractandaError("testTimeout", "Finite helper did not exit after EOF")
                }
                let owned = pid
                // Child is still waitable; cleanup its exact owned group before releasing the PID.
                _ = kill(-owned, SIGTERM)
                var status: Int32 = 0
                guard waitpid(owned, &status, 0) == owned else {
                    throw TractandaError("fixtureProcess", "Owned helper reap failed")
                }
                pid = -1
                XCTAssertEqual(status & 0x7f, 0)
                XCTAssertEqual((status >> 8) & 255, expectedExit)
                print("TARGET-HELPER-CHILD pid=\(owned) exit=\((status >> 8) & 255) reaped=true")
                var bytes = [UInt8](repeating: 0, count: 4097)
                let count = read(diagnostics, &bytes, bytes.count)
                guard count >= 0 || errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw TractandaError("fixtureProcess", "Cannot inspect bounded helper diagnostic pipe")
                }
                XCTAssertLessThanOrEqual(max(0, count), 4096)
                if expectedExit == 0 {
                    XCTAssertLessThanOrEqual(count, 0, "Successful helper must not log payload diagnostics.")
                }
            }
            func terminate() { if pid > 0 { _ = kill(-pid, SIGTERM) } }
            private func cleanup() {
                if pid > 0 {
                    terminate()
                    if !waitForExit(2) { _ = kill(-pid, SIGKILL) }
                    if waitForExit(2) {
                        var status: Int32 = 0
                        _ = waitpid(pid, &status, 0)
                        pid = -1
                    } else {
                        XCTFail("Exact helper cleanup incomplete; no process closure claim is valid.")
                    }
                }
                io = nil  // Restore flags before closing/releasing descriptor numbers.
                for fd in [input, output, diagnostics] where fd >= 0 { tractanda_close(fd) }
                input = -1
                output = -1
                diagnostics = -1
            }
            deinit { cleanup() }
        }
        func open() throws -> Child {
            let child = try Child(executable: executable, arguments: f.arguments)
            XCTAssertEqual(try child.reply().operation, "ready")
            // Exercise a genuinely split length header and private input body over actual stdio.
            let count = UInt32(f.bytes.count)
            let header = Data([
                UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
            ])
            try child.io.writeAll(Data(header.prefix(2)))
            Thread.sleep(forTimeInterval: 0.01)
            try child.io.writeAll(Data(header.suffix(2)))
            try child.io.writeAll(f.bytes)
            XCTAssertEqual(try child.reply().operation, "opened")
            return child
        }
        do {
            let child = try Child(executable: executable, arguments: f.arguments)
            XCTAssertEqual(try child.reply().operation, "ready")
            child.terminate()  // Actual standalone SIGTERM while waiting for private input.
            try child.finishInputAndReap(expectedExit: 1, closeInput: false)
            f.pending()
        }
        var resumedPartial = false
        var appendedPartial = false
        func transfer(_ child: Child, stopAfterPartial: Bool) throws {
            var advance = false
            for round in 0..<256 {
                if round % 8 == 0 { try f.capacity() }
                try child.send([
                    "operation": "resume", "packageID": f.material.baseline.packageID, "advance": advance,
                ])
                let page = try child.reply()
                XCTAssertEqual(page.operation, "page")
                if page.complete == true { return }
                let missing = (page.entries ?? []).filter { !$0.verifiedComplete }
                if let entry = missing.first {
                    if entry.descriptor.kind == .attachment, entry.nextOffset > 0 { resumedPartial = true }
                    let chunk = try f.source.readPeerEnrollment(
                        .init(operationID: f.operation), object: entry.descriptor,
                        offset: entry.nextOffset, maximumBytes: entry.descriptor.chunkBytes, forUID: f.uid)
                    try child.send([
                        "operation": "append", "packageID": f.material.baseline.packageID,
                        "ordinal": entry.ordinal, "offset": entry.nextOffset,
                    ])
                    try child.io.send(chunk.bytes, maximum: entry.descriptor.chunkBytes)
                    if stopAfterPartial, entry.descriptor.kind == .attachment,
                        entry.nextOffset + chunk.bytes.count < entry.descriptor.length
                    {
                        // Leave the append reply unread; EOF cannot erase this durable prefix.
                        appendedPartial = true
                        return
                    }
                    XCTAssertEqual(try child.reply().operation, "appended")
                    advance = false
                } else {
                    advance = true
                }
            }
            throw TractandaError("testTimeout", "Bounded target helper traversal did not complete")
        }
        do {
            let child = try open()
            try transfer(child, stopAfterPartial: true)
            XCTAssertTrue(appendedPartial)
            try child.finishInputAndReap()
            f.pending()
            try f.capacity()
        }
        do {
            let child = try open()
            try transfer(child, stopAfterPartial: false)
            XCTAssertTrue(resumedPartial)
            try child.send(["operation": "finish"])
            // Canonical completion may precede a lost response. Reap, then reopen exact material.
            try child.finishInputAndReap()
            try f.capacity()
        }
        let files = InitialAuthorityBootstrap.files(f.targetRoot)
        let retained = try XCTUnwrap(PeerEnrollmentActivation.loadReceipt(files))
        do {
            let child = try open()
            try child.send(["operation": "finish"])
            let reply = try child.reply()
            XCTAssertEqual(reply.operation, "finished")
            XCTAssertEqual(reply.receipt, retained)
            try child.send(["operation": "close"])
            XCTAssertEqual(try child.reply().operation, "closed")
            try child.finishInputAndReap()
        }
        XCTAssertNoThrow(try ItemStore.requireInitializedRoot(f.targetRoot))
        let target = try ItemStore.openInitialized(root: f.targetRoot)
        XCTAssertEqual(try target.peerIntakeContextToken().isEmpty, false)
        try f.capacity()
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
