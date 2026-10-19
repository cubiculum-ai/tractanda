import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

final class PeerNameResolverTests: XCTestCase {
    func testTimedOutLookupRetainsActualSlotAndCloseWaitsForCompletion() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let entered = expectation(description: "actual resolver entered")
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        let resolver = PeerNameResolver(loop: group.next()) { _, _ in
            calls.withLock { $0 += 1 }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [address]
        }
        defer {
            release.signal()
            try? await resolver.close()
        }
        let lookup = Task { try await resolver.resolve(host: "held.example", port: 1234, seconds: 0.03) }
        await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await lookup.value
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "deadlineExceeded") }
        let held = await resolver.isResolvingForTesting()
        XCTAssertTrue(held)
        for _ in 0..<5 {
            do {
                _ = try await resolver.resolve(host: "retry.example", port: 1234, seconds: 1)
                XCTFail("Expected held slot")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
        }
        // Literal addresses never queue a second libc job, including while the DNS slot is held.
        let literal = try await resolver.resolve(host: "::1", port: 1234, seconds: 1)
        XCTAssertEqual(literal, [try SocketAddress(ipAddress: "::1", port: 1234)])
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let closed = Mutex(false)
        let closing = Task {
            try await resolver.close()
            closed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(closed.withLock { $0 })
        release.signal()
        try await closing.value
        XCTAssertTrue(closed.withLock { $0 })
        let stillHeld = await resolver.isResolvingForTesting()
        XCTAssertFalse(stillHeld)
    }

    func testCancelledLookupCannotDeliverLateAddressesOrFreeUnderlyingSlot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let entered = expectation(description: "held cancelled lookup")
        let release = DispatchSemaphore(value: 0)
        let resolver = PeerNameResolver(loop: group.next()) { _, port in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [try SocketAddress(ipAddress: "127.0.0.1", port: port)]
        }
        defer {
            release.signal()
            try? await resolver.close()
        }
        let task = Task { try await resolver.resolve(host: "held.example", port: 1234, seconds: 2) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled caller received addresses")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "cancelled") }
        let held = await resolver.isResolvingForTesting()
        XCTAssertTrue(held)
        do {
            _ = try await resolver.resolve(host: "another.example", port: 1234, seconds: 1)
            XCTFail("Expected held slot")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
        release.signal()
        try await resolver.close()
    }
    func testBoundedLookupRetainsBothFamiliesBeyondFirstSixteenRows() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }
        let ipv6 = try (1...20).map {
            try SocketAddress(ipAddress: "2001:db8::" + String($0, radix: 16), port: 1234)
        }
        let ipv4 = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        let resolver = PeerNameResolver(loop: group.next()) { _, _ in ipv6 + [ipv4] }
        defer { try? await resolver.close() }
        let addresses = try await resolver.resolve(host: "dual.example", port: 1234, seconds: 1)
        XCTAssertEqual(addresses.count, 16)
        XCTAssertEqual(Array(addresses.prefix(15)), Array(ipv6.prefix(15)))
        XCTAssertEqual(addresses.last, ipv4)
    }

}
