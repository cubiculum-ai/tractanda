import Foundation
import NIOCore
import NIOPosix
import Synchronization
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class PeerResolutionCompletion: Sendable {
    let promise: EventLoopPromise<[SocketAddress]>
    private let finished = Mutex(false)
    init(loop: any EventLoop) { promise = loop.makePromise() }
    func complete(_ result: Result<[SocketAddress], Error>) {
        let first = finished.withLock { done in
            guard !done else { return false }
            done = true
            return true
        }
        if first { promise.completeWith(result) }
    }
}

/// One owned libc lookup, no queued lookups. Caller timeout never frees the underlying slot.
/// libc lookup cannot safely be interrupted: graceful close waits for that one actual return.
package actor PeerNameResolver {
    private let pool: NIOThreadPool
    private let loop: any EventLoop
    private let resolveAddress: @Sendable (String, Int) throws -> [SocketAddress]
    private var active: (UUID, EventLoopFuture<[SocketAddress]>, PeerResolutionCompletion)?
    private var stopped = false
    private var closing: Task<Void, Error>?
    package init(
        loop: any EventLoop,
        resolving: (@Sendable (String, Int) throws -> [SocketAddress])? = nil
    ) {
        self.loop = loop
        resolveAddress = resolving ?? { try Self.addresses(host: $0, port: $1) }
        pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
    }
    package func resolve(host: String, port: Int, seconds: Double) async throws -> [SocketAddress] {
        guard !stopped else { throw TractandaError("serviceClosed", "Peer resolver is closed.") }
        if let numeric = try? SocketAddress(ipAddress: host, port: port) { return [numeric] }
        guard active == nil else {
            throw TractandaError("serviceBusy", "A peer hostname lookup is still outstanding.")
        }
        guard seconds.isFinite, seconds > 0, seconds <= 60 else {
            throw TractandaError("deadlineExceeded", "Peer lookup deadline expired.")
        }
        try Task.checkCancellation()
        let id = UUID()
        let completion = PeerResolutionCompletion(loop: loop)
        let resolveAddress = resolveAddress
        let future = pool.runIfActive(eventLoop: loop) { try resolveAddress(host, port) }
        active = (id, future, completion)
        let deadline = loop.scheduleTask(in: .nanoseconds(Int64(seconds * 1_000_000_000))) {
            completion.complete(
                .failure(TractandaError("deadlineExceeded", "Peer hostname lookup timed out.")))
        }
        future.whenComplete { [self] result in
            deadline.cancel()
            completion.complete(result)
            Task { await finished(id) }
        }
        return try await withTaskCancellationHandler {
            let addresses = try await completion.promise.futureResult.get()
            try Task.checkCancellation()
            let bounded = Self.boundedAddresses(addresses)
            guard !bounded.isEmpty else {
                throw TractandaError("resourceLimit", "Peer lookup returned no usable bounded addresses.")
            }
            return bounded
        } onCancel: {
            completion.complete(.failure(TractandaError("cancelled", "Peer hostname lookup cancelled.")))
        }
    }
    private static func boundedAddresses(_ input: [SocketAddress]) -> [SocketAddress] {
        var output: [SocketAddress] = []
        for address in input.prefix(64) where !output.contains(address) {
            if output.count < 16 {
                output.append(address)
            } else if !output.contains(where: { $0.protocolFamily == address.protocolFamily }) {
                // Keep OS order among retained entries while reserving a fallback in the other family.
                output.removeLast()
                output.append(address)
            }
        }
        return output
    }
    /// A single system lookup; copy at most sixty-four TCP rows and inspect at most
    /// sixty-four rows. Keep OS order so both address families remain available for fallback.
    private static func addresses(host: String, port: Int) throws -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
            hints.ai_socktype = SOCK_STREAM
        #else
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else {
            throw TractandaError("connectionFailed", "Peer hostname lookup failed.")
        }
        defer { if let result { freeaddrinfo(result) } }
        var cursor = result
        var addresses: [SocketAddress] = []
        var inspected = 0
        while let row = cursor, inspected < 64 {
            inspected += 1
            cursor = row.pointee.ai_next
            guard let raw = row.pointee.ai_addr else { continue }
            let address: SocketAddress
            if row.pointee.ai_family == AF_INET, Int(row.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size
            {
                address = SocketAddress(UnsafeRawPointer(raw).load(as: sockaddr_in.self), host: host)
            } else if row.pointee.ai_family == AF_INET6,
                Int(row.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in6>.size
            {
                address = SocketAddress(UnsafeRawPointer(raw).load(as: sockaddr_in6.self), host: host)
            } else {
                continue
            }
            if !addresses.contains(address) { addresses.append(address) }
        }
        guard !addresses.isEmpty else {
            throw TractandaError("connectionFailed", "Peer lookup has no TCP address.")
        }
        return addresses
    }
    private func finished(_ id: UUID) {
        if active?.0 == id { active = nil }
    }
    package func close() async throws {
        if let closing { return try await closing.value }
        stopped = true
        active?.2.complete(.failure(TractandaError("cancelled", "Peer resolver stopped.")))
        let work = active?.1
        let pool = pool
        let task = Task {
            if let work { _ = try? await work.get() }
            try await pool.shutdownGracefully()
        }
        closing = task
        try await task.value
        active = nil
    }
    package func isResolvingForTesting() -> Bool { active != nil }
}
