import Foundation
import TractandaCore
import TractandaPeerTransport

/// Supplied once by the daemon's enrollment owner. Every admission remains an actual
/// current/exact-job domain check; this bridge creates no administrator or data grant.
struct PersonalEnrollmentRuntimeBridge: Sendable {
    let material: @Sendable () async throws -> PersonalEnrollmentRuntimeMaterial
    let validate: @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose) async throws -> Void
    let handle:
        @Sendable (PeerExchangeBinding, PersonalEnrollmentTransportPurpose, PeerExchangeRequest) async throws
            -> Data
    let completedCut: @Sendable (PeerExchangeBinding, PersonalSyncReport) async -> Void
}

/// Operation-local cancellation closes only its actual dial/request, never an unrelated
/// healthy transfer. It contains no authority and never enters serialized job state.
final class PersonalEnrollmentRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [@Sendable () -> Void] = []
    func add(_ action: @escaping @Sendable () -> Void) {
        let invoke = lock.withLock {
            if cancelled { return true }
            actions.append(action)
            return false
        }
        if invoke { action() }
    }
    func attach(_ connection: PersonalPeerConnection) { add { _ = connection.close() } }
    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let result = actions
            actions = []
            return result
        }
        for action in pending { action() }
    }
}
