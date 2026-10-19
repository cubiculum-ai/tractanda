import Foundation
import XCTest
@testable import TractandaCore

final class UUIDHardwareNodeCacheTests: XCTestCase {
    private let hardware = UUIDHardwareNode(
        node: 0x0011_2233_4455, interfaceName: "en0", source: "fixture", isBuiltIn: true)

    func testFailedDiscoveryCanRecoverWithoutRestart() throws {
        let cache = UUIDHardwareNodeCache()
        var attempts = 0
        func discover() throws -> UUIDHardwareNode {
            attempts += 1
            if attempts == 1 { throw TractandaError("uuidNodeUnavailable", "Transient fixture") }
            return hardware
        }
        XCTAssertThrowsError(try cache.current(discover: discover)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "uuidNodeUnavailable")
        }
        XCTAssertEqual(try cache.current(discover: discover).node, hardware.node)
        XCTAssertEqual(attempts, 2)
    }

    func testSuccessfulNodeStaysFixedWhenLaterDiscoveryWouldDifferOrFail() throws {
        let cache = UUIDHardwareNodeCache()
        XCTAssertEqual(try cache.current { hardware }.node, hardware.node)
        var laterDiscoveryCalls = 0
        let selected = try cache.current {
            laterDiscoveryCalls += 1
            throw TractandaError("uuidNodeUnavailable", "Must not rediscover a selected issuer")
        }
        XCTAssertEqual(selected.node, hardware.node)
        XCTAssertEqual(selected.interfaceName, "en0")
        XCTAssertEqual(laterDiscoveryCalls, 0)
    }

    func testConcurrentCallsChooseOneSuccessfulIssuer() throws {
        let cache = UUIDHardwareNodeCache()
        let hardware = hardware
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            do {
                let node = try cache.current {
                    results.discovered()
                    return hardware
                }
                results.append(node.node)
            } catch { results.failed() }
        }
        XCTAssertEqual(results.discoveryCount, 1)
        XCTAssertEqual(results.nodes.count, 100)
        XCTAssertEqual(Set(results.nodes), [hardware.node])
        XCTAssertEqual(results.failureCount, 0)
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var discoveries = 0
        private var values: [UInt64] = []
        private var failures = 0
        func discovered() { lock.lock(); defer { lock.unlock() }; discoveries += 1 }
        func append(_ value: UInt64) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        func failed() { lock.lock(); defer { lock.unlock() }; failures += 1 }
        var discoveryCount: Int { lock.lock(); defer { lock.unlock() }; return discoveries }
        var nodes: [UInt64] { lock.lock(); defer { lock.unlock() }; return values }
        var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }
    }
}
