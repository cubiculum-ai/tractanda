import Foundation

/// Host-only source ownership. No network or public service request can construct this scope.
/// It permits private baseline construction, never peer authentication or activation.
enum PeerEnrollmentApproval {
    static let capability = "tractanda.peer-enrollment-approval.v1"
    static let directory = ".peer-enrollment-operations"

    struct OwnerExportScope {
        let context: PeerPackage.Context
        let validate: () throws -> Void
    }
    static func requireExport(_ context: PeerPackage.Context, coordinator: PeerIntakeCoordinator,
                              ownerScope: OwnerExportScope?) throws {
        if let ownerScope {
            guard ownerScope.context == context else { throw failure("Enrollment export scope differs.") }
            try ownerScope.validate()
        } else {
            try coordinator.requireCurrent(context)
        }
    }
    struct Request: Sendable {
        let operationID: String
        let preparationBytes: Data
        let sourceContext: PeerPackage.Context
        let targetContext: PeerPackage.Context
        let sourceCredential: PeerCredential
        let targetCredential: PeerCredential
    }
    struct Handle: Sendable { let operationID: String }
    struct Status: Sendable {
        enum Phase: String, Sendable { case selecting, building, ready, accepted }
        let phase: Phase
        let approval: AuthorityBinding?
        let manifest: PeerPackage.Manifest?
    }
    struct Input: Codable {
        let preparationBytes: Data
        let sourceContext: PeerPackage.Context
        let targetContext: PeerPackage.Context
        let sourceCredentialCommitment: String
        let targetCredentialCommitment: String
        let sourcePrivateBytesDigest: String
        let targetPrivateBytesDigest: String
        let pairingID: String
        let sourceIsInitiator: Bool
        let profile: String
    }
    struct Operation: Codable {
        let profile: String
        let operationID: String
        let input: Input
        let actorUID: UInt32
        let actor: String
        let groups: [String: ItemValue]
        let sourceAdministration: ItemValue
        let administrationPolicies: [ItemValue]
        let trustedOrigins: [String]
        let bootstrap: AuthorityBinding
        var issuerAdmission: AuthorityBinding? = nil
        let securityBinding: String
        let approvalID: String
        let publicationID: String
        let framingID: String
        let planID: String
        let packageID: String
        let createdAt: String
    }
    struct Draft: Codable {
        struct Record: Codable {
            let binding: AuthorityBinding
            let packageID: String
            let framingID: String
        }
        let cut: AuthorityBinding
        let records: [Record]
    }
    struct Capture: Codable {
        let boundary: PeerInventory.Boundary
        let cut: AuthorityBinding
    }
    struct Selection: Codable {
        let sequence: Int
        let previousDigest: String
        let cursor: PeerInventory.Cursor?
        let complete: Bool
    }
    struct Accepted: Codable {
        let approval: AuthorityBinding
        let publicationID: String
        let manifestDigest: String
    }
    struct Journal {
        let files: DocumentContentFiles
        let operationID: String
        func path(_ name: String) throws -> [String] {
            _ = try AuthorityRecord.persistentID(.text(operationID))
            return [directory, operationID, name]
        }
        func read<T: Codable>(_ type: T.Type, _ name: String, readBudget: ((Int) throws -> Void)? = nil) throws -> T? {
            try files.readIfPresent(path: path(name), maximumBytes: PeerPackage.maximumPageBytes, readBudget: readBudget)
                .map { try PeerPackage.decode(type, $0) }
        }
        func write<T: Encodable>(_ value: T, _ name: String) throws {
            let bytes = try JSON.encode(value), path = try path(name)
            guard bytes.count <= PeerPackage.maximumPageBytes else {
                throw TractandaError("resourceLimit", "Enrollment metadata frame exceeds its window.")
            }
            if let old = try files.readIfPresent(path: path, maximumBytes: PeerPackage.maximumPageBytes) {
                guard old == bytes else { throw failure("Enrollment immutable operation bytes differ.") }
                try files.synchronizeDirectory(Array(path.dropLast()))
            } else {
                try files.writeImmutable(bytes, path: path, maximumBytes: PeerPackage.maximumPageBytes)
            }
        }
        func selection(maximumWork: Int) throws -> Selection? {
            var sequence = 0, previous = "", last: Selection?
            while let value = try read(Selection.self, "selection-\(sequence + 1).json") {
                guard sequence < maximumWork, value.sequence == sequence + 1,
                    value.previousDigest == previous, last?.complete != true,
                    value.complete == (value.cursor == nil)
                else { throw failure("Enrollment selection journal is invalid.") }
                sequence += 1
                previous = AuthorityRecordCodec.sha256(try JSON.encode(value))
                last = value
            }
            return last
        }
    }
    static func preparation(_ bytes: Data) throws -> PeerEnrollment.Preparation {
        let value = try PeerPackage.decode(PeerEnrollment.Preparation.self, bytes,
                                          maximum: PeerEnrollment.maximumBytes)
        let ids = [value.commonStoreID, value.sourceReplicaID, value.targetReplicaID, value.operationID]
        for id in ids { _ = try AuthorityRecord.persistentID(.text(id)) }
        guard value.formatVersion == 1, Set(ids).count == ids.count else {
            throw failure("Enrollment preparation identity differs.")
        }
        return value
    }
    static func compare(_ a: PeerCredential, _ b: PeerCredential) throws {
        let same = try a.commitment == b.commitment && a.withTLSInput { _, secret in
            b.withTLSInput { _, other in secret == other }
        }
        guard same else { throw failure("Exact supplied private credential differs.") }
    }
    static func checkPair(_ request: Request, source: String, storeID: String,
                          trustedOrigins: [String]) throws -> Input {
        let preparation = try preparation(request.preparationBytes)
        let a = request.sourceCredential.binding, b = request.targetCredential.binding
        let sameSecret = request.sourceCredential.withTLSInput { _, secret in
            request.targetCredential.withTLSInput { _, other in secret == other }
        }
        guard preparation.commonStoreID == storeID, preparation.sourceReplicaID == source,
            a.storeID == storeID, b.storeID == storeID,
            a.localReplicaID == source, a.remoteReplicaID == preparation.targetReplicaID,
            b.localReplicaID == preparation.targetReplicaID, b.remoteReplicaID == source,
            a.pairingID == b.pairingID, a.localIsInitiator != b.localIsInitiator, sameSecret,
            request.sourceContext.peerID == a.peerID, request.targetContext.peerID == b.peerID,
            request.sourceContext.storeID == storeID, request.targetContext.storeID == storeID,
            request.sourceContext.configurationDigest == a.configurationDigest,
            request.targetContext.configurationDigest == b.configurationDigest,
            request.sourceContext.permittedOrigins == [preparation.targetReplicaID],
            request.targetContext.permittedOrigins == trustedOrigins
        else { throw failure("Oriented preparation/credential/context binding differs.") }
        return try .init(preparationBytes: request.preparationBytes,
            sourceContext: request.sourceContext, targetContext: request.targetContext,
            sourceCredentialCommitment: request.sourceCredential.commitment,
            targetCredentialCommitment: request.targetCredential.commitment,
            sourcePrivateBytesDigest: request.sourceCredential.privateBytesDigest,
            targetPrivateBytesDigest: request.targetCredential.privateBytesDigest,
            pairingID: a.pairingID, sourceIsInitiator: a.localIsInitiator,
            profile: PeerCredential.supportedProfile)
    }
    static func failure(_ message: String) -> TractandaError {
        TractandaError("enrollmentReviewRequired", message)
    }
}
