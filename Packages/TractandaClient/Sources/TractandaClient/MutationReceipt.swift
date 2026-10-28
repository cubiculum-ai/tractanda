import Foundation

/// Wire-only commit acknowledgement. Content and unbounded DAG details are read separately.
public struct MutationReceipt: Codable, Equatable, Sendable {
    public enum Diagnostic: String, Codable, CaseIterable, Hashable, Sendable {
        case indexDelayed, checkpointPending, additionalDiagnostics
    }
    public let itemID: String
    public let revisionID: String
    public let operationID: String
    public let wasReplayed: Bool
    public let isIndexReady: Bool
    public let diagnostics: [Diagnostic]
    private enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case revisionID = "revisionId"
        case operationID = "operationId"
        case wasReplayed = "replayed"
        case isIndexReady = "indexReady"
        case diagnostics
    }
    public init(_ result: CommitResult) throws {
        itemID = result.revision.itemID
        revisionID = result.revision.revisionID
        operationID = result.revision.fields["operationID"]?.string ?? ""
        wasReplayed = result.wasReplayed
        isIndexReady = result.isIndexReady
        var codes: Set<Diagnostic> = []
        for warning in result.warnings {
            switch warning {
            case "Committed; directory durability could not be confirmed.",
                "Committed; an ancestor directory could not be synchronized.":
                throw TractandaError(
                    "serverPartialFail",
                    "Publication durability is unconfirmed; retain the exact operation ID and intent.")
            case "Committed to files; the disposable index will recover before the next request.",
                "Committed to files; index update failed. Rebuild before querying.":
                codes.insert(.indexDelayed)
            case "Committed; checkpoint marker remains and startup will recover fully.":
                codes.insert(.checkpointPending)
            default: codes.insert(.additionalDiagnostics)
            }
        }
        if !isIndexReady { codes.insert(.indexDelayed) }
        diagnostics = Diagnostic.allCases.filter { codes.contains($0) }
        try validate()
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try c.decode(String.self, forKey: .itemID)
        revisionID = try c.decode(String.self, forKey: .revisionID)
        operationID = try c.decode(String.self, forKey: .operationID)
        wasReplayed = try c.decode(Bool.self, forKey: .wasReplayed)
        isIndexReady = try c.decode(Bool.self, forKey: .isIndexReady)
        diagnostics = try c.decode([Diagnostic].self, forKey: .diagnostics)
        try validate()
    }
    public func validate() throws {
        try Identifier.validate(itemID)
        try Identifier.validate(revisionID)
        guard itemID.utf8.count == 36, revisionID.utf8.count == 36,
            !operationID.isEmpty, operationID.utf8.count <= 200, !operationID.contains("\0"),
            diagnostics.count <= Diagnostic.allCases.count, Set(diagnostics).count == diagnostics.count
        else { throw TractandaError("invalidResponse", "Invalid compact mutation receipt.") }
    }

    /// A proved tuple bound: UUIDs are36ASCII bytes, each operation-ID byte can require six
    /// JSON escape bytes, false is the longer Boolean spelling, and diagnostics are a finite set.
    /// This bound includes the exact method/call-ID encoding and is reserved before publication.
    public static func maximumResponseBytes(method: String, callID: String) throws -> Int {
        let diagnosticValues = Diagnostic.allCases.map { JMAPValue.string($0.rawValue) }
        let value = JMAPValue.object([
            .init("itemId", .string(String(repeating: "0", count: 36))),
            .init("revisionId", .string(String(repeating: "0", count: 36))),
            .init("operationId", .string(String(repeating: "\u{1}", count: 200))),
            .init("replayed", .bool(false)), .init("indexReady", .bool(false)),
            .init("diagnostics", .array(diagnosticValues)),
        ])
        return try JMAPInvocation(name: method, arguments: value, callID: callID).value.encoded().count
    }
}
