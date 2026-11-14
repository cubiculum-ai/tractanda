import Crypto
import Foundation
import TractandaCore

public struct ImportLimits: Codable, Equatable, Sendable {
    public var maximumRecords: Int
    public var maximumPlanBytes: Int
    public var maximumProjectionBytes: Int
    public var maximumLinksPerRecord: Int
    public var maximumOriginalBytes: Int64
    public var maximumJournalBytes: Int
    public var minimumFreeBytes: Int64

    public init(
        maximumRecords: Int = 256, maximumPlanBytes: Int = 8 * 1024 * 1024,
        maximumProjectionBytes: Int = 1024 * 1024, maximumLinksPerRecord: Int = 4096,
        maximumOriginalBytes: Int64 = 1024 * 1024 * 1024,
        maximumJournalBytes: Int = 32 * 1024 * 1024, minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    ) {
        self.maximumRecords = maximumRecords
        self.maximumPlanBytes = maximumPlanBytes
        self.maximumProjectionBytes = maximumProjectionBytes
        self.maximumLinksPerRecord = maximumLinksPerRecord
        self.maximumOriginalBytes = maximumOriginalBytes
        self.maximumJournalBytes = maximumJournalBytes
        self.minimumFreeBytes = minimumFreeBytes
    }

    public func validate() throws {
        guard (1...100_000).contains(maximumRecords),
            (1024...64 * 1024 * 1024).contains(maximumPlanBytes),
            (1024...4 * 1024 * 1024).contains(maximumProjectionBytes),
            (1...100_000).contains(maximumLinksPerRecord), maximumOriginalBytes >= 0,
            (1024...256 * 1024 * 1024).contains(maximumJournalBytes), minimumFreeBytes >= 0
        else { throw TractandaError("importLimits", "Invalid import resource limits.") }
    }
}

public struct ImportDiagnostic: Codable, Equatable, Hashable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case information, warning, unsupported, error
    }
    public var code: String
    public var message: String
    public var severity: Severity
    public var sourceID: String?

    public init(_ code: String, _ message: String, severity: Severity = .warning, sourceID: String? = nil) {
        self.code = code
        self.message = message
        self.severity = severity
        self.sourceID = sourceID
    }
}

public struct ImportOriginal: Codable, Equatable, Sendable {
    public var relativePath: String
    public var filename: String
    public var mediaType: String
    public var byteCount: Int64
    public var sha256: String

    public init(
        relativePath: String, filename: String? = nil, mediaType: String = "application/octet-stream",
        byteCount: Int64, sha256: String
    ) {
        self.relativePath = relativePath
        self.filename = filename ?? URL(fileURLWithPath: relativePath).lastPathComponent
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public func validate() throws {
        _ = try ImportSourceFiles.components(relativePath)
        let mediaParts = mediaType.split(separator: "/", omittingEmptySubsequences: false)
        let validMedia =
            mediaParts.count == 2
            && mediaParts.allSatisfy { part in
                !part.isEmpty
                    && part.utf8.allSatisfy { byte in
                        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                            || "!#$&^_.+-".utf8.contains(byte)
                    }
            }
        guard byteCount >= 0, ImportHash.valid(sha256), !filename.isEmpty,
            filename.utf8.count <= 1024,
            !filename.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
            mediaType.utf8.count <= 255, validMedia
        else { throw TractandaError("importOriginal", "Invalid original-byte descriptor.") }
    }
}

public struct ImportLink: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, external, missing, unsafe, unsupported }
    public var originalTarget: String
    public var targetSourceID: String?
    public var fragment: String?
    public var kind: Kind
    public var sourceLine: Int?
    public var sourceColumn: Int?

    public init(
        originalTarget: String, targetSourceID: String? = nil, fragment: String? = nil, kind: Kind = .local,
        sourceLine: Int? = nil, sourceColumn: Int? = nil
    ) {
        self.originalTarget = originalTarget
        self.targetSourceID = targetSourceID
        self.fragment = fragment
        self.kind = kind
        self.sourceLine = sourceLine
        self.sourceColumn = sourceColumn
    }
}

/// Adapter output is data only. Projection keys never select permissions, classes or server fields.
public struct ImportRecord: Codable, Equatable, Sendable {
    public var sourceID: String
    public var original: ImportOriginal
    public var projection: [String: ItemValue]
    public var links: [ImportLink]
    public var metadata: [String: ItemValue]
    public var diagnostics: [ImportDiagnostic]

    public init(
        sourceID: String, original: ImportOriginal, projection: [String: ItemValue], links: [ImportLink] = [],
        metadata: [String: ItemValue] = [:], diagnostics: [ImportDiagnostic] = []
    ) {
        self.sourceID = sourceID
        self.original = original
        self.projection = projection
        self.links = links
        self.metadata = metadata
        self.diagnostics = diagnostics
    }
}

public struct ImportPlan: Codable, Equatable, Sendable {
    public static let schema = "tractanda.import-plan.v1"
    public var schema: String
    public var namespace: String
    public var adapter: String
    /// Operational source binding, never the logical source namespace.
    public var sourceRoot: String
    public var records: [ImportRecord]
    /// Old source ID -> new source ID. Explicit rename only; disappearance never deletes.
    public var renames: [String: String]
    public var limits: ImportLimits

    public init(
        namespace: String, adapter: String, sourceRoot: String, records: [ImportRecord],
        renames: [String: String] = [:], limits: ImportLimits = ImportLimits()
    ) {
        schema = Self.schema
        self.namespace = namespace
        self.adapter = adapter
        self.sourceRoot = sourceRoot
        self.records = records
        self.renames = renames
        self.limits = limits
    }

    public func validate() throws {
        try limits.validate()
        guard schema == Self.schema, ImportHash.validIdentity(namespace), ImportHash.validIdentity(adapter),
            sourceRoot.hasPrefix("/"), !sourceRoot.contains("\0"),
            records.count <= limits.maximumRecords, Set(records.map(\.sourceID)).count == records.count,
            Set(renames.values).count == renames.count,
            try JSON.encode(self).count <= limits.maximumPlanBytes
        else { throw TractandaError("importPlan", "Invalid, duplicate or oversized import plan.") }
        let ids = Set(records.map(\.sourceID))
        var total: Int64 = 0
        for (old, new) in renames {
            guard ImportHash.validIdentity(old), old != new, ids.contains(new), !ids.contains(old),
                renames[new] == nil
            else {
                throw TractandaError(
                    "importRename", "Renames must identify one old identity and one selected new identity.")
            }
        }
        for record in records {
            try record.original.validate()
            let sum = total.addingReportingOverflow(record.original.byteCount)
            guard ImportHash.validIdentity(record.sourceID), !sum.overflow,
                sum.partialValue <= limits.maximumOriginalBytes,
                record.links.count <= limits.maximumLinksPerRecord,
                try JSON.encode(record.projection).count + JSON.encode(record.metadata).count
                    <= limits.maximumProjectionBytes,
                record.projection.keys.allSatisfy({
                    !ImportFields.forbidden.contains($0) && !$0.hasPrefix("import") && !$0.isEmpty
                        && !$0.contains("\0")
                })
            else { throw TractandaError("importPlan", "Invalid or oversized imported record.") }
            try ItemValue.object(record.projection).validate()
            try ItemValue.object(record.metadata).validate()
            for key in ["subject", "body"] where record.projection[key] != nil {
                guard record.projection[key]?.string != nil else {
                    throw TractandaError("importPlan", "Imported subject and body projections must be text.")
                }
            }
            for link in record.links {
                guard link.originalTarget.utf8.count <= 16_384, !link.originalTarget.contains("\0"),
                    link.targetSourceID.map(ImportHash.validIdentity) ?? true,
                    (link.fragment?.utf8.count ?? 0) <= 16_384,
                    link.sourceLine.map({ $0 > 0 }) ?? true, link.sourceColumn.map({ $0 > 0 }) ?? true
                else { throw TractandaError("importLink", "Invalid imported link.") }
            }
            total = sum.partialValue
        }
    }

    public var sha256: String { get throws { try ImportHash.digest(self) } }
}

public enum ImportDisposition: String, Codable, Sendable {
    case create, update, unchanged, localDivergence, conflict, duplicate, missing, incomplete, tombstone,
        failed
}

public struct ImportOutcome: Codable, Equatable, Sendable {
    public var sourceID: String
    public var disposition: ImportDisposition
    public var itemID: String?
    public var revisionID: String?
    public var diagnostics: [ImportDiagnostic]
    public init(
        sourceID: String, disposition: ImportDisposition, itemID: String? = nil, revisionID: String? = nil,
        diagnostics: [ImportDiagnostic] = []
    ) {
        self.sourceID = sourceID
        self.disposition = disposition
        self.itemID = itemID
        self.revisionID = revisionID
        self.diagnostics = diagnostics
    }
}

public struct ImportReport: Codable, Equatable, Sendable {
    public var schema = "tractanda.import-report.v1"
    public var namespace: String
    public var outcomes: [ImportOutcome]
    public var diagnostics: [ImportDiagnostic]
    public var replication = "local canonical state only; replication acknowledgement not established"
    public init(namespace: String, outcomes: [ImportOutcome] = [], diagnostics: [ImportDiagnostic] = []) {
        self.namespace = namespace
        self.outcomes = outcomes
        self.diagnostics = diagnostics
    }
    public var completeCount: Int {
        outcomes.filter {
            $0.itemID != nil && $0.revisionID != nil
                && [.unchanged, .localDivergence, .update, .create].contains($0.disposition)
        }.count
    }
}

public struct ImportBinding: Codable, Equatable, Sendable {
    public var storeID: String
    public var principal: String
    public var endpoint: String
    public init(storeID: String, principal: String, endpoint: String) {
        self.storeID = storeID
        self.principal = principal
        self.endpoint = endpoint
    }
}

/// Explicit content projection. It omits requestIdentity/ancestry and is never a canonical
/// Revision or a replacement for the exact native revision exported with ItemDirectoryExport.
public struct ImportItemSnapshot: Codable, Equatable, Sendable {
    public let itemID: String
    public let revisionID: String
    public let fields: [String: ItemValue]
    public var isDeleted: Bool { fields["isDeleted"]?.booleanValue == true }
    public init(itemID: String, revisionID: String, fields: [String: ItemValue]) throws {
        try Identifier.validate(itemID)
        try Identifier.validate(revisionID)
        guard fields["itemID"]?.string == itemID, fields["revisionID"]?.string == revisionID,
            fields["requestIdentity"] == nil, fields["revisionAncestry"] == nil
        else {
            throw TractandaError(
                "importProjection",
                "Import content projection has inconsistent identity or includes excluded bookkeeping.")
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.fields = fields
    }
}

enum ImportFields {
    static let schema = "tractanda.source-import.v1"
    static let forbidden: Set<String> = [
        "itemID", "revisionID", "classID", "actor", "operationID", "createdAt", "modifiedAt", "schemaVersion",
        "supersedes", "revisionAncestry", "requestIdentity", "permissions", "attachments", "attachmentText",
        "attachmentDocument", "isDeleted",
    ]
}

enum ImportHash {
    static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { bytes(try JSON.encode(value)) }
    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\0")
    }
}
