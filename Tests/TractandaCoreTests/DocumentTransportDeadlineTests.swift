import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class DocumentTransportDeadlineTests: XCTestCase {
    func testOnlySingleDocumentExtractionSelectsLongResponseWait() throws {
        func request(_ methods: [String]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability],
                "methodCalls": methods.map { [$0, [:], "call"] as [Any] },
            ])
        }
        XCTAssertEqual(
            LocalTransport.responseTimeoutMilliseconds(
                for: try request(["TractandaAttachment/extractDocument"])), 390_000)
        for methods in [
            ["TractandaStore/info"], ["TractandaAttachment/document"],
            ["TractandaAttachment/extractText"],
            ["TractandaAttachment/extractDocument", "TractandaStore/info"],
        ] {
            XCTAssertEqual(LocalTransport.responseTimeoutMilliseconds(for: try request(methods)), 15_000)
        }
        XCTAssertEqual(LocalTransport.responseTimeoutMilliseconds(for: Data("invalid".utf8)), 15_000)
    }

    func testReceiveOptionLeavesSendAloneAndShortInjectedWaitExpires() throws {
        var pair: [Int32] = [0, 0]
        #if canImport(Darwin)
            let kind = SOCK_STREAM
        #else
            let kind = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, kind, 0, &pair), 0)
        defer {
            _ = close(pair[0])
            _ = close(pair[1])
        }
        var sendBefore = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, SO_SNDTIMEO, &sendBefore, &length), 0)
        XCTAssertEqual(tractanda_socket_receive_timeout(pair[0], 100), 0)
        var receive = timeval()
        var sendAfter = timeval()
        length = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, SO_RCVTIMEO, &receive, &length), 0)
        XCTAssertEqual(receive.tv_sec, 0)
        XCTAssertGreaterThanOrEqual(receive.tv_usec, 100_000)
        XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, SO_SNDTIMEO, &sendAfter, &length), 0)
        XCTAssertEqual(sendBefore.tv_sec, sendAfter.tv_sec)
        XCTAssertEqual(sendBefore.tv_usec, sendAfter.tv_usec)
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let started = ContinuousClock.now
        XCTAssertEqual(tractanda_receive_frame(pair[0], &pointer, &count), -1)
        XCTAssertNil(pointer)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(tractanda_socket_receive_timeout(pair[0], 390_000), 0)
        XCTAssertEqual(tractanda_socket_receive_timeout(pair[0], 0), -1)
        XCTAssertEqual(tractanda_socket_receive_timeout(pair[0], 390_001), -1)
    }
}
