import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Origin proof emitted only by the owned process deadline check, never worker frames/callbacks.
struct DocumentWorkerDeadlineExpired: Error {}

/// Single-worker ownership. Only cancellation is shared; all pipe/status mutations stay on its worker.
final class DocumentOwnedProcess {
    let pid: Int32
    private var input: Int32
    private var output: Int32
    private var error: Int32
    private var pending = Data()
    private(set) var stderrTail = Data()
    private(set) var terminationStatus: Int32?
    private let cancellation: DocumentConversionCancellation
    private let graceSeconds: Double

    init(
        executable: String, arguments: [String], cancellation: DocumentConversionCancellation,
        graceSeconds: Double = 2
    ) throws {
        guard executable.hasPrefix("/"), !executable.contains("\0"), arguments.count <= 16,
            arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }),
            graceSeconds.isFinite, graceSeconds > 0, graceSeconds <= 60
        else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Invalid owned worker launch or termination grace.")
        }
        try cancellation.check()
        self.cancellation = cancellation
        self.graceSeconds = graceSeconds
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { for string in strings { free(string) } }
        guard strings.allSatisfy({ $0 != nil }) else {
            throw Self.failure("Cannot allocate worker arguments.")
        }
        let argv: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        var child: Int32 = -1
        var stdin: Int32 = -1
        var stdout: Int32 = -1
        var stderr: Int32 = -1
        let launched = executable.withCString { path in
            argv.withUnsafeBufferPointer { arguments in
                tractanda_document_spawn(path, arguments.baseAddress, &child, &stdin, &stdout, &stderr)
            }
        }
        guard launched == 0 else { throw Self.failure("Cannot launch isolated document worker.") }
        pid = child
        input = stdin
        output = stdout
        error = stderr
    }
    deinit { terminateAndWait() }
    func duplicateOutputForTesting() throws -> Int32 {
        let copy = fcntl(output, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw failure("Cannot duplicate owned test output.") }
        return copy
    }

    private static func failure(_ message: String) -> TractandaError {
        TractandaError("nativeWorkerFailed", message, osError: errno)
    }
    private func failure(_ message: String) -> TractandaError { Self.failure(message) }
    private func check(_ deadline: ContinuousClock.Instant) throws {
        try cancellation.check()
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw DocumentWorkerDeadlineExpired()
        }
    }
    func writeLine(_ data: Data, deadline: ContinuousClock.Instant) throws {
        guard data.count <= NativeWorkerProtocol.requestBytes, !data.contains(10), input >= 0 else {
            throw NativeWorkerProtocol.invalid()
        }
        var bytes = data
        bytes.append(10)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try check(deadline)
                let count = tractanda_document_write(
                    input, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try pump(limit: NativeWorkerProtocol.pageBytes, waitMilliseconds: 20)
                    continue
                }
                guard count > 0 else { throw failure("Native worker stopped accepting requests.") }
                offset += Int(count)
            }
        }
    }
    /// Caller supplies a shared absolute phase/liveness deadline, never a per-frame reset.
    func nextLine(limit: Int, deadline: ContinuousClock.Instant) throws -> Data? {
        guard (1...NativeWorkerProtocol.pageBytes).contains(limit) else {
            throw NativeWorkerProtocol.invalid()
        }
        while true {
            try check(deadline)
            if let newline = pending.firstIndex(of: 10) {
                let length = pending.distance(from: pending.startIndex, to: newline)
                guard length <= limit else { throw NativeWorkerProtocol.invalid() }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                return line
            }
            guard pending.count <= limit else { throw NativeWorkerProtocol.invalid() }
            if output < 0 {
                guard pending.isEmpty else { throw NativeWorkerProtocol.invalid() }
                return nil
            }
            try pump(limit: limit, waitMilliseconds: 20)
        }
    }
    private func closeInput() {
        if input >= 0 {
            _ = close(input)
            input = -1
        }
    }
    private func pump(limit: Int, waitMilliseconds: Int32) throws {
        var descriptors = [
            pollfd(fd: output, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: error, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
        ]
        let result = descriptors.withUnsafeMutableBufferPointer {
            poll($0.baseAddress, nfds_t($0.count), waitMilliseconds)
        }
        if result < 0, errno == EINTR { return }
        guard result >= 0 else { throw failure("Cannot supervise document worker pipes.") }
        if output >= 0, descriptors[0].revents != 0 {
            guard pending.count <= limit else { throw NativeWorkerProtocol.invalid() }
            var bytes = [UInt8](repeating: 0, count: min(8192, limit + 1 - pending.count))
            let count = bytes.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                _ = close(output)
                output = -1
            } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                throw failure("Cannot read document worker output.")
            }
        }
        // A bounded batch prevents a log-flooding child from starving stdout/deadline checks.
        if error >= 0, descriptors[1].revents != 0 {
            for _ in 0..<8 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = bytes.withUnsafeMutableBytes { read(error, $0.baseAddress, $0.count) }
                if count > 0 {
                    stderrTail.append(contentsOf: bytes.prefix(count))
                    if stderrTail.count > 65_536 { stderrTail.removeFirst(stderrTail.count - 65_536) }
                } else if count == 0 {
                    _ = close(error)
                    error = -1
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    break
                } else {
                    throw failure("Cannot drain document worker diagnostics.")
                }
            }
        }
    }
    /// Matching terminal/closed frame has already been consumed; any extra stdout is invalid.
    func finish(deadline: ContinuousClock.Instant, requireSuccessful: Bool = true) throws {
        closeInput()
        while true {
            try check(deadline)
            try pump(limit: NativeWorkerProtocol.controlBytes, waitMilliseconds: 20)
            guard pending.isEmpty else { throw NativeWorkerProtocol.invalid() }
            let exited = tractanda_document_exited(pid)
            if exited == 1 { break }
            if exited < 0, errno != EINTR { throw failure("Cannot observe native worker exit.") }
        }
        try pump(limit: NativeWorkerProtocol.controlBytes, waitMilliseconds: 0)
        guard pending.isEmpty else { throw NativeWorkerProtocol.invalid() }
        terminateAndWait()
        if requireSuccessful {
            guard terminationStatus == 0 else { throw failure("Native worker exited unsuccessfully.") }
        }
    }
    /// Keep child PID waitable until group cleanup, preventing PID/group reuse before the final kill.
    func terminateAndWait() {
        guard terminationStatus == nil else { return }
        closeInput()
        _ = kill(-pid, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(graceSeconds))
        while ContinuousClock.now < deadline {
            if tractanda_document_exited(pid) == 1 { break }
            try? pumpDiscarding(waitMilliseconds: 20)
        }
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            status = -1
            break
        }
        terminationStatus = status
        // Drain the finite kernel buffers after group death, retaining only the diagnostic tail.
        for _ in 0..<256 {
            if output < 0, error < 0 { break }
            try? pumpDiscarding(waitMilliseconds: 0)
        }
        if output >= 0 {
            _ = close(output)
            output = -1
        }
        if error >= 0 {
            _ = close(error)
            error = -1
        }
        pending.removeAll()
    }
    private func pumpDiscarding(waitMilliseconds: Int32) throws {
        pending.removeAll(keepingCapacity: true)
        try pump(limit: NativeWorkerProtocol.pageBytes, waitMilliseconds: waitMilliseconds)
        pending.removeAll(keepingCapacity: true)
    }
}

/// Pure phase/counter validation. Only a real transition or increasing completed count is liveness.
struct DocumentMeaningfulProgress {
    private(set) var phase: String?
    private(set) var completed: Int64 = 0
    private(set) var total: Int64 = 0
    private(set) var pageStarted = false
    private(set) var modelReady = false
    mutating func beginPage() {
        phase = nil
        completed = 0
        total = 0
        pageStarted = false
    }
    mutating func observe(phase next: String, completed nextCompleted: Int64, total nextTotal: Int64) throws
        -> Bool
    {
        let phases = [
            "modelVerify", "modelLoad", "modelReady", "render", "prepare", "prefill", "generate", "drain",
        ]
        guard let rank = phases.firstIndex(of: next), nextCompleted >= 0, nextCompleted <= nextTotal else {
            throw NativeWorkerProtocol.invalid()
        }
        let priorRank = phase.flatMap { phases.firstIndex(of: $0) }
        if let priorRank { guard rank >= priorRank else { throw NativeWorkerProtocol.invalid() } }
        if phase == next {
            guard nextCompleted >= completed, nextTotal >= total else { throw NativeWorkerProtocol.invalid() }
        }
        if modelReady, rank < 2 { throw NativeWorkerProtocol.invalid() }
        let meaningful = phase != next || nextCompleted > completed
        phase = next
        completed = nextCompleted
        total = nextTotal
        if rank >= 2 { modelReady = true }
        if rank >= 3 { pageStarted = true }
        return meaningful
    }
}
