import Foundation

/// One bounded progress record. Counts describe verified work, not a resumable SQLite cursor.
public struct StoreRebuildStatus: Codable, Equatable, Sendable {
    public var jobID: String
    public var operationID: String
    public var state: String
    public var phase: String
    public var durabilityEntriesChecked: Int64
    public var itemsProjected: Int64
    public var recordsVerified: Int64
    public var originalBytesVerified: Int64
    public var documentPagesVerified: Int64
    public var updatedAt: String
    public var noProgressTimeoutSeconds: Double
    public var indexTrusted: Bool
    public var requiresRecovery: Bool
    public var errorCode: String?
    public var isTerminal: Bool {
        ["completed", "cancelled", "failed", "interruptedRecovered"].contains(state)
    }
    public init(
        jobID: String, operationID: String, state: String = "queued", phase: String = "draining",
        recordsVerified: Int64 = 0, itemsProjected: Int64 = 0, durabilityEntriesChecked: Int64 = 0,
        originalBytesVerified: Int64 = 0,
        documentPagesVerified: Int64 = 0,
        updatedAt: String, noProgressTimeoutSeconds: Double = 120, indexTrusted: Bool = false,
        requiresRecovery: Bool = true, errorCode: String? = nil
    ) {
        self.jobID = jobID
        self.operationID = operationID
        self.state = state
        self.phase = phase
        self.durabilityEntriesChecked = durabilityEntriesChecked
        self.itemsProjected = itemsProjected
        self.recordsVerified = recordsVerified
        self.originalBytesVerified = originalBytesVerified
        self.documentPagesVerified = documentPagesVerified
        self.updatedAt = updatedAt
        self.noProgressTimeoutSeconds = noProgressTimeoutSeconds
        self.indexTrusted = indexTrusted
        self.requiresRecovery = requiresRecovery
        self.errorCode = errorCode
    }
    public func validate() throws {
        try DocumentValue.validateID(jobID)
        guard !operationID.isEmpty,
            operationID.utf8.count <= 200, !operationID.contains("\0"),
            ["queued", "running", "stopping", "completed", "cancelled", "failed", "interruptedRecovered"]
                .contains(state),
            !phase.isEmpty, phase.utf8.count <= 128, recordsVerified >= 0, originalBytesVerified >= 0,
            documentPagesVerified >= 0, itemsProjected >= 0, durabilityEntriesChecked >= 0,
            Timestamp.parse(updatedAt) != nil,
            noProgressTimeoutSeconds.isFinite, noProgressTimeoutSeconds > 0,
            requiresRecovery == !indexTrusted,
            errorCode == nil || errorCode!.utf8.count <= 128
        else {
            throw TractandaError("protocolError", "Invalid bounded rebuild status.")
        }
    }

}
