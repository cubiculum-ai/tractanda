import Foundation
import TractandaCore

struct NativeCredentialRegistrationSession: Sendable {
    let byteCount: Int
    let commit: @Sendable (PeerPrivateCredentialInput) async throws -> Data
    let cancel: @Sendable () async -> Void
}

extension DaemonApplication {
    func beginPrivateCredential(_ data: Data, forUID uid: UInt32, control: PeerExchangeControl) async throws
        -> NativeCredentialRegistrationSession
    {
        let request = try NativePeerCredentialRegistration.Begin.parse(data)
        return try await makePrivateCredentialSession(request, forUID: uid, control: control)
    }
}
