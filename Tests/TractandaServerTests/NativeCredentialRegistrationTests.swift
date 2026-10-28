import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
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

private final class NativeCredentialAccounts: AccountDirectory, @unchecked Sendable {
    let base: PeerServiceFixture.Accounts
    private let admin = Mutex(true)
    init(_ base: PeerServiceFixture.Accounts) { self.base = base }
    func demote() { admin.withLock { $0 = false } }
    func user(forUID uid: UInt32) throws -> AccountIdentity {
        if uid == tractanda_uid() {
            let human = try base.user(forUID: base.human)
            return .init(
                uid: uid, name: human.name, primaryGroupName: human.primaryGroupName,
                groupIDs: admin.withLock { $0 } ? human.groupIDs : [])
        }
        return try base.user(forUID: uid)
    }
    func user(named name: String) throws -> AccountIdentity {
        name == "human" ? try user(forUID: tractanda_uid()) : try base.user(named: name)
    }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}

private actor NativeCredentialGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class NativeCredentialRegistrationTests: XCTestCase {
    private func credential(
        _ f: PeerServiceFixture, alias: String = "new-peer", generation: String? = nil,
        secret: UInt8 = 0x5a, pairing: String? = nil
    ) throws -> PeerCredential {
        let source = f.request.sourceCredential.binding
        return try .init(
            binding: .init(
                peerID: alias, storeID: source.storeID, localReplicaID: source.localReplicaID,
                remoteReplicaID: source.remoteReplicaID, pairingID: pairing ?? PeerServiceFixture.id(),
                localIsInitiator: true,
                configurationDigest: generation
                    ?? AuthorityRecordCodec.sha256(Data("native-registration".utf8))),
            secret: Array(repeating: secret, count: 32))
    }
    private func input(_ root: URL, credential: PeerCredential, name: String = "input") throws
        -> PeerPrivateCredentialInput
    {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try PeerCredentialStore(
            files: DocumentContentFiles(
                root: folder, ownerUID: tractanda_uid(),
                minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes))
        ).stage(credential)
        let file = try PeerCredentialStore.path(
            peerID: credential.binding.peerID, configurationDigest: credential.binding.configurationDigest
        )
        .reduce(folder) { $0.appendingPathComponent($1) }
        return try PeerPrivateCredentialInput.capture(path: file.path)
    }
    private func request(_ f: PeerServiceFixture, input: PeerPrivateCredentialInput, operation: String? = nil)
        throws
        -> NativePeerCredentialRegistration.Begin
    {
        try .init(
            operationID: operation ?? PeerServiceFixture.id(),
            permittedOrigins: f.request.sourceContext.permittedOrigins,
            byteCount: input.count)
    }
    func testKernelSocketRegistrationAndExactCurrentRetryUseExistingImmutableBytes() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "NativeCredentialRegistrationTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerServiceFixture(root: root)
        let accounts = NativeCredentialAccounts(f.accounts)
        let value = try credential(f)
        let payload = try input(root, credential: value)
        let operation = try PeerServiceFixture.id()
        f.releaseWriter()
        let socket = root.appendingPathComponent("s")
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: socket.path, httpPort: nil), makeAccountDirectory: { accounts })
        defer { await daemon.close() }
        let connection = ServerConnection(socketPath: socket.path)
        let origins = f.request.sourceContext.permittedOrigins
        if tractanda_uid() != 0 {
            let wrongDaemon = ServerConnection(socketPath: socket.path, serverUser: "root")
            do {
                _ = try await Task.detached {
                    try NativePeerCredentialRegistration.register(
                        connection: wrongDaemon,
                        input: payload, permittedOrigins: origins, operationID: operation)
                }.value
                XCTFail("Actual kernel daemon UID must match before private begin.")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "forbidden") }
        }
        for _ in 0..<2 {
            let result = try await Task.detached {
                try NativePeerCredentialRegistration.register(
                    connection: connection, input: payload,
                    permittedOrigins: origins, operationID: operation)
            }.value
            XCTAssertTrue(try JSON.decode(NativePeerCredentialRegistration.Result.self, result).registered)
            XCTAssertFalse(String(decoding: result, as: UTF8.self).contains("ZZZZZZZZ"))
        }
        let inputPath = try PeerCredentialStore.path(
            peerID: value.binding.peerID,
            configurationDigest: value.binding.configurationDigest
        ).reduce(root.appendingPathComponent("input")) { $0.appendingPathComponent($1) }.path
        #if os(macOS)
            let executable = Bundle(for: NativeCredentialRegistrationTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("tractanda")
        #else
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("tractanda")
        #endif
        let cli = try await Task.detached { () throws -> (Int32, Data, Data) in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = [
                "--socket", socket.path, "peer", "credential", "register", "--file", inputPath,
                "--origin", origins[0], "--operation-id", operation,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TRACTANDA_SERVER_USER")
            process.environment = environment
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
            defer { timeout.cancel() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, bytes, diagnostics)
        }.value
        XCTAssertEqual(cli.0, 0, String(decoding: cli.2, as: UTF8.self))
        XCTAssertTrue(try JSON.decode(NativePeerCredentialRegistration.Result.self, cli.1).registered)
        XCTAssertFalse(String(decoding: cli.2, as: UTF8.self).contains("ZZZZZZZZ"))
        // A different payload conflicts with immutable same-generation bytes, independently of operation ID.
        let other = try credential(f, secret: 0x33, pairing: value.binding.pairingID)
        let conflict = try input(root, credential: other, name: "conflict")
        do {
            _ = try await Task.detached {
                try NativePeerCredentialRegistration.register(
                    connection: connection,
                    input: conflict, permittedOrigins: origins, operationID: operation)
            }.value
            XCTFail("Existing private generation must not be overwritten.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "invalidPeerCredential") }
        await daemon.close()
        let reopened = try ItemStore.openInitialized(root: f.sourceRoot, accounts: accounts)
        let loaded = try reopened.loadPeerCredential(peerID: value.binding.peerID)
        loaded.withTLSInput { _, bytes in XCTAssertEqual(bytes, Array(repeating: 0x5a, count: 32)) }
        try f.capacity()
    }
    func testKernelServiceOwnerIsDeniedBeforePayloadAndGenericRoutesHaveNoAdapter() async throws {
        guard tractanda_uid() != 0 else {
            throw XCTSkip("Host-root repair is an existing separate policy path.")
        }
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "NativeCredentialRegistrationTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerServiceFixture(root: root)
        let value = try credential(f)
        let payload = try input(root, credential: value)
        let accounts = f.accounts
        let origins = f.request.sourceContext.permittedOrigins
        let operation = try PeerServiceFixture.id()
        f.releaseWriter()
        let socket = root.appendingPathComponent("s")
        let daemon = try await SharedDaemon.startForTesting(
            configuration: .init(
                storePath: f.sourceRoot.path,
                socketPath: socket.path, httpPort: nil), makeAccountDirectory: { accounts })
        defer { await daemon.close() }
        let connection = ServerConnection(socketPath: socket.path)
        do {
            _ = try await Task.detached {
                try NativePeerCredentialRegistration.register(
                    connection: connection,
                    input: payload, permittedOrigins: origins, operationID: operation)
            }.value
            XCTFail("Filesystem service ownership is not a canonical administrator grant.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "forbidden") }
        await daemon.close()
        let coordinator = try await ServiceCoordinator(
            opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "private")
        defer { await app.close() }
        let token = try await sessions.issue(forUID: f.accounts.human).token
        let forged = try JSONSerialization.data(withJSONObject: [
            "using": TractandaJMAP.using,
            "methodCalls": [["TractandaPeer/registerCredential", ["uid": 0, "administrator": true], "x"]],
        ])
        for reply in [
            try await sessions.dispatch(forged, token: token),
            try await app.native(forged, forUID: f.accounts.human),
        ] {
            XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("unknownMethod"))
            XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("registered"))
        }
        let http = try await app.http(
            .init(
                method: "POST", uri: "/api",
                headers: [
                    "host": ["127.0.0.1:48730"],
                    "content-type": ["application/json"], "authorization": ["Bearer " + token],
                ], body: forged, localPort: 48730))
        XCTAssertTrue(String(decoding: http.body, as: UTF8.self).contains("unknownMethod"))
        try f.capacity()
    }
    func testReadyIsNotAuthorityAndContextCancellationAndShutdownFailClosed() async throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "NativeCredentialRegistrationTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerServiceFixture(root: root)
        let accounts = NativeCredentialAccounts(f.accounts)
        let value = try credential(f)
        let payload = try input(root, credential: value)
        let begin = try request(f, input: payload)
        f.releaseWriter()
        let coordinator = try await ServiceCoordinator(
            opening: f.sourceRoot, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
        defer { await coordinator.close() }
        let sessions = SessionAuthority(coordinator: coordinator)
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data(), manual: Data(), nonce: "private")
        defer { await app.close() }
        let malformed = try PeerPrivateCredentialInput(bytes: Data(repeating: 0x5a, count: 36))
        let malformedSession = try await app.makePrivateCredentialSession(
            request(f, input: malformed),
            forUID: tractanda_uid(), control: .init())
        do {
            _ = try await malformedSession.commit(malformed)
            XCTFail("Malformed private bytes cannot be accepted.")
        } catch {
            XCTAssertEqual((error as? TractandaError)?.code, "invalidPeerCredential")
            XCTAssertFalse(String(describing: error).contains("ZZZZZZZZ"))
        }
        await malformedSession.cancel()
        let waiting = try await app.makePrivateCredentialSession(
            begin, forUID: tractanda_uid(), control: .init())
        // No Store access scope is held by READY: an ordinary authorized write completes while input waits.
        let commit = CommitRequest(
            classID: "Item", changes: ["subject": .text("during-ready")],
            operationID: try PeerServiceFixture.id())
        let arguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSON.encode(commit)) as? [String: Any])
        let written = try await nativeFixtureResponse(
            coordinator, forUID: tractanda_uid(), method: "TractandaItem/commit", arguments: arguments,
            callID: "w")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let responses = try XCTUnwrap(envelope["methodResponses"] as? [[Any]])
        XCTAssertEqual(
            responses.first?.first as? String, "TractandaItem/commit",
            "The ordinary write must actually commit before asserting a stale context.")
        do {
            _ = try await waiting.commit(payload)
            XCTFail("Old context must not commit.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "operationReviewRequired") }
        await waiting.cancel()
        let cancellation = try PeerExchangeControl()
        let cancelled = try await app.makePrivateCredentialSession(
            begin, forUID: tractanda_uid(), control: cancellation)
        cancellation.cancel()
        do {
            _ = try await cancelled.commit(payload)
            XCTFail("Cancelled admission must not enter mutation.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "cancelled") }
        await cancelled.cancel()
        let changed = try await app.makePrivateCredentialSession(
            begin, forUID: tractanda_uid(), control: .init())
        if tractanda_uid() != 0 {
            accounts.demote()
            do {
                _ = try await changed.commit(payload)
                XCTFail("READY cannot preserve administrator rights.")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "forbidden") }
        }
        await changed.cancel()
        await app.close()
        do {
            _ = try await app.makePrivateCredentialSession(begin, forUID: tractanda_uid(), control: .init())
            XCTFail()
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceClosed") }
        try f.capacity()
    }
    func testPrivateFramesFragmentBoundPayloadAndListenerCloseCancelsWaitingSession() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "NativeCredentialRegistrationTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let socket = root.appendingPathComponent("s")
        let committed = Mutex(0)
        let cancellations = Mutex<[String: Int]>([:])
        let origins = [try PeerServiceFixture.id()]
        let firstID = try PeerServiceFixture.id()
        let secondID = try PeerServiceFixture.id()
        let thirdID = try PeerServiceFixture.id()
        func begin(_ operation: String) throws -> Data {
            try NativePeerCredentialRegistration.Begin(
                operationID: operation, permittedOrigins: origins, byteCount: 36
            ).encoded()
        }
        let ordinaryCalls = Mutex(0)
        let ordinary = try await DaemonListeners.unix(
            group: group, socketPath: socket.path, permissions: 0o600,
            managed: false,
            handler: { _, _ in
                ordinaryCalls.withLock { $0 += 1 }
                return Data("ordinary".utf8)
            })
        defer { try? await ordinary.close() }
        let unsupported = ServerConnection(socketPath: socket.path)
        let emptyPrivate = try PeerPrivateCredentialInput(bytes: Data(repeating: 0, count: 36))
        do {
            _ = try await Task.detached {
                try NativePeerCredentialRegistration.register(
                    connection: unsupported,
                    input: emptyPrivate, permittedOrigins: origins, operationID: firstID)
            }.value
            XCTFail("An unsupported listener must never elicit the private payload.")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "privateCredentialProtocol") }
        XCTAssertEqual(ordinaryCalls.withLock { $0 }, 0)
        let ordinaryResult = try await Task.detached { try unsupported.send(Data("request".utf8)) }.value
        XCTAssertEqual(ordinaryResult, Data("ordinary".utf8))
        XCTAssertEqual(ordinaryCalls.withLock { $0 }, 1)
        try await ordinary.close()
        let listener = try await DaemonListeners.unixWithPrivateCredential(
            group: group, socketPath: socket.path,
            permissions: 0o600, managed: false, handler: { _, _ in Data("ordinary".utf8) },
            privateBegin: { request, uid, _ in
                XCTAssertEqual(uid, tractanda_uid())
                let value = try NativePeerCredentialRegistration.Begin.parse(request)
                return .init(
                    byteCount: value.byteCount,
                    commit: { _ in
                        committed.withLock { $0 += 1 }
                        return try JSON.encode(NativePeerCredentialRegistration.Result(registered: true))
                    }, cancel: { cancellations.withLock { $0[value.operationID, default: 0] += 1 } })
            })
        try await Task.detached {
            let fd = tractanda_connect(socket.path)
            guard fd >= 0 else { throw NativePeerCredentialRegistration.protocolFailure() }
            defer { tractanda_close(fd) }
            let deadline = tractanda_private_io_begin(fd)
            let start = ContinuousClock.now
            let oversizedBegin = Data([0x80, 0, 0x40, 1])  // 16 KiB + 1; no body sent.
            XCTAssertEqual(oversizedBegin.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, 4)
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            XCTAssertEqual(tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline), -1)
            if let pointer { tractanda_private_free(pointer, count) }
            XCTAssertLessThan(
                start.duration(to: .now), .seconds(5),
                "Marked length must be rejected before waiting for a body.")
        }.value
        let path = socket.path
        let first = try begin(firstID)
        try await Task.detached {
            let fd = tractanda_connect(path)
            guard fd >= 0 else { throw NativePeerCredentialRegistration.protocolFailure() }
            defer { tractanda_close(fd) }
            let header = UInt32(first.count) | 0x8000_0000
            let bytes =
                Data([
                    UInt8(header >> 24), UInt8((header >> 16) & 255), UInt8((header >> 8) & 255),
                    UInt8(header & 255),
                ]) + first + Data([0])
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            let received = tractanda_private_receive_frame(
                fd, &pointer, &count, 4096, tractanda_private_io_begin(fd))
            if let pointer {
                defer { tractanda_private_free(pointer, count) }
                // A single send does not prove receive-time coalescing. If the extra byte
                // remained kernel-queued until READY, it is only an incomplete next header.
                XCTAssertEqual(
                    Data(bytes: pointer, count: Int(count)), NativePeerCredentialRegistration.ready)
            } else {
                XCTAssertEqual(received, -1)
            }
        }.value
        XCTAssertEqual(committed.withLock { $0 }, 0)
        let second = try begin(secondID)
        try await Task.detached {
            let fd = tractanda_connect(path)
            guard fd >= 0 else { throw NativePeerCredentialRegistration.protocolFailure() }
            defer { tractanda_close(fd) }
            let deadline = tractanda_private_io_begin(fd)
            let header = UInt32(second.count) | 0x8000_0000
            let bytes =
                Data([
                    UInt8(header >> 24), UInt8((header >> 16) & 255), UInt8((header >> 8) & 255),
                    UInt8(header & 255),
                ]) + second
            for part in [Data(bytes.prefix(2)), Data(bytes.dropFirst(2).prefix(2)), Data(bytes.dropFirst(4))]
            {
                XCTAssertEqual(part.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, part.count)
                try await Task.sleep(for: .milliseconds(20))
            }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            guard tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline) == 0,
                let ready = pointer
            else {
                throw NativePeerCredentialRegistration.protocolFailure()
            }
            XCTAssertEqual(Data(bytes: ready, count: Int(count)), NativePeerCredentialRegistration.ready)
            tractanda_private_free(ready, count)
            pointer = nil
            // Invalid length is rejected from its header, without waiting for a body.
            let oversized = Data([0, 0, 0x10, 1])
            XCTAssertEqual(oversized.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, 4)
            XCTAssertEqual(tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline), -1)
            if let pointer { tractanda_private_free(pointer, count) }
        }.value
        let third = try begin(thirdID)
        let fd = tractanda_connect(path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { tractanda_close(fd) }
        let deadline = tractanda_private_io_begin(fd)
        try await Task.detached {
            XCTAssertEqual(
                third.withUnsafeBytes {
                    tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
                }, 0)
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            guard tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline) == 0, let pointer
            else {
                throw NativePeerCredentialRegistration.protocolFailure()
            }
            defer { tractanda_private_free(pointer, count) }
            XCTAssertEqual(Data(bytes: pointer, count: Int(count)), NativePeerCredentialRegistration.ready)
        }.value
        try await listener.close()
        XCTAssertEqual(cancellations.withLock { $0[thirdID] }, 1)
        XCTAssertEqual(cancellations.withLock { $0[secondID] }, 1)
        XCTAssertEqual(committed.withLock { $0 }, 0)
    }
    func testListenerRetainsClosedChildSlotsAndDrainsHeldBeginCommitAndCancel() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "NativeCredentialRegistrationTests", test: name, socket: "s")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let path = root.appendingPathComponent("s").path
        let beginEntered = expectation(description: "begin held")
        let cancelEntered = expectation(description: "late cancel held")
        let beginGate = NativeCredentialGate(beginEntered)
        let cancelGate = NativeCredentialGate(cancelEntered)
        defer {
            await beginGate.release()
            await cancelGate.release()
        }
        let begins = Mutex(0)
        let operation = try PeerServiceFixture.id()
        let frame = try NativePeerCredentialRegistration.Begin(
            operationID: operation,
            permittedOrigins: [PeerServiceFixture.id()], byteCount: 36
        ).encoded()
        let listener = try await DaemonListeners.unixWithPrivateCredential(
            group: group, socketPath: path,
            permissions: 0o600, managed: false, connectionLimitForTesting: 1,
            handler: { _, _ in Data() },
            privateBegin: { _, _, _ in
                let number = begins.withLock {
                    $0 += 1
                    return $0
                }
                if number == 1 { await beginGate.wait() }
                // Intentionally return a late successful session after transport closure.
                return .init(byteCount: 36, commit: { _ in Data() }, cancel: { await cancelGate.wait() })
            })
        defer {
            await beginGate.release()
            await cancelGate.release()
            try? await listener.close()
        }
        let firstFD = tractanda_connect(path)
        XCTAssertGreaterThanOrEqual(firstFD, 0)
        let first = FileHandle(fileDescriptor: firstFD, closeOnDealloc: true)
        defer { try? first.close() }
        try await Task.detached {
            XCTAssertEqual(
                frame.withUnsafeBytes {
                    tractanda_private_send_begin(
                        firstFD, $0.baseAddress, UInt32($0.count), tractanda_private_io_begin(firstFD))
                }, 0)
        }.value
        await fulfillment(of: [beginEntered], timeout: 5)
        await listener.closeChildrenForTesting()  // Actual closeFuture; begin remains held.
        try await Task.detached {
            let fd = tractanda_connect(path)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { tractanda_close(fd) }
            let deadline = tractanda_private_io_begin(fd)
            _ = frame.withUnsafeBytes {
                tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
            }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            XCTAssertEqual(tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline), -1)
            if let pointer { tractanda_private_free(pointer, count) }
        }.value
        XCTAssertEqual(
            begins.withLock { $0 }, 1,
            "Closed transport must not release a slot while authorization remains unresolved.")
        let closingStarted = expectation(description: "listener close started")
        let closed = Mutex(false)
        let closing = Task {
            closingStarted.fulfill()
            try await listener.close()
            closed.withLock { $0 = true }
        }
        await fulfillment(of: [closingStarted], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed.withLock { $0 })
        await beginGate.release()
        await fulfillment(of: [cancelEntered], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed.withLock { $0 }, "Late session cancellation is owned, not detached.")
        let duplicateStarted = expectation(description: "duplicate close started")
        let duplicateClosed = Mutex(false)
        let duplicate = Task {
            duplicateStarted.fulfill()
            try await listener.close()
            duplicateClosed.withLock { $0 = true }
        }
        await fulfillment(of: [duplicateStarted], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(duplicateClosed.withLock { $0 })
        await cancelGate.release()
        try await closing.value
        try await duplicate.value
        XCTAssertTrue(closed.withLock { $0 })
        XCTAssertTrue(duplicateClosed.withLock { $0 })

        let commitEntered = expectation(description: "commit held")
        let commitCancelled = expectation(description: "commit cancellation observed")
        let commitGate = NativeCredentialGate(commitEntered)
        defer { await commitGate.release() }
        let commitBegins = Mutex(0)
        let secondListener = try await DaemonListeners.unixWithPrivateCredential(
            group: group, socketPath: path,
            permissions: 0o600, managed: false, connectionLimitForTesting: 1,
            handler: { _, _ in Data() },
            privateBegin: { _, _, _ in
                commitBegins.withLock { $0 += 1 }
                return .init(
                    byteCount: 36,
                    commit: { _ in
                        await commitGate.wait()
                        return try JSON.encode(NativePeerCredentialRegistration.Result(registered: true))
                    }, cancel: { commitCancelled.fulfill() })
            })
        defer {
            await commitGate.release()
            try? await secondListener.close()
        }
        let secondFD = tractanda_connect(path)
        XCTAssertGreaterThanOrEqual(secondFD, 0)
        let second = FileHandle(fileDescriptor: secondFD, closeOnDealloc: true)
        defer { try? second.close() }
        try await Task.detached {
            let deadline = tractanda_private_io_begin(secondFD)
            XCTAssertEqual(
                frame.withUnsafeBytes {
                    tractanda_private_send_begin(secondFD, $0.baseAddress, UInt32($0.count), deadline)
                }, 0)
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            XCTAssertEqual(tractanda_private_receive_frame(secondFD, &pointer, &count, 4096, deadline), 0)
            if let pointer { tractanda_private_free(pointer, count) }
            let payload = Data(repeating: 0, count: 36)
            XCTAssertEqual(
                payload.withUnsafeBytes {
                    tractanda_private_send_frame(secondFD, $0.baseAddress, UInt32($0.count), deadline)
                }, 0)
        }.value
        await fulfillment(of: [commitEntered], timeout: 5)
        await secondListener.closeChildrenForTesting()
        await fulfillment(of: [commitCancelled], timeout: 5)
        try await Task.detached {
            let fd = tractanda_connect(path)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { tractanda_close(fd) }
            let deadline = tractanda_private_io_begin(fd)
            _ = frame.withUnsafeBytes {
                tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
            }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            XCTAssertEqual(tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline), -1)
            if let pointer { tractanda_private_free(pointer, count) }
        }.value
        XCTAssertEqual(commitBegins.withLock { $0 }, 1)
        let closingCommitStarted = expectation(description: "commit listener close started")
        let commitClosed = Mutex(false)
        let closingCommit = Task {
            closingCommitStarted.fulfill()
            try await secondListener.close()
            commitClosed.withLock { $0 = true }
        }
        await fulfillment(of: [closingCommitStarted], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(commitClosed.withLock { $0 })
        await commitGate.release()
        try await closingCommit.value
        XCTAssertTrue(commitClosed.withLock { $0 })
    }
}
