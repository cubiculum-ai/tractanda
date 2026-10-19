import Foundation
import NIOCore
import NIOPosix
import Synchronization
import XCTest

@testable import TractandaCore
@testable import TractandaServer

final class NISTTimeSamplerTests: XCTestCase {
    func testDNSDeadlineDetachesAndBoundsOutstandingLookupsAcrossCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let entered = expectation(description: "lookup started")
        let released = DispatchSemaphore(value: 0)
        let returned = expectation(description: "lookup returned after shutdown")
        let count = Mutex(0)
        let sampler = NISTTimeSampler(
            group: group,
            resolve: { _, port in
                count.withLock { $0 += 1 }
                entered.fulfill()
                _ = released.wait(timeout: .now() + 5)
                returned.fulfill()
                return try SocketAddress(ipAddress: "127.0.0.1", port: port)
            })
        let start = ProcessInfo.processInfo.systemUptime
        let first = Task { try await sampler.sample(configuration: .init(timeout: 0.05)) }
        await fulfillment(of: [entered], timeout: 1)
        do {
            _ = try await first.value
            XCTFail("DNS must share attempt deadline")
        } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        do {
            _ = try await sampler.sample(configuration: .init(timeout: 0.05))
            XCTFail("No overlapping DNS")
        } catch {}
        XCTAssertEqual(count.withLock { $0 }, 1)
        try await group.shutdownGracefully()
        released.signal()
        await fulfillment(of: [returned], timeout: 1)
        // A late resolver completion is safe with no living event loop.
    }

    func testCancellationDuringDNSReturnsBeforeLookupAndAllowsGroupShutdown() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let entered = expectation(description: "lookup started")
        let released = DispatchSemaphore(value: 0)
        let returned = expectation(description: "lookup returned")
        let sampler = NISTTimeSampler(
            group: group,
            resolve: { _, port in
                entered.fulfill()
                _ = released.wait(timeout: .now() + 5)
                returned.fulfill()
                return try SocketAddress(ipAddress: "127.0.0.1", port: port)
            })
        let work = Task { try await sampler.sample(configuration: .init(timeout: 5)) }
        await fulfillment(of: [entered], timeout: 1)
        let start = ProcessInfo.processInfo.systemUptime
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled DNS must not publish a sample")
        } catch {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        try await group.shutdownGracefully()
        released.signal()
        await fulfillment(of: [returned], timeout: 1)
    }

    func testLoopbackSampleUsesActualEndpointAndCancelsSilentUDP() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let instants = Mutex(0)
        let clock = NISTTimeSampler.Clock(
            wall: { 1_700_000_000 + (instants.withLock { $0 } >= 2 ? 0.02 : 0) },
            monotonic: {
                instants.withLock { value in
                    value += 1
                    return value == 1 ? 100 : 100.02
                }
            })
        let handler = Reply()
        let server = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        let sampler = NISTTimeSampler(
            group: group, clock: clock,
            resolve: { _, port in
                try SocketAddress(ipAddress: "127.0.0.1", port: port)
            })
        let sample = try await sampler.sample(configuration: .init(timeout: 1), port: port)
        XCTAssertEqual(sample.offset, 0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(sample.uncertainty, 0.001)
        try await server.close().get()

        let silent = try await DatagramBootstrap(group: group)
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        let silentPort = try XCTUnwrap(silent.localAddress?.port)
        do {
            _ = try await sampler.sample(configuration: .init(timeout: 0.05), port: silentPort)
            XCTFail("No reply")
        } catch {}
        let work = Task { try await sampler.sample(configuration: .init(timeout: 5), port: silentPort) }
        try await Task.sleep(for: .milliseconds(10))
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled UDP")
        } catch {}
        try await silent.close().get()
        try await group.shutdownGracefully()
    }

    func testWrongResolvedEndpointResponseIsRejected() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let rogue = try await DatagramBootstrap(group: group)
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        let handler = Reply(rogue: rogue)
        let server = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        let sampler = NISTTimeSampler(
            group: group,
            resolve: { _, port in
                try SocketAddress(ipAddress: "127.0.0.1", port: port)
            })
        do {
            _ = try await sampler.sample(
                configuration: .init(timeout: 1), port: XCTUnwrap(server.localAddress?.port))
            XCTFail("Different source port must be rejected even with matching nonce")
        } catch {
            if case NISTTimeSampler.Failure.invalidSource = error {
            } else {
                XCTFail("Expected endpoint rejection, got \(error)")
            }
        }
        try await server.close().get()
        try await rogue.close().get()
        try await group.shutdownGracefully()
    }

    func testMonitorIneligibleTicksNeverSampleAndCloseFencesAdmission() async {
        let prepared = expectation(description: "local eligibility queried")
        let calls = Mutex(0)
        let ranges = Mutex<[ClosedRange<Double>]>([])
        let monitor = PeerClockMonitor(
            prepare: { _, _, _ in
                prepared.fulfill()
                return nil
            },
            finish: { _, _, _, _ in XCTFail("Ineligible monitor cannot record") },
            sample: { _ in
                calls.withLock { $0 += 1 }
                return .init(offset: 0, uncertainty: 0)
            },
            now: { 100 },
            draw: { range in
                ranges.withLock { $0.append(range) }
                return range.lowerBound
            })
        await monitor.tick()
        await fulfillment(of: [prepared], timeout: 1)
        await monitor.close()
        await monitor.tick()
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(ranges.withLock { $0 }, [1_800...3_600])
        let running = await monitor.isRunningForTesting()
        XCTAssertFalse(running)
    }

    func testMonitorRecordsSuccessfulEvidenceAndRandomizedNextInterval() async throws {
        let finished = expectation(description: "sample recorded")
        let prepared = Mutex(0)
        let draws = Mutex(0)
        let configuration = PeerClockHealth.Configuration(minimumInterval: 4, maximumInterval: 8)
        let lease = ServiceCoordinator.PeerClockRuntimeLease.forTesting(configuration: configuration)
        let monitor = PeerClockMonitor(
            configuration: configuration,
            prepare: { now, interval, _ in
                XCTAssertEqual(now, 100)
                XCTAssertEqual(interval, 4)
                prepared.withLock { $0 += 1 }
                return lease
            },
            finish: { _, evidence, now, interval in
                XCTAssertEqual(evidence, .init(offset: 0.25, uncertainty: 0.1))
                XCTAssertEqual(now, 100)
                XCTAssertEqual(interval, 8)
                finished.fulfill()
            },
            sample: { _ in .init(offset: 0.25, uncertainty: 0.1) }, now: { 100 },
            draw: { range in
                draws.withLock { value in
                    value += 1
                    return value == 1 ? range.lowerBound : range.upperBound
                }
            })
        await monitor.tick()
        await fulfillment(of: [finished], timeout: 1)
        await monitor.close()
        XCTAssertEqual(prepared.withLock { $0 }, 1)
        XCTAssertEqual(draws.withLock { $0 }, 2)
    }

    func testMonitorSuppressesOverlappingTicksAndCloseCancelsWithoutRecording() async {
        let started = expectation(description: "probe started")
        let cancelled = expectation(description: "probe cancelled")
        let prepares = Mutex(0)
        let records = Mutex(0)
        let lease = ServiceCoordinator.PeerClockRuntimeLease.forTesting(configuration: .init())
        let monitor = PeerClockMonitor(
            prepare: { _, _, _ in
                prepares.withLock { $0 += 1 }
                return lease
            },
            finish: { _, _, _, _ in records.withLock { $0 += 1 } },
            sample: { _ in
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.fulfill() }
                // Even a provider that returns evidence after cancellation cannot publish it.
                return .init(offset: 0, uncertainty: 0)
            })
        await monitor.tick()
        await fulfillment(of: [started], timeout: 1)
        await monitor.tick()
        await monitor.tick()
        XCTAssertEqual(prepares.withLock { $0 }, 1)
        await monitor.close()
        await fulfillment(of: [cancelled], timeout: 1)
        await monitor.tick()
        XCTAssertEqual(records.withLock { $0 }, 0)
        XCTAssertEqual(prepares.withLock { $0 }, 1)
        let running = await monitor.isRunningForTesting()
        XCTAssertFalse(running)
    }

    private final class Reply: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>
        private let rogue: (any Channel)?
        init(rogue: (any Channel)? = nil) { self.rogue = rogue }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let request = unwrapInboundIn(data)
            let bytes = Array(request.data.readableBytesView)
            guard bytes.count == 48 else { return }
            var response = [UInt8](repeating: 0, count: 48)
            response[0] = 0x24
            response[1] = 1
            response.replaceSubrange(24..<32, with: bytes[40..<48])
            let seconds: UInt32 = 3_908_988_800  // Unix 1,700,000,000.
            for index in 0..<4 {
                response[32 + index] = UInt8(truncatingIfNeeded: seconds >> (24 - index * 8))
                response[40 + index] = response[32 + index]
            }
            var buffer = context.channel.allocator.buffer(capacity: 48)
            buffer.writeBytes(response)
            let envelope = AddressedEnvelope(remoteAddress: request.remoteAddress, data: buffer)
            if let rogue {
                rogue.writeAndFlush(envelope, promise: nil)
            } else {
                context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
            }
        }
    }
}
