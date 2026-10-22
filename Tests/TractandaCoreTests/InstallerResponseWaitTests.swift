import CTractandaPlatform
import Foundation
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class InstallerResponseWaitTests: XCTestCase {
    private func sockets() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        #if os(Linux)
            let type = Int32(SOCK_STREAM.rawValue)
        #else
            let type = SOCK_STREAM
        #endif
        guard socketpair(AF_UNIX, type, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        XCTAssertEqual(
            setsockopt(
                pair[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))), 0
        )
        return (pair[0], pair[1])
    }
    func testInstallerWaitPreservesPartialFrameAcrossBoundedReadTimeouts() throws {
        let (reader, writer) = try sockets()
        defer { _ = close(reader) }
        let completed = expectation(description: "single response sender completed")
        DispatchQueue.global().async {
            defer {
                _ = close(writer)
                completed.fulfill()
            }
            for fragment: [UInt8] in [[0, 0], [0, 3, 1], [2, 3]] {
                fragment.withUnsafeBytes { _ = write(writer, $0.baseAddress, $0.count) }
                Thread.sleep(forTimeInterval: 0.06)
            }
        }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_installer_frame(reader, &bytes, &count), 0)
        if let bytes {
            XCTAssertEqual(Data(bytes: bytes, count: Int(count)), Data([1, 2, 3]))
            tractanda_free(bytes)
        }
        wait(for: [completed], timeout: 2)
    }
    func testOrdinaryResponseStillTimesOutAndInstallerEOFStillFails() throws {
        let (reader, writer) = try sockets()
        defer { _ = close(reader) }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_frame(reader, &bytes, &count), -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
        _ = close(writer)
        XCTAssertEqual(tractanda_receive_installer_frame(reader, &bytes, &count), -1)
        XCTAssertEqual(errno, ECONNRESET)
    }
    func testInstallerCancellationAndFrameLimitRemainEnforced() throws {
        let (reader, writer) = try sockets()
        defer {
            _ = close(reader)
            _ = close(writer)
        }
        XCTAssertEqual(tractanda_start_signals(), 0)
        _ = kill(getpid(), SIGTERM)
        var cancelledBytes: UnsafeMutableRawPointer?
        var cancelledCount: UInt32 = 0
        XCTAssertEqual(tractanda_receive_installer_frame(reader, &cancelledBytes, &cancelledCount), -1)
        XCTAssertEqual(errno, ECANCELED)
        tractanda_restore_signals()
        // Reset only the test process cancellation flag, preserving its original handlers.
        XCTAssertEqual(tractanda_start_signals(), 0)
        tractanda_restore_signals()
        let oversized: [UInt8] = [0, 128, 0, 1]
        oversized.withUnsafeBytes { _ = write(writer, $0.baseAddress, $0.count) }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_installer_frame(reader, &bytes, &count), -1)
        XCTAssertEqual(errno, EMSGSIZE)
    }
}
