import Foundation

/// Nonsecret local diagnostics. Readiness describes this Store's current serving gate,
/// not a proof that every replica or all replication history has been verified.
public struct PeerOperatorStatus: Codable, Sendable {
    public static let nativeMethod = "TractandaPeer/status"
    public let canonical: PeerCanonicalStatus
    public let runtime: PeerOperatorRuntimeStatus
    public init(canonical: PeerCanonicalStatus, runtime: PeerOperatorRuntimeStatus) {
        self.canonical = canonical; self.runtime = runtime
    }
}

public struct PeerCanonicalStatus: Codable, Sendable {
    public enum Readiness: String, Codable, Sendable {
        case ready, recoveryRequired, pendingActivation, authorityUnavailable
    }
    public let storeID: String
    public let replicaID: String?
    public let readiness: Readiness
    /// Nil means current canonical disposal evidence could not be inspected safely.
    public let localDisposed: Bool?
    public let configuredPairingCount: Int?
    /// Canonical commitments only; status never reads or validates private key bytes.
    public let committedPairingCount: Int?
}

public struct PeerSynchronizationStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable { case disabled, active, stopped, unavailable }
    public let state: State
    public let activeJobCount: Int?
    public let eligibleEdgeCount: Int?
    public let outcomeCounts: [String: Int]
    public let lastErrorCode: String?
    public init(state: State, activeJobCount: Int? = nil, eligibleEdgeCount: Int? = nil,
        outcomeCounts: [String: Int] = [:], lastErrorCode: String? = nil) throws {
        guard activeJobCount.map({ (0...2).contains($0) }) ?? true,
            eligibleEdgeCount.map({ (0...256).contains($0) }) ?? true,
            outcomeCounts.count <= 7,
            outcomeCounts.allSatisfy({ ["complete", "yielded", "held", "missing", "rejected", "repairRequired", "unsupported"].contains($0.key)
                && (0...256).contains($0.value) }) else { throw Self.invalid() }
        self.state = state; self.activeJobCount = activeJobCount; self.eligibleEdgeCount = eligibleEdgeCount
        self.outcomeCounts = outcomeCounts; self.lastErrorCode = Self.safeCode(lastErrorCode)
    }
    static func safeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        // Remote failures are untrusted strings. Do not reflect arbitrary error-code content.
        let allowed: Set<String> = ["serviceClosed", "serviceBusy", "untrustedPeer", "invalidPeerCredential",
            "peerConfigurationChanged", "peerIntakeDisabled", "localReplicaRetired", "peerRetired",
            "recoveryRequired", "peerLeaseChanged", "peerSessionExhausted", "connectionFailed",
            "deadlineExceeded", "cancelled", "resourceLimit", "peerRepairRequired", "peerSyncWorkInvalid",
            "peerPayloadVerifying", "peerVerificationBusy", "peerExportChanged", "peerSyncUnavailable",
            "peerRuntimeUnavailable", "invalidPeerResponse", "invalidPeerFrame", "unsupportedAuthorityContext",
            "invalidPeerConfiguration", "invalidOriginAdmission", "documentIntegrity", "invalidPeerPackage",
            "invalidPeerExport", "forbidden", "incompatiblePeer", "peerCompatibilityRequired",
            "incompatibleCanonicalReader", "unknownCanonicalCompatibility"]
        return allowed.contains(code) ? code : "peerRuntimeUnavailable"
    }
    static func invalid() -> TractandaError { TractandaError("invalidPeerStatus", "Peer status exceeds its diagnostic bounds.") }
}

public struct PeerOperatorRuntimeStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable { case disabled, active, stopped, unavailable }
    public let state: State
    /// Immutable facts from the configuration loaded at startup, never a later file read.
    public let configurationPath: String?
    public let settingsDigest: String?
    public let synchronizationEnabled: Bool
    public let listenerConfigured: Bool?
    public let responderPublished: Bool?
    public let incomingConnectionCount: Int?
    public let outgoingConnectionCount: Int?
    public let pendingConnectionCount: Int?
    public let lastErrorCode: String?
    public let synchronization: PeerSynchronizationStatus
    public init(state: State, configurationPath: String? = nil, settingsDigest: String? = nil,
        synchronizationEnabled: Bool = false, listenerConfigured: Bool? = nil, responderPublished: Bool? = nil,
        incomingConnectionCount: Int? = nil, outgoingConnectionCount: Int? = nil,
        pendingConnectionCount: Int? = nil, lastErrorCode: String? = nil,
        synchronization: PeerSynchronizationStatus) throws {
        guard [incomingConnectionCount, outgoingConnectionCount, pendingConnectionCount].allSatisfy({ value in
            value.map { (0...64).contains($0) } ?? true
        }) else { throw PeerSynchronizationStatus.invalid() }
        guard (configurationPath == nil) == (settingsDigest == nil),
            configurationPath.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096
                && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true,
            settingsDigest.map({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true
        else { throw PeerSynchronizationStatus.invalid() }
        self.configurationPath = configurationPath; self.settingsDigest = settingsDigest
        self.synchronizationEnabled = synchronizationEnabled
        self.state = state; self.listenerConfigured = listenerConfigured; self.responderPublished = responderPublished
        self.incomingConnectionCount = incomingConnectionCount; self.outgoingConnectionCount = outgoingConnectionCount
        self.pendingConnectionCount = pendingConnectionCount
        self.lastErrorCode = PeerSynchronizationStatus.safeCode(lastErrorCode); self.synchronization = synchronization
    }
    private enum CodingKeys: String, CodingKey {
        case state, configurationPath, settingsDigest, synchronizationEnabled, listenerConfigured
        case responderPublished, incomingConnectionCount, outgoingConnectionCount, pendingConnectionCount
        case lastErrorCode, synchronization
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(state: c.decode(State.self, forKey: .state),
            configurationPath: c.decodeIfPresent(String.self, forKey: .configurationPath),
            settingsDigest: c.decodeIfPresent(String.self, forKey: .settingsDigest),
            synchronizationEnabled: c.decode(Bool.self, forKey: .synchronizationEnabled),
            listenerConfigured: c.decodeIfPresent(Bool.self, forKey: .listenerConfigured),
            responderPublished: c.decodeIfPresent(Bool.self, forKey: .responderPublished),
            incomingConnectionCount: c.decodeIfPresent(Int.self, forKey: .incomingConnectionCount),
            outgoingConnectionCount: c.decodeIfPresent(Int.self, forKey: .outgoingConnectionCount),
            pendingConnectionCount: c.decodeIfPresent(Int.self, forKey: .pendingConnectionCount),
            lastErrorCode: c.decodeIfPresent(String.self, forKey: .lastErrorCode),
            synchronization: c.decode(PeerSynchronizationStatus.self, forKey: .synchronization))
    }
    public static var unavailable: Self {
        // Fixed literals satisfy the same bounded constructors as live diagnostics.
        try! .init(state: .unavailable, synchronization: .init(state: .unavailable))
    }
}
