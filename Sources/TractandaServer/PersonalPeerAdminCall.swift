import Foundation
import TractandaCore

/// Native Unix-socket administration only. HTTP/MCP dispatch never installs this route.
struct PersonalPeerAdminCall {
    static let method = "TractandaPeerPersonal/admin"
    let callID: String
    let request: PeerExchangeRequest
    static func parse(_ bytes: Data) throws -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let raw = object["methodCalls"] as? [Any],
            raw.contains(where: { ($0 as? [Any])?.first as? String == method })
        else { return nil }
        guard bytes.count <= 256 * 1024, Set(object.keys) == ["using", "methodCalls"],
            object["using"] as? [String] == [ItemService.capability],
            let calls = raw as? [[Any]], calls.count == 1, calls[0].count == 3,
            calls[0][0] as? String == method, let arguments = calls[0][1] as? [String: Any],
            let id = calls[0][2] as? String, !id.isEmpty, id.utf8.count <= 128,
            !id.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
        else {
            throw TractandaError(
                "invalidArguments", "Use one bounded native personal peer administration call.")
        }
        let input = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        // Native envelopes permit ordinary JSON whitespace/escaping. Canonical peer-wire
        // byte equality applies to TLS frames, not to this already parsed local envelope.
        let request = try JSON.decode(PeerExchangeRequest.self, input)
        guard Set(arguments.keys) == ["operation", "fields"], request.operation.utf8.count <= 128 else {
            throw TractandaError("invalidArguments", "Unknown personal administration fields.")
        }
        return Self(callID: id, request: request)
    }
    func response(_ bytes: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        let result = try JSONSerialization.data(
            withJSONObject: ["methodResponses": [[Self.method, object, callID]]], options: [.sortedKeys])
        guard result.count <= 256 * 1024 else {
            throw TractandaError("resourceLimit", "Personal administration response exceeds its bound.")
        }
        return result
    }
    func failure(_ error: any Error) -> Data {
        let failure =
            error as? TractandaError
            ?? TractandaError("peerAdministrationFailed", "Personal peer administration failed.")
        return
            (try? JSONSerialization.data(
                withJSONObject: [
                    "methodResponses": [
                        [
                            "error",
                            [
                                "type": failure.code,
                                "description": failure.message,
                            ], callID,
                        ]
                    ]
                ], options: [.sortedKeys])) ?? Data()
    }
}
