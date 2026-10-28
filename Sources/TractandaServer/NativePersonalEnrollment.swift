import Foundation
import TractandaCore

struct NativePersonalEnrollmentSession: Sendable {
    let byteCount: Int
    let commit: @Sendable (Data) async throws -> Data
    let cancel: @Sendable () async -> Void
    let control: PeerExchangeControl
}

extension DaemonApplication {
    func beginPrivatePersonalEnrollment(_ data: Data, forUID uid: UInt32, control: PeerExchangeControl) async throws
        -> NativePersonalEnrollmentSession {
        try await makePrivatePersonalEnrollmentSession(NativePersonalEnrollment.Begin.parse(data), forUID: uid, control: control)
    }
}
