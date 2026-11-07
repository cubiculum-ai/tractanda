import NIOCore
import NIOPosix

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// A busy loopback port is an initialization wait, including when an old helper
/// left a non-reusable TIME_WAIT connection. Keep the loaded model in its owner.
public enum LoopbackListener {
    public static func bind(
        group: any EventLoopGroup,
        port: Int,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>,
        report: @escaping @Sendable (String) -> Void
    ) async throws -> any Channel {
        let channel = try await retryAddressInUse(
            port: port,
            operation: {
                try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .serverChannelOption(ChannelOptions.backlog, value: 16)
                    .childChannelInitializer(childChannelInitializer)
                    .bind(host: "127.0.0.1", port: port)
                    .get()
            },
            report: report)
        do {
            try Task.checkCancellation()
            return channel
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    // Separate from the socket construction so failure classification is tested
    // without a model, and without manufacturing unrelated operating-system faults.
    static func retryAddressInUse<Value>(
        port: Int,
        operation: () async throws -> Value,
        report: (String) -> Void
    ) async throws -> Value {
        var delayMilliseconds = 100
        var hasRetried = false
        let clock = ContinuousClock()
        var lastReport: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                if hasRetried {
                    report(
                        "Embedding listener bound to 127.0.0.1:\(port) after waiting for the occupied port.")
                }
                return value
            } catch let error as IOError where error.errnoCode == EADDRINUSE {
                hasRetried = true
                let now = clock.now
                if lastReport == nil || lastReport!.duration(to: now) >= .seconds(30) {
                    report(
                        "Embedding listener waiting for 127.0.0.1:\(port): address already in use; retrying until the port is free or startup is cancelled."
                    )
                    lastReport = now
                }
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
                delayMilliseconds = min(1_000, delayMilliseconds * 2)
            }
        }
    }
}
