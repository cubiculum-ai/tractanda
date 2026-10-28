import CTractandaPlatform
import Foundation
import NIOCore
import NIOPosix
import TractandaClient
import XCTest

@testable import TractandaCore
@testable import TractandaServer

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Private two-daemon API fixture. This does not exercise the CLI or a real installation.
final class PersonalEnrollmentDaemonTests: XCTestCase, @unchecked Sendable {
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let source: Bool
        init(source: Bool) { self.source = source }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() { return try user(named: source ? "alice" : "bob") }
            if source && uid == 55001 { return try user(named: "bob") }
            if !source && uid == 54001 { return try user(named: "alice") }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture UID.")
        }
        func user(named name: String) throws -> AccountIdentity {
            let staff: UInt32 = source ? 72001 : 82001
            let admins: UInt32 = source ? 72002 : 82002
            if name == "alice" {
                return .init(
                    uid: source ? tractanda_uid() : 54001, name: name,
                    primaryGroupName: "staff", groupIDs: source ? [staff, admins] : [staff])
            }
            if name == "bob" {
                return .init(
                    uid: source ? 55001 : tractanda_uid(), name: name,
                    primaryGroupName: "staff", groupIDs: source ? [staff] : [staff, admins])
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
        }
        func groupID(named name: String) throws -> UInt32 {
            if name == "staff" { return source ? 72001 : 82001 }
            if name == "admins" { return source ? 72002 : 82002 }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
        }
    }
    /// Same cluster names with different numeric mappings and one local admin per host.
    private final class MeshAccounts: AccountDirectory, @unchecked Sendable {
        let localName: String
        let node: UInt32
        init(_ localName: String, node: UInt32) {
            self.localName = localName
            self.node = node
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() { return try user(named: localName) }
            for (index, name) in ["alice", "bob", "carol"].enumerated() {
                if name != localName, uid == 60000 + node * 100 + UInt32(index) {
                    return try user(named: name)
                }
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture UID.")
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let index = ["alice", "bob", "carol"].firstIndex(of: name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
            let staff = 70000 + node * 100
            let admins = staff + 1
            return .init(
                uid: name == localName ? tractanda_uid() : 60000 + node * 100 + UInt32(index),
                name: name, primaryGroupName: "staff",
                groupIDs: name == localName ? [staff, admins] : [staff])
        }
        func groupID(named name: String) throws -> UInt32 {
            if name == "staff" { return 70000 + node * 100 }
            if name == "admins" { return 70001 + node * 100 }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
        }
    }
    /// The same kernel UID can resolve to a different canonical login after READY.
    private final class RemappingAccounts: AccountDirectory, @unchecked Sendable {
        private let lock = NSLock()
        private var current = "alice"
        func switchToBob() {
            lock.lock()
            current = "bob"
            lock.unlock()
        }
        private func name() -> String {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() else {
                throw TractandaError("unresolvedPrincipal", "Fixture UID missing.")
            }
            return .init(uid: uid, name: name(), primaryGroupName: "staff", groupIDs: [91001, 91002])
        }
        func user(named value: String) throws -> AccountIdentity {
            guard value == "alice" || value == "bob" else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing.")
            }
            let uid = value == name() ? tractanda_uid() : tractanda_uid() + 10000
            return .init(uid: uid, name: value, primaryGroupName: "staff", groupIDs: [91001, 91002])
        }
        func groupID(named value: String) throws -> UInt32 {
            if value == "staff" { return 91001 }
            if value == "admins" { return 91002 }
            throw TractandaError("unresolvedPrincipal", "Fixture group missing.")
        }
    }
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var complete = false
        func mark() {
            lock.lock()
            complete = true
            lock.unlock()
        }
        func value() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return complete
        }
    }
    private struct PrivateSession: Sendable {
        let fd: Int32
        let deadline: UInt64
    }

    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func checkCapacity(_ root: URL) throws {
        try PeerFixtureCapacity.requireFree(at: root)
        let iterator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bytes: UInt64 = 0
        for case let file as URL in iterator {
            let metadata: FileMetadata
            do { metadata = try FileMetadata.read(at: file) } catch FileMetadataError.posix(let code)
                where code == ENOENT
            { continue }
            if metadata.type == .regular {
                guard metadata.size <= PeerFixtureCapacity.fixtureCapBytes - bytes else {
                    throw TractandaError("resourceLimit", "Private daemon fixture exceeded 128MiB.")
                }
                bytes += metadata.size
            }
        }
    }
    private func freePort() async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(channel.localAddress?.port)
        try await channel.close().get()
        return port
    }
    private func request(_ method: String, arguments: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "using": [NativePersonalEnrollment.capability],
                "methodCalls": [["TractandaEnrollmentLocal/" + method, arguments, "fixture"]],
            ], options: [.sortedKeys])
    }
    private func privateCall(_ socket: String, _ method: String, _ arguments: [String: Any] = [:])
        async throws -> [String: Any]
    {
        let data = try request(method, arguments: arguments)
        let response = try await Task.detached {
            try NativePersonalEnrollment.call(connection: .init(socketPath: socket), request: data)
        }.value
        let body = try NativeMethodResult.unwrap(
            response, method: "TractandaEnrollmentLocal/" + method, callID: "fixture")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    private func status(_ socket: String) async throws -> PeerOperatorStatus {
        let bytes = try await Task.detached {
            try ItemClient(socketPath: socket).call(PeerOperatorStatus.nativeMethod)
        }.value
        return try JSON.decode(PeerOperatorStatus.self, bytes)
    }
    private func wait(_ description: String, root: URL, _ test: () async throws -> Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 180 {
            try checkCapacity(root)
            if try await test() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TractandaError("fixtureWait", description)
    }
    private func waitThree(
        _ description: String, root: URL, deadline: TimeInterval, observe: () async -> Void,
        condition: () async throws -> Bool
    ) async throws {
        var observedAt: TimeInterval = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCapacity(root)
            if try await condition() { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - observedAt >= 1 {
                observedAt = now
                await observe()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TractandaError("fixtureWait", description)
    }
    /// Test-only, explicitly allowlisted diagnostics. Never serialize private request/response bodies.
    private func enrollmentDiagnostic(
        sourceSocket: String, targetSocket: String,
        sourceSummary: [String: Any]? = nil, targetSummary: [String: Any]? = nil
    ) async -> Data? {
        func safeCode(_ value: Any?) -> String? {
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
                text.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { return nil }
            return text
        }
        func safeUUID(_ value: Any?) -> String? {
            guard let text = value as? String, let uuid = UUID(uuidString: text),
                uuid.version1Components != nil, uuid.uuidString.lowercased() == text
            else { return nil }
            return text
        }
        func safeDigest(_ value: String?) -> String? {
            guard let value, value.utf8.count == 64,
                value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return nil }
            return value
        }
        func publicJob(_ value: [String: Any]?) -> [String: Any] {
            guard let value else { return ["status": "unavailable"] }
            var result: [String: Any] = [:]
            if let phase = safeCode(value["phase"]) { result["phase"] = phase }
            if let code = safeCode(value["lastErrorCode"]) { result["lastErrorCode"] = code }
            if let pending = value["baselinePending"] as? Bool { result["baselinePending"] = pending }
            for key in ["stagedMembers", "committedMembers"] {
                if let members = value[key] as? [String], members.count <= 16,
                    members.allSatisfy({ safeUUID($0) != nil })
                {
                    result[key] = members
                }
            }
            return result
        }
        func publicPeer(_ value: PeerOperatorStatus?) -> [String: Any] {
            guard let value else { return ["status": "unavailable"] }
            var result: [String: Any] = ["readiness": value.canonical.readiness.rawValue]
            if let digest = safeDigest(value.canonical.personal?.currentMembershipDigest) {
                result["currentDigest"] = digest
            }
            if let digest = safeDigest(value.canonical.personal?.pendingMembershipDigest) {
                result["pendingDigest"] = digest
            }
            if let source = safeUUID(value.canonical.personal?.baselineSourceReplicaID) {
                result["baselineSource"] = source
            }
            var observations: [[String: Any]] = []
            for peer in (value.runtime.personalPeers ?? []).prefix(16) {
                guard let replica = safeUUID(peer.replicaID) else { continue }
                var item: [String: Any] = [
                    "replicaID": replica, "connected": peer.connected,
                    "pullRunning": peer.pullRunning, "completedCuts": peer.completedCuts,
                ]
                if let control = peer.controlOnly { item["controlOnly"] = control }
                if let outcome = peer.lastOutcome?.rawValue { item["lastOutcome"] = outcome }
                if let code = safeCode(peer.lastErrorCode) { item["lastErrorCode"] = code }
                if let progress = peer.currentPull {
                    item["progress"] = [
                        "phase": progress.phase.rawValue,
                        "revisions": progress.revisionCount, "bytes": progress.transferredBytes,
                    ]
                }
                observations.append(item)
            }
            result["observations"] = observations
            return result
        }
        func peerStatus(_ socket: String) async -> PeerOperatorStatus? {
            try? await Task.detached {
                let client = ItemClient(transport: { request in
                    try ServerConnection(socketPath: socket).send(request, responseWait: .bounded)
                })
                return try JSON.decode(PeerOperatorStatus.self, client.call(PeerOperatorStatus.nativeMethod))
            }.value
        }
        let sourceJob: [String: Any]?
        if let sourceSummary {
            sourceJob = sourceSummary
        } else {
            sourceJob = try? await privateCall(sourceSocket, "status")
        }
        let targetJob: [String: Any]?
        if let targetSummary {
            targetJob = targetSummary
        } else {
            targetJob = try? await privateCall(targetSocket, "status")
        }
        let sourcePeer = await peerStatus(sourceSocket)
        let targetPeer = await peerStatus(targetSocket)
        let object: [String: Any] = [
            "source": ["job": publicJob(sourceJob), "peer": publicPeer(sourcePeer)],
            "target": ["job": publicJob(targetJob), "peer": publicPeer(targetPeer)],
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            bytes.count <= 32 * 1024 - 64
        else { return nil }
        return bytes
    }
    private func emitEnrollmentDiagnostic(_ bytes: Data, event: String) {
        guard ["progress", "failure"].contains(event), bytes.count <= 32 * 1024 - 64,
            var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        else { return }
        object["event"] = event
        guard let output = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            output.count <= 32 * 1024 - 1
        else { return }
        FileHandle.standardError.write(output + Data([10]))
    }

    private func validatePrivateFrameLimits(socket: String, root: URL) async throws {
        var exact = try request("status", arguments: [:])
        XCTAssertLessThan(exact.count, NativePersonalEnrollment.maximumInput)
        exact.append(Data(repeating: 32, count: NativePersonalEnrollment.maximumInput - exact.count))
        let exactInput = exact
        let response = try await Task.detached {
            try NativePersonalEnrollment.call(connection: .init(socketPath: socket), request: exactInput)
        }.value
        _ = try NativeMethodResult.unwrap(
            response, method: "TractandaEnrollmentLocal/status", callID: "fixture")
        let trapPath = root.appendingPathComponent("trap.sock").path
        let listener = tractanda_listen(trapPath)
        XCTAssertGreaterThanOrEqual(listener, 0)
        guard listener >= 0 else {
            throw TractandaError("fixtureSocket", "Cannot create private socket trap.")
        }
        defer {
            _ = close(listener)
            _ = unlink(trapPath)
        }
        let flags = fcntl(listener, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(listener, F_SETFL, flags | O_NONBLOCK), 0)
        let oversized = exactInput + Data([32])
        let failure = await Task.detached { () -> String in
            do {
                _ = try NativePersonalEnrollment.call(
                    connection: .init(socketPath: trapPath), request: oversized)
                return "unexpectedSuccess"
            } catch { return (error as? TractandaError)?.code ?? "unexpectedError" }
        }.value
        XCTAssertEqual(failure, "privateEnrollmentUnavailable")
        errno = 0
        let accepted = accept(listener, nil, nil)
        let acceptError = errno
        if accepted >= 0 { _ = close(accepted) }
        XCTAssertEqual(accepted, -1, "Oversized request must be rejected before connecting.")
        XCTAssertTrue(acceptError == EAGAIN || acceptError == EWOULDBLOCK)
    }

    private func beginPrivateSession(_ socket: String, byteCount: Int) async throws -> PrivateSession {
        let header = try NativePersonalEnrollment.Begin(byteCount: byteCount).encoded()
        return try await Task.detached {
            let fd = tractanda_connect(socket)
            guard fd >= 0 else { throw TractandaError("fixtureSocket", "Private session connect failed.") }
            var keep = false
            defer { if !keep { tractanda_close(fd) } }
            var peer: UInt32 = .max
            guard tractanda_peer_uid(fd, &peer) == 0, peer == tractanda_uid() else {
                throw TractandaError("fixturePeer", "Unexpected private session peer UID.")
            }
            let deadline = tractanda_private_io_begin(fd)
            guard deadline != 0,
                header.withUnsafeBytes({
                    tractanda_private_send_begin(fd, $0.baseAddress, UInt32($0.count), deadline)
                }) == 0
            else { throw TractandaError("fixtureSocket", "Private begin frame failed.") }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            guard tractanda_private_receive_frame(fd, &pointer, &count, 4096, deadline) == 0,
                let pointer
            else { throw TractandaError("fixtureSocket", "Private ready frame missing.") }
            defer { tractanda_private_free(pointer, count) }
            guard Data(bytes: pointer, count: Int(count)) == NativePersonalEnrollment.ready else {
                throw TractandaError("fixtureSocket", "Private session did not return READY.")
            }
            keep = true
            return PrivateSession(fd: fd, deadline: deadline)
        }.value
    }
    private func sendPrivateBody(_ session: PrivateSession, body: Data) async throws -> Data {
        try await Task.detached {
            guard
                body.withUnsafeBytes({
                    tractanda_private_send_frame(
                        session.fd, $0.baseAddress, UInt32($0.count), session.deadline)
                }) == 0
            else { throw TractandaError("fixtureSocket", "Private request frame failed.") }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            guard
                tractanda_private_receive_frame(
                    session.fd, &pointer, &count,
                    UInt32(NativePersonalEnrollment.maximumReply), session.deadline) == 0,
                let pointer
            else { throw TractandaError("fixtureSocket", "Private response frame missing.") }
            defer { tractanda_private_free(pointer, count) }
            return Data(bytes: pointer, count: Int(count))
        }.value
    }
    private func pinFixture(_ root: URL, accounts: RemappingAccounts) async throws -> (
        SharedDaemon, String, URL
    ) {
        let storeRoot = root.appendingPathComponent("source")
        let socket = root.appendingPathComponent("s.sock").path
        let policy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("alice"), .text("bob")]),
            "administration": .text("system"), "administratorGroup": .text("admins"),
        ])
        do {
            _ = try ItemStore.initializePersonalWorkgroup(
                root: storeRoot, accounts: accounts, accessConfiguration: policy)
        }
        let port = try await freePort()
        let runtime = root.appendingPathComponent("peer-runtime.json")
        let settings = try PersonalPeerRuntimeConfiguration(
            settings: PeerRuntimeConfiguration(
                listen: .init(host: "127.0.0.1", port: port), peers: [],
                synchronization: .init(enabled: true, intervalSeconds: 15)))
        try PrivateConfiguration.write(settings.encoded(), to: runtime)
        let config = DaemonConfiguration(
            storePath: storeRoot.path, socketPath: socket, httpPort: nil,
            attachmentUploadPolicy: .init(
                maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
            peerRuntimeConfigurationPath: runtime.path)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: config, makeAccountDirectory: { accounts })
        return (daemon, socket, storeRoot)
    }

    func testPrivateSessionPinsCanonicalNameAcrossReadyAndBody() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "pin-", source: "PersonalEnrollmentDaemonTests", test: name, socket: "s.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = RemappingAccounts()
        let (daemon, socket, storeRoot) = try await pinFixture(root, accounts: accounts)
        do {
            let alice = try accounts.user(forUID: tractanda_uid())
            XCTAssertEqual(alice.name, "alice")
            XCTAssertTrue(alice.groupIDs.contains(try accounts.groupID(named: "admins")))
            let body = try request("invite", arguments: ["hostname": "localhost"])
            let session = try await beginPrivateSession(socket, byteCount: body.count)
            defer { tractanda_close(session.fd) }
            accounts.switchToBob()
            let bob = try accounts.user(forUID: tractanda_uid())
            XCTAssertEqual(bob.name, "bob")
            XCTAssertEqual(alice.uid, bob.uid)
            XCTAssertTrue(bob.groupIDs.contains(try accounts.groupID(named: "admins")))
            let response = try await sendPrivateBody(session, body: body)
            let failure = try JSON.decode(TractandaError.self, response)
            XCTAssertEqual(failure.code, "forbidden")
            let state = try await privateCall(socket, "status")
            XCTAssertNil(state["operationID"] as? String)
            let observed = try await status(socket)
            XCTAssertNil(observed.canonical.personal?.currentMembership)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: storeRoot.appendingPathComponent(".personal-enrollment/current.bin").path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: storeRoot.appendingPathComponent(".personal-enrollment/job.bin").path))
            try checkCapacity(root)
            await daemon.close()
        } catch {
            await daemon.close()
            throw error
        }
    }

    func testDaemonCloseCancelsPrivateSessionWaitingForBody() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "cls-", source: "PersonalEnrollmentDaemonTests", test: name, socket: "s.sock")
        var safeToClean = true
        defer { if safeToClean { try? FileManager.default.removeItem(at: root) } }
        let accounts = RemappingAccounts()
        let (daemon, socket, storeRoot) = try await pinFixture(root, accounts: accounts)
        let body = try request("invite", arguments: ["hostname": "localhost"])
        let session: PrivateSession
        do { session = try await beginPrivateSession(socket, byteCount: body.count) } catch {
            await daemon.close()
            throw error
        }
        let finished = CompletionFlag()
        let start = ProcessInfo.processInfo.systemUptime
        let closeTask = Task {
            await daemon.close()
            finished.mark()
        }
        while !finished.value() && ProcessInfo.processInfo.systemUptime - start < 5 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let closedBeforeClient = finished.value()
        if closedBeforeClient {
            var descriptor = pollfd(fd: session.fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let observed = poll(&descriptor, 1, 0)
            XCTAssertEqual(observed, 1, "Daemon close must terminate the accepted private socket.")
            var byte: UInt8 = 0
            XCTAssertEqual(recv(session.fd, &byte, 1, Int32(MSG_DONTWAIT)), 0)
        }
        // Release the held client even on failure, so the fixture never waits for the product deadline.
        _ = shutdown(session.fd, Int32(SHUT_RDWR))
        tractanda_close(session.fd)
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !finished.value() && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(
            closedBeforeClient, "Daemon close must not wait for the withheld body or 20-second deadline.")
        guard finished.value() else {
            safeToClean = false
            XCTFail(
                "Daemon did not close after the fixture released its client; private fixture retained for inspection."
            )
            return
        }
        await closeTask.value
        let reopened = try ItemStore.openInitialized(root: storeRoot, accounts: accounts)
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(
            store: reopened, forUID: tractanda_uid())
        let issuer = try PersonalEnrollmentRegistry(root: storeRoot, ownerUID: tractanda_uid()).status(
            authorization: authorization)
        XCTAssertNil(issuer)
        XCTAssertNil(try reopened.personalSyncIdentity().membership)
        try checkCapacity(root)
    }

    func testUnavailableIssuerProbeRetainsInvitationAndClaimingPhase() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "prb-", source: "PersonalEnrollmentDaemonTests",
            test: name, socket: "t.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts(source: false)
        let targetRoot = root.appendingPathComponent("target")
        let socket = root.appendingPathComponent("t.sock").path
        let policy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("bob")]),
            "administration": .text("system"), "administratorGroup": .text("admins"),
        ])
        let storeID = try id()
        do {
            let target = try ItemStore.createJoiningPersonalSyncReplica(
                root: targetRoot, storeID: storeID,
                accessConfiguration: policy, accounts: accounts)
            XCTAssertTrue(target.isPersonalBaselinePending)
        }
        // Reserve and release a loopback port without starting an issuer daemon.
        let unavailablePort = try await freePort()
        let metadata = try PersonalEnrollmentInvitationMetadata(
            operationID: id(), storeID: storeID,
            issuerReplicaID: id(), bootstrapReplicaID: id(), pairingID: id(),
            endpoints: [.init(host: "localhost", port: unavailablePort)],
            expiresAt: Int64(Date().timeIntervalSince1970) + 600, expectedMembershipDigest: nil)
        let secret = try PersonalEnrollmentSecret.generate()
        let invitation = try PersonalEnrollmentInvitation(metadata: metadata, secret: secret)
        let runtimeFile = root.appendingPathComponent("target-runtime.json")
        let runtime = try PersonalPeerRuntimeConfiguration(
            settings: PeerRuntimeConfiguration(
                peers: [], synchronization: .init(enabled: true, intervalSeconds: 15)))
        try PrivateConfiguration.write(runtime.encoded(), to: runtimeFile)
        let configuration = DaemonConfiguration(
            storePath: targetRoot.path, socketPath: socket, httpPort: nil,
            attachmentUploadPolicy: .init(
                maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
            peerRuntimeConfigurationPath: runtimeFile.path)
        let daemon = try await SharedDaemon.startForTesting(
            configuration: configuration, makeAccountDirectory: { accounts })
        do {
            let joined = try await privateCall(
                socket, "join", ["code": invitation.privateCode(), "hostname": "target.fixture"])
            XCTAssertEqual(joined["operationID"] as? String, metadata.operationID)
            try await wait("Unavailable issuer probe did not report a bounded error.", root: root) {
                let job = try await self.privateCall(socket, "status", ["operationID": metadata.operationID])
                return job["lastErrorCode"] as? String != nil
            }
            let state = try await privateCall(socket, "status", ["operationID": metadata.operationID])
            XCTAssertEqual(state["phase"] as? String, "claiming")
            XCTAssertEqual(state["baselinePending"] as? Bool, true)
            let protected = try XCTUnwrap(PersonalEnrollmentStateFiles(root: targetRoot).read("target.bin"))
            guard protected.count >= 4 else {
                throw TractandaError("fixtureState", "Target state header missing.")
            }
            let length = protected.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(length) <= protected.count - 4 else {
                throw TractandaError("fixtureState", "Target state header is invalid.")
            }
            let secretCount = protected.count - 4 - Int(length)
            XCTAssertEqual(
                secretCount, 64, "Unaccepted invitation and continuation must both remain persisted.")
            guard secretCount == 64 else {
                throw TractandaError("fixtureState", "Target state secret length changed.")
            }
            let invitationBytes = Data(protected.suffix(64).prefix(32))
            XCTAssertTrue(
                secret.withBytes { Data($0) } == invitationBytes,
                "The exact invitation credential must survive an unsuccessful continuation probe.")
            try checkCapacity(root)
            await daemon.close()
        } catch {
            await daemon.close()
            throw error
        }
    }

    func testTwoNodesPairOverSingleOutboundConnectionAndReplicateHistoryAndPayload() async throws {
        XCTAssertNotEqual(tractanda_uid(), 54001)
        XCTAssertNotEqual(tractanda_uid(), 55001)
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "ped-", source: "PersonalEnrollmentDaemonTests", test: name, socket: "trap.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source")
        let targetRoot = root.appendingPathComponent("target")
        let sourceSocket = root.appendingPathComponent("s.sock").path
        let targetSocket = root.appendingPathComponent("t.sock").path
        let sourceAccounts = Accounts(source: true)
        let targetAccounts = Accounts(source: false)
        let sourceAlice = try sourceAccounts.user(named: "alice")
        let targetAlice = try targetAccounts.user(named: "alice")
        let targetBob = try targetAccounts.user(named: "bob")
        XCTAssertEqual(sourceAlice.uid, tractanda_uid())
        XCTAssertEqual(targetBob.uid, tractanda_uid())
        XCTAssertNotEqual(sourceAlice.uid, targetAlice.uid)
        XCTAssertNotEqual(
            try sourceAccounts.groupID(named: "staff"), try targetAccounts.groupID(named: "staff"))
        XCTAssertTrue(sourceAlice.groupIDs.contains(try sourceAccounts.groupID(named: "admins")))
        XCTAssertFalse(targetAlice.groupIDs.contains(try targetAccounts.groupID(named: "admins")))
        XCTAssertTrue(targetBob.groupIDs.contains(try targetAccounts.groupID(named: "admins")))
        let sourcePolicy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("alice"), .text("bob")]),
            "groups": .list([.text("staff")]), "administration": .text("system"),
            "administratorGroup": .text("admins"),
        ])
        let targetPolicy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("bob")]),
            "administration": .text("system"), "administratorGroup": .text("admins"),
        ])
        let permissions: ItemValue = .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("alice"), "group": .text("staff"),
            "mode": .integer(0o660), "acl": .object([:]),
        ])
        let sourceIdentity: PersonalSyncIdentity
        let targetIdentity: PersonalSyncIdentity
        do {
            let source = try ItemStore.initializePersonalWorkgroup(
                root: sourceRoot, accounts: sourceAccounts, accessConfiguration: sourcePolicy)
            sourceIdentity = try source.personalSyncIdentity()
            let target = try ItemStore.createJoiningPersonalSyncReplica(
                root: targetRoot, storeID: sourceIdentity.storeID,
                accessConfiguration: targetPolicy, accounts: targetAccounts)
            targetIdentity = try target.personalSyncIdentity()
            XCTAssertTrue(target.isPersonalBaselinePending)
            XCTAssertNotEqual(sourceIdentity.replicaID, targetIdentity.replicaID)
        }
        let port = try await freePort()
        let sourceRuntime = root.appendingPathComponent("source-runtime.json")
        let targetRuntime = root.appendingPathComponent("target-runtime.json")
        let sourceSettings = try PersonalPeerRuntimeConfiguration(
            settings: PeerRuntimeConfiguration(
                listen: .init(host: "127.0.0.1", port: port), peers: [],
                synchronization: .init(enabled: true, intervalSeconds: 15)))
        let targetSettings = try PersonalPeerRuntimeConfiguration(
            settings: PeerRuntimeConfiguration(
                peers: [], synchronization: .init(enabled: true, intervalSeconds: 15)))
        try PrivateConfiguration.write(sourceSettings.encoded(), to: sourceRuntime)
        try PrivateConfiguration.write(targetSettings.encoded(), to: targetRuntime)
        let policy = AttachmentUploadPolicy(
            maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        let sourceConfig = DaemonConfiguration(
            storePath: sourceRoot.path, socketPath: sourceSocket, httpPort: nil,
            attachmentUploadPolicy: policy, peerRuntimeConfigurationPath: sourceRuntime.path)
        let targetConfig = DaemonConfiguration(
            storePath: targetRoot.path, socketPath: targetSocket, httpPort: nil,
            attachmentUploadPolicy: policy, peerRuntimeConfigurationPath: targetRuntime.path)
        var source: SharedDaemon? = try await .startForTesting(
            configuration: sourceConfig, makeAccountDirectory: { sourceAccounts })
        var target: SharedDaemon?
        do {
            target = try await .startForTesting(
                configuration: targetConfig, makeAccountDirectory: { targetAccounts })
            let targetEndpoints = await target!.endpoints()
            let sourceEndpoints = await source!.endpoints()
            XCTAssertNil(targetEndpoints.peerPort)
            XCTAssertEqual(sourceEndpoints.peerPort, port)
            let initially = try await status(targetSocket)
            XCTAssertEqual(initially.canonical.readiness, .pendingActivation)
            try await validatePrivateFrameLimits(socket: sourceSocket, root: root)
            let seed = try await Task.detached {
                try ItemClient(socketPath: sourceSocket).commitFixture(
                    .init(
                        classID: "Item",
                        changes: [
                            "subject": .text("enrollment-fixture"), "body": .text("first"),
                            "permissions": permissions,
                        ],
                        operationID: "enrollment-seed"))
            }.value
            let revised = try await Task.detached {
                try ItemClient(socketPath: sourceSocket).commitFixture(
                    .init(
                        action: .revise,
                        itemID: seed.revision.itemID, expectedRevisionID: seed.revision.revisionID,
                        changes: ["body": .text("second")], operationID: "enrollment-revise"))
            }.value
            let payload = Data(repeating: 0x6a, count: 4096)
            let original = root.appendingPathComponent("owned.bin")
            try PrivateConfiguration.write(payload, to: original)
            let attached = try await Task.detached {
                try AttachmentFiles.attach(
                    client: ItemClient(socketPath: sourceSocket), source: original,
                    itemID: seed.revision.itemID, expectedRevisionID: revised.revision.revisionID,
                    operationID: "enrollment-attach", mediaType: "application/octet-stream")
            }.value
            let inviteRequest = try request("invite", arguments: ["hostname": "localhost"])
            let ordinary = try await Task.detached {
                try ServerConnection(socketPath: sourceSocket).send(inviteRequest)
            }.value
            XCTAssertThrowsError(
                try NativeMethodResult.unwrap(
                    ordinary, method: "TractandaEnrollmentLocal/invite", callID: "fixture")
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "unknownCapability")
            }
            let before = try await privateCall(sourceSocket, "status")
            XCTAssertNil(before["operationID"] as? String)
            let issued = try await privateCall(sourceSocket, "invite", ["hostname": "localhost"])
            let code = try XCTUnwrap(issued["code"] as? String)
            let metadata = try PersonalEnrollmentInvitation.parsePrivateCode(code).metadata
            XCTAssertEqual(metadata.storeID, sourceIdentity.storeID)
            let redisplayed = try await privateCall(sourceSocket, "invite", ["resume": true])
            XCTAssertTrue(
                redisplayed["code"] as? String == code, "Redisplay must retain the exact unused invitation.")
            let joined = try await privateCall(
                targetSocket, "join", ["code": code, "hostname": "target.fixture"])
            XCTAssertEqual(joined["operationID"] as? String, metadata.operationID)
            XCTAssertEqual(joined["replicaID"] as? String, targetIdentity.replicaID)
            XCTAssertEqual(joined["baselinePending"] as? Bool, true)
            var lastDiagnostic: Data?
            var lastObservation: TimeInterval = 0
            // Reserve half the 32KiB log budget for the final failure snapshot.
            var progressDiagnosticBudget = 16 * 1024
            try await wait("Two-node enrollment did not reach completed baseline.", root: root) {
                let a = try await self.privateCall(
                    sourceSocket, "status", ["operationID": metadata.operationID])
                let b = try await self.privateCall(
                    targetSocket, "status", ["operationID": metadata.operationID])
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastObservation >= 1 {
                    lastObservation = now
                    if let diagnostic = await self.enrollmentDiagnostic(
                        sourceSocket: sourceSocket,
                        targetSocket: targetSocket, sourceSummary: a, targetSummary: b),
                        diagnostic != lastDiagnostic
                    {
                        if diagnostic.count + 64 <= progressDiagnosticBudget {
                            self.emitEnrollmentDiagnostic(diagnostic, event: "progress")
                            progressDiagnosticBudget -= diagnostic.count + 64
                        }
                        lastDiagnostic = diagnostic
                    }
                }
                return a["phase"] as? String == "complete" && b["phase"] as? String == "complete"
                    && b["baselinePending"] as? Bool == false
            }
            let sourceStatus = try await status(sourceSocket)
            let targetStatus = try await status(targetSocket)
            let sourceMembers = try XCTUnwrap(sourceStatus.canonical.personal?.currentMembership)
            let targetMembers = try XCTUnwrap(targetStatus.canonical.personal?.currentMembership)
            XCTAssertEqual(sourceMembers, targetMembers)
            XCTAssertEqual(
                Set(sourceMembers.members.map(\.replicaID)),
                Set([sourceIdentity.replicaID, targetIdentity.replicaID]))
            XCTAssertEqual(targetStatus.canonical.readiness, .ready)
            let sourceRuntimeHandle = await source!.personalPeerRuntimeForTesting()
            let targetRuntimeHandle = await target!.personalPeerRuntimeForTesting()
            let sourceNetwork = try XCTUnwrap(sourceRuntimeHandle)
            let targetNetwork = try XCTUnwrap(targetRuntimeHandle)
            try await wait("Outbound-only target must retain an authenticated duplex connection.", root: root)
            {
                let sourceConnected = await sourceNetwork.hasConnectionForTesting(
                    remoteReplicaID: targetIdentity.replicaID)
                let targetConnected = await targetNetwork.hasConnectionForTesting(
                    remoteReplicaID: sourceIdentity.replicaID)
                let sourceObservation = try await sourceNetwork.operatorStatus().personalPeers?.first {
                    $0.replicaID == targetIdentity.replicaID
                }
                let targetObservation = try await targetNetwork.operatorStatus().personalPeers?.first {
                    $0.replicaID == sourceIdentity.replicaID
                }
                return sourceConnected && targetConnected
                    && (sourceObservation?.incomingConnectionCount ?? 0) > 0
                    && (targetObservation?.outgoingConnectionCount ?? 0) > 0
            }
            let targetCurrent = try await Task.detached {
                try ItemClient(socketPath: targetSocket).revision(for: seed.revision.itemID)
            }.value
            XCTAssertEqual(targetCurrent.revisionID, attached.revisionID)
            let history = try await Task.detached {
                try ItemClient(socketPath: targetSocket).history(itemID: seed.revision.itemID)
            }.value
            XCTAssertTrue(
                Set(history.list.map(\.revisionID)).isSuperset(of: [
                    seed.revision.revisionID, revised.revision.revisionID, attached.revisionID,
                ]))
            let query = try await Task.detached {
                try ItemClient(socketPath: targetSocket).query(criteria: ["text": "enrollment-fixture"])
            }.value
            XCTAssertTrue(String(decoding: query, as: UTF8.self).contains(seed.revision.itemID))
            let received = try await Task.detached {
                let client = ItemClient(socketPath: targetSocket)
                let descriptor = try XCTUnwrap(
                    client.listAttachments(itemID: seed.revision.itemID).attachments.first)
                return try client.attachmentContent(
                    itemID: seed.revision.itemID, attachmentID: descriptor.attachmentID
                ).data
            }.value
            XCTAssertEqual(received, payload)
            let targetEdit = try await Task.detached {
                try ItemClient(socketPath: targetSocket).commitFixture(
                    .init(
                        action: .revise, itemID: seed.revision.itemID,
                        expectedRevisionID: attached.revisionID, changes: ["body": .text("target-write")],
                        operationID: "target-write"))
            }.value
            try await wait("Target-origin revision must reach source over duplex session.", root: root) {
                let current = try? await Task.detached {
                    try ItemClient(socketPath: sourceSocket).revision(for: seed.revision.itemID)
                }.value
                return current?.revisionID == targetEdit.revision.revisionID
            }
            try checkCapacity(root)
            await target!.close()
            target = nil
            await source!.close()
            source = nil
        } catch {
            let diagnostic =
                await enrollmentDiagnostic(sourceSocket: sourceSocket, targetSocket: targetSocket)
                ?? Data("{\"status\":\"diagnosticUnavailable\"}".utf8)
            if diagnostic.count <= 16 * 1024 - 64 {
                emitEnrollmentDiagnostic(diagnostic, event: "failure")
            } else {
                emitEnrollmentDiagnostic(Data("{\"status\":\"diagnosticTooLarge\"}".utf8), event: "failure")
            }
            await target?.close()
            await source?.close()
            throw error
        }
    }
    func testNonFounderAddsThirdNodeOnlyAfterRetainedMemberReturns() async throws {
        let fixtureDeadline = ProcessInfo.processInfo.systemUptime + 360
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "mesh-", source: "PersonalEnrollmentDaemonTests",
            test: name, socket: "c.sock")
        defer { try? FileManager.default.removeItem(at: root) }
        let aRoot = root.appendingPathComponent("a")
        let bRoot = root.appendingPathComponent("b")
        let cRoot = root.appendingPathComponent("c")
        let aSocket = root.appendingPathComponent("a.sock").path
        let bSocket = root.appendingPathComponent("b.sock").path
        let cSocket = root.appendingPathComponent("c.sock").path
        let aAccounts = MeshAccounts("alice", node: 1)
        let bAccounts = MeshAccounts("bob", node: 2)
        let cAccounts = MeshAccounts("carol", node: 3)
        guard !(60100...60302).contains(tractanda_uid()) else {
            throw TractandaError("fixtureIdentity", "Fixture UID collides with a synthetic account mapping.")
        }
        let aBob = try aAccounts.user(named: "bob")
        let cBob = try cAccounts.user(named: "bob")
        XCTAssertNotEqual(try aAccounts.groupID(named: "staff"), try bAccounts.groupID(named: "staff"))
        XCTAssertNotEqual(try bAccounts.groupID(named: "staff"), try cAccounts.groupID(named: "staff"))
        XCTAssertTrue(
            try aAccounts.user(forUID: tractanda_uid()).groupIDs.contains(aAccounts.groupID(named: "admins")))
        XCTAssertTrue(
            try cAccounts.user(forUID: tractanda_uid()).groupIDs.contains(cAccounts.groupID(named: "admins")))
        XCTAssertFalse(aBob.groupIDs.contains(try aAccounts.groupID(named: "admins")))
        XCTAssertFalse(cBob.groupIDs.contains(try cAccounts.groupID(named: "admins")))
        XCTAssertTrue(
            try bAccounts.user(forUID: tractanda_uid()).groupIDs.contains(bAccounts.groupID(named: "admins")))
        XCTAssertNotEqual(aBob.uid, cBob.uid)
        let commonPolicy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text("alice"), .text("bob"), .text("carol")]), "groups": .list([.text("staff")]),
            "administration": .text("system"), "administratorGroup": .text("admins"),
        ])
        func provisional(_ owner: String) -> ItemValue {
            .object([
                "profile": .text(AccessConfiguration.profile), "users": .list([.text(owner)]),
                "administration": .text("system"), "administratorGroup": .text("admins"),
            ])
        }
        func permission(_ owner: String) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
                "mode": .integer(0o660), "acl": .object([:]),
            ])
        }
        let alicePermissions = permission("alice")
        let bobPermissions = permission("bob")
        let aID: PersonalSyncIdentity
        let bID: PersonalSyncIdentity
        let cID: PersonalSyncIdentity
        do {
            let founder = try ItemStore.initializePersonalWorkgroup(
                root: aRoot, accounts: aAccounts, accessConfiguration: commonPolicy)
            aID = try founder.personalSyncIdentity()
            let second = try ItemStore.createJoiningPersonalSyncReplica(
                root: bRoot, storeID: aID.storeID,
                accessConfiguration: provisional("bob"), accounts: bAccounts)
            bID = try second.personalSyncIdentity()
            let third = try ItemStore.createJoiningPersonalSyncReplica(
                root: cRoot, storeID: aID.storeID,
                accessConfiguration: provisional("carol"), accounts: cAccounts)
            cID = try third.personalSyncIdentity()
            XCTAssertEqual(Set([aID.replicaID, bID.replicaID, cID.replicaID]).count, 3)
        }
        let aPort = try await freePort()
        var bPort = try await freePort()
        while bPort == aPort { bPort = try await freePort() }
        let aRuntime = root.appendingPathComponent("a-runtime.json")
        let bRuntime = root.appendingPathComponent("b-runtime.json")
        let cRuntime = root.appendingPathComponent("c-runtime.json")
        func runtime(port: Int?) throws -> Data {
            let endpoint = try port.map { try PeerRuntimeConfiguration.Endpoint(host: "127.0.0.1", port: $0) }
            return try PersonalPeerRuntimeConfiguration(
                settings: PeerRuntimeConfiguration(
                    listen: endpoint, peers: [],
                    synchronization: .init(enabled: true, intervalSeconds: 15))
            ).encoded()
        }
        try PrivateConfiguration.write(runtime(port: aPort), to: aRuntime)
        try PrivateConfiguration.write(runtime(port: bPort), to: bRuntime)
        try PrivateConfiguration.write(runtime(port: nil), to: cRuntime)
        let limits = AttachmentUploadPolicy(
            maximumStagedBytes: 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        let aConfig = DaemonConfiguration(
            storePath: aRoot.path, socketPath: aSocket, httpPort: nil,
            attachmentUploadPolicy: limits, peerRuntimeConfigurationPath: aRuntime.path)
        let bConfig = DaemonConfiguration(
            storePath: bRoot.path, socketPath: bSocket, httpPort: nil,
            attachmentUploadPolicy: limits, peerRuntimeConfigurationPath: bRuntime.path)
        let cConfig = DaemonConfiguration(
            storePath: cRoot.path, socketPath: cSocket, httpPort: nil,
            attachmentUploadPolicy: limits, peerRuntimeConfigurationPath: cRuntime.path)
        var a: SharedDaemon? = try await .startForTesting(
            configuration: aConfig, makeAccountDirectory: { aAccounts })
        var b: SharedDaemon?
        var c: SharedDaemon?
        var diagnosticBudget = 16 * 1024
        var lastDiagnostic: Data?
        func observe(_ source: String, _ target: String) async {
            if let data = await self.enrollmentDiagnostic(sourceSocket: source, targetSocket: target),
                data != lastDiagnostic
            {
                if data.count + 64 <= diagnosticBudget {
                    self.emitEnrollmentDiagnostic(data, event: "progress")
                    diagnosticBudget -= data.count + 64
                }
                lastDiagnostic = data
            }
        }
        do {
            b = try await .startForTesting(configuration: bConfig, makeAccountDirectory: { bAccounts })
            let first = try await Task.detached {
                try ItemClient(socketPath: aSocket).commitFixture(
                    .init(
                        classID: "Item",
                        changes: [
                            "subject": .text("mesh-foundation"), "body": .text("first"),
                            "permissions": alicePermissions,
                        ],
                        operationID: "mesh-a-create"))
            }.value
            let revised = try await Task.detached {
                try ItemClient(socketPath: aSocket).commitFixture(
                    .init(
                        action: .revise, itemID: first.revision.itemID,
                        expectedRevisionID: first.revision.revisionID, changes: ["body": .text("second")],
                        operationID: "mesh-a-revise"))
            }.value
            let payload = Data(repeating: 0x4d, count: 4096)
            let sourceFile = root.appendingPathComponent("owned.bin")
            try PrivateConfiguration.write(payload, to: sourceFile)
            let attached = try await Task.detached {
                try AttachmentFiles.attach(
                    client: ItemClient(socketPath: aSocket), source: sourceFile,
                    itemID: first.revision.itemID, expectedRevisionID: revised.revision.revisionID,
                    operationID: "mesh-a-attach", mediaType: "application/octet-stream")
            }.value
            let firstInvite = try await privateCall(aSocket, "invite", ["hostname": "localhost"])
            let firstCode = try XCTUnwrap(firstInvite["code"] as? String)
            let firstMetadata = try PersonalEnrollmentInvitation.parsePrivateCode(firstCode).metadata
            _ = try await privateCall(bSocket, "join", ["code": firstCode, "hostname": "b.fixture"])
            try await waitThree(
                "Initial A-B join did not finish.", root: root, deadline: fixtureDeadline,
                observe: { await observe(aSocket, bSocket) },
                condition: {
                    let source = try await self.privateCall(
                        aSocket, "status", ["operationID": firstMetadata.operationID])
                    let target = try await self.privateCall(
                        bSocket, "status", ["operationID": firstMetadata.operationID])
                    return source["phase"] as? String == "complete"
                        && target["phase"] as? String == "complete"
                        && target["baselinePending"] as? Bool == false
                })
            let aBefore = try await status(aSocket)
            let bBefore = try await status(bSocket)
            let previous = try XCTUnwrap(bBefore.canonical.personal?.currentMembership)
            XCTAssertEqual(aBefore.canonical.personal?.currentMembership, previous)
            XCTAssertEqual(Set(previous.members.map(\.replicaID)), Set([aID.replicaID, bID.replicaID]))
            let oldDigest = try previous.digest
            for path in [aRoot, bRoot] {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: path.appendingPathComponent(".personal-credentials-" + oldDigest + ".json")
                            .path))
            }
            let bobItem = try await Task.detached {
                try ItemClient(socketPath: bSocket).commitFixture(
                    .init(
                        classID: "Item",
                        changes: ["subject": .text("mesh-b-data"), "permissions": bobPermissions],
                        operationID: "mesh-b-create"))
            }.value
            try await waitThree(
                "B item did not reach A before its maintenance stop.", root: root, deadline: fixtureDeadline,
                observe: { await observe(aSocket, bSocket) },
                condition: {
                    let revision = try? await Task.detached {
                        try ItemClient(socketPath: aSocket).revision(for: bobItem.revision.itemID)
                    }.value
                    return revision?.revisionID == bobItem.revision.revisionID
                })
            let secondInvite = try await privateCall(bSocket, "invite", ["hostname": "localhost"])
            let secondCode = try XCTUnwrap(secondInvite["code"] as? String)
            let secondMetadata = try PersonalEnrollmentInvitation.parsePrivateCode(secondCode).metadata
            XCTAssertEqual(secondMetadata.issuerReplicaID, bID.replicaID)
            let bPolicyBefore = try XCTUnwrap(PersonalWorkgroupProfile.load(bRoot)).accessConfiguration
            let cPolicyBefore = try XCTUnwrap(PersonalWorkgroupProfile.load(cRoot)).accessConfiguration
            await a!.close()
            a = nil
            let bRuntimeHandle = await b!.personalPeerRuntimeForTesting()
            let bNetwork = try XCTUnwrap(bRuntimeHandle)
            try await waitThree(
                "A did not disconnect before the offline admission test.", root: root,
                deadline: fixtureDeadline,
                observe: { await observe(bSocket, cSocket) },
                condition: {
                    !(await bNetwork.hasConnectionForTesting(remoteReplicaID: aID.replicaID))
                })
            c = try await .startForTesting(configuration: cConfig, makeAccountDirectory: { cAccounts })
            let cEndpoints = await c!.endpoints()
            XCTAssertNil(cEndpoints.peerPort)
            let requested = try await privateCall(
                cSocket, "join", ["code": secondCode, "hostname": "c.fixture"])
            XCTAssertEqual(requested["operationID"] as? String, secondMetadata.operationID)
            try await waitThree(
                "Offline retained A did not block the three-node operation.", root: root,
                deadline: fixtureDeadline,
                observe: { await observe(bSocket, cSocket) },
                condition: {
                    let issuer = try await self.privateCall(
                        bSocket, "status", ["operationID": secondMetadata.operationID])
                    let target = try await self.privateCall(
                        cSocket, "status", ["operationID": secondMetadata.operationID])
                    return target["phase"] as? String == "claimed"
                        && issuer["lastErrorCode"] as? String != nil
                })
            let offlineJob = try await privateCall(
                bSocket, "status", ["operationID": secondMetadata.operationID])
            let reason = try XCTUnwrap(offlineJob["lastErrorCode"] as? String)
            XCTAssertTrue(
                ["membersOffline", "connectionFailed"].contains(reason),
                "Expected the retained-member connection failure.")
            XCTAssertEqual(offlineJob["operationID"] as? String, secondMetadata.operationID)
            XCTAssertTrue((offlineJob["stagedMembers"] as? [String] ?? []).isEmpty)
            XCTAssertTrue((offlineJob["committedMembers"] as? [String] ?? []).isEmpty)
            XCTAssertFalse(
                ["staging", "committing", "copyingBaseline", "complete"].contains(
                    offlineJob["phase"] as? String ?? ""))
            let offlineB = try await status(bSocket)
            let offlineC = try await status(cSocket)
            XCTAssertEqual(offlineB.canonical.personal?.currentMembership, previous)
            XCTAssertNil(offlineB.canonical.personal?.pendingMembership)
            XCTAssertNil(offlineC.canonical.personal?.currentMembership)
            XCTAssertNil(offlineC.canonical.personal?.pendingMembership)
            XCTAssertEqual(offlineC.canonical.readiness, .pendingActivation)
            XCTAssertEqual(
                try XCTUnwrap(PersonalWorkgroupProfile.load(bRoot)).accessConfiguration, bPolicyBefore)
            XCTAssertEqual(
                try XCTUnwrap(PersonalWorkgroupProfile.load(cRoot)).accessConfiguration, cPolicyBefore)
            let stillAvailable = try await Task.detached {
                try ItemClient(socketPath: bSocket).revision(for: bobItem.revision.itemID)
            }.value
            XCTAssertEqual(stillAvailable.revisionID, bobItem.revision.revisionID)
            a = try await .startForTesting(configuration: aConfig, makeAccountDirectory: { aAccounts })
            let restoredA = try await status(aSocket)
            XCTAssertEqual(restoredA.canonical.replicaID, aID.replicaID)
            XCTAssertEqual(restoredA.canonical.personal?.currentMembership, previous)
            let resumedB = try await privateCall(
                bSocket, "resume", ["operationID": secondMetadata.operationID])
            let resumedC = try await privateCall(
                cSocket, "resume", ["operationID": secondMetadata.operationID])
            XCTAssertEqual(resumedB["operationID"] as? String, secondMetadata.operationID)
            XCTAssertEqual(resumedC["operationID"] as? String, secondMetadata.operationID)
            XCTAssertEqual(resumedB["replicaID"] as? String, bID.replicaID)
            XCTAssertEqual(resumedC["replicaID"] as? String, cID.replicaID)
            try await waitThree(
                "Three-node enrollment did not complete after A returned.", root: root,
                deadline: fixtureDeadline,
                observe: { await observe(bSocket, cSocket) },
                condition: {
                    let issuer = try await self.privateCall(
                        bSocket, "status", ["operationID": secondMetadata.operationID])
                    let target = try await self.privateCall(
                        cSocket, "status", ["operationID": secondMetadata.operationID])
                    let founder = try await self.status(aSocket)
                    return issuer["phase"] as? String == "complete"
                        && target["phase"] as? String == "complete"
                        && target["baselinePending"] as? Bool == false
                        && founder.canonical.personal?.currentMembership?.members.count == 3
                })
            let aFinal = try await status(aSocket)
            let bFinal = try await status(bSocket)
            let cFinal = try await status(cSocket)
            let final = try XCTUnwrap(bFinal.canonical.personal?.currentMembership)
            XCTAssertEqual(aFinal.canonical.personal?.currentMembership, final)
            XCTAssertEqual(cFinal.canonical.personal?.currentMembership, final)
            XCTAssertEqual(
                Set(final.members.map(\.replicaID)), Set([aID.replicaID, bID.replicaID, cID.replicaID]))
            XCTAssertEqual(cFinal.canonical.readiness, .ready)
            let cHistory = try await Task.detached {
                try ItemClient(socketPath: cSocket).history(itemID: first.revision.itemID)
            }.value
            XCTAssertTrue(
                Set(cHistory.list.map(\.revisionID)).isSuperset(of: [
                    first.revision.revisionID, revised.revision.revisionID, attached.revisionID,
                ]))
            let cBob = try await Task.detached {
                try ItemClient(socketPath: cSocket).revision(for: bobItem.revision.itemID)
            }.value
            XCTAssertEqual(cBob.revisionID, bobItem.revision.revisionID)
            let received = try await Task.detached {
                let client = ItemClient(socketPath: cSocket)
                let descriptor = try XCTUnwrap(
                    client.listAttachments(itemID: first.revision.itemID).attachments.first)
                return try client.attachmentContent(
                    itemID: first.revision.itemID, attachmentID: descriptor.attachmentID
                ).data
            }.value
            XCTAssertEqual(received, payload)
            // The founder is not needed for established B-C synchronization.
            await a!.close()
            a = nil
            let carolEdit = try await Task.detached {
                try ItemClient(socketPath: cSocket).commitFixture(
                    .init(
                        action: .revise, itemID: first.revision.itemID,
                        expectedRevisionID: attached.revisionID,
                        changes: ["body": .text("carol-offline-founder")], operationID: "mesh-c-revise"))
            }.value
            try await waitThree(
                "C edit did not reach B while founder A was offline.", root: root, deadline: fixtureDeadline,
                observe: { await observe(bSocket, cSocket) },
                condition: {
                    let revision = try? await Task.detached {
                        try ItemClient(socketPath: bSocket).revision(for: first.revision.itemID)
                    }.value
                    return revision?.revisionID == carolEdit.revision.revisionID
                })
            await c!.close()
            c = nil
            await b!.close()
            b = nil
            for path in [aRoot, bRoot] {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: path.appendingPathComponent(".personal-credentials-" + oldDigest + ".json")
                            .path))
                let retired = try XCTUnwrap(PersonalEnrollmentMemberRegistry(root: path).state())
                XCTAssertEqual(retired.phase, .complete)
            }
            try checkCapacity(root)
        } catch {
            let diagnostic =
                await enrollmentDiagnostic(sourceSocket: bSocket, targetSocket: cSocket)
                ?? Data("{\"status\":\"diagnosticUnavailable\"}".utf8)
            if diagnostic.count <= 16 * 1024 - 64 {
                emitEnrollmentDiagnostic(diagnostic, event: "failure")
            } else {
                emitEnrollmentDiagnostic(Data("{\"status\":\"diagnosticTooLarge\"}".utf8), event: "failure")
            }
            await c?.close()
            await b?.close()
            await a?.close()
            throw error
        }
    }

}
