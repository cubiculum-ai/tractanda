import Foundation
import TractandaCore

struct PeerEnrollmentActivateOptions {
    var connection: ConnectionOptions
    let operationID: String
    let filePath: String
    let targetRoot: String
    let pin: PeerTargetEnrollmentPin
    let custody: PeerEnrollmentTargetCustody
    let ssh: PeerEnrollmentSSHDestination?

    func execute() throws -> Data {
        // Capture only the target envelope before resolving the source connection.
        let input = try PeerEnrollmentTargetOutput.capture(path: filePath)
        let resolved = try connection.resolve()
        return try PeerEnrollmentSupervisor.run(
            connection: resolved,
            operationID: operationID,
            input: input,
            targetRoot: targetRoot,
            pin: pin,
            custody: custody,
            ssh: ssh)
    }
}

/// Parses target activation without reading private input, resolving an account, or connecting.
func peerEnrollmentActivateOptions(
    arguments: [String], options: ConnectionOptions
) throws -> PeerEnrollmentActivateOptions? {
    guard arguments.count >= 3,
        arguments[0] == "peer", arguments[1] == "enrollment", arguments[2] == "activate"
    else { return nil }

    let usage = peerEnrollmentActivateUsage()
    let allowed: Set<String> = [
        "--operation-id", "--file", "--root", "--source-replica", "--bootstrap-id",
        "--bootstrap-sha256", "--approval-id", "--approval-sha256", "--target-user",
        "--ssh-host", "--ssh-login", "--ssh-platform",
    ]
    var values: [String: String] = [:]
    var index = 3
    while index < arguments.count {
        let flag = arguments[index]
        guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
            throw usage
        }
        let value = arguments[index + 1]
        guard !value.isEmpty, !value.hasPrefix("--") else { throw usage }
        values[flag] = value
        index += 2
    }

    let required: Set<String> = [
        "--operation-id", "--file", "--root", "--source-replica", "--bootstrap-id",
        "--bootstrap-sha256", "--approval-id", "--approval-sha256",
    ]
    guard required.isSubset(of: Set(values.keys)),
        let operationID = values["--operation-id"], SelfCanonical.isUUIDv1(operationID),
        let filePath = values["--file"], SelfCanonical.isPath(filePath, absolute: false),
        let targetRoot = values["--root"], SelfCanonical.isPath(targetRoot, absolute: true),
        let sourceReplicaID = values["--source-replica"], SelfCanonical.isUUIDv1(sourceReplicaID),
        let bootstrapID = values["--bootstrap-id"], SelfCanonical.isUUIDv1(bootstrapID),
        let bootstrapSHA256 = values["--bootstrap-sha256"], SelfCanonical.isSHA256(bootstrapSHA256),
        let approvalID = values["--approval-id"], SelfCanonical.isUUIDv1(approvalID),
        let approvalSHA256 = values["--approval-sha256"], SelfCanonical.isSHA256(approvalSHA256)
    else { throw usage }

    let custody: PeerEnrollmentTargetCustody
    if let targetUser = values["--target-user"] {
        guard SelfCanonical.isOSUser(targetUser) else { throw usage }
        custody = .existingUser(targetUser)
    } else {
        custody = .current
    }

    let sshFlags: Set<String> = ["--ssh-host", "--ssh-login", "--ssh-platform"]
    let suppliedSSHFlags = sshFlags.intersection(values.keys)
    let ssh: PeerEnrollmentSSHDestination?
    if suppliedSSHFlags.isEmpty {
        ssh = nil
    } else {
        guard suppliedSSHFlags == sshFlags,
            let host = values["--ssh-host"],
            let login = values["--ssh-login"],
            let platformValue = values["--ssh-platform"],
            let platform = PeerEnrollmentSSHPlatform(rawValue: platformValue)
        else { throw usage }
        do {
            ssh = try PeerEnrollmentSSHDestination(host: host, login: login, platform: platform)
        } catch {
            throw usage
        }
    }

    let pin: PeerTargetEnrollmentPin
    do {
        pin = try PeerTargetEnrollmentPin(
            sourceReplicaID: sourceReplicaID,
            bootstrapID: bootstrapID,
            bootstrapSHA256: bootstrapSHA256,
            approvalID: approvalID,
            approvalSHA256: approvalSHA256)
    } catch {
        throw usage
    }

    var connection = options
    connection.startsService = false
    return PeerEnrollmentActivateOptions(
        connection: connection,
        operationID: operationID,
        filePath: filePath,
        targetRoot: targetRoot,
        pin: pin,
        custody: custody,
        ssh: ssh)
}

private enum SelfCanonical {
    static func isUUIDv1(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.version1Components != nil else { return false }
        return uuid.uuidString.lowercased() == value
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func isPath(_ value: String, absolute: Bool) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0)
            && (!absolute || value.hasPrefix("/"))
    }

    static func isOSUser(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value.first != "-" else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}

private func peerEnrollmentActivateUsage() -> TractandaError {
    TractandaError("usage", "Use tractanda [--profile NAME | --socket PATH] peer enrollment activate --operation-id UUID --file PATH --root ABSOLUTE_PATH --source-replica UUID --bootstrap-id UUID --bootstrap-sha256 HEX --approval-id UUID --approval-sha256 HEX [--target-user OS_USER] [--ssh-host HOST --ssh-login OS_USER --ssh-platform macos|linux]. This runs a finite local workflow with the current operating-system identity, or a fixed SSH remote workflow when all three SSH destination flags are supplied. Pins are independent assertions; it never starts a service or provisions accounts.")
}
