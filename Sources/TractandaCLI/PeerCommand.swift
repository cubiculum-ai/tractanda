import Foundation
import TractandaCore

struct PeerCredentialRegistrationOptions {
    var connection: ConnectionOptions
    var filePath: String
    var permittedOrigins: [String]
    var operationID: String
}

/// Parses a bounded, explicit credential-registration request without opening a connection.
func peerCredentialRegistrationOptions(
    arguments: [String], options: ConnectionOptions
) throws -> PeerCredentialRegistrationOptions? {
    guard arguments.first == "peer", arguments.dropFirst().first == "credential" else { return nil }
    guard arguments.count >= 3, arguments[2] == "register" else {
        throw TractandaError(
            "usage",
            "Use tractanda [--profile NAME | --socket PATH] peer credential register --file PATH --origin UUID [--origin UUID...] --operation-id UUID."
        )
    }

    var filePath: String?
    var operationID: String?
    var origins: [String] = []
    var seenOrigins = Set<String>()
    var index = 3
    while index < arguments.count {
        let flag = arguments[index]
        guard index + 1 < arguments.count else {
            throw TractandaError("usage", "Missing value for \(flag).")
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("--") else {
            throw TractandaError("usage", "Missing value for \(flag).")
        }
        switch flag {
        case "--file":
            guard filePath == nil else { throw TractandaError("usage", "Duplicate --file.") }
            filePath = value
        case "--operation-id":
            guard operationID == nil else { throw TractandaError("usage", "Duplicate --operation-id.") }
            operationID = value
        case "--origin":
            guard origins.count < 256, let uuid = UUID(uuidString: value),
                uuid.version1Components != nil, uuid.uuidString.lowercased() == value,
                seenOrigins.insert(value).inserted
            else {
                throw TractandaError(
                    "usage",
                    "Each --origin must be a unique canonical lowercase UUIDv1; at most 256 are allowed.")
            }
            origins.append(value)
        default:
            throw TractandaError("usage", "Unknown peer credential option: \(flag).")
        }
        index += 2
    }

    guard let filePath, let operationID, !origins.isEmpty,
        let operationUUID = UUID(uuidString: operationID),
        operationUUID.version1Components != nil,
        operationUUID.uuidString.lowercased() == operationID
    else {
        throw TractandaError(
            "usage",
            "Use tractanda [--profile NAME | --socket PATH] peer credential register --file PATH --origin UUID [--origin UUID...] --operation-id UUID."
        )
    }

    var connection = options
    connection.startsService = false
    return PeerCredentialRegistrationOptions(
        connection: connection,
        filePath: filePath,
        permittedOrigins: origins.sorted(),
        operationID: operationID)
}

/// Peer status deliberately never auto-starts a daemon or opens/initializes a Store.
func peerStatusOptions(arguments: [String], options: ConnectionOptions) throws -> ConnectionOptions? {
    guard arguments.first == "peer" else { return nil }
    guard arguments == ["peer", "status"] else {
        throw TractandaError("usage", "Use tractanda [--profile NAME | --socket PATH] peer status.")
    }
    var result = options
    result.startsService = false
    return result
}
