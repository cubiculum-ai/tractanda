import Foundation
import TractandaCore

extension SetupEngine {
    /// Explicit operator selection only. A package hook never reaches this path and no bootstrap,
    /// credential replacement, ownership rewrite or canonical administrator grant happens here.
    func prepareExplicitReplicaAdoption(
        _ receipt: inout InstallationReceipt,
        storeID: String, replicaID: String, uid: UInt32
    ) throws {
        let store = URL(fileURLWithPath: receipt.store)
        let index = URL(fileURLWithPath: receipt.indexDirectory)
        let runtime = URL(fileURLWithPath: receipt.socket).deletingLastPathComponent()
        guard !exists(runtime) else {
            throw SetupError("A runtime path exists without an owned installation receipt.")
        }
        try requireServiceDirectory(store, uid: uid)
        let mode =
            (try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber)?
            .intValue
        guard !trustedOwnership || mode == 0o700 else {
            throw SetupError("Prepared replica custody must remain private; no permissions were changed.")
        }
        try ensureServiceDirectory(index, uid: uid, mode: 0o700)
        if let packagePreparedVerification {
            try packagePreparedVerification(receipt, storeID, replicaID)
        } else {
            try successful(
                "/usr/bin/sudo",
                [
                    "-n", "-u", roots.platform.serviceUser, "--",
                    packagePayload.appendingPathComponent("bin/tractanda-setup").path,
                    "--verify-prepared-target", store.path, index.path, storeID, replicaID,
                ])
        }
        receipt.preparedStoreID = storeID
        receipt.preparedReplicaID = replicaID
        receipt.initialized = true
        receipt.sampled = false
    }

    func verifySelectedReplicaIdentity(_ receipt: InstallationReceipt, requireUnjoined: Bool = false) throws {
        guard let storeID = receipt.freshTargetStoreID ?? receipt.preparedStoreID,
            let replicaID = receipt.freshTargetReplicaID ?? receipt.preparedReplicaID else { return }
        let root = URL(fileURLWithPath: receipt.store)
        let uid: UInt32
        if trustedOwnership {
            uid = try SystemAccountDirectory().user(named: roots.platform.serviceUser).uid
        } else {
            guard
                let value = try FileManager.default.attributesOfItem(atPath: root.path)[.ownerAccountID]
                    as? NSNumber
            else {
                throw SetupError("Prepared replica ownership is unavailable.")
            }
            uid = value.uint32Value
        }
        if requireUnjoined {
            try ItemStore.verifyUnjoinedPersonalSyncReplicaIdentityForSetup(
                root: root, ownerUID: uid, expectedStoreID: storeID, expectedReplicaID: replicaID)
        } else {
            try ItemStore.verifyPersonalSyncReplicaIdentityForSetup(
                root: root, ownerUID: uid, expectedStoreID: storeID, expectedReplicaID: replicaID)
        }
    }
}
