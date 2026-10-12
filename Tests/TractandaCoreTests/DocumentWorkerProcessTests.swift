import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentWorkerProcessTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func deadline(_ seconds: Double = 5) -> ContinuousClock.Instant {
        .now.advanced(by: .seconds(seconds))
    }
    private func python(
        _ script: String, arguments: [String] = [], cancellation: DocumentConversionCancellation = .init()
    ) throws -> DocumentOwnedProcess {
        try DocumentOwnedProcess(
            executable: "/usr/bin/python3", arguments: ["-c", script] + arguments, cancellation: cancellation,
            graceSeconds: 0.05)
    }
    private func reaped(_ process: DocumentOwnedProcess) {
        var status: Int32 = 0
        XCTAssertEqual(waitpid(process.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
    private func finishHarness(_ process: DocumentOwnedProcess, phase: String, seconds: Double = 5) throws {
        do {
            try process.finish(deadline: deadline(seconds))
        } catch {
            throw TractandaError(
                "nativeHarnessFailure",
                "phase=\(phase); status=\(process.terminationStatus.map(String.init) ?? "unknown"); stderr=\(String(decoding: process.stderrTail, as: UTF8.self)); error=\(error)"
            )
        }
    }
    func testChildGroupAndUnrelatedDescriptorIsolation() throws {
        let fd = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }
        let foreign = fcntl(fd, F_DUPFD, 200)  // Deliberately not CLOEXEC.
        XCTAssertGreaterThanOrEqual(foreign, 200)
        defer { _ = close(foreign) }
        let process = try python(
            "import os,sys,json\ntry: os.fstat(int(sys.argv[1])); leaked=True\nexcept OSError: leaked=False\nprint(json.dumps({'ownGroup':os.getpid()==os.getpgrp(),'leaked':leaked}))",
            arguments: [String(foreign)])
        let line = try XCTUnwrap(process.nextLine(limit: 4096, deadline: deadline()))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Bool])
        XCTAssertEqual(result["ownGroup"], true)
        XCTAssertEqual(result["leaked"], false)
        try process.finish(deadline: deadline())
        reaped(process)
    }
    func testBoundedStderrBackpressureAndSequentialPipeExchange() throws {
        let process = try python(
            "import os,sys\nos.write(2,b'x'*200000)\nfor line in sys.stdin.buffer:\n os.write(1,line)\n if line==b'close\\n': break"
        )
        try process.writeLine(Data("hello".utf8), deadline: deadline())
        XCTAssertEqual(try process.nextLine(limit: 4096, deadline: deadline()), Data("hello".utf8))
        try process.writeLine(Data("close".utf8), deadline: deadline())
        XCTAssertEqual(try process.nextLine(limit: 4096, deadline: deadline()), Data("close".utf8))
        try process.finish(deadline: deadline())
        XCTAssertEqual(process.stderrTail.count, 65536)
        reaped(process)
    }
    func testTimeoutCancellationMissingLFAndOversizeAllReap() throws {
        for script in [
            "import time; time.sleep(10)", "import os; os.write(1,b'partial')",
            "import os; os.write(1,b'x'*5000+b'\\n')",
        ] {
            let process = try python(script)
            XCTAssertThrowsError(try process.nextLine(limit: 4096, deadline: deadline(0.1)))
            process.terminateAndWait()
            reaped(process)
        }
        let cancellation = DocumentConversionCancellation()
        let process = try python("import time; time.sleep(10)", cancellation: cancellation)
        cancellation.cancel()
        XCTAssertThrowsError(try process.nextLine(limit: 4096, deadline: deadline())) {
            XCTAssertTrue($0 is CancellationError)
        }
        process.terminateAndWait()
        reaped(process)
    }
    func testFailedTerminalExitIsReapedBeforeFreshSession() throws {
        let failed = try python("import os; os.write(1,b'failed\\n'); raise SystemExit(1)")
        XCTAssertEqual(try failed.nextLine(limit: 4096, deadline: deadline()), Data("failed".utf8))
        try failed.finish(deadline: deadline(), requireSuccessful: false)
        XCTAssertNotEqual(failed.terminationStatus, 0)
        reaped(failed)
        let fresh = try python("print('fresh')")
        XCTAssertEqual(try fresh.nextLine(limit: 4096, deadline: deadline()), Data("fresh".utf8))
        try fresh.finish(deadline: deadline())
        reaped(fresh)
    }
    func testEPIPEAndClosedStdioInsideOwnedNativeHarness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-process-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // Source+binary+output estimate <1MiB; cap16MiB and genuine reserve checked before compilation.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let platform = repository.appendingPathComponent("Sources/CTractandaPlatform/platform.c").path
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = root.appendingPathComponent("harness.c")
        let executable = root.appendingPathComponent("harness")
        let proof = root.appendingPathComponent("proof")
        let code = """
            #include "\(platform)"
            int main(int argc, char **argv) {
                if (argc == 1) {
                    signal(SIGPIPE, SIG_DFL);
                    int pipes[2]; if (pipe(pipes)) return 2;
                    close(pipes[0]);
                    int64_t count = tractanda_document_write(pipes[1], "x", 1);
                    int saved = errno; close(pipes[1]);
                    struct sigaction current; sigaction(SIGPIPE, NULL, &current);
                    if (count != -1 || saved != EPIPE || current.sa_handler != SIG_DFL) return 3;
                    puts("epipe-handled"); return 0;
                }
                int proof = open(argv[1], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
                if (proof < 3) return 4;
                close(0); close(1); close(2);
                const char *args[] = {"/bin/cat", NULL};
                int32_t pid, input, output, error;
                if (tractanda_document_spawn("/bin/cat", args, &pid, &input, &output, &error)) return 5;
                if (input < 3 || output < 3 || error < 3) return 6;
                if (tractanda_document_write(input, "token\\n", 6) != 6) return 7;
                close(input);
                char bytes[32]; ssize_t count = -1;
                for (int i=0; i<100; ++i) {
                    struct pollfd waiting = {output, POLLIN | POLLHUP, 0}; poll(&waiting,1,20);
                    count = read(output,bytes,sizeof(bytes)); if (count >= 0) break;
                    if (errno != EAGAIN && errno != EINTR) break;
                }
                for (int i=0; i<100 && tractanda_document_exited(pid)!=1; ++i) {
                    struct pollfd waiting = {error,POLLIN,0}; poll(&waiting,1,10);
                }
                kill(-pid,SIGKILL); int status; while(waitpid(pid,&status,0)<0 && errno==EINTR) {}
                close(output); close(error);
                if (count <= 0 || status != 0) return 8;
                if (write(proof,bytes,(size_t)count)!=count || fsync(proof)) return 9;
                close(proof); return 0;
            }
            """
        try Data(code.utf8).write(to: source)
        var flags = [
            source.path, "-I", repository.appendingPathComponent("Sources/CTractandaPlatform/include").path,
            "-lpam", "-lpthread", "-o", executable.path,
        ]
        #if os(Linux)
            flags.append("-luuid")
        #endif
        let compiler = try DocumentOwnedProcess(
            executable: "/usr/bin/cc", arguments: flags, cancellation: .init(), graceSeconds: 0.05)
        while try compiler.nextLine(limit: 4096, deadline: deadline(60)) != nil {}
        try finishHarness(compiler, phase: "compiler", seconds: 60)
        XCTAssertLessThan(try FileMetadata.read(at: executable).size, 1024 * 1024)
        let epipe = try DocumentOwnedProcess(
            executable: executable.path, arguments: [], cancellation: .init(), graceSeconds: 0.05)
        XCTAssertEqual(try epipe.nextLine(limit: 4096, deadline: deadline()), Data("epipe-handled".utf8))
        try finishHarness(epipe, phase: "EPIPE")
        reaped(epipe)
        let stdio = try DocumentOwnedProcess(
            executable: executable.path, arguments: [proof.path], cancellation: .init(), graceSeconds: 0.05)
        XCTAssertNil(try stdio.nextLine(limit: 4096, deadline: deadline()))
        try finishHarness(stdio, phase: "closed-stdio")
        XCTAssertEqual(try Data(contentsOf: proof), Data("token\n".utf8))
        reaped(stdio)
    }
    func testIgnoringTERMDescendantLosesInheritedPipeAfterGroupKill() throws {
        let script = """
            import os,signal,time
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            child=os.fork()
            if child==0:
                while True: time.sleep(1)
            print(child,flush=True)
            while True: time.sleep(1)
            """
        let process = try python(script)
        let line = try XCTUnwrap(process.nextLine(limit: 4096, deadline: deadline()))
        let descendant = try XCTUnwrap(Int32(try XCTUnwrap(String(data: line, encoding: .utf8))))
        // Duplicate reader lets the test prove writer closure rather than merely our own fd closure.
        let reader = try process.duplicateOutputForTesting()
        defer {
            _ = close(reader)
            _ = kill(descendant, SIGKILL)
        }
        XCTAssertThrowsError(try process.nextLine(limit: 4096, deadline: deadline(0.05)))
        process.terminateAndWait()
        reaped(process)
        var waiting = pollfd(fd: reader, events: Int16(POLLIN | POLLHUP), revents: 0)
        XCTAssertGreaterThan(poll(&waiting, 1, 1000), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(
            read(reader, &byte, 1), 0, "Descendant must lose its inherited stdout writer after group kill")
    }

}
