import CTractandaPlatform
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package enum PeerEnrollmentTargetCustody: Sendable { case current, existingUser(String) }

/// One finite enrollment workflow. Neither paths nor helper replies establish source authority.
package enum PeerEnrollmentSupervisor {
    static func failure(_ code: String = "enrollmentSupervisorFailed") -> TractandaError {
        .init(code, "Enrollment stopped. Reuse the exact accepted operation and private target material; no automatic repair was performed.")
    }
    final class Job {
        let deadline: UInt64
        let cancelled: () -> Bool
        static func now() throws -> UInt64 {
            var value = timespec()
            guard clock_gettime(CLOCK_MONOTONIC, &value) == 0, value.tv_sec >= 0, value.tv_nsec >= 0 else { throw failure() }
            return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
        }
        init(seconds: Double, cancelled: @escaping () -> Bool) throws {
            guard seconds.isFinite, seconds > 0, seconds <= 1800 else { throw failure() }
            deadline = try Self.now() + UInt64(seconds * 1_000_000_000); self.cancelled = cancelled
        }
        func check() throws {
            try Task.checkCancellation()
            guard !cancelled() else { throw failure("cancelled") }
            guard try Self.now() < deadline else { throw failure("deadlineExceeded") }
        }
        func sourceDeadline() throws -> UInt64 { try check(); return min(deadline, try Self.now() + 20_000_000_000) }
    }
    static func actualImage() throws -> URL {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard tractanda_current_executable(&bytes, UInt32(bytes.count)) == 0,
            let path = String(validatingUTF8: bytes), path.hasPrefix("/"), !path.hasSuffix(" (deleted)"),
            path.utf8.count <= 4095 else { throw failure("helperUnavailable") }
        return URL(fileURLWithPath: path)
    }
    static func sibling(image: URL) throws -> URL {
        guard image.path.hasPrefix("/"), image.standardizedFileURL.path == image.path else { throw failure("helperUnavailable") }
        let helper = image.deletingLastPathComponent().appendingPathComponent("tractanda-setup")
        guard tractanda_validate_enrollment_helper(helper.path, 0) == 0 else { throw failure("helperUnavailable") }
        return helper
    }
    static func sudoArguments(user: String, helper: URL, arguments: [String]) throws -> [String] {
        guard !user.isEmpty, user.utf8.count <= 128, !user.hasPrefix("-"),
            user.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) })
        else { throw failure("invalidTargetCustody") }
        return ["-n", "-u", user, "--", helper.path] + arguments
    }
    struct Launch {
        let executable: URL
        let arguments: [String]
        var indirectCustody = false
    }
    static func launch(root: String, pin: PeerTargetEnrollmentPin, custody: PeerEnrollmentTargetCustody,
                       helperForTesting: URL?) throws -> Launch {
        guard root.hasPrefix("/"), root.utf8.count <= 4096, !root.utf8.contains(0) else { throw failure() }
        let arguments = ["--activate-peer-target-stdio", root, pin.sourceReplicaID, pin.bootstrapID,
            pin.bootstrapSHA256, pin.approvalID, pin.approvalSHA256]
        var account: AccountIdentity?
        if case let .existingUser(name) = custody {
            _ = try sudoArguments(user: name, helper: URL(fileURLWithPath: "/unused/tractanda-setup"), arguments: [])
            account = try SystemAccountDirectory().user(named: name)
            guard account!.uid != 0 else { throw failure("invalidTargetCustody") }
        }
        if account == nil || account!.uid == tractanda_uid() {
            let helper: URL
            if let helperForTesting {
                guard tractanda_validate_enrollment_helper(helperForTesting.path, 0) == 0 else { throw failure("helperUnavailable") }
                helper = helperForTesting
            } else { helper = try sibling(image: actualImage()) }
            return .init(executable: helper, arguments: arguments)
        }
        #if os(macOS)
        // Only the protected managed installation may cross OS custody. No arbitrary executable option.
        let base = URL(fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda")
        let alias = base.appendingPathComponent("current")
        let link = try FileMetadata.read(at: alias)
        guard link.type == .symbolicLink, link.uid == 0 else { throw failure("helperUnavailable") }
        let helper = alias.appendingPathComponent("bin/tractanda-setup").resolvingSymlinksInPath()
        guard helper.path.hasPrefix(base.resolvingSymlinksInPath().appendingPathComponent("releases").path + "/"),
            tractanda_validate_enrollment_helper(helper.path, 1) == 0 else { throw failure("helperUnavailable") }
        let sudo = URL(fileURLWithPath: "/usr/bin/sudo"), metadata = try FileMetadata.read(at: sudo)
        guard metadata.type == .regular, metadata.uid == 0, metadata.mode & 0o022 == 0 else { throw failure("helperUnavailable") }
        return try .init(executable: sudo, arguments: sudoArguments(user: account!.name, helper: helper, arguments: arguments), indirectCustody: true)
        #else
        // Debian owns one protected real active directory. No retained-release alias, caller
        // executable option or source-relative helper is accepted across OS custody.
        let base = URL(fileURLWithPath: "/opt/tractanda/current")
        let active = try FileMetadata.read(at: base)
        guard active.type == .directory, active.uid == 0, active.mode & 0o022 == 0 else {
            throw failure("helperUnavailable")
        }
        let helper = base.appendingPathComponent("bin/tractanda-setup")
        guard helper.resolvingSymlinksInPath().path == helper.path,
            tractanda_validate_enrollment_helper(helper.path, 1) == 0 else { throw failure("helperUnavailable") }
        let metadata = try FileMetadata.read(at: helper)
        guard metadata.type == .regular, metadata.uid == 0, metadata.mode & 0o022 == 0 else {
            throw failure("helperUnavailable")
        }
        let sudo = URL(fileURLWithPath: "/usr/bin/sudo"), sudoMetadata = try FileMetadata.read(at: sudo)
        guard sudoMetadata.type == .regular, sudoMetadata.uid == 0, sudoMetadata.mode & 0o022 == 0 else {
            throw failure("helperUnavailable")
        }
        return try .init(executable: sudo, arguments: sudoArguments(user: account!.name, helper: helper, arguments: arguments), indirectCustody: true)
        #endif
    }
    struct Hooks: Sendable {
        var helper: URL? = nil
        var sshClient: URL? = nil // Internal controlled fixture executable, never a CLI option.
        var reply: (@Sendable (String, Data) throws -> Data)? = nil
        var didSendPrivateInput: (@Sendable () -> Void)? = nil
        var beforeRegister: (@Sendable () throws -> Void)? = nil
        var spawned: (@Sendable (Int32) -> Void)? = nil
        var reaped: (@Sendable (Int32, Int32) -> Void)? = nil
    }
    final class Child {
        private(set) var pid: Int32 = -1
        private var input: Int32 = -1, output: Int32 = -1, diagnostics: Int32 = -1
        private var diagnosticBytes = 0
        let job: Job
        var didReap: (@Sendable (Int32, Int32) -> Void)?
        var io: PeerTargetEnrollment.IO!
        init(_ launch: Launch, job: Job) throws {
            self.job = job
            guard launch.arguments.count <= 16, launch.arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else { throw failure() }
            let strings = ([launch.executable.path] + launch.arguments).map { strdup($0) }
            defer { strings.forEach { free($0) } }
            guard strings.allSatisfy({ $0 != nil }) else { throw failure() }
            let argv: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
            guard argv.withUnsafeBufferPointer({ tractanda_document_spawn(launch.executable.path, $0.baseAddress,
                &pid, &input, &output, &diagnostics) }) == 0 else { throw failure("helperUnavailable") }
            do {
                io = try PeerTargetEnrollment.IO(input: output, output: input,
                    control: .init(seconds: 1800, cancelled: { job.cancelled() }),
                    onWait: { [weak self] in try job.check(); try self?.drainDiagnostics() })
            } catch { cleanup(); throw error }
        }
        deinit { cleanup() }
        private func drainDiagnostics() throws {
            guard diagnostics >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            defer { bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            for _ in 0..<32 {
                let amount = read(diagnostics, &bytes, bytes.count)
                if amount < 0, errno == EINTR { continue }
                if amount < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                guard amount >= 0 else { throw failure() }
                if amount == 0 { tractanda_close(diagnostics); diagnostics = -1; return }
                diagnosticBytes += amount
                guard diagnosticBytes <= 65536 else { throw failure("helperDiagnosticsExceeded") }
            }
        }
        func closeInput() {
            guard input >= 0 else { return }
            io?.restoreBeforeClosing(input); tractanda_close(input); input = -1
        }
        func reapAfterClosed() throws {
            closeInput()
            while true {
                try job.check(); try drainDiagnostics()
                if let data = try availableOutput(), !data.isEmpty { throw failure("invalidHelperReply") }
                let exited = tractanda_document_exited(pid)
                if exited == 1 { break }
                guard exited == 0 || errno == EINTR else { throw failure() }
                var event = pollfd(fd: diagnostics, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 20)
            }
            try drainDiagnostics()
            if let data = try availableOutput(), !data.isEmpty { throw failure("invalidHelperReply") }
            let status = reap()
            guard status >= 0, status & 0x7f == 0, (status >> 8) & 255 == 0 else { throw failure("helperFailed") }
        }
        private func availableOutput() throws -> Data? {
            guard output >= 0 else { return nil }
            var byte: UInt8 = 0
            let count = read(output, &byte, 1)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            guard count >= 0 else { throw failure() }
            return count == 0 ? nil : Data([byte])
        }
        private func reap() -> Int32 {
            guard pid > 0 else { return -1 }
            // Keep the original PID waitable until owned-group cleanup; never signal after reap.
            _ = kill(-pid, SIGTERM)
            var status: Int32 = 0, result: Int32
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            let owned = pid; pid = -1
            if result > 0 { didReap?(owned, status) }
            return result > 0 ? status : -1
        }
        func cleanup() {
            closeInput()
            if pid > 0 {
                _ = kill(-pid, SIGTERM)
                let stop = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                while DispatchTime.now().uptimeNanoseconds < stop {
                    if tractanda_document_exited(pid) == 1 { break }
                    try? drainDiagnostics()
                    // Discard bounded stdout during abort; HUP/readable readiness must not spin the grace loop.
                    var scratch = [UInt8](repeating: 0, count: 4096)
                    for _ in 0..<16 {
                        let count = read(output, &scratch, scratch.count)
                        if count <= 0 { break }
                    }
                    scratch.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
                    _ = poll(nil, 0, 20)
                }
                _ = kill(-pid, SIGKILL)
                _ = reap() // Physical OS cleanup may outlast the semantic deadline; ownership is retained.
            }
            io = nil
            for fd in [input, output, diagnostics] where fd >= 0 { tractanda_close(fd) }
            input = -1; output = -1; diagnostics = -1
        }
    }
    static func encodedRequest(_ request: PeerTargetEnrollment.Request) throws -> Data {
        let bytes = try JSON.encode(request)
        _ = try PeerTargetEnrollment.Request.decode(bytes) // Same exact scalar schema as the helper.
        return bytes
    }
    static func checkedReply(_ data: Data, expected: String) throws -> PeerTargetEnrollment.Reply {
        if let reply = try? JSON.decode(PeerTargetEnrollment.Reply.self, data), reply.operation == "error" {
            let allowed: Set<String> = ["invalidTargetPin", "invalidTargetProtocol", "cancelled", "deadlineExceeded",
                "custodyUncertain", "storeBusy", "resourceLimit", "peerRepairRequired", "recoveryRequired", "missingDependencies",
                "peerPayloadVerifying", "enrollmentConflict", "invalidEnrollmentTarget", "enrollmentPending"]
            guard let code = reply.code, allowed.contains(code) else { throw failure("invalidHelperReply") }
            var exact = PeerTargetEnrollment.Reply("error"); exact.code = code
            guard data == (try JSON.encode(exact)) else { throw failure("invalidHelperReply") }
            throw failure(code)
        }
        do {
            let reply = try JSON.decode(PeerTargetEnrollment.Reply.self, data)
            guard reply.profile == PeerTargetEnrollment.profile, reply.operation == expected,
                try JSON.encode(reply) == data else { throw failure("invalidHelperReply") }
            switch expected {
            case "ready", "opened", "appended", "closed":
                guard data == (try JSON.encode(PeerTargetEnrollment.Reply(expected))) else { throw failure("invalidHelperReply") }
            case "finished":
                guard let receipt = reply.receipt else { throw failure("invalidHelperReply") }
                var expected = PeerTargetEnrollment.Reply("finished"); expected.receipt = receipt
                guard try JSON.encode(expected) == data else { throw failure("invalidHelperReply") }
            case "page":
                guard let entries = reply.entries, entries.count <= 128, let phase = reply.phase, PeerPackage.IntakePhase(rawValue: phase) != nil,
                    reply.blockedOnIndex != nil, reply.complete != nil, reply.receipt == nil, reply.code == nil else { throw failure("invalidHelperReply") }
                for (ordinal, entry) in entries.enumerated() {
                    try entry.descriptor.validate()
                    guard entry.ordinal == ordinal, entry.nextOffset >= 0, entry.nextOffset <= entry.descriptor.length,
                        !entry.verifiedComplete || entry.nextOffset == entry.descriptor.length else { throw failure("invalidHelperReply") }
                }
                if reply.complete == true { guard reply.blockedOnIndex == false, entries.allSatisfy(\.verifiedComplete) else { throw failure("invalidHelperReply") } }
            default: throw failure("invalidHelperReply")
            }
            return reply
        } catch { throw failure("invalidHelperReply") }
    }
    static func validate(_ status: PeerEnrollmentOperatorStatus, operationID: String,
                         record: PeerEnrollmentActivation.Record, registered: Bool = false) throws {
        let prep = try record.preparation
        guard status.operationID == operationID, status.storeID == prep.commonStoreID,
            status.sourceReplicaID == prep.sourceReplicaID, status.targetReplicaID == prep.targetReplicaID,
            status.bootstrap == record.pin.bootstrap, status.approval == record.pin.approval else { throw failure("sourceEnrollmentMismatch") }
        let baseline = try JSON.encode(record.baseline)
        if registered {
            // The existing registration ACK omits the manifest; initial status never may.
            guard status.phase == "registered", status.baselineManifest == nil || status.baselineManifest == baseline else {
                throw failure("sourceEnrollmentMismatch")
            }
        } else {
            guard ["accepted", "registered"].contains(status.phase), status.baselineManifest == baseline else {
                throw failure("sourceEnrollmentMismatch")
            }
        }
    }
    static func validate(_ receipt: PeerEnrollmentActivation.Receipt, record: PeerEnrollmentActivation.Record) throws {
        guard receipt.profile == PeerEnrollmentActivation.capability, receipt.requestDigest == (try record.digest),
            receipt.approval == record.pin.approval, receipt.baselineDigest == AuthorityRecordCodec.sha256(try JSON.encode(record.baseline)),
            receipt.configurationSequence > 0 else { throw failure("invalidHelperReply") }
        _ = try AuthorityRecord.digest(.text(receipt.configurationDigest))
    }
    package static func run(connection: ServerConnection, operationID: String, input: PeerEnrollmentTargetOutput,
        targetRoot: String, pin: PeerTargetEnrollmentPin, custody: PeerEnrollmentTargetCustody,
        ssh: PeerEnrollmentSSHDestination? = nil) throws -> Data {
        try run(connection: connection, operationID: operationID, input: input, targetRoot: targetRoot,
            pin: pin, custody: custody, ssh: ssh, seconds: 1800, cancelled: { tractanda_stopping() != 0 }, hooks: .init())
    }
    static func run(connection: ServerConnection, operationID: String, input: PeerEnrollmentTargetOutput,
        targetRoot: String, pin: PeerTargetEnrollmentPin, custody: PeerEnrollmentTargetCustody,
        ssh: PeerEnrollmentSSHDestination? = nil, seconds: Double, cancelled: @escaping () -> Bool, hooks: Hooks) throws -> Data {
        guard getuid() != 0, getuid() == tractanda_uid() else { throw failure("invalidTargetCustody") }
        let job = try Job(seconds: seconds, cancelled: cancelled)
        _ = try AuthorityRecord.persistentID(.text(operationID))
        let record = try input.withBytes { try PeerEnrollmentTargetOutput.decode($0).0 }
        let approval = try AuthorityRecordCodec.decode(record.proof.approvalBytes).record
        guard record.pin == (try pin.value), approval.payload["operationID"]?.string == operationID else { throw failure("sourceEnrollmentMismatch") }
        let launch: Launch
        if let ssh {
            launch = try PeerEnrollmentSSH.launch(destination: ssh, root: targetRoot, pin: pin, custody: custody,
                job: job, clientForTesting: hooks.sshClient, helperForTesting: hooks.helper)
        } else {
            guard hooks.sshClient == nil else { throw failure("helperUnavailable") }
            launch = try self.launch(root: targetRoot, pin: pin, custody: custody, helperForTesting: hooks.helper)
        }
        var receipt: PeerEnrollmentActivation.Receipt?, closed = false, reaped = false, registrationStarted = false
        var child: Child?
        defer { child?.cleanup() }
        do {
            try job.check()
            try validate(NativePeerEnrollment.boundedCall(connection: connection, action: .status,
                operationID: operationID, deadline: job.sourceDeadline()), operationID: operationID, record: record)
            let process = try Child(launch, job: job); child = process
            process.didReap = hooks.reaped; hooks.spawned?(process.pid)
            func receive(_ operation: String) throws -> PeerTargetEnrollment.Reply {
                guard var data = try process.io.receive(maximum: PeerTargetEnrollment.maximumReplyBytes) else { throw failure("invalidHelperReply") }
                if let filter = hooks.reply { data = try filter(operation, data) }
                return try checkedReply(data, expected: operation)
            }
            var work = 0
            func consume() throws {
                try job.check(); work += 1
                guard work <= PeerPackage.Limits().maximumWork else { throw failure("resourceLimit") }
            }
            func yieldTransient() throws { try job.check(); _ = poll(nil, 0, 20); try job.check() }
            func request(_ object: PeerTargetEnrollment.Request) throws { try job.check(); try process.io.send(encodedRequest(object)) }
            func exchange(_ operation: String, _ object: PeerTargetEnrollment.Request, payload: Data? = nil, maximum: Int = 0) throws -> PeerTargetEnrollment.Reply {
                while true {
                    try consume(); try request(object)
                    if let payload { try process.io.send(payload, maximum: maximum) }
                    do { return try receive(operation) }
                    catch let error as TractandaError where error.code == "peerPayloadVerifying" { try yieldTransient() }
                }
            }
            _ = try receive("ready") // Version/compatibility refusal BEFORE private bytes.
            try input.withBytes { try process.io.send($0, maximum: PeerEnrollmentTargetOutput.maximumBytes) }
            hooks.didSendPrivateInput?(); _ = try receive("opened")
            for package in [record.baseline.packageID, record.proof.manifest.packageID] {
                var advance = false, done = false
                while !done {
                    let page = try exchange("page", .init(operation: "resume", packageID: package, advance: advance))
                    guard page.packageID == package else { throw failure("invalidHelperReply") }
                    if page.complete == true { done = true; continue }
                    if let entry = page.entries!.first(where: { !$0.verifiedComplete }) {
                        let count = min(entry.descriptor.chunkBytes, entry.descriptor.length - entry.nextOffset)
                        guard count > 0 else { throw failure("invalidHelperReply") }
                        var chunk = Data(); defer { chunk.resetBytes(in: 0..<chunk.count) }
                        while chunk.count < count {
                            try consume()
                            do {
                                let piece = try NativePeerEnrollment.readChunk(connection: connection, operationID: operationID,
                                    object: entry.descriptor, offset: entry.nextOffset + chunk.count,
                                    maximumBytes: min(65536, count - chunk.count), deadline: job.sourceDeadline())
                                guard !piece.bytes.isEmpty else { throw failure("invalidSourceChunk") }
                                chunk.append(piece.bytes)
                            } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
                                // Same descriptor/offset, no byte advance until an exact source reply succeeds.
                                try yieldTransient()
                            }
                        }
                        _ = try exchange("appended", .init(operation: "append", packageID: package,
                            ordinal: entry.ordinal, offset: entry.nextOffset),
                            payload: chunk, maximum: entry.descriptor.chunkBytes)
                        advance = false
                    } else { advance = true }
                }
            }
            let finish = try exchange("finished", .init(operation: "finish"))
            let value = finish.receipt!; try validate(value, record: record); receipt = value
            _ = try exchange("closed", .init(operation: "close")); closed = true
            try process.reapAfterClosed(); reaped = true
            try job.check(); try hooks.beforeRegister?(); try job.check(); registrationStarted = true
            let registered = try NativePeerEnrollment.boundedCall(connection: connection, action: .register,
                operationID: operationID, deadline: job.sourceDeadline())
            try validate(registered, operationID: operationID, record: record, registered: true)
            return try JSON.encode(["phase": "registered", "operationID": operationID, "targetReplicaID": record.preparation.targetReplicaID])
        } catch {
            if launch.indirectCustody, child != nil, !closed || !reaped {
                throw TractandaError("targetCustodyUncertain", "Target activation or custody release could not be confirmed across indirect custody. Only the owned local client is drained and reaped; target descendants may remain. Source registration was not attempted. Retry exact material.")
            }
            if receipt != nil {
                if !closed || !reaped { throw TractandaError("targetCustodyUncertain", "Target activation completed; custody release was not confirmed. Source registration was not attempted. Retry exact material.") }
                throw TractandaError("sourceRegistrationUncertain", registrationStarted
                    ? "Target activation and release completed; source registration could not be confirmed. Retry the same accepted operation."
                    : "Target activation and release completed; source registration was not attempted. Retry the same accepted operation.")
            }
            if error is CancellationError { throw failure("cancelled") }
            let code = (error as? TractandaError)?.code ?? "enrollmentSupervisorFailed"
            let allowed: Set<String> = ["forbidden", "cancelled", "deadlineExceeded", "connectionFailed", "helperUnavailable",
                "invalidHelperReply", "invalidTargetProtocol", "invalidTargetCustody", "resourceLimit", "sourceEnrollmentMismatch", "nativeEnrollmentProtocol",
                "peerRepairRequired", "recoveryRequired", "peerPayloadVerifying", "missingDependencies", "storeBusy", "enrollmentPending"]
            throw failure(allowed.contains(code) ? code : "enrollmentSupervisorFailed")
        }
    }
}
