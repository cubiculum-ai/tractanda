import Foundation

/// Host-private resumable references, never wire authority, secrets, bodies or trusted cursors.
package struct PeerSyncWork: Codable, Sendable {
    package struct Transfer: Codable, Sendable {
        package let planID: String
        package let packageID: String
        package let roots: [String]
        package var manifestDigest: String?
        package init(planID: String, packageID: String, roots: [String], manifestDigest: String? = nil) {
            self.planID = planID
            self.packageID = packageID
            self.roots = roots
            self.manifestDigest = manifestDigest
        }
        func validate() throws {
            for id in [planID, packageID] + roots { _ = try AuthorityRecord.persistentID(.text(id)) }
            guard planID != packageID, !roots.isEmpty, roots.count <= 128, Set(roots).count == roots.count
            else {
                throw PeerSyncWork.invalid()
            }
            if let manifestDigest { _ = try AuthorityRecord.digest(.text(manifestDigest)) }
        }
    }
    package struct Completion: Codable, Sendable {
        package let planID: String
        package let packageID: String
        package let manifestDigest: String
        package let outcome: String
        package init(_ transfer: Transfer, outcome: String) throws {
            guard let digest = transfer.manifestDigest,
                ["accepted", "held", "missing", "rejected"].contains(outcome)
            else {
                throw PeerSyncWork.invalid()
            }
            planID = transfer.planID
            packageID = transfer.packageID
            manifestDigest = digest
            self.outcome = outcome
        }
        func validate() throws {
            for id in [planID, packageID] { _ = try AuthorityRecord.persistentID(.text(id)) }
            _ = try AuthorityRecord.digest(.text(manifestDigest))
            guard ["accepted", "held", "missing", "rejected"].contains(outcome), planID != packageID else {
                throw PeerSyncWork.invalid()
            }
        }
    }
    let profile: String
    let pairingID: String
    let bindingDigest: String
    package var sequence: UInt64
    package var outbound: Transfer?
    package var inbound: Transfer?
    package var completedOutbound: Completion?
    package var completedInbound: Completion?
    init(pairingID: String, bindingDigest: String, sequence: UInt64 = 0) {
        profile = "tractanda.peer-sync-work.v1"
        self.pairingID = pairingID
        self.bindingDigest = bindingDigest
        self.sequence = sequence
    }
    func validate() throws {
        _ = try AuthorityRecord.persistentID(.text(pairingID))
        _ = try AuthorityRecord.digest(.text(bindingDigest))
        guard profile == "tractanda.peer-sync-work.v1", sequence < UInt64.max else { throw Self.invalid() }
        try outbound?.validate()
        try inbound?.validate()
        try completedOutbound?.validate()
        try completedInbound?.validate()
        if let outbound, let inbound {
            guard outbound.planID != inbound.planID, outbound.packageID != inbound.packageID else {
                throw Self.invalid()
            }
        }
        guard try JSON.encode(self).count <= 16 * 1024 else { throw Self.invalid() }
    }
    static func invalid() -> TractandaError {
        TractandaError("peerSyncWorkInvalid", "Private synchronization work binding differs.")
    }
}

/// One bounded private scheduling checkpoint per explicit pairing. Missing bookkeeping starts
/// a current inventory rescan; it cannot make a descriptor missing or create admission authority.
/// Existing unsafe/malformed state is never silently replaced. Referenced journals stay canonical.
struct PeerSyncWorkStore {
    let files: DocumentContentFiles
    private func path(_ binding: PeerExchangeBinding) -> [String] {
        ["authority", "sync-work", binding.pairingID, "checkpoint.json"]
    }
    private func digest(_ binding: PeerExchangeBinding, security: String) throws -> String {
        AuthorityRecordCodec.sha256(
            try JSON.encode([
                binding.storeID, binding.localReplicaID,
                binding.remoteReplicaID, binding.pairingID, String(binding.localIsInitiator),
                binding.configurationDigest, security,
            ]))
    }
    func load(binding: PeerExchangeBinding, security: String) throws -> PeerSyncWork {
        let bindingDigest = try digest(binding, security: security)
        guard let data = try files.readPeerCheckpoint(path: path(binding)) else {
            return .init(pairingID: binding.pairingID, bindingDigest: bindingDigest)
        }
        let old = try PeerPackage.decode(PeerSyncWork.self, data, maximum: 16 * 1024)
        try old.validate()
        guard old.pairingID == binding.pairingID else { throw PeerSyncWork.invalid() }
        return old.bindingDigest == bindingDigest
            ? old
            : .init(pairingID: binding.pairingID, bindingDigest: bindingDigest, sequence: old.sequence)
    }
    func save(_ proposed: PeerSyncWork, binding: PeerExchangeBinding, security: String) throws -> PeerSyncWork
    {
        try proposed.validate()
        let old = try load(binding: binding, security: security)
        guard proposed.pairingID == old.pairingID, proposed.bindingDigest == old.bindingDigest,
            proposed.sequence == old.sequence
        else { throw PeerSyncWork.invalid() }
        var next = proposed
        next.sequence += 1
        let path = path(binding)
        try files.ensurePrivateDirectory(Array(path.dropLast()))
        try files.replacePeerCheckpoint(JSON.encode(next), path: path)
        return next
    }
}

/// Checked framing metadata shared with the driver; this grants no origin or read authority.
package struct PeerSyncDescriptor: Sendable {
    package let value: ItemValue
    package let id: String
    package let key: String
    package let kind: String
    package let length: Int
    package let chunkBytes: Int
    package init(_ value: ItemValue) throws {
        let object = try PeerExchangeState.decodeDescriptor(value)
        self.value = PeerExchangeState.descriptor(object)
        id = object.id
        key = object.key
        kind = object.kind.rawValue
        length = object.length
        chunkBytes = object.chunkBytes
    }
}

extension PeerSyncWork {
    package static func transfer(roots: [String]) throws -> Transfer {
        let value = Transfer(
            planID: try UUID.makeVersion1().uuidString.lowercased(),
            packageID: try UUID.makeVersion1().uuidString.lowercased(), roots: roots)
        try value.validate()
        return value
    }
    package static func manifestDigest(_ bytes: Data, packageID: String, storeID: String) throws -> String {
        let manifest = try PeerPackage.decode(PeerPackage.Manifest.self, bytes)
        try manifest.validate()
        guard manifest.packageID == packageID, manifest.storeID == storeID else {
            throw TractandaError("peerObjectCollision", "Sealed manifest work identity differs.")
        }
        return AuthorityRecordCodec.sha256(bytes)
    }
}
