import Dispatch
import Foundation

/// Owns the one mutable store/service pair used by all transports. Every operation runs on
/// a private serial GCD queue so SQLite and filesystem work never occupies a Swift executor.
/// Closures submitted to this type must not suspend while ItemStore has an access context.
public actor ServiceCoordinator {
    private let core: CoreBox
    private var accepting = true
    private var pending = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private static let maximumPending = 64

    /// Opens one exclusive store writer outside the cooperative executor.
    public init(
        opening root: URL,
        indexDirectory: URL? = nil,
        makeAccountDirectory: @escaping @Sendable () -> any AccountDirectory = { SystemAccountDirectory() }
    ) async throws {
        core = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try CoreBox(
                            root: root, indexDirectory: indexDirectory, accounts: makeAccountDirectory()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The UID is authenticated by the in-process transport and never read from request bytes.
    public func handle(_ request: Data, forUID uid: UInt32) async throws -> Data {
        try beginWork()
        defer { finishWork() }
        return try await submit { service in service.handle(request, peerUID: uid) }
    }

    public func accountIdentity(forUID uid: UInt32) async throws -> AccountIdentity {
        try beginWork()
        defer { finishWork() }
        return try await submit { service in try service.store.accountIdentity(forUID: uid) }
    }

    /// Startup metadata for the trusted listener, without impersonating a client account.
    public func localSocketPermissions() async throws -> UInt32 {
        try beginWork()
        defer { finishWork() }
        return try await submit { service in service.store.isMultiUser ? 0o666 : 0o600 }
    }

    /// Derived semantic work has no client identity and runs only between request scopes.
    public func maintain() async throws {
        try beginWork()
        defer { finishWork() }
        _ = try await submit { service in
            service.maintainSemanticIndex()
            return ()
        }
    }

    /// Stops future admission, drains already accepted queue entries, and releases the writer lock.
    public func close() async {
        guard accepting else { return }
        accepting = false
        while pending > 0 {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
        await core.close()
    }

    private func beginWork() throws {
        guard accepting else { throw TractandaError("serviceClosed", "The shared service is closed.") }
        guard pending < Self.maximumPending else {
            throw TractandaError("serviceBusy", "The shared service request queue is full.")
        }
        pending += 1
    }

    private func finishWork() {
        pending -= 1
        guard pending == 0 else { return }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func submit<T: Sendable>(_ body: @escaping @Sendable (ItemService) throws -> T) async throws -> T
    {
        try await core.submit(body)
    }
}

/// The only unchecked boundary. ItemService and ItemStore never leave `queue`.
private final class CoreBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tractanda.service-coordinator")
    private var service: ItemService?

    init(root: URL, indexDirectory: URL?, accounts: any AccountDirectory) throws {
        service = ItemService(
            store: try ItemStore(
                root: root, indexDirectory: indexDirectory, accounts: accounts))
    }

    func submit<T: Sendable>(_ body: @escaping @Sendable (ItemService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let service else {
                    continuation.resume(
                        throwing: TractandaError("serviceClosed", "The shared service is closed."))
                    return
                }
                do {
                    continuation.resume(returning: try body(service))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                service = nil
                continuation.resume()
            }
        }
    }
}
