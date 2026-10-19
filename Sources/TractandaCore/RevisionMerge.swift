import Foundation

enum RevisionMerge {
    static let profile = "tractanda.merge.v2"
    static let managedFields: Set<String> = [
        "itemID", "revisionID", "createdAt", "modifiedAt", "supersedes", "actor", "operationID",
        "requestIdentity", "revisionAncestry",
    ]
    static let protectedFields: Set<String> = [
        "classID", "schemaVersion", "permissions", "isDeleted", "accessConfiguration",
        "selection", "categoryParents", "categoryOrder", "categoryOverrides", "categoryAssignments",
        "categoryExclusions",
        "captureAliases", "captureDate", "templateKey", "learningFeedback", "attachments",
        "attachmentText", "attachmentDocument", "viewDefinition", "personalState", "personalOverrides",
        "target", "learningSettings",
    ]
    static let protectedClasses: Set<String> = [
        "CategoryItem", "PersonalStateItem", "AccessConfigurationItem",
    ]

    struct Candidate: Equatable, Sendable {
        let revisionID: String
        let write: RevisionFieldWrite
    }

    struct Analysis: Equatable, Sendable {
        let frontier: [String]
        let values: [String: RevisionFieldWrite]
        let conflicts: [String: [Candidate]]
        let protectedFields: Set<String>
        let representativeRevisionID: String?
        let needsMaterialization: Bool

        var isResolved: Bool { conflicts.isEmpty && protectedFields.isEmpty }
        var fields: [String: ItemValue] {
            values.reduce(into: [:]) { result, pair in
                if case .set(let value) = pair.value { result[pair.key] = value }
            }
        }
    }

    /// A factory allocation and a validated plan; deliberately not a canonical Revision/receipt.
    struct Draft: Equatable, Sendable {
        let itemID: String
        let revisionID: String
        let parents: [String]
        let frontier: [String]
        let profile: String
        let fields: [String: ItemValue]
        let modifiedAt: String
    }

    static func semanticFields(_ revision: Revision) -> [String: ItemValue] {
        revision.fields.filter { !managedFields.contains($0.key) }
    }

    static func node(_ revision: Revision, parent: Revision? = nil) throws -> RevisionGraph.Node {
        guard let provenance = try revision.provenance else {
            return try legacyNode(revision, parent: parent)
        }
        try provenance.validate(in: revision.fields)
        var writes = Dictionary(
            uniqueKeysWithValues: provenance.writtenFields.map {
                ($0, RevisionFieldWrite.set(revision.fields[$0]!))
            })
        for field in provenance.unsetFields { writes[field] = .unset }
        let kind: RevisionAncestry.Kind
        switch provenance.kind {
        case .authored: kind = .authored(writes: writes)
        case .automaticMerge:
            kind = .automaticMerge(profile: provenance.mergeProfile!, frontier: provenance.frontier)
        case .resolution: kind = .resolution(reviewedFrontier: provenance.frontier, writes: writes)
        }
        return RevisionGraph.Node(revision: revision, parents: provenance.parents, kind: kind)
    }

    /// Existing linear snapshots remain immutable. Applied deltas do not pretend that
    /// retained client requests contain defaults, copy transforms or server-managed writes.
    static func legacyNode(_ revision: Revision, parent: Revision?) throws -> RevisionGraph.Node {
        try revision.validate()
        let fields = semanticFields(revision)
        var writes: [String: RevisionFieldWrite] = [:]
        if let parent {
            guard revision.supersedes == parent.revisionID, revision.itemID == parent.itemID else {
                throw TractandaError("invalidRevisionGraph", "Legacy predecessor does not match.")
            }
            let old = semanticFields(parent)
            for key in Set(old.keys).union(fields.keys) where old[key] != fields[key] {
                writes[key] = fields[key].map(RevisionFieldWrite.set) ?? .unset
            }
        } else {
            guard revision.supersedes == nil else {
                throw TractandaError("invalidRevisionGraph", "Legacy predecessor is missing.")
            }
            writes = fields.mapValues(RevisionFieldWrite.set)
        }
        return RevisionGraph.Node(
            revision: revision, parents: parent.map { [$0.revisionID] } ?? [],
            kind: .authored(writes: writes))
    }

    /// Exact 100 ns ticks; supported Gregorian years 0001...9999, seconds 00...59,
    /// optional 1...7 fraction digits and Z or a numeric UTC offset. No Double comparison.
    static func timestamp(after inputs: [String], now: () -> String) throws -> String {
        guard !inputs.isEmpty, inputs.count <= 4096 else {
            throw TractandaError("invalidMergeTimestamp", "A merge needs timestamp inputs.")
        }
        let maximum = try inputs.map(RevisionTimestamp.init).map(\.ticks).max()!
        let current = try RevisionTimestamp(now()).ticks
        let successor = maximum.addingReportingOverflow(1)
        guard !successor.overflow else {
            throw TractandaError("invalidMergeTimestamp", "Merge timestamp exhausted its range.")
        }
        return try RevisionTimestamp(ticks: max(current, successor.partialValue)).formatted()
    }
}

struct RevisionTimestamp: Comparable, Sendable {
    let ticks: Int64
    private static let frequency: Int64 = 10_000_000

    init(_ text: String) throws {
        let bytes = Array(text.utf8.prefix(36))
        func failure() -> TractandaError {
            TractandaError("invalidMergeTimestamp", "Unsupported or invalid exact revision timestamp.")
        }
        guard (20...35).contains(bytes.count), bytes[4] == 45, bytes[7] == 45,
            bytes[10] == 84, bytes[13] == 58, bytes[16] == 58
        else { throw failure() }
        func number(_ start: Int, _ count: Int) throws -> Int {
            guard start >= 0, start + count <= bytes.count else { throw failure() }
            var result = 0
            for byte in bytes[start..<start + count] {
                guard (48...57).contains(byte) else { throw failure() }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        let year = try number(0, 4)
        let month = try number(5, 2)
        let day = try number(8, 2)
        let hour = try number(11, 2)
        let minute = try number(14, 2)
        let second = try number(17, 2)
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
            (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second)
        else { throw failure() }
        let months = Self.monthLengths(year)
        guard day <= months[month - 1] else { throw failure() }
        var position = 19
        var fraction: Int64 = 0
        if bytes[position] == 46 {
            position += 1
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            let digits = position - start
            guard (1...7).contains(digits) else { throw failure() }
            fraction = Int64(try number(start, digits))
            for _ in digits..<7 { fraction *= 10 }
        }
        let offset: Int
        if position + 1 == bytes.count, bytes[position] == 90 {
            offset = 0
        } else {
            guard position + 6 == bytes.count, [43, 45].contains(bytes[position]),
                bytes[position + 3] == 58
            else { throw failure() }
            let hours = try number(position + 1, 2)
            let minutes = try number(position + 4, 2)
            guard hours <= 23, minutes <= 59 else { throw failure() }
            offset = (hours * 3600 + minutes * 60) * (bytes[position] == 43 ? 1 : -1)
        }
        let ordinal = Self.daysBeforeYear(year) + Int64(months.prefix(month - 1).reduce(0, +) + day - 1)
        let midnight = (ordinal - Self.unixEpochDay) * 86_400
        let seconds = midnight + Int64(hour * 3600 + minute * 60 + second - offset)
        ticks = seconds * Self.frequency + fraction
        _ = try formatted()
    }

    init(ticks: Int64) { self.ticks = ticks }

    func formatted() throws -> String {
        var seconds = ticks / Self.frequency
        var fraction = ticks % Self.frequency
        if fraction < 0 {
            seconds -= 1
            fraction += Self.frequency
        }
        var day = seconds / 86_400
        var daytime = seconds % 86_400
        if daytime < 0 {
            day -= 1
            daytime += 86_400
        }
        let ordinal = day + Self.unixEpochDay
        guard ordinal >= 0, ordinal < Self.daysBeforeYear(10_000) else {
            throw TractandaError("invalidMergeTimestamp", "Merge timestamp is outside supported years.")
        }
        var lower = 1
        var upper = 10_000
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if Self.daysBeforeYear(middle) <= ordinal { lower = middle } else { upper = middle }
        }
        var remainder = Int(ordinal - Self.daysBeforeYear(lower))
        let months = Self.monthLengths(lower)
        var month = 0
        while remainder >= months[month] {
            remainder -= months[month]
            month += 1
        }
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%07lldZ", lower, month + 1, remainder + 1,
            Int(daytime / 3600), Int(daytime % 3600 / 60), Int(daytime % 60), fraction)
    }

    private static let unixEpochDay: Int64 = 719_162

    private static func daysBeforeYear(_ year: Int) -> Int64 {
        let prior = Int64(year - 1)
        return prior * 365 + prior / 4 - prior / 100 + prior / 400
    }

    private static func monthLengths(_ year: Int) -> [Int] {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }

    static func < (left: Self, right: Self) -> Bool { left.ticks < right.ticks }
}
