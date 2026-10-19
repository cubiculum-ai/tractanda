import CTractandaPlatform
import Foundation
import TractandaCore

/// Finite offline custody only. No Store, listener, canonical caller identity or installer.
enum PeerTargetPreparation {
    static func run(
        root: String, commonStoreID: String, sourceReplicaID: String,
        requiredOwnerUID: UInt32
    ) throws -> Data {
        guard tractanda_uid() == requiredOwnerUID, requiredOwnerUID != 0,
            root.hasPrefix("/"), root.utf8.count <= 4096, !root.utf8.contains(0)
        else {
            throw SetupError(
                "Target preparation must run as its existing unprivileged service account in a private empty directory."
            )
        }
        do {
            let preparation = try PeerEnrollment.prepareTarget(
                root: URL(fileURLWithPath: root),
                commonStoreID: commonStoreID, sourceReplicaID: sourceReplicaID)
            return try JSON.encode(preparation)  // Canonical preparation, no pretty-print/newline mutation.
        } catch {
            let code = (error as? TractandaError)?.code
            let safe: Set<String> = [
                "invalidEnrollmentTarget", "storeBusy", "enrollmentConflict", "identifierCollision",
            ]
            throw TractandaError(
                code.flatMap { safe.contains($0) ? $0 : nil } ?? "invalidEnrollmentTarget",
                "Target preparation failed; existing content was not adopted.")
        }
    }
}
