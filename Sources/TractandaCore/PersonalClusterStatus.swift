import Foundation

/// Local administrator configuration. A pending proposal grants no content access.
/// No preparation nonce, credential, or baseline selection token is part of diagnostics.
public struct PersonalClusterCanonicalStatus: Codable, Sendable {
    public let currentMembership: PersonalMembershipConfiguration?
    public let currentMembershipDigest: String?
    public let pendingMembership: PersonalMembershipConfiguration?
    public let pendingMembershipDigest: String?
    public let requiredOnlineReplicaIDs: [String]
    public let baselineSourceReplicaID: String?
    public init(storeID: String, currentMembership: PersonalMembershipConfiguration?,
        pendingMembership: PersonalMembershipConfiguration?, requiredOnlineReplicaIDs: [String] = [],
        baselineSourceReplicaID: String? = nil) throws {
        for membership in [currentMembership, pendingMembership].compactMap({ $0 }) {
            try membership.validate()
            guard membership.storeID == storeID else { throw PeerSynchronizationStatus.invalid() }
        }
        guard requiredOnlineReplicaIDs.count <= 256,
            Set(requiredOnlineReplicaIDs).count == requiredOnlineReplicaIDs.count
        else { throw PeerSynchronizationStatus.invalid() }
        for id in requiredOnlineReplicaIDs { try PersonalSyncValidation.identifier(id) }
        if let baselineSourceReplicaID { try PersonalSyncValidation.identifier(baselineSourceReplicaID) }
        self.currentMembership = currentMembership
        self.currentMembershipDigest = try currentMembership?.digest
        self.pendingMembership = pendingMembership
        self.pendingMembershipDigest = try pendingMembership?.digest
        self.requiredOnlineReplicaIDs = requiredOnlineReplicaIDs.sorted()
        self.baselineSourceReplicaID = baselineSourceReplicaID
    }
}

/// Process-lifetime observations of one authenticated UUID/configuration pair.
/// A socket is duplex; initiator direction never means item-flow direction.
/// Finite-cut completion does not certify remote health, baseline readiness, or convergence.
public struct PersonalPeerObservation: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case complete, remoteNotReady, failed }
    public let replicaID: String
    public let configurationDigest: String
    public let connected: Bool
    public let incomingConnectionCount: Int
    public let outgoingConnectionCount: Int
    public let controlOnly: Bool?
    public let pullRunning: Bool
    public let completedCuts: Int
    public let currentPull: PersonalPullProgress?
    public let lastConnectedAt: String?
    public let lastDisconnectedAt: String?
    public let lastPullStartedAt: String?
    public let lastPullFinishedAt: String?
    public let lastOutcome: Outcome?
    public let lastErrorCode: String?
    public let lastErrorAt: String?
    public let lastRevisionCount: Int?
    public let lastTransferredBytes: Int64?
    public let lastRevisionOutcomes: [String: Int]
    public init(replicaID: String, configurationDigest: String, connected: Bool,
        incomingConnectionCount: Int = 0, outgoingConnectionCount: Int = 0,
        controlOnly: Bool? = nil, pullRunning: Bool = false, completedCuts: Int = 0,
        currentPull: PersonalPullProgress? = nil,
        lastConnectedAt: String? = nil, lastDisconnectedAt: String? = nil,
        lastPullStartedAt: String? = nil, lastPullFinishedAt: String? = nil,
        lastOutcome: Outcome? = nil, lastErrorCode: String? = nil, lastErrorAt: String? = nil,
        lastRevisionCount: Int? = nil, lastTransferredBytes: Int64? = nil,
        lastRevisionOutcomes: [String: Int] = [:]) throws {
        self.replicaID = replicaID; self.configurationDigest = configurationDigest
        self.connected = connected; self.incomingConnectionCount = incomingConnectionCount
        self.outgoingConnectionCount = outgoingConnectionCount; self.controlOnly = controlOnly
        self.pullRunning = pullRunning; self.completedCuts = completedCuts
        self.currentPull = currentPull
        self.lastConnectedAt = lastConnectedAt; self.lastDisconnectedAt = lastDisconnectedAt
        self.lastPullStartedAt = lastPullStartedAt; self.lastPullFinishedAt = lastPullFinishedAt
        self.lastOutcome = lastOutcome; self.lastErrorCode = PeerSynchronizationStatus.safeCode(lastErrorCode)
        self.lastErrorAt = lastErrorAt; self.lastRevisionCount = lastRevisionCount
        self.lastTransferredBytes = lastTransferredBytes; self.lastRevisionOutcomes = lastRevisionOutcomes
        try validate()
    }
    public func validate() throws {
        try currentPull?.validate()
        try PersonalSyncValidation.identifier(replicaID)
        try PersonalSyncValidation.sha256(configurationDigest)
        guard (0...64).contains(incomingConnectionCount), (0...64).contains(outgoingConnectionCount),
            completedCuts >= 0, lastRevisionCount.map({ $0 >= 0 }) ?? true,
            lastTransferredBytes.map({ $0 >= 0 }) ?? true,
            lastRevisionOutcomes.count <= 5,
            lastRevisionOutcomes.allSatisfy({
                ["known", "accepted", "merged", "conflicted", "reviewRequired"].contains($0.key)
                    && $0.value >= 0
            }), PeerSynchronizationStatus.safeCode(lastErrorCode) == lastErrorCode
        else { throw PeerSynchronizationStatus.invalid() }
        for timestamp in [lastConnectedAt, lastDisconnectedAt, lastPullStartedAt, lastPullFinishedAt, lastErrorAt].compactMap({ $0 }) {
            guard timestamp.utf8.count <= 32, ISO8601DateFormatter().date(from: timestamp) != nil else {
                throw PeerSynchronizationStatus.invalid()
            }
        }
    }
}

/// Cumulative work actually observed in the active local pull, with no inferred total or percent.
public struct PersonalPullProgress: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case checkingReadiness, inventory, dependencies, transferring, applying, checkpointing
    }
    public let phase: Phase
    public let revisionCount: Int
    public let transferredBytes: Int64
    /// Last completed operation/data append, never a periodic timer or status-request time.
    public let lastProgressAt: String?
    public init(phase: Phase, revisionCount: Int = 0, transferredBytes: Int64 = 0,
        lastProgressAt: String? = nil) throws {
        self.phase = phase; self.revisionCount = revisionCount
        self.transferredBytes = transferredBytes; self.lastProgressAt = lastProgressAt
        try validate()
    }
    public func validate() throws {
        guard revisionCount >= 0, transferredBytes >= 0,
            lastProgressAt.map({ $0.utf8.count <= 32 && ISO8601DateFormatter().date(from: $0) != nil }) ?? true
        else { throw PeerSynchronizationStatus.invalid() }
    }
}
