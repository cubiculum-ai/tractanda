import Foundation
import TractandaCore

/// Recognized only from DaemonApplication.native; generic HTTP/MCP method dispatch has no route.
struct PeerOperatorStatusNativeCall {
    let callID: String
    static func parse(_ call: NativeMethodInvocation) throws -> Self? {
        guard call.method == PeerOperatorStatus.nativeMethod else { return nil }
        guard call.callCount == 1, call.arguments.members?.isEmpty == true else {
            throw TractandaError(
                "invalidArguments", "Use one native peer status invocation with empty arguments.")
        }
        return Self(callID: call.callID)
    }
    func response(_ status: PeerOperatorStatus) throws -> NativeMethodOutcome {
        guard try status.encoded().count <= PeerOperatorStatus.maximumResponseBytes else {
            throw TractandaError("resourceLimit", "Peer status response exceeds its bound.")
        }
        return try .nativeEncodedSuccess(PeerOperatorStatus.nativeMethod, status)
    }
    func failure(_ error: any Error) -> NativeMethodOutcome {
        let code: String
        if error is CancellationError {
            code = "cancelled"
        } else if let failure = error as? TractandaError,
            [
                "forbidden", "serviceBusy", "serviceClosed", "resourceLimit", "recoveryRequired",
                "authorityBootstrapRequired",
            ].contains(failure.code)
        {
            code = failure.code
        } else {
            code = "peerStatusUnavailable"
        }
        return .failure(
            .init(code, description: "Peer status is unavailable for this caller or current store state."),
            effects: .none)
    }
}
