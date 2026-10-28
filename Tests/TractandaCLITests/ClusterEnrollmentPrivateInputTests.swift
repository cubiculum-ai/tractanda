import CTractandaPlatform
import Foundation
import TractandaCore
import XCTest

@testable import TractandaCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ClusterEnrollmentPrivateInputTests: XCTestCase {
    private func invitation() throws -> PersonalEnrollmentInvitation {
        func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        return try .init(
            metadata: .init(
                operationID: id(), storeID: id(), issuerReplicaID: id(),
                bootstrapReplicaID: id(), pairingID: id(),
                endpoints: [.init(host: "source.fixture", port: 48732)],
                expiresAt: 20_000, expectedMembershipDigest: nil),
            secret: .init(bytes: [UInt8](repeating: 31, count: 32)))
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #if os(Linux)
            let selected = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #else
            let selected = root
        #endif
        let directory = selected.appendingPathComponent("private-pairing-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
    func testPositivePrivateFileRoundTripAndExclusiveNoOverwrite() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pairing")
        let code = try invitation()
        try ClusterEnrollmentPrivateInput.writeInvitation(code, toPrivateFile: file.path)
        XCTAssertEqual(
            try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path).metadata,
            code.metadata)
        let bytes = try Data(contentsOf: file)
        XCTAssertThrowsError(
            try ClusterEnrollmentPrivateInput.writeInvitation(invitation(), toPrivateFile: file.path))
        XCTAssertTrue(try Data(contentsOf: file) == bytes, "Existing private output must remain exact.")
    }
    func testMalformedPrivateFileFailsWithGenericError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pairing")
        try Data("sensitive-code-material".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path)) {
            error in
            XCTAssertFalse(String(describing: error).contains("sensitive-code-material"))
            XCTAssertEqual((error as? TractandaError)?.code, "invalidEnrollmentInput")
            XCTAssertEqual(
                (error as? TractandaError)?.message, "Private enrollment input is unavailable or unsafe.")
        }
    }

    func testRejectsSymlinkAndHardLinkInputs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("source")
        try Data("tractanda-pair-v1.bad".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let link = dir.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: file, to: link)
        XCTAssertThrowsError(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: link.path))
        let symlink = dir.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertThrowsError(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: symlink.path))
    }

    func testRejectsOversizedAndNonCanonicalInputWithoutEchoingCode() throws {
        XCTAssertThrowsError(
            try PersonalEnrollmentInvitation.parsePrivateCode(String(repeating: "x", count: 12 * 1024 + 1)))
        XCTAssertThrowsError(
            try PersonalEnrollmentInvitation.parsePrivateCode("tractanda-pair-v1.secret-sentinel")
        ) { error in
            XCTAssertFalse(String(describing: error).contains("secret-sentinel"))
        }
    }

    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var value: Result<PersonalEnrollmentInvitation, Error>?
        func set(_ result: Result<PersonalEnrollmentInvitation, Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }
        func get() -> Result<PersonalEnrollmentInvitation, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
    func testPTYInputRestoresEchoOnSuccessMalformedInputAndCancellation() throws {
        let code = try invitation()
        for payload in [
            Array((try code.privateCode() + "\n").utf8), Array("secret-malformed-sentinel\n".utf8),
            [UInt8(3)],
        ] {
            var master: Int32 = -1
            var slave: Int32 = -1
            XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
            defer {
                close(master)
                close(slave)
            }
            var original = termios()
            XCTAssertEqual(tcgetattr(slave, &original), 0)
            let result = ResultBox()
            let finished = DispatchSemaphore(value: 0)
            let inputFD = slave
            DispatchQueue.global().async {
                var beforeMask = sigset_t()
                var afterMask = sigset_t()
                XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &beforeMask), 0)
                result.set(Result { try ClusterEnrollmentPrivateInput.readInvitation(terminalFD: inputFD) })
                XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &afterMask), 0)
                XCTAssertEqual(sigismember(&beforeMask, SIGTERM), sigismember(&afterMask, SIGTERM))
                XCTAssertEqual(sigismember(&beforeMask, SIGHUP), sigismember(&afterMask, SIGHUP))
                finished.signal()
            }
            let deadline = Date().addingTimeInterval(2)
            var hidden = termios()
            repeat {
                XCTAssertEqual(tcgetattr(slave, &hidden), 0)
                if hidden.c_lflag & tcflag_t(ECHO) == 0 { break }
                Thread.sleep(forTimeInterval: 0.001)
            } while Date() < deadline
            XCTAssertEqual(hidden.c_lflag & tcflag_t(ECHO), 0)
            XCTAssertEqual(payload.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }, payload.count)
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            var restored = termios()
            XCTAssertEqual(tcgetattr(slave, &restored), 0)
            XCTAssertEqual(restored.c_lflag, original.c_lflag)
            if payload == Array((try code.privateCode() + "\n").utf8) {
                XCTAssertEqual(try XCTUnwrap(result.get()).get().metadata, code.metadata)
            } else {
                XCTAssertThrowsError(try XCTUnwrap(result.get()).get()) {
                    XCTAssertFalse(String(describing: $0).contains("secret-malformed-sentinel"))
                }
            }
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            var observed = [UInt8](repeating: 0, count: 16 * 1024)
            XCTAssertLessThanOrEqual(
                observed.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }, 0)
        }
    }
    func testPTYRealTerminationAndHangupOnAnotherThreadWakeInputAndRestoreEcho() throws {
        for selectedSignal in [SIGTERM, SIGHUP] {
            var master: Int32 = -1
            var slave: Int32 = -1
            XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
            defer {
                close(master)
                close(slave)
            }
            var original = termios()
            XCTAssertEqual(tcgetattr(slave, &original), 0)
            let originalFlags = fcntl(slave, F_GETFL)
            let result = ResultBox()
            let finished = DispatchSemaphore(value: 0)
            let inputFD = slave
            DispatchQueue.global().async {
                var beforeMask = sigset_t()
                var afterMask = sigset_t()
                XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &beforeMask), 0)
                result.set(Result { try ClusterEnrollmentPrivateInput.readInvitation(terminalFD: inputFD) })
                XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &afterMask), 0)
                XCTAssertEqual(sigismember(&beforeMask, SIGTERM), sigismember(&afterMask, SIGTERM))
                XCTAssertEqual(sigismember(&beforeMask, SIGHUP), sigismember(&afterMask, SIGHUP))
                finished.signal()
            }
            let deadline = Date().addingTimeInterval(2)
            var hidden = termios()
            repeat {
                XCTAssertEqual(tcgetattr(slave, &hidden), 0)
                if hidden.c_lflag & tcflag_t(ECHO) == 0 { break }
                Thread.sleep(forTimeInterval: 0.001)
            } while Date() < deadline
            XCTAssertEqual(hidden.c_lflag & tcflag_t(ECHO), 0)
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                // Send a real process-directed signal from a non-reading thread. The
                // handler may run on any unmasked thread; its pipe wakes the reader.
                var selected = sigset_t()
                var original = sigset_t()
                sigemptyset(&selected)
                sigaddset(&selected, selectedSignal)
                XCTAssertEqual(pthread_sigmask(SIG_UNBLOCK, &selected, &original), 0)
                XCTAssertEqual(kill(getpid(), selectedSignal), 0)
                XCTAssertEqual(pthread_sigmask(SIG_SETMASK, &original, nil), 0)
                delivered.signal()
            }
            XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertThrowsError(try XCTUnwrap(result.get()).get())
            var restored = termios()
            XCTAssertEqual(tcgetattr(slave, &restored), 0)
            XCTAssertEqual(restored.c_lflag, original.c_lflag)
            XCTAssertEqual(fcntl(slave, F_GETFL), originalFlags)
        }
    }
    #if os(macOS)
        func testReadGrantACLOnSecretLeafAndPrivateDirectoryIsRejected() throws {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("pairing")
            try ClusterEnrollmentPrivateInput.writeInvitation(invitation(), toPrivateFile: file.path)
            func chmod(_ arguments: [String]) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
            try chmod(["+a", "everyone allow read", file.path])
            XCTAssertThrowsError(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path))
            try chmod(["-N", file.path])
            XCTAssertNotNil(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path))
            try chmod(["+a", "everyone allow list,search", dir.path])
            XCTAssertThrowsError(try ClusterEnrollmentPrivateInput.readInvitation(fromPrivateFile: file.path))
            XCTAssertThrowsError(
                try ClusterEnrollmentPrivateInput.writeInvitation(
                    invitation(), toPrivateFile: dir.appendingPathComponent("blocked").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("blocked").path))
            try chmod(["-N", dir.path])
        }
    #endif
}
