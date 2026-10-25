import Crypto
import Foundation

/// Current peer membership is local administrator configuration, never an item or old admission log.
public struct PersonalMember: Codable, Equatable, Sendable {
    public let replicaID: String
    public let hostname: String
    public init(replicaID: String, hostname: String) throws {
        try PersonalSyncValidation.identifier(replicaID)
        let endpoint = try PeerRuntimeConfiguration.Endpoint(host: hostname, port: 1)
        guard !hostname.contains(":"), !hostname.allSatisfy({ $0.isNumber || $0 == "." }),
            !["*", "0.0.0.0", "::"].contains(hostname)
        else {
            throw TractandaError("invalidPersonalMembership", "Use a DNS hostname for a member.")
        }
        self.replicaID = replicaID
        self.hostname = endpoint.host
    }
    func validate() throws { _ = try Self(replicaID: replicaID, hostname: hostname) }
}

public struct PersonalMembershipConfiguration: Codable, Equatable, Sendable {
    public static let profileName = "tractanda.personal-membership.v1"
    public let profile: String
    public let storeID: String
    public let configurationID: String
    public let members: [PersonalMember]
    public init(storeID: String, configurationID: String, members: [PersonalMember]) throws {
        profile = Self.profileName
        self.storeID = storeID
        self.configurationID = configurationID
        self.members = members.sorted { $0.replicaID < $1.replicaID }
        try validate()
    }
    public func validate() throws {
        try PersonalSyncValidation.identifier(storeID)
        try PersonalSyncValidation.identifier(configurationID)
        guard profile == Self.profileName, (1...256).contains(members.count),
            members.map(\.replicaID) == Array(Set(members.map(\.replicaID))).sorted(),
            Set(members.map(\.hostname)).count == members.count
        else {
            throw TractandaError("invalidPersonalMembership", "Invalid current personal membership.")
        }
        for member in members { try member.validate() }
    }
    public var digest: String {
        get throws {
            try validate()
            return try PersonalSyncValidation.digest(JSON.encode(self))
        }
    }
}

public struct PersonalSyncIdentity: Codable, Equatable, Sendable {
    public let storeID: String
    public let replicaID: String
    public let membership: PersonalMembershipConfiguration?
}

public struct PersonalDocumentPart: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case manifest, node, page }
    public let role: Role
    public let level: Int
    public let ordinal: Int64
    public init(role: Role, level: Int = 0, ordinal: Int64 = 0) {
        self.role = role
        self.level = level
        self.ordinal = ordinal
    }
    var peerPart: PeerPackage.DocumentPart {
        .init(role: .init(rawValue: role.rawValue)!, level: level, ordinal: ordinal)
    }
}

/// Exact immutable bytes, without a sender-selected pathname, UID or permission assertion.
public struct PersonalObjectDescriptor: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case revision, original, document }
    public let kind: Kind
    public let id: String
    public let byteCount: Int64
    public let sha256: String
    public let itemID: String?
    public let parentRevisionIDs: [String]
    public let attachment: AttachmentDescriptor?
    public let part: PersonalDocumentPart?
    public init(
        kind: Kind, id: String, byteCount: Int64, sha256: String,
        itemID: String? = nil, parentRevisionIDs: [String] = [],
        attachment: AttachmentDescriptor? = nil, part: PersonalDocumentPart? = nil
    ) throws {
        self.kind = kind
        self.id = id
        self.byteCount = byteCount
        self.sha256 = sha256
        self.itemID = itemID
        self.parentRevisionIDs = parentRevisionIDs
        self.attachment = attachment
        self.part = part
        try validate()
    }
    public func validate() throws {
        try PersonalSyncValidation.identifier(id)
        try PersonalSyncValidation.sha256(sha256)
        guard byteCount >= 0, parentRevisionIDs.count <= 1024,
            parentRevisionIDs == Array(Set(parentRevisionIDs)).sorted()
        else {
            throw TractandaError("invalidPersonalObject", "Invalid immutable object descriptor.")
        }
        for id in parentRevisionIDs { try PersonalSyncValidation.identifier(id) }
        if let itemID { try PersonalSyncValidation.identifier(itemID) }
        switch kind {
        case .revision:
            guard itemID != nil, attachment == nil, part == nil, byteCount > 0,
                byteCount <= PooledCanonicalRecord.maximumRecordBytes
            else { throw invalid() }
        case .original:
            guard itemID == nil, parentRevisionIDs.isEmpty, part == nil, let attachment,
                attachment.attachmentID == id, attachment.byteCount == byteCount,
                attachment.sha256 == sha256
            else { throw invalid() }
            _ = try AttachmentDescriptor(attachment.itemValue)
        case .document:
            guard itemID == nil, parentRevisionIDs.isEmpty, attachment == nil, let part,
                byteCount > 0,
                byteCount
                    <= (part.role == .page
                        ? DocumentContentStore.maximumPageBytes : DocumentContentStore.maximumNodeBytes)
            else { throw invalid() }
            try part.peerPart.validate()
        }
    }
    var key: String {
        get throws {
            try validate()
            return try PersonalSyncValidation.digest(JSON.encode(self))
        }
    }
    var peerObject: PeerPackage.Object {
        .init(kind: .document, id: id, length: Int(byteCount), sha256: sha256, part: part?.peerPart)
    }
    private func invalid() -> TractandaError {
        TractandaError("invalidPersonalObject", "Object kind and metadata disagree.")
    }
}

public struct PersonalInventoryPage: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let generationID: String
    public let cutRowID: Int64
    public let entries: [PersonalObjectDescriptor]
    public let nextOffset: Int?
    public let complete: Bool
}
public struct PersonalDependencyPage: Codable, Equatable, Sendable {
    public let entries: [PersonalObjectDescriptor]
    public let nextOffset: Int?
    public let complete: Bool
}
public struct PersonalObjectProgress: Codable, Equatable, Sendable {
    public let nextOffset: Int64
    public let complete: Bool
    public let knownRevision: Bool
    public init(nextOffset: Int64, complete: Bool, knownRevision: Bool = false) {
        self.nextOffset = nextOffset
        self.complete = complete
        self.knownRevision = knownRevision
    }
}
public struct PersonalApplyResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case known, accepted, merged, conflicted, reviewRequired }
    public let status: Status
    public let revisionID: String
    public let itemID: String
    public let currentState: ItemState?
    public let reviewItemID: String?
}
public struct PersonalSharingMetadata: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let stateToken: String
    public let permissions: ItemValue
}

public struct PersonalMembershipReady: Codable, Equatable, Sendable {
    public let configurationDigest: String
    public let nonce: String
    public let replicaID: String
    public let administrator: String
}
package struct PersonalMembershipOnlineAcknowledgement: Sendable {
    package let response: PersonalMembershipReady
    package let binding: PeerExchangeBinding
    package let control: PeerExchangeControl
    /// Host calls after an authenticated reply; the control is canceled on connection close.
    package init(
        binding: PeerExchangeBinding, response: PersonalMembershipReady,
        control: PeerExchangeControl
    ) throws {
        guard response.replicaID == binding.remoteReplicaID,
            response.configurationDigest == binding.configurationDigest
        else {
            throw TractandaError(
                "invalidPersonalMembership", "Online response is not bound to its authenticated peer.")
        }
        self.response = response
        self.binding = binding
        self.control = control
    }
}
public struct PersonalMembershipPreparation: Codable, Equatable, Sendable {
    public let configuration: PersonalMembershipConfiguration
    public let expectedDigest: String?
    public let nonce: String
    public let administrator: String
    public let requiredOnlineReplicaIDs: [String]
    public let readmission: Bool
}

struct PersonalSyncInventorySnapshot {
    let binding: PeerExchangeBinding
    let highWaterRowID: Int64
    let catalogueGeneration: String
}
struct PersonalSyncStage: Codable, Equatable {
    let descriptor: PersonalObjectDescriptor
    let stageID: String
}
struct PersonalBaselineSelection: Codable, Equatable {
    let selectionID: String
    let storeID: String
    let sourceReplicaID: String
}

enum PersonalSyncValidation {
    static let capability = "tractanda.personal-sync.v1"
    static func identifier(_ value: String) throws {
        try Identifier.validate(value)
        guard UUID(uuidString: value)?.version1Components != nil else {
            throw TractandaError("invalidPersonalObject", "Personal identities require UUIDv1.")
        }
    }
    static func sha256(_ value: String) throws {
        guard DocumentHashNode.isDigest(value) else {
            throw TractandaError("invalidPersonalObject", "Expected an exact SHA256 digest.")
        }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PersonalCredentialAliases: Codable, Equatable {
    let configurationDigest: String
    let aliases: [String]
}
public struct PersonalIncomingReview: Codable, Equatable, Sendable {
    public let reviewID: String
    public let descriptor: PersonalObjectDescriptor
    public let sourceReplicaID: String
    public let currentFrontier: [String]
    public let baseRevisionIDs: [String]
    public let reason: String
    public var disposition: String
}
