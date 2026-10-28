import CTractandaPlatform
import Foundation
import Synchronization
import TractandaClient
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

    /// Exercises the current opaque private request boundary without a legacy authority store,
    /// activation record, SSH helper, or mock enrollment authorization.
    func testCurrentPersonalPrivateClientRefusesWrongKernelUIDAndUnsupportedReadyBeforeBody() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "np", source: "NativePeerEnrollmentSupervisorTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = SystemAccountDirectory()
        let actualUser = try accounts.user(forUID: tractanda_uid()).name
        let wrongUser = tractanda_uid() == 0 ? "daemon" : "root"
        XCTAssertNotEqual(try accounts.user(named: wrongUser).uid, tractanda_uid())
        let request = try JMAPValue.object([
            .init("using", .array([.string(NativePersonalEnrollment.capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: "TractandaEnrollmentLocal/join",
                        arguments: .object([.init("code", .string("synthetic-private-invitation"))]),
                        callID: "privacy"
                    ).value
                ])),
        ]).encoded()
        for unsupportedReady in [false, true] {
            let path = root.appendingPathComponent(unsupportedReady ? "r" : "u").path
            let listener = tractanda_listen(path)
            guard listener >= 0 else { throw TractandaError("fixtureSocket", "Listen failed") }
            defer { tractanda_close(listener) }
            let server = Task.detached { () throws -> (Data?, Data) in
                // Fixture-only bound: a broken test must not leave a task blocked in accept/read.
                try Self.socketReadable(listener)
                let fd = tractanda_accept(listener)
                guard fd >= 0 else { throw TractandaError("fixtureSocket", "Accept failed") }
                defer { tractanda_close(fd) }
                var begin: Data?
                if unsupportedReady {
                    let header = try Self.socketBytes(fd, maximum: 4)
                    guard header.count == 4 else {
                        throw TractandaError("fixtureSocket", "Missing marked begin header")
                    }
                    let marked = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let count = Int(marked & 0x7fff_ffff)
                    guard marked & 0x8000_0000 != 0, (1...4096).contains(count) else {
                        throw TractandaError("fixtureSocket", "Invalid begin frame bound")
                    }
                    let bytes = try Self.socketBytes(fd, maximum: count)
                    guard bytes.count == count else {
                        throw TractandaError("fixtureSocket", "Incomplete begin frame")
                    }
                    begin = bytes
                    let reply = NativePersonalEnrollment.ready + Data("/unsupported".utf8)
                    let deadline = tractanda_private_io_begin(fd)
                    guard
                        reply.withUnsafeBytes({
                            tractanda_private_send_frame(fd, $0.baseAddress, UInt32($0.count), deadline)
                        }) == 0
                    else {
                        throw TractandaError("fixtureSocket", "READY fixture send failed")
                    }
                }
                // EOF must precede even the first byte of a request-body frame (or BEGIN on UID error).
                return (begin, try Self.socketBytes(fd, maximum: 1))
            }
            let connection = ServerConnection(
                socketPath: path, serverUser: unsupportedReady ? actualUser : wrongUser)
            let client = await Task.detached { () -> String? in
                do {
                    _ = try NativePersonalEnrollment.call(connection: connection, request: request)
                    return nil
                } catch { return (error as? TractandaError)?.code ?? "untyped" }
            }.value
            // Await every owned task before leaving the fixture, including when an assertion fails.
            let (begin, leaked) = try await server.value
            XCTAssertEqual(client, unsupportedReady ? "privateEnrollmentUnavailable" : "forbidden")
            XCTAssertTrue(leaked.isEmpty, "Untrusted private endpoint received request bytes")
            if unsupportedReady {
                let header = try NativePersonalEnrollment.Begin.parse(XCTUnwrap(begin))
                XCTAssertEqual(header.byteCount, request.count)
            } else {
                XCTAssertNil(begin)
            }
        }
    }

    private static func socketReadable(_ fd: Int32) throws {
        var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&event, 1, 5_000) > 0 else {
            throw TractandaError("fixtureSocket", "Socket fixture did not become readable")
        }
    }

    private static func socketBytes(_ fd: Int32, maximum: Int) throws -> Data {
        var result = Data()
        while result.count < maximum {
            try socketReadable(fd)
            var bytes = [UInt8](repeating: 0, count: maximum - result.count)
            let count = recv(fd, &bytes, bytes.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw TractandaError("fixtureSocket", "Socket fixture read failed") }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }

}
