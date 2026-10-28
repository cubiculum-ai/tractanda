import Foundation

/// Explicit authoring opt-in. Imports and ordinary commits do not interpret hashtags.
public struct CapturePreparation: Codable, Equatable, Sendable {
    public let request: CommitRequest
    public let at: String?
    public init(request: CommitRequest, at: String? = nil) {
        self.request = request
        self.at = at
    }
}

public struct CaptureMention: Codable, Equatable, Sendable {
    public let token: String
    public let categoryID: String?
    public let candidates: [String]
    public let reusedBinding: Bool
    public let dateProperty: String?
    /// YYYY-MM-DD local calendar date, not a timestamp.
    public let dateValue: String?
    public init(
        token: String, categoryID: String?, candidates: [String] = [],
        reusedBinding: Bool = false, dateProperty: String? = nil, dateValue: String? = nil
    ) {
        self.token = token
        self.categoryID = categoryID
        self.candidates = candidates
        self.reusedBinding = reusedBinding
        self.dateProperty = dateProperty
        self.dateValue = dateValue
    }
}

public struct CaptureIssue: Codable, Equatable, Sendable {
    public let token: String
    public let code: String
    public let message: String
    public init(token: String, code: String, message: String) {
        self.token = token
        self.code = code
        self.message = message
    }
}

/// Retain and retry this exact plan after an uncertain write. The server checks it again.
public struct CapturePlan: Codable, Equatable, Sendable {
    public let request: CommitRequest
    public let evaluatedAt: String
    public let commitRequest: CommitRequest
    public let categoryRevisionIDs: [String: String]
    public let mentions: [CaptureMention]
    public let issues: [CaptureIssue]
    public var canCommit: Bool { issues.isEmpty }
    public init(
        request: CommitRequest, evaluatedAt: String, commitRequest: CommitRequest,
        categoryRevisionIDs: [String: String], mentions: [CaptureMention], issues: [CaptureIssue]
    ) {
        self.request = request
        self.evaluatedAt = evaluatedAt
        self.commitRequest = commitRequest
        self.categoryRevisionIDs = categoryRevisionIDs
        self.mentions = mentions
        self.issues = issues
    }
}

extension ItemClient {
    public func prepareCapture(_ preparation: CapturePreparation) async throws -> CapturePlan {
        try await call("TractandaItem/prepareCapture", arguments: preparation, returning: CapturePlan.self)
    }
    public func commitCapture(_ plan: CapturePlan) async throws -> MutationReceipt {
        let receipt = try await call("TractandaItem/commitCapture", arguments: plan, returning: MutationReceipt.self)
        guard receipt.operationID == plan.commitRequest.operationID,
            plan.commitRequest.action == .create || plan.commitRequest.action == .copy
                || receipt.itemID == plan.commitRequest.itemID
        else { throw TractandaError("protocolError", "Capture receipt does not match its intent.") }
        return receipt
    }
}
