import Foundation

/// Exact native JSON result unwrapping. Codable preserves arbitrary strings, including a
/// leading or sole U+FEFF; Foundation JSONSerialization can normalize that string away.
public enum NativeMethodResult {
    public static func unwrap(_ response: Data, method: String, callID: String = "client") throws -> Data {
        guard response.count <= ItemClient.maximumMessageBytes else {
            throw TractandaError("responseLimit", "Native response exceeds its message limit.")
        }
        let value: Value
        do { value = try JSON.decode(Value.self, response) } catch {
            throw TractandaError("protocolError", "Invalid native response.")
        }
        guard case .object(let envelope) = value else {
            throw TractandaError("protocolError", "Invalid native response.")
        }
        if case .string(let code)? = envelope["code"] {
            let message: String
            if case .string(let text)? = envelope["message"] { message = text } else { message = "" }
            throw TractandaError(code, message)
        }
        guard case .array(let calls)? = envelope["methodResponses"], calls.count == 1,
            case .array(let call) = calls[0], call.count == 3,
            case .string(let identity) = call[2], identity == callID,
            case .string(let returnedMethod) = call[0], case .object(let result) = call[1]
        else { throw TractandaError("protocolError", "Missing native method response.") }
        if returnedMethod == "error" {
            let code: String
            let description: String
            if case .string(let type)? = result["type"] { code = type } else { code = "error" }
            if case .string(let text)? = result["description"] {
                description = text
            } else {
                description = ""
            }
            throw TractandaError(code, description)
        }
        guard returnedMethod == method else {
            throw TractandaError("protocolError", "Unexpected native method result.")
        }
        return try JSON.encode(call[1])
    }

    private indirect enum Value: Codable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case integer(Int64)
        case unsigned(UInt64)
        case real(Double)
        case boolean(Bool)
        case null

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .null
            } else if let decoded = try? value.decode(Bool.self) {
                self = .boolean(decoded)
            } else if let decoded = try? value.decode(String.self) {
                self = .string(decoded)
            } else if let decoded = try? value.decode(Int64.self) {
                self = .integer(decoded)
            } else if let decoded = try? value.decode(UInt64.self) {
                self = .unsigned(decoded)
            } else if let decoded = try? value.decode(Double.self) {
                self = .real(decoded)
            } else if let decoded = try? value.decode([Value].self) {
                self = .array(decoded)
            } else {
                self = .object(try value.decode([String: Value].self))
            }
        }
        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .object(let object): try value.encode(object)
            case .array(let array): try value.encode(array)
            case .string(let string): try value.encode(string)
            case .integer(let integer): try value.encode(integer)
            case .unsigned(let unsigned): try value.encode(unsigned)
            case .real(let real): try value.encode(real)
            case .boolean(let boolean): try value.encode(boolean)
            case .null: try value.encodeNil()
            }
        }
    }
}
