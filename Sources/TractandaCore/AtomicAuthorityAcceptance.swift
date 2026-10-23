import Foundation

/// Per-root canonical receipt, separate from both private staging and the physical package seal.
/// A receipt proves one completed historical Store decision; it is never a permanent current ACL
/// grant. Cold recovery reopens its exact immutable context/originals and rechecks current rights.
enum AtomicAuthorityAcceptance {
    static let profile = "tractanda.atomic-control-acceptance.v1"

    struct ConfigurationReference: Codable, Equatable {
        let fileName: String
        let sha256: String
        func validate() throws {
            guard fileName.count == 25, fileName.hasSuffix(".json"),
                let sequence = UInt64(fileName.prefix(20)), sequence > 0,
                fileName == String(format: "%020llu.json", sequence)
            else { throw AtomicAuthorityFormat.invalid("Invalid exact configuration history reference.") }
            _ = try AuthorityRecord.digest(.text(sha256))
        }
    }
    /// Hash-tree roots reference existing immutable authority originals. No context page is a
    /// logical control, PRE cut, support opinion, administrator decision or physical part thereof.
    enum ValidationPurpose: String, Codable {
        case authenticatedRequest, nativeRuntime, authenticatedSourceCut, backgroundSourceCut
        var isSourceCut: Bool { self == .authenticatedSourceCut || self == .backgroundSourceCut }
    }
    struct Context: Codable, Equatable {
        let configuration: ConfigurationReference
        let authorities: PeerPackage.Manifest
        let authorityCount: Int64
        let requestPrincipal: String
        var validationPurpose: ValidationPurpose = .authenticatedRequest
        func validate(storeID: String, rootID: String) throws {
            try configuration.validate()
            try authorities.validate()
            guard authorities.storeID == storeID, authorities.packageID == rootID, authorityCount > 0 else {
                throw AtomicAuthorityFormat.invalid("Accepted context does not bind its exact store/root.")
            }
            _ = try AuthorityRecord.text(.text(requestPrincipal))
        }
    }
    struct Receipt: Codable, Equatable {
        let profile: String
        let storeID: String
        let receiverReplicaID: String
        let root: AuthorityBinding
        let packageID: String
        let manifestSHA256: String
        let validationContextSHA256: String
        let context: Context
        init(
            storeID: String, receiverReplicaID: String, root: AuthorityBinding,
            packageID: String, manifestSHA256: String, validationContextSHA256: String, context: Context
        ) throws {
            profile = AtomicAuthorityAcceptance.profile
            self.storeID = storeID
            self.receiverReplicaID = receiverReplicaID
            self.root = root
            self.packageID = packageID
            self.manifestSHA256 = manifestSHA256
            self.validationContextSHA256 = validationContextSHA256
            self.context = context
            try validate()
        }
        func validate() throws {
            guard profile == AtomicAuthorityAcceptance.profile else {
                throw AtomicAuthorityFormat.invalid("Unknown atomic acceptance receipt profile.")
            }
            _ = try AuthorityRecord.persistentID(.text(storeID))
            _ = try AuthorityRecord.persistentID(.text(receiverReplicaID))
            _ = try AuthorityRecord.persistentID(.text(packageID))
            _ = try AuthorityRecord.digest(.text(root.sha256))
            _ = try AuthorityRecord.persistentID(.text(root.recordID))
            _ = try AuthorityRecord.digest(.text(manifestSHA256))
            _ = try AuthorityRecord.digest(.text(validationContextSHA256))
            try context.validate(storeID: storeID, rootID: root.recordID)
            if context.validationPurpose == .backgroundSourceCut {
                guard context.requestPrincipal == "replica:" + receiverReplicaID else {
                    throw AtomicAuthorityFormat.invalid(
                        "Background source cut cannot invent a user/admin witness.")
                }
            }
        }
    }

    /// Only the durable journal reader creates this handle, after exact receipt parsing and
    /// configuration/context byte-closure checks. Store still validates semantic/current authority.
    struct Sealed {
        let receipt: Receipt
        let bytesSHA256: String
        fileprivate init(receipt: Receipt, bytesSHA256: String) {
            self.receipt = receipt
            self.bytesSHA256 = bytesSHA256
        }
    }
}

extension PeerIntakeJournal {
    /// Reads historical inputs, never substitutes today's configuration for its captured version.
    /// Part closure and semantic/current checks remain Store's responsibility before activation.
    func atomicAcceptance(packageID: String, root: AuthorityBinding) throws
        -> AtomicAuthorityAcceptance.Sealed?
    {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.persistentID(.text(root.recordID))
        guard
            let bytes = try files.readIfPresent(
                path: ["authority", "intake", packageID, "atomic-accepted", root.recordID + ".json"],
                maximumBytes: PeerPackage.maximumPageBytes)
        else { return nil }
        let receipt = try PeerPackage.decode(AtomicAuthorityAcceptance.Receipt.self, bytes)
        try receipt.validate()
        guard receipt.root == root, receipt.packageID == packageID,
            let publication = try publication(packageID), publication.context.storeID == receipt.storeID,
            publication.manifestDigest == receipt.manifestSHA256
        else {
            throw AtomicAuthorityFormat.invalid("Atomic receipt lost exact physical publication binding.")
        }
        let configuration = try files.read(
            path: [".peer-configuration", receipt.context.configuration.fileName],
            maximumBytes: PeerPackage.maximumPageBytes)
        guard AuthorityRecordCodec.sha256(configuration) == receipt.context.configuration.sha256 else {
            throw AtomicAuthorityFormat.invalid("Atomic receipt configuration original changed.")
        }
        // This is typed strict configuration, not raw bytes asserted to be a policy witness.
        let value = try PeerPackage.decode(AuthorityStore.Configuration.self, configuration)
        guard value.profile == "tractanda.peer-configuration.v1", value.bootstrap != nil else {
            throw AtomicAuthorityFormat.invalid(
                "Atomic receipt lacks its initialized canonical configuration.")
        }
        try value.validateCredentialBindings()
        _ = try walkUntrustedAtomicContext(receipt) { _ in }
        return .init(receipt: receipt, bytesSHA256: AuthorityRecordCodec.sha256(bytes))
    }
    /// Complete protected structural context walk. Prefix callbacks may populate only private
    /// work; they are not authority facts, and failure never returns a completed context.
    @discardableResult
    func walkUntrustedAtomicContext(
        _ receipt: AtomicAuthorityAcceptance.Receipt,
        visit: (PeerPackage.Object) throws -> Void
    ) throws -> Int64 {
        try receipt.validate()
        guard receipt.context.authorityCount <= Int64(limits.maximumObjects) else {
            throw TractandaError("resourceLimit", "Atomic context original allowance exhausted.")
        }
        var active = Set<String>()
        var work = 0
        var count: Int64 = 0
        var last: String?
        func page(_ expected: PeerPackage.Object, depth: Int) throws {
            try Task.checkCancellation()
            work += 1
            guard expected.kind == .index, work <= limits.maximumWork, depth <= limits.maximumDepth,
                active.insert(expected.id).inserted
            else {
                throw AtomicAuthorityFormat.invalid("Atomic context has an invalid/cyclic index closure.")
            }
            defer { active.remove(expected.id) }
            try expected.validate()
            let bytes = try files.read(
                path: [
                    "authority", "intake", receipt.packageID, "atomic-context",
                    receipt.root.recordID, "pages", expected.id,
                ], maximumBytes: PeerPackage.maximumPageBytes)
            guard bytes.count == expected.length, AuthorityRecordCodec.sha256(bytes) == expected.sha256 else {
                throw AtomicAuthorityFormat.invalid("Atomic context page changed its committed reference.")
            }
            let value = try PeerPackage.decode(PeerPackage.Page.self, bytes)
            try value.validate()
            for child in value.children { try page(child, depth: depth + 1) }
            for object in value.objects {
                try Task.checkCancellation()
                work += 1
                guard work <= limits.maximumWork, object.kind == .authority, object.part == nil,
                    last.map({ $0 < object.id }) ?? true
                else {
                    throw AtomicAuthorityFormat.invalid(
                        "Atomic context originals are not strictly ordered authority descriptors.")
                }
                count = try AtomicAuthorityFormat.sum(count, 1)
                guard count <= receipt.context.authorityCount else {
                    throw AtomicAuthorityFormat.invalid("Atomic context contains extra originals.")
                }
                last = object.id
                try visit(object)
            }
        }
        try page(receipt.context.authorities.root, depth: 0)
        guard count == receipt.context.authorityCount else {
            throw AtomicAuthorityFormat.invalid("Atomic context closure count differs from its receipt.")
        }
        return count
    }
}
