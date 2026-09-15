import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Spool child output to a private file, avoiding pipe backpressure while waiting for exit.
/// Helpers are bounded, reaped on timeout, and receive an explicit environment.
public struct FoundationProcessRunner: SetupProcessRunning {
    let timeout: TimeInterval
    let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 30, maximumOutputBytes: Int = 8 * 1024 * 1024) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> ProcessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-setup-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        guard
            FileManager.default.createFile(
                atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw SetupError("Cannot create a private helper output file.") }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            .merging(environment) { _, replacement in replacement }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: String?
        while process.isRunning {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber
            if (size?.intValue ?? 0) > maximumOutputBytes {
                failure = "Helper output exceeded its limit: \(executable)."
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                failure = "Timed out running \(executable)."
            }
            if failure != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let input = try FileHandle(forReadingFrom: outputURL)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: maximumOutputBytes + 1) ?? Data()
        if bytes.count > maximumOutputBytes { failure = "Helper output exceeded its limit: \(executable)." }
        if let failure { throw SetupError(failure) }
        return ProcessResult(
            status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
    }
}
