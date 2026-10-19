import Foundation
import TractandaCore

struct PeerTargetActivationArguments {
    let root: String
    let pin: PeerTargetEnrollmentPin

    static let usage = """
        Usage: tractanda-setup --activate-peer-target-stdio ROOT SOURCE_REPLICA_UUID BOOTSTRAP_UUID BOOTSTRAP_SHA256 APPROVAL_UUID APPROVAL_SHA256
        Runs a finite target helper as the existing non-root custodian. Private enrollment data uses binary standard input/output; public trust pins are supplied separately. Ordinary commands do not start or enroll peers.
        """

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.first == "--activate-peer-target-stdio" else { return nil }
        guard arguments.count == 7 else { throw SetupError(usage) }
        let root = arguments[1]
        let sourceReplicaID = arguments[2]
        let bootstrapID = arguments[3]
        let bootstrapSHA256 = arguments[4]
        let approvalID = arguments[5]
        let approvalSHA256 = arguments[6]
        guard !root.hasPrefix("--"), root.hasPrefix("/"), root.utf8.count <= 4096,
            !root.utf8.contains(0),
            ![sourceReplicaID, bootstrapID, bootstrapSHA256, approvalID, approvalSHA256]
                .contains(where: { $0.hasPrefix("--") }),
            Self.isCanonicalV1(sourceReplicaID), Self.isCanonicalV1(bootstrapID),
            Self.isCanonicalV1(approvalID), Self.isLowercaseSHA256(bootstrapSHA256),
            Self.isLowercaseSHA256(approvalSHA256)
        else { throw SetupError(usage) }
        do {
            let pin = try PeerTargetEnrollmentPin(
                sourceReplicaID: sourceReplicaID,
                bootstrapID: bootstrapID,
                bootstrapSHA256: bootstrapSHA256,
                approvalID: approvalID,
                approvalSHA256: approvalSHA256)
            return Self(root: root, pin: pin)
        } catch {
            throw SetupError(usage)
        }
    }

    private static func isCanonicalV1(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.version1Components != nil else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
