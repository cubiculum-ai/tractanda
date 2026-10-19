import CTractandaPlatform
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package enum PeerEnrollmentSSHPlatform: String, Sendable { case macOS = "macos", linux }

/// Public addressing only. An SSH login never supplies source authority or a local UID.
package struct PeerEnrollmentSSHDestination: Sendable {
    package let host: String
    package let login: String
    package let platform: PeerEnrollmentSSHPlatform
    package init(host: String, login: String, platform: PeerEnrollmentSSHPlatform) throws {
        guard PeerEnrollmentSSH.validHost(host), PeerEnrollmentSSH.validUser(login) else {
            throw PeerEnrollmentSupervisor.failure("invalidSSHDestination")
        }
        self.host = host; self.login = login; self.platform = platform
    }
}

package enum PeerEnrollmentSSH {
    static let keyExchange = "mlkem768x25519-sha256,sntrup761x25519-sha512"
    static func validUser(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.hasPrefix("-") && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }
    static func validHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, value.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        if value.contains(":") {
            var address = in6_addr()
            return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        let name = value.hasSuffix(".") ? String(value.dropLast()) : value
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }
    }
    static func quoted(_ value: String) throws -> String {
        guard !value.utf8.contains(0) else { throw PeerEnrollmentSupervisor.failure("invalidSSHDestination") }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func helper(_ platform: PeerEnrollmentSSHPlatform) -> URL {
        URL(fileURLWithPath: platform == .macOS
            ? "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-setup"
            : "/opt/tractanda/current/bin/tractanda-setup")
    }
    static func arguments(destination: PeerEnrollmentSSHDestination, root: String, pin: PeerTargetEnrollmentPin,
        custody: PeerEnrollmentTargetCustody, remainingNanoseconds: UInt64, helperForTesting: URL? = nil) throws -> [String] {
        guard remainingNanoseconds > 0, root.hasPrefix("/"), root.utf8.count <= 4096, !root.utf8.contains(0) else {
            throw PeerEnrollmentSupervisor.failure("invalidSSHDestination")
        }
        // Validate independently even when a caller obtained a pin from another path.
        _ = try pin.value
        let helper = helperForTesting ?? helper(destination.platform)
        if helperForTesting != nil {
            guard tractanda_validate_enrollment_helper(helper.path, 0) == 0 else { throw PeerEnrollmentSupervisor.failure("helperUnavailable") }
        }
        var command = [helper.path, "--activate-peer-target-stdio", root, pin.sourceReplicaID,
            pin.bootstrapID, pin.bootstrapSHA256, pin.approvalID, pin.approvalSHA256]
        if case let .existingUser(user) = custody {
            guard validUser(user), user != "root" else { throw PeerEnrollmentSupervisor.failure("invalidTargetCustody") }
            command = ["/usr/bin/sudo", "-n", "-u", user, "--"] + command
        }
        let remote = try command.map(quoted).joined(separator: " ")
        guard remote.utf8.count <= 4096 else { throw PeerEnrollmentSupervisor.failure("invalidSSHDestination") }
        // Ceil, rather than zero, for a sub-second remainder; the Job still owns the exact deadline.
        let timeout = min(10, 1 + (remainingNanoseconds - 1) / 1_000_000_000)
        return ["-F/dev/null", "-T", "-Snone", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
            "-oUpdateHostKeys=no", "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oCompression=no",
            "-oKexAlgorithms=\(keyExchange)", "-oConnectTimeout=\(timeout)", "-l", destination.login,
            "--", destination.host, remote]
    }
    static func launch(destination: PeerEnrollmentSSHDestination, root: String, pin: PeerTargetEnrollmentPin,
        custody: PeerEnrollmentTargetCustody, job: PeerEnrollmentSupervisor.Job,
        clientForTesting: URL? = nil, helperForTesting: URL? = nil) throws -> PeerEnrollmentSupervisor.Launch {
        try job.check()
        let executable: URL
        if let clientForTesting {
            guard tractanda_validate_enrollment_helper(clientForTesting.path, 0) == 0 else { throw PeerEnrollmentSupervisor.failure("helperUnavailable") }
            executable = clientForTesting
        } else {
            guard helperForTesting == nil, tractanda_validate_enrollment_ssh() == 0 else { throw PeerEnrollmentSupervisor.failure("helperUnavailable") }
            executable = URL(fileURLWithPath: "/usr/bin/ssh")
        }
        let now = try PeerEnrollmentSupervisor.Job.now()
        guard now < job.deadline else { throw PeerEnrollmentSupervisor.failure("deadlineExceeded") }
        return try .init(executable: executable, arguments: arguments(destination: destination, root: root,
            pin: pin, custody: custody, remainingNanoseconds: job.deadline - now, helperForTesting: helperForTesting),
            indirectCustody: true)
    }
}
