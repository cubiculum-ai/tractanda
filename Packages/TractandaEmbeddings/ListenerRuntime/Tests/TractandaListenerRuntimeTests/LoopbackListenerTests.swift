import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import TractandaListenerRuntime

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var values: [String] { lock.withLock { messages } }
}

private enum ProbeError: Error { case missingWaitReport }

private final class CloseWhenRead: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Match the HTTP server's active-close direction after a response.
        context.close(promise: nil)
    }
}

private func waitForReport(_ reports: Reports) async throws {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: .seconds(5))
    while reports.values.isEmpty {
        guard clock.now < limit else { throw ProbeError.missingWaitReport }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func withEventLoop(_ operation: (MultiThreadedEventLoopGroup) async throws -> Void) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        try await operation(group)
        try await group.shutdownGracefully()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func occupiedPort(_ group: MultiThreadedEventLoopGroup) async throws -> any Channel {
    try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in channel.close() }
        .bind(host: "127.0.0.1", port: 0).get()
}

private func bind(_ group: MultiThreadedEventLoopGroup, port: Int, reports: Reports) async throws
    -> any Channel
{
    try await LoopbackListener.bind(
        group: group, port: port,
        childChannelInitializer: { channel in channel.close() },
        report: reports.append)
}

@Test func occupiedForeignListenerWaitsThenBindsWithoutChangingProcess() async throws {
    try await withEventLoop { group in
        let foreign = try await occupiedPort(group)
        let port = try #require(foreign.localAddress?.port)
        let reports = Reports()
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiting = Task { try await bind(group, port: port, reports: reports) }
        do {
            try await waitForReport(reports)
            #expect(foreign.isActive)
            #expect(reports.values.count == 1)
            #expect(reports.values[0].contains("waiting for 127.0.0.1:\(port)"))
            #expect(!reports.values.contains { $0.contains("bound to") })
            try await foreign.close().get()
            let own = try await waiting.value
            #expect(ProcessInfo.processInfo.processIdentifier == pid)
            #expect(own.isActive && own.localAddress?.port == port)
            #expect(reports.values.last?.contains("after waiting") == true)
            try await own.close().get()
        } catch {
            waiting.cancel()
            if let own = try? await waiting.value { try? await own.close().get() }
            try? await foreign.close().get()
            throw error
        }
    }
}

@Test func cancellationWhileBlockedKeepsForeignListenerAndStopsRetries() async throws {
    try await withEventLoop { group in
        let foreign = try await occupiedPort(group)
        let port = try #require(foreign.localAddress?.port)
        let reports = Reports()
        let waiting = Task { try await bind(group, port: port, reports: reports) }
        do {
            try await waitForReport(reports)
            waiting.cancel()
            do {
                let unexpected = try await waiting.value
                try await unexpected.close().get()
                Issue.record("Cancelled bind unexpectedly succeeded")
            } catch is CancellationError {
                #expect(foreign.isActive)
                #expect(!reports.values.contains { $0.contains("bound to") })
            }
            try await foreign.close().get()
        } catch {
            waiting.cancel()
            if let own = try? await waiting.value { try? await own.close().get() }
            try? await foreign.close().get()
            throw error
        }
    }
}

@Test func nonAddressErrorPropagatesWithoutRetry() async throws {
    var attempts = 0
    var reports: [String] = []
    do {
        let _: Int = try await LoopbackListener.retryAddressInUse(
            port: 0,
            operation: {
                attempts += 1
                throw IOError(errnoCode: EACCES, reason: "test refusal")
            },
            report: { reports.append($0) })
        Issue.record("Permission error unexpectedly succeeded")
    } catch let error as IOError {
        #expect(error.errnoCode == EACCES)
        #expect(attempts == 1)
        #expect(reports.isEmpty)
    }
}

@Test func alreadyCancelledDoesNotAttemptBind() async throws {
    let reports = Reports()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let _: Int = try await LoopbackListener.retryAddressInUse(
            port: 0,
            operation: {
                reports.append("unexpected bind")
                return 1
            },
            report: reports.append)
    }
    do {
        try await task.value
        Issue.record("Cancelled operation unexpectedly succeeded")
    } catch is CancellationError {
        #expect(reports.values.isEmpty)
    }
}

@Test func currentListenerCanRestartOnItsOwnPort() async throws {
    try await withEventLoop { group in
        let reports = Reports()
        let first = try await LoopbackListener.bind(
            group: group, port: 0,
            childChannelInitializer: { $0.pipeline.addHandler(CloseWhenRead()) },
            report: reports.append)
        let port = try #require(first.localAddress?.port)
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
        try await client.writeAndFlush(ByteBuffer(string: "probe")).get()
        try await client.closeFuture.get()
        try await first.close().get()
        let second = try await bind(group, port: port, reports: reports)
        #expect(second.isActive && second.localAddress?.port == port)
        #expect(reports.values.isEmpty)
        try await second.close().get()
    }
}

#if os(Linux)
    @Test func legacyNonReusableTimeWaitRecoversWithoutRestart() async throws {
        try await withEventLoop { group in
            let legacy = try await ServerBootstrap(group: group)
                .childChannelInitializer { $0.pipeline.addHandler(CloseWhenRead()) }
                .bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(legacy.localAddress?.port)
            #expect(try await legacy.getOption(ChannelOptions.socketOption(.so_reuseaddr)).get() == 0)
            let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
            try await client.writeAndFlush(ByteBuffer(string: "legacy probe")).get()
            try await client.closeFuture.get()
            try await legacy.close().get()
            let reports = Reports()
            let pid = ProcessInfo.processInfo.processIdentifier
            let waiting = Task { try await bind(group, port: port, reports: reports) }
            do {
                try await waitForReport(reports)
                #expect(!reports.values.contains { $0.contains("bound to") })
                // Let the kernel retire its own TIME_WAIT. No drain, sysctl, killed
                // process, overall wait deadline or artificial port reassignment.
                let listener = try await waiting.value
                #expect(listener.isActive && listener.localAddress?.port == port)
                #expect(ProcessInfo.processInfo.processIdentifier == pid)
                #expect(reports.values.last?.contains("after waiting") == true)
                try await listener.close().get()
            } catch {
                waiting.cancel()
                if let own = try? await waiting.value { try? await own.close().get() }
                throw error
            }
        }
    }
#endif
