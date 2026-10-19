import Foundation
import TractandaCore

/// Recognized only from DaemonApplication.native; generic HTTP/MCP method dispatch has no route.
struct PeerOperatorStatusNativeCall {
    let callID: String
    static func parse(_ data: Data) throws -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawCalls = object["methodCalls"] as? [Any],
            rawCalls.contains(where: { ($0 as? [Any])?.first as? String == PeerOperatorStatus.nativeMethod }) else { return nil }
        guard let calls = rawCalls as? [[Any]], data.count <= 8192, Set(object.keys) == ["using", "methodCalls"],
            object["using"] as? [String] == [ItemService.capability], calls.count == 1,
            calls[0].count == 3, calls[0][0] as? String == PeerOperatorStatus.nativeMethod,
            let arguments = calls[0][1] as? [String: Any], arguments.isEmpty,
            let id = calls[0][2] as? String, !id.isEmpty, id.utf8.count <= 128,
            !id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else {
            throw TractandaError("invalidArguments", "Use one native peer status call with empty arguments.")
        }
        return Self(callID: id)
    }
    func response(_ status: PeerOperatorStatus) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: JSON.encode(status))
        let data = try JSONSerialization.data(withJSONObject: ["methodResponses": [[PeerOperatorStatus.nativeMethod, value, callID]]],
            options: [.sortedKeys])
        guard data.count <= 16 * 1024 else { throw TractandaError("resourceLimit", "Peer status response exceeds its bound.") }
        return data
    }
    func failure(_ error: any Error) -> Data {
        let code: String
        if error is CancellationError { code = "cancelled" }
        else if let failure = error as? TractandaError,
            ["forbidden", "serviceBusy", "serviceClosed", "resourceLimit", "recoveryRequired", "authorityBootstrapRequired"].contains(failure.code) {
            code = failure.code
        } else { code = "peerStatusUnavailable" }
        return (try? JSONSerialization.data(withJSONObject: ["methodResponses": [["error", [
            "type": code, "description": "Peer status is unavailable for this caller or current store state."
        ], callID]]], options: [.sortedKeys])) ?? Data()
    }
}
