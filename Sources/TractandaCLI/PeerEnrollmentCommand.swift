import Foundation
import TractandaCore

enum PeerEnrollmentCommand {
    case pair(preparationPath: String, outputPath: String, sourcePeerID: String, targetPeerID: String,
        sourceIsInitiator: Bool)
    case begin(filePath: String)
    case action(NativePeerEnrollment.Action, operationID: String)
    case exportTarget(operationID: String, outputPath: String)
    case read(operationID: String, descriptorPath: String, offset: Int, maximumBytes: Int, outputPath: String)
}

struct PeerEnrollmentOptions {
    var connection: ConnectionOptions
    var command: PeerEnrollmentCommand

    func execute() throws -> Data {
        switch command {
        case let .pair(preparationPath, outputPath, sourcePeerID, targetPeerID, sourceIsInitiator):
            return try NativePeerEnrollment.createPair(
                preparationPath: preparationPath,
                outputPath: outputPath,
                sourcePeerID: sourcePeerID,
                targetPeerID: targetPeerID,
                sourceIsInitiator: sourceIsInitiator)
        case let .begin(filePath):
            let input = try PeerEnrollmentPairInput.capture(path: filePath)
            let resolved = try connection.resolve()
            return try NativePeerEnrollment.begin(connection: resolved, input: input)
        case let .action(action, operationID):
            return try NativePeerEnrollment.call(
                connection: connection.resolve(), action: action, operationID: operationID)
        case let .exportTarget(operationID, outputPath):
            return try NativePeerEnrollment.exportTarget(
                connection: connection.resolve(), operationID: operationID, outputPath: outputPath)
        case let .read(operationID, descriptorPath, offset, maximumBytes, outputPath):
            return try NativePeerEnrollment.readObject(
                connection: connection.resolve(), operationID: operationID,
                descriptorPath: descriptorPath, offset: offset, maximumBytes: maximumBytes,
                outputPath: outputPath)
        }
    }
}

/// Parses the bounded enrollment commands without touching files or resolving a connection.
func peerEnrollmentOptions(
    arguments: [String], options: ConnectionOptions
) throws -> PeerEnrollmentOptions? {
    guard arguments.count >= 2, arguments[0] == "peer", arguments[1] == "enrollment" else { return nil }
    guard arguments.count >= 3 else { throw peerEnrollmentUsage() }

    let commandName = arguments[2]
    let tail = Array(arguments.dropFirst(3))
    let values: [String: String]
    let command: PeerEnrollmentCommand
    switch commandName {
    case "pair":
        values = try peerEnrollmentValues(tail, allowed: ["--preparation", "--out", "--source-peer", "--target-peer", "--source-role"])
        guard let preparation = values["--preparation"], let output = values["--out"],
            let source = values["--source-peer"], let target = values["--target-peer"],
            let role = values["--source-role"], role == "initiator" || role == "responder"
        else { throw peerEnrollmentUsage() }
        try peerEnrollmentValidatePath(preparation)
        try peerEnrollmentValidatePath(output)
        try peerEnrollmentValidateAlias(source)
        try peerEnrollmentValidateAlias(target)
        command = .pair(preparationPath: preparation, outputPath: output,
            sourcePeerID: source, targetPeerID: target, sourceIsInitiator: role == "initiator")
    case "begin":
        values = try peerEnrollmentValues(tail, allowed: ["--file"])
        guard let file = values["--file"] else { throw peerEnrollmentUsage() }
        try peerEnrollmentValidatePath(file)
        command = .begin(filePath: file)
    case "step", "status", "accept", "register":
        values = try peerEnrollmentValues(tail, allowed: ["--operation-id"])
        guard let operationID = values["--operation-id"], peerEnrollmentIsCanonicalV1(operationID),
            let action = NativePeerEnrollment.Action(rawValue: commandName)
        else { throw peerEnrollmentUsage() }
        command = .action(action, operationID: operationID)
    case "export-target":
        values = try peerEnrollmentValues(tail, allowed: ["--operation-id", "--out"])
        guard let operationID = values["--operation-id"], peerEnrollmentIsCanonicalV1(operationID),
            let output = values["--out"]
        else { throw peerEnrollmentUsage() }
        try peerEnrollmentValidatePath(output)
        command = .exportTarget(operationID: operationID, outputPath: output)
    case "read":
        values = try peerEnrollmentValues(tail, allowed: ["--operation-id", "--descriptor", "--offset", "--maximum-bytes", "--out"],
            optional: ["--maximum-bytes"])
        guard let operationID = values["--operation-id"], peerEnrollmentIsCanonicalV1(operationID),
            let descriptor = values["--descriptor"], let offsetText = values["--offset"],
            let offset = Int(offsetText), offset >= 0, let output = values["--out"]
        else { throw peerEnrollmentUsage() }
        let maximumBytes: Int
        if let maximumText = values["--maximum-bytes"] {
            guard let parsed = Int(maximumText), (1...1_048_576).contains(parsed) else {
                throw peerEnrollmentUsage()
            }
            maximumBytes = parsed
        } else {
            maximumBytes = 1_048_576
        }
        try peerEnrollmentValidatePath(descriptor)
        try peerEnrollmentValidatePath(output)
        command = .read(operationID: operationID, descriptorPath: descriptor, offset: offset,
            maximumBytes: maximumBytes, outputPath: output)
    default:
        throw peerEnrollmentUsage()
    }

    var connection = options
    connection.startsService = false
    return PeerEnrollmentOptions(connection: connection, command: command)
}

private func peerEnrollmentValues(
    _ arguments: [String], allowed: Set<String>, optional: Set<String> = []
) throws -> [String: String] {
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
            throw peerEnrollmentUsage()
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("--") else { throw peerEnrollmentUsage() }
        values[flag] = value
        index += 2
    }
    guard allowed.subtracting(optional).isSubset(of: Set(values.keys)) else { throw peerEnrollmentUsage() }
    return values
}

private func peerEnrollmentValidatePath(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 4096, !value.utf8.contains(0) else {
        throw peerEnrollmentUsage()
    }
}

private func peerEnrollmentValidateAlias(_ value: String) throws {
    guard !value.isEmpty, value != "local", value.utf8.count <= 256,
        !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw peerEnrollmentUsage() }
}

private func peerEnrollmentIsCanonicalV1(_ value: String) -> Bool {
    guard let uuid = UUID(uuidString: value), uuid.version1Components != nil else { return false }
    return uuid.uuidString.lowercased() == value
}

private func peerEnrollmentUsage() -> TractandaError {
    TractandaError("usage", "Use tractanda [--profile NAME | --socket PATH] peer enrollment pair|begin|step|status|accept|register|export-target|read with the required command options.")
}
