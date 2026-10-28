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
    func testConnectedWaitPreservesPartialFrameAcrossBoundedReadTimeouts() throws {
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
        XCTAssertEqual(tractanda_receive_connected_frame(reader, &bytes, &count), 0)
        if let bytes {
            XCTAssertEqual(Data(bytes: bytes, count: Int(count)), Data([1, 2, 3]))
            tractanda_free(bytes)
        }
        wait(for: [completed], timeout: 2)
    }
    func testConnectedZeroLengthFrameIsRejected() throws {
        let (reader, writer) = try sockets()
        defer {
            _ = close(reader)
            _ = close(writer)
        }
        let emptyHeader: [UInt8] = [0, 0, 0, 0]
        emptyHeader.withUnsafeBytes { _ = write(writer, $0.baseAddress, $0.count) }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_connected_frame(reader, &bytes, &count), -1)
        XCTAssertEqual(errno, EMSGSIZE)
        XCTAssertNil(bytes)
    }
    func testConnectedSendRetainsPartialBodyAcrossBackpressure() throws {
        let (writer, reader) = try sockets()
        defer { _ = close(writer) }
        var timeout = timeval(tv_sec: 0, tv_usec: 20_000)
        XCTAssertEqual(
            setsockopt(
                writer, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                socklen_t(MemoryLayout.size(ofValue: timeout))), 0)
        var smallBuffer: Int32 = 4096
        XCTAssertEqual(
            setsockopt(
                writer, SOL_SOCKET, SO_SNDBUF, &smallBuffer,
                socklen_t(MemoryLayout.size(ofValue: smallBuffer))), 0)
        let body = Data(repeating: 37, count: 256 * 1024)
        let completed = expectation(description: "slow reader completed")
        DispatchQueue.global().async {
            defer {
                _ = close(reader)
                completed.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.12)
            var bytes: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            XCTAssertEqual(tractanda_receive_connected_frame(reader, &bytes, &count), 0)
            if let bytes {
                XCTAssertEqual(Data(bytes: bytes, count: Int(count)), body)
                tractanda_free(bytes)
            }
        }
        XCTAssertEqual(
            body.withUnsafeBytes {
                tractanda_send_connected_frame(writer, $0.baseAddress, UInt32($0.count))
            }, 0)
        wait(for: [completed], timeout: 2)
    }
    func testExplicitBoundedResponseStillTimesOutAndConnectedEOFStillFails() throws {
        let (reader, writer) = try sockets()
        defer { _ = close(reader) }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_frame(reader, &bytes, &count), -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
        _ = close(writer)
        XCTAssertEqual(tractanda_receive_connected_frame(reader, &bytes, &count), -1)
        XCTAssertEqual(errno, ECONNRESET)
    }
    func testConnectedCancellationAndFrameLimitRemainEnforced() throws {
        let (reader, writer) = try sockets()
        defer {
            _ = close(reader)
            _ = close(writer)
        }
        XCTAssertEqual(tractanda_start_signals(), 0)
        _ = kill(getpid(), SIGTERM)
        var cancelledBytes: UnsafeMutableRawPointer?
        var cancelledCount: UInt32 = 0
        XCTAssertEqual(tractanda_receive_connected_frame(reader, &cancelledBytes, &cancelledCount), -1)
        XCTAssertEqual(errno, ECANCELED)
        let body: [UInt8] = [1]
        XCTAssertEqual(
            body.withUnsafeBytes {
                tractanda_send_connected_frame(writer, $0.baseAddress, UInt32($0.count))
            }, -1)
        XCTAssertEqual(errno, ECANCELED)
        tractanda_restore_signals()
        // Reset only the test process cancellation flag, preserving its original handlers.
        XCTAssertEqual(tractanda_start_signals(), 0)
        tractanda_restore_signals()
        let oversized: [UInt8] = [0, 128, 0, 1]
        oversized.withUnsafeBytes { _ = write(writer, $0.baseAddress, $0.count) }
        var bytes: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_receive_connected_frame(reader, &bytes, &count), -1)
        XCTAssertEqual(errno, EMSGSIZE)
    }
}
