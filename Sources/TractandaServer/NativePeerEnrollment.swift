import Foundation
import TractandaCore

/// Two fixed enrollment operations, not a general native upload/download capability.
struct NativePeerEnrollmentSession: Sendable {
    let operation: NativePeerEnrollment.PrivateRequest.Operation
    let byteCount: Int
    let commit: @Sendable (Data?) async throws -> Data
    let cancel: @Sendable () async -> Void
    var validateBeforeDelivery: @Sendable () async throws -> Void = {}
    var control: PeerExchangeControl? = nil
}

enum NativePrivateSession: Sendable {
    case credential(NativeCredentialRegistrationSession)
    case enrollment(NativePeerEnrollmentSession)
    var byteCount: Int { switch self { case .credential(let s): s.byteCount; case .enrollment(let s): s.byteCount } }
    var ready: Data { switch self { case .credential: NativePeerCredentialRegistration.ready; case .enrollment: NativePeerEnrollment.ready } }
    var maximumReply: Int {
        switch self {
        case .credential: NativePeerCredentialRegistration.maximumResult
        case .enrollment(let s): s.operation == .exportTarget ? NativePeerEnrollment.maximumTargetOutputBytes : NativePeerEnrollment.maximumMetadata
        }
    }
    var outputOnly: Bool {
        switch self { case .credential: false; case .enrollment(let s): s.operation == .exportTarget }
    }
    func complete(_ data: Data?) async throws -> Data {
        switch self {
        case .credential(let s):
            guard let data else { throw NativePeerCredentialRegistration.protocolFailure() }
            return try await s.commit(PeerPrivateCredentialInput(bytes: data))
        case .enrollment(let s): return try await s.commit(data)
        }
    }
    func validateBeforeDelivery() async throws {
        if case .enrollment(let s) = self { try await s.validateBeforeDelivery(); try s.control?.check() }
    }
    func checkDelivery() throws {
        if case .enrollment(let s) = self { try s.control?.check() }
    }
    func cancel() async { switch self { case .credential(let s): await s.cancel(); case .enrollment(let s): await s.cancel() } }
    func failure(_ error: any Error) -> Data {
        switch self { case .credential: NativePeerCredentialRegistration.failure(error); case .enrollment: NativePeerEnrollment.failure(error) }
    }
}

extension DaemonApplication {
    func beginPrivateEnrollment(_ data: Data, forUID uid: UInt32, control: PeerExchangeControl) async throws -> NativePeerEnrollmentSession {
        try await makePrivateEnrollmentSession(NativePeerEnrollment.PrivateRequest.parse(data), forUID: uid, control: control)
    }
}
