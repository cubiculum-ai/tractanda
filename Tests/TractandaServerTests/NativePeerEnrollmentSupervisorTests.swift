import CTractandaPlatform
import Foundation
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaServer

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class NativePeerEnrollmentSupervisorTests: XCTestCase {
    final class Fixture {
        let root: URL, sourceRoot: URL, targetRoot: URL
        let operation: String, pin: PeerTargetEnrollmentPin, input: PeerEnrollmentTargetOutput
        let itemID: String
        init(test: String, targetName: String = "target") throws {
            try PeerFixtureCapacity.requireFree()
            guard PeerFixtureCapacity.fixtureCapBytes >= 24 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Supervisor fixture setup estimate exceeds its cap")
            }
            root = try GuardedFixtureDirectory.create(
                prefix: "e", source: "NativePeerEnrollmentSupervisorTests", test: test, socket: "s")
            sourceRoot = root.appendingPathComponent("source")
            targetRoot = root.appendingPathComponent(targetName)
            try FileManager.default.createDirectory(
                at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let accounts = SystemAccountDirectory()
            let uid = tractanda_uid()
            let account = try accounts.user(forUID: uid)
            let store = try ItemStore.initializeFresh(
                root: sourceRoot, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text(account.name)]),
                    "administration": .text("system"), "administratorGroup": .text(account.primaryGroupName),
                ]))
            let sourceDirectory = sourceRoot
            let fixtureRoot = root
            itemID = try store.withAccess(forUID: uid) {
                let base = try store.commit(
                    .init(
                        classID: "Item", changes: ["subject": .text("local supervisor")],
                        operationID: "supervisor-base")
                ).revision
                let data = Data(repeating: 0x71, count: 300 * 1024)
                let upload = try store.beginAttachment(
                    .init(
                        itemID: base.itemID, expectedRevisionID: base.revisionID,
                        operationID: "supervisor-attachment", filename: "tiny.pdf",
                        mediaType: "application/pdf",
                        byteCount: Int64(data.count), sha256: AuthorityRecordCodec.sha256(data)))
                let id = try XCTUnwrap(upload.uploadID)
                _ = try store.appendAttachment(uploadID: id, offset: 0, data: data.prefix(256 * 1024))
                _ = try store.appendAttachment(
                    uploadID: id, offset: 256 * 1024, data: data.dropFirst(256 * 1024))
                let attached = try store.finishAttachment(uploadID: id).revision
                guard
                    case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                        itemID: attached.itemID,
                        expectedRevisionID: attached.revisionID, attachmentID: upload.attachment.attachmentID,
                        operationID: "supervisor-document", identity: .init())
                else {
                    throw TractandaError("fixture", "Tiny saved document snapshot missing")
                }
                let writer = try DocumentContentStore(
                    root: sourceDirectory, ownerUID: uid,
                    minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)
                ).begin(
                    source: snapshot.source,
                    identity: .init(), maximumWriteBytes: 1024 * 1024)
                // >16 real verification units, using tiny failed-page outcomes, not large payloads.
                for page in 1...17 {
                    try Self.capacity(fixtureRoot)
                    try writer.append(
                        .init(
                            pageNumber: Int64(page), sourceSHA256: snapshot.source.sha256,
                            status: "failed", failureCode: "tiny-supervisor-fixture"))
                }
                let prepared = try writer.preparePublication()
                let corpus = try store.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
                _ = try store.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
                return base.itemID
            }
            let storeID = try CanonicalReaderRequirement.storeIdentity(root: sourceRoot, ownerUID: uid)
            let prep = try PeerEnrollment.prepareTarget(
                root: targetRoot, commonStoreID: storeID, sourceReplicaID: XCTUnwrap(store.replicaID))
            let path = root.appendingPathComponent("prep")
            let pair = root.appendingPathComponent("pair")
            try JSON.encode(prep).write(to: path)
            _ = try NativePeerEnrollment.createPair(
                preparationPath: path.path, outputPath: pair.path,
                sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true)
            let captured = try PeerEnrollmentPairInput.capture(path: pair.path)
            operation = try captured.operationID
            _ = try store.nativeEnrollmentBegin(captured, forUID: uid)
            var sealed = false
            for _ in 0..<256 {
                try Self.capacity(root)
                let status = try store.stepPeerEnrollment(
                    .init(operationID: operation), forUID: uid,
                    window: .init(maximumUnits: 16, maximumEdges: 64))
                if status.manifest != nil {
                    sealed = true
                    break
                }
            }
            guard sealed else { throw TractandaError("testTimeout", "Tiny supervisor source did not seal") }
            _ = try store.acceptPeerEnrollment(.init(operationID: operation), forUID: uid)
            input = try .init(
                material: store.peerEnrollmentActivationMaterial(.init(operationID: operation), forUID: uid))
            let record = try input.withBytes { try PeerEnrollmentTargetOutput.decode($0).0 }
            pin = try .init(
                sourceReplicaID: record.pin.sourceReplicaID, bootstrapID: record.pin.bootstrap.recordID,
                bootstrapSHA256: record.pin.bootstrap.sha256, approvalID: record.pin.approval.recordID,
                approvalSHA256: record.pin.approval.sha256)
            try Self.capacity(root)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        static func capacity(_ root: URL) throws {
            try PeerFixtureCapacity.requireFree(at: root)
            var bytes: UInt64 = 0
            var count = 0
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            while let path = scan.nextObject() as? URL {
                count += 1
                guard count <= 4096 else {
                    throw TractandaError("resourceLimit", "Supervisor fixture entry bound")
                }
                let metadata = try FileMetadata.read(at: path)
                if metadata.type == .regular {
                    guard
                        metadata.size <= PeerFixtureCapacity.fixtureCapBytes
                            - min(bytes, PeerFixtureCapacity.fixtureCapBytes)
                    else { throw TractandaError("resourceLimit", "Supervisor fixture byte bound") }
                    bytes += metadata.size
                }
            }
        }
        var connection: ServerConnection { .init(socketPath: root.appendingPathComponent("s").path) }
        func helper() throws -> URL {
            #if os(macOS)
                let executable = Bundle(for: NativePeerEnrollmentSupervisorTests.self).bundleURL
                    .deletingLastPathComponent().appendingPathComponent("tractanda-setup")
            #else
                let executable = try PeerEnrollmentSupervisor.sibling(
                    image: PeerEnrollmentSupervisor.actualImage())
            #endif
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw TractandaError("fixtureBinary", "Just-built setup sibling is missing")
            }
            return executable
        }
    }
    // A controlled SSH-shaped process exercises the production sixteen-argument command and
    // actual helper pump. It simulates transport only, without SSH trust or KEX negotiation.
    static func simulatedSSH(_ f: Fixture, failure: String? = nil, exitAfterHelper: Bool = false) throws
        -> URL
    {
        let directory = f.root.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("tractanda-setup")
        let body =
            failure.map { "exit \($0)\n" }
            ?? (exitAfterHelper ? "/bin/sh -c \"${16}\"\nexit 255\n" : "exec /bin/sh -c \"${16}\"\n")
        let script =
            "#!/bin/sh\ncd " + (try PeerEnrollmentSSH.quoted(f.root.path))
            + " || exit 254\n[ \"$#\" -eq 16 ] || exit 254\n[ \"$1\" = '-F/dev/null' ] || exit 254\n[ \"${10}\" = '-oKexAlgorithms=mlkem768x25519-sha256,sntrup761x25519-sha512' ] || exit 254\n"
            + body
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        try Fixture.capacity(f.root)
        return path
    }
    final class Children: Sendable {
        let state = Mutex<[Int32: Int32?]>([:])
        func hooks(helper: URL) -> PeerEnrollmentSupervisor.Hooks {
            .init(
                helper: helper, spawned: { [self] pid in state.withLock { $0[pid] = .some(nil) } },
                reaped: { [self] pid, status in
                    state.withLock { $0[pid] = .some(status) }
                    print("SUPERVISOR-HELPER-CHILD pid=\(pid) status=\(status) reaped=true")
                })
        }
        func assertClosed(file: StaticString = #filePath, line: UInt = #line) {
            let rows = state.withLock { $0 }
            XCTAssertFalse(rows.isEmpty, file: file, line: line)
            for (pid, status) in rows {
                XCTAssertNotNil(status, file: file, line: line)
                XCTAssertEqual(kill(pid, 0), -1, file: file, line: line)
                XCTAssertEqual(errno, ESRCH, file: file, line: line)
            }
        }
    }
    func testActualNativeSourceAndFixedHelperTransferRegisterAndExactRetry() async throws {
        var phase = "fixture"
        do {
            let f = try Fixture(test: name)
            let daemon = try await SharedDaemon.startForTesting(
                configuration: .init(
                    storePath: f.sourceRoot.path,
                    socketPath: f.connection.socketPath, httpPort: nil),
                makeAccountDirectory: { SystemAccountDirectory() })
            defer { await daemon.close() }
            let connection = f.connection
            let operation = f.operation
            let input = f.input
            let pin = f.pin
            let target = f.targetRoot
            let children = Children()
            let transientFinish = Mutex(0)
            var hooks = children.hooks(helper: try f.helper())
            hooks.reply = { operation, data in
                if operation == "finished",
                    let reply = try? JSON.decode(PeerTargetEnrollment.Reply.self, data),
                    reply.code == "peerPayloadVerifying"
                {
                    transientFinish.withLock { $0 += 1 }
                }
                return data
            }
            let stable = hooks
            for iteration in 0..<2 {
                phase = iteration == 0 ? "run1" : "run2"
                let result = try await Task.detached {
                    try PeerEnrollmentSupervisor.run(
                        connection: connection, operationID: operation, input: input,
                        targetRoot: target.path, pin: pin, custody: .current, seconds: 60,
                        cancelled: { false }, hooks: stable)
                }.value
                XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("registered"))
                try Fixture.capacity(f.root)
            }
            children.assertClosed()
            XCTAssertGreaterThan(transientFinish.withLock { $0 }, 0)
            phase = "targetOpen"
            let targetStore = try ItemStore.openInitialized(root: target, accounts: SystemAccountDirectory())
            phase = "targetGet"
            let current = try targetStore.withAccess(forUID: tractanda_uid()) {
                try targetStore.get(f.itemID)
            }
            XCTAssertEqual(current.fields["subject"], .text("local supervisor"))
            phase = "documentManifest"
            let saved = try XCTUnwrap(
                AttachmentDocumentRepresentation.representations(in: current.fields).first)
            let reference = try XCTUnwrap(saved.content)
            let manifest = try DocumentContentStore(
                root: target, ownerUID: tractanda_uid(),
                minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)
            ).manifest(reference)
            XCTAssertEqual(manifest.pageCount, 17)
            phase = "attachmentRead"
            let attachment = try XCTUnwrap(AttachmentDescriptor.descriptors(in: current.fields).first)
            let data = try targetStore.withAccess(forUID: tractanda_uid()) {
                let first = try targetStore.attachmentContent(
                    itemID: f.itemID, attachmentID: attachment.attachmentID)
                let last = try targetStore.attachmentContent(
                    itemID: f.itemID, attachmentID: attachment.attachmentID, offset: first.nextOffset)
                XCTAssertTrue(last.isComplete)
                return first.data + last.data
            }
            XCTAssertEqual(data, Data(repeating: 0x71, count: 300 * 1024))
            XCTAssertEqual(AuthorityRecordCodec.sha256(data), attachment.sha256)
            try Fixture.capacity(f.root)
            phase = "sourceReadonlyStatus"
            let status = try await Task.detached {
                try NativePeerEnrollment.call(connection: connection, action: .status, operationID: operation)
            }.value
            // Existing read-only status describes the accepted enrollment decision, even after registration.
            XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, status).phase, "accepted")
            phase = "registrationWitness"
            let files = InitialAuthorityBootstrap.files(f.sourceRoot)
            let record = try input.withBytes { try PeerEnrollmentTargetOutput.decode($0).0 }
            let registered = try JSON.decode(
                AuthorityBinding.self,
                files.read(
                    path: [PeerEnrollmentActivation.sourceDirectory, operation, "registered.json"],
                    maximumBytes: 4096))
            let commit = try JSON.decode(
                PeerEnrollmentActivation.ConfigurationCommit.self,
                files.read(
                    path: [PeerEnrollmentActivation.sourceDirectory, operation, "configuration.json"],
                    maximumBytes: PeerEnrollmentActivation.maximumBytes))
            XCTAssertEqual(registered, record.pin.approval)
            XCTAssertEqual(commit.approval, registered)
            XCTAssertTrue(commit.after.peers.contains(record.sourceContext))
            XCTAssertEqual(
                try files.read(
                    path: [".peer-configuration", String(format: "%020llu.json", commit.sequence)],
                    maximumBytes: PeerEnrollmentActivation.maximumBytes), try JSON.encode(commit.after))
            XCTAssertEqual(try AuthorityStore.configurationSequence(root: f.sourceRoot), commit.sequence)
        } catch {
            let code = (error as? TractandaError)?.code ?? "untyped"
            let safeCode =
                code.utf8.count <= 64
                    && code.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    }) ? code : "unclassified"
            print(
                "B1-BOUNDARY phase=\(phase) type=\(String(reflecting: type(of: error))) code=\(safeCode) parentCancelled=\(Task.isCancelled)"
            )
            throw error
        }
    }
    func testLostClosedAfterFinishedSkipsRegistrationThenExactRetryCompletes() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let children = Children()
        let registrations = Mutex(0)
        var hooks = children.hooks(helper: try f.helper())
        hooks.reply = { operation, data in
            if operation == "closed" { return Data("lost reply".utf8) }
            return data
        }
        hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
        let damaged = hooks
        do {
            _ = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: connection, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, seconds: 60,
                    cancelled: { false }, hooks: damaged)
            }.value
            XCTFail("Injected CLOSED loss must not register")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "targetCustodyUncertain") }
        XCTAssertEqual(registrations.withLock { $0 }, 0)
        let status = try await Task.detached {
            try NativePeerEnrollment.call(connection: connection, action: .status, operationID: operation)
        }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, status).phase, "accepted")
        try ItemStore.requireInitializedRoot(target)
        let exact = children.hooks(helper: try f.helper())
        _ = try await Task.detached {
            try PeerEnrollmentSupervisor.run(
                connection: connection, operationID: operation,
                input: input, targetRoot: target.path, pin: pin, custody: .current, seconds: 60,
                cancelled: { false }, hooks: exact)
        }.value
        children.assertClosed()
        try Fixture.capacity(f.root)
    }
    func testRepeatedExactTransientStopsOnCancellationDrainsChildAndNeverRegisters() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let children = Children()
        let transients = Mutex(0)
        let registration = Mutex(0)
        var hooks = children.hooks(helper: try f.helper())
        hooks.reply = { operation, data in
            guard operation == "finished" else { return data }
            transients.withLock { $0 += 1 }
            var reply = PeerTargetEnrollment.Reply("error")
            reply.code = "peerPayloadVerifying"
            return try JSON.encode(reply)  // Controlled no-progress wire fault, not a stalled-Core claim.
        }
        hooks.beforeRegister = { registration.withLock { $0 += 1 } }
        let stable = hooks
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: connection, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, seconds: 30,
                    cancelled: { transients.withLock { $0 >= 3 } }, hooks: stable)
            }.value
            XCTFail("Repeated transient must stop at cancellation")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "cancelled") }
        XCTAssertEqual(transients.withLock { $0 }, 3)
        XCTAssertEqual(registration.withLock { $0 }, 0)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started, 35_000_000_000)
        children.assertClosed()
        let lock = tractanda_lock(target.appendingPathComponent(".writer.lock").path)
        XCTAssertGreaterThanOrEqual(lock, 0)
        if lock >= 0 { tractanda_unlock(lock) }
        let status = try await Task.detached {
            try NativePeerEnrollment.call(connection: connection, action: .status, operationID: operation)
        }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, status).phase, "accepted")
        try Fixture.capacity(f.root)
    }
    func testWrongSourceKernelIdentityAndOldReadyRefuseBeforePrivateInput() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let sent = Mutex(0)
        let children = Children()
        var hooks = children.hooks(helper: try f.helper())
        hooks.didSendPrivateInput = { sent.withLock { $0 += 1 } }
        let wrong = ServerConnection(socketPath: f.connection.socketPath, serverUser: "root")
        let unchanged = hooks
        do {
            _ = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: wrong, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, seconds: 2,
                    cancelled: { false }, hooks: unchanged)
            }.value
            XCTFail("Wrong kernel daemon UID")
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, "forbidden")
            XCTAssertEqual(sent.withLock { $0 }, 0)
        }
        XCTAssertTrue(children.state.withLock { $0.isEmpty })
        hooks.reply = { operation, data in
            operation == "ready"
                ? Data(
                    String(decoding: data, as: UTF8.self).replacingOccurrences(of: ".v2", with: ".v1").utf8)
                : data
        }
        let old = hooks
        let connection = f.connection
        do {
            _ = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: connection, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, seconds: 2,
                    cancelled: { false }, hooks: old)
            }.value
            XCTFail("Old helper must be refused")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "invalidHelperReply") }
        XCTAssertEqual(sent.withLock { $0 }, 0)
        children.assertClosed()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("index").path))
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(target)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
        try Fixture.capacity(f.root)
    }
    func testSimulatedSSHQuotedCommandActualHelperTransferAndExactRetry() async throws {
        let f = try Fixture(test: name, targetName: "target '雪';$(touch injected)`id`")
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let destination = try PeerEnrollmentSSHDestination(
            host: "simulated.example", login: "remote-login", platform: .linux)
        let children = Children()
        let registrations = Mutex(0)
        var hooks = children.hooks(helper: try f.helper())
        hooks.sshClient = try Self.simulatedSSH(f)
        hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
        let stable = hooks
        for _ in 0..<2 {
            let result = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: connection, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, ssh: destination,
                    seconds: 60, cancelled: { false }, hooks: stable)
            }.value
            XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("registered"))
            try Fixture.capacity(f.root)
        }
        XCTAssertEqual(registrations.withLock { $0 }, 2)
        children.assertClosed()
        let store = try ItemStore.openInitialized(root: target, accounts: SystemAccountDirectory())
        XCTAssertEqual(
            try store.withAccess(forUID: tractanda_uid()) { try store.get(f.itemID) }.fields["subject"],
            .text("local supervisor"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("injected").path))
    }
    func testSimulatedSSHExit255AndOldReadyNeverSendPrivateInputOrRegister() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let destination = try PeerEnrollmentSSHDestination(
            host: "simulated.example", login: "remote", platform: .macOS)
        let children = Children()
        let privateInputs = Mutex(0)
        let registrations = Mutex(0)
        // Exit 255 simulates SSH refusing host trust or an unsupported KEX before READY.
        // It does not establish an actual host-key or algorithm negotiation result.
        for oldReady in [false, true] {
            var hooks = children.hooks(helper: try f.helper())
            hooks.sshClient = try Self.simulatedSSH(f, failure: oldReady ? nil : "255")
            hooks.didSendPrivateInput = { privateInputs.withLock { $0 += 1 } }
            hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
            if oldReady {
                hooks.reply = { operation, data in
                    operation == "ready"
                        ? Data(
                            String(decoding: data, as: UTF8.self).replacingOccurrences(of: ".v2", with: ".v1")
                                .utf8) : data
                }
            }
            let stable = hooks
            do {
                _ = try await Task.detached {
                    try PeerEnrollmentSupervisor.run(
                        connection: connection, operationID: operation,
                        input: input, targetRoot: target.path, pin: pin, custody: .current, ssh: destination,
                        seconds: 5, cancelled: { false }, hooks: stable)
                }.value
                XCTFail("A simulated remote refusal must stop before secrets")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "targetCustodyUncertain") }
        }
        XCTAssertEqual(privateInputs.withLock { $0 }, 0)
        XCTAssertEqual(registrations.withLock { $0 }, 0)
        children.assertClosed()
        try Fixture.capacity(f.root)
        XCTAssertThrowsError(try ItemStore.requireInitializedRoot(target)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "enrollmentPending")
        }
    }
    func testSimulatedSSHLostClosedAndExitAfterClosedSkipRegistrationUntilExactRetry() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let destination = try PeerEnrollmentSSHDestination(
            host: "simulated.example", login: "remote", platform: .linux)
        let children = Children()
        let registrations = Mutex(0)
        for loseClosed in [true, false] {
            var hooks = children.hooks(helper: try f.helper())
            hooks.sshClient = try Self.simulatedSSH(f, exitAfterHelper: !loseClosed)
            hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
            if loseClosed {
                hooks.reply = { operation, data in operation == "closed" ? Data("lost CLOSED".utf8) : data }
            }
            let stable = hooks
            do {
                _ = try await Task.detached {
                    try PeerEnrollmentSupervisor.run(
                        connection: connection, operationID: operation,
                        input: input, targetRoot: target.path, pin: pin, custody: .current, ssh: destination,
                        seconds: 60, cancelled: { false }, hooks: stable)
                }.value
                XCTFail("CLOSED and successful local SSH reap must both precede registration")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "targetCustodyUncertain") }
            XCTAssertEqual(registrations.withLock { $0 }, 0)
            try Fixture.capacity(f.root)
        }
        var hooks = children.hooks(helper: try f.helper())
        hooks.sshClient = try Self.simulatedSSH(f)
        hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
        let stable = hooks
        _ = try await Task.detached {
            try PeerEnrollmentSupervisor.run(
                connection: connection, operationID: operation,
                input: input, targetRoot: target.path, pin: pin, custody: .current, ssh: destination,
                seconds: 60, cancelled: { false }, hooks: stable)
        }.value
        XCTAssertEqual(registrations.withLock { $0 }, 1)
        children.assertClosed()
        try Fixture.capacity(f.root)
    }
    func testSimulatedSSHCancelledTransferReportsRemoteUncertaintyAndReapsOnlyLocalClient() async throws {
        let f = try Fixture(test: name)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: f.connection.socketPath, httpPort: nil),
            makeAccountDirectory: { SystemAccountDirectory() })
        defer { await daemon.close() }
        let connection = f.connection
        let operation = f.operation
        let input = f.input
        let pin = f.pin
        let target = f.targetRoot
        let destination = try PeerEnrollmentSSHDestination(
            host: "simulated.example", login: "remote", platform: .macOS)
        let children = Children()
        let transients = Mutex(0)
        let registrations = Mutex(0)
        var hooks = children.hooks(helper: try f.helper())
        hooks.sshClient = try Self.simulatedSSH(f)
        hooks.beforeRegister = { registrations.withLock { $0 += 1 } }
        hooks.reply = { operation, data in
            guard operation == "finished" else { return data }
            transients.withLock { $0 += 1 }
            var reply = PeerTargetEnrollment.Reply("error")
            reply.code = "peerPayloadVerifying"
            return try JSON.encode(reply)
        }
        let stable = hooks
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await Task.detached {
                try PeerEnrollmentSupervisor.run(
                    connection: connection, operationID: operation,
                    input: input, targetRoot: target.path, pin: pin, custody: .current, ssh: destination,
                    seconds: 30, cancelled: { transients.withLock { $0 >= 3 } }, hooks: stable)
            }.value
            XCTFail("Cancellation must stop remote work")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "targetCustodyUncertain") }
        XCTAssertEqual(transients.withLock { $0 }, 3)
        XCTAssertEqual(registrations.withLock { $0 }, 0)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 35_000_000_000)
        children.assertClosed()
        try Fixture.capacity(f.root)
        let status = try await Task.detached {
            try NativePeerEnrollment.call(connection: connection, action: .status, operationID: operation)
        }.value
        XCTAssertEqual(try JSON.decode(PeerEnrollmentOperatorStatus.self, status).phase, "accepted")
    }

}
