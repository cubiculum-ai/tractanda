import Foundation

public struct Holding: Sendable {
    public let key: String
    public let holder: ItemReference
    public let start: Date
    public let end: Date?
}

public enum RoleSemantics {
    public static func holdings(_ revision: Revision) throws -> [Holding] {
        guard revision.classID == "RoleItem" else { return [] }
        guard revision.fields["holder"] == nil else {
            throw TractandaError(
                "invalidRole", "holder is derived from holdings; it is not a second stored property.")
        }
        guard let value = revision.fields["holdings"] else { return [] }
        guard let entries = value.array else {
            throw TractandaError("invalidRole", "holdings must be a list.")
        }
        let holdings = try entries.map { value -> Holding in
            guard let entry = value.map, let key = entry["key"]?.string, !key.isEmpty,
                let holder = entry["holder"]?.link,
                let startText = entry["start"]?.dateString, let start = Timestamp.parse(startText)
            else {
                throw TractandaError(
                    "invalidRole", "A holding needs key, holder reference and start timestamp.")
            }
            var end: Date?
            if let value = entry["end"] {
                guard let text = value.dateString, let date = Timestamp.parse(text), date > start else {
                    throw TractandaError("invalidRole", "Holding end must be a timestamp after start.")
                }
                end = date
            }
            return Holding(key: key, holder: holder, start: start, end: end)
        }.sorted { $0.start < $1.start }
        guard Set(holdings.map(\.key)).count == holdings.count else {
            throw TractandaError("invalidRole", "Duplicate holding key.")
        }
        for i in holdings.indices.dropFirst() {
            guard let end = holdings[i - 1].end, end <= holdings[i].start else {
                throw TractandaError("invalidRole", "This prototype permits at most one holder at any time.")
            }
        }
        return holdings
    }
    public static func holder(_ revision: Revision, at date: Date) throws -> ItemReference? {
        try holdings(revision).first { $0.start <= date && ($0.end == nil || date < $0.end!) }?.holder
    }
}

public enum ItemSemantics {
    public static func validate(_ revision: Revision) throws {
        guard !ItemTypes.abstract.contains(revision.classID) else {
            throw TractandaError("abstractClass", "Choose a concrete item class.")
        }
        for key in revision.fields.keys where key.isEmpty || key.contains("\0") {
            throw TractandaError("invalidKey", "Empty/NUL property key.")
        }
        _ = try RoleSemantics.holdings(revision)
        _ = try CategoryHierarchy.parents(of: revision)
        _ = try ItemReferenceLabel.labels(in: revision)
        _ = try CategoryHierarchy.excludedCategories(
            revision.fields["selection"]?.map?["excludedCategoryIDs"])
        if let order = revision.fields["categoryOrder"], order.integerValue == nil {
            throw TractandaError("invalidCategory", "categoryOrder must be an integer.")
        }
        if let value = revision.fields["permissions"] { _ = try ItemPermissions(value) }
        if revision.classID == AccessConfiguration.classID {
            guard !revision.isDeleted, let value = revision.fields["accessConfiguration"] else {
                throw TractandaError(
                    "invalidAccessConfiguration", "An access configuration cannot be deleted.")
            }
            _ = try AccessConfiguration(value)
        }
        if let overrides = revision.fields["personalOverrides"] {
            guard revision.classID == "PersonalStateItem",
                let target = revision.fields["target"]?.link, target.revisionID == nil,
                let entries = overrides.map
            else {
                throw TractandaError(
                    "invalidPersonalState", "Personal overrides need an unpinned target item.")
            }
            for (id, decision) in entries {
                try Identifier.validate(id)
                guard decision.string == "include" || decision.string == "exclude" else {
                    throw TractandaError("invalidPersonalState", "Personal overrides are include or exclude.")
                }
            }
        }
        _ = try CategoryLearningSettings(revision.fields["learningSettings"])
        if let value = revision.fields["learningFeedback"] {
            guard let feedback = value.map else {
                throw TractandaError("invalidLearningFeedback", "learningFeedback must be an object.")
            }
            for (id, value) in feedback {
                try Identifier.validate(id)
                _ = try LearningFeedback(value)
            }
        }
        if let definition = revision.fields["viewDefinition"] { _ = try SavedViewDefinition(definition) }
        if let selection = revision.fields["selection"] {
            guard let map = selection.map, map["language"]?.string == SpotlightQuery.profile,
                let expression = map["expression"]?.string
            else {
                throw TractandaError("invalidSelection", "selection needs language and expression.")
            }
            _ = try SpotlightQuery(expression)
            if let zone = map["timeZone"] {
                guard let name = zone.string else {
                    throw TractandaError("invalidSelection", "timeZone must be text.")
                }
                _ = try QueryCalendar.make(timeZone: name)
            }
            if let window = map["timeWindow"] { _ = try CategoryTimeWindow(window) }
        }
        if let overrides = revision.fields["categoryOverrides"] {
            guard let map = overrides.map else {
                throw TractandaError("invalidCategory", "categoryOverrides must be an object.")
            }
            for (id, value) in map {
                try Identifier.validate(id)
                guard value.string == "include" || value.string == "exclude" else {
                    throw TractandaError(
                        "invalidCategory", "An override is include or exclude; remove the key to reset.")
                }
            }
        }
        if let waiting = revision.fields["waitingOn"] {
            guard waiting.link != nil || waiting.string != nil else {
                throw TractandaError(
                    "invalidWaitingOn", "waitingOn is a person/event reference or explanatory text.")
            }
        }
    }
}

extension PersonItem {
    public var displayName: String { self["displayName"]?.string ?? subject }
    public var phone: String? { self["phone"]?.string }
}
extension RoleItem {
    public func holder(at date: Date = Date()) throws -> ItemReference? {
        try RoleSemantics.holder(revision, at: date)
    }
}
public struct Resolution: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case value, unsetField, unsetReference, accessDenied, resolutionError
    }
    public let status: Status
    public let value: ItemValue?
    public let visited: [ItemReference]
    public let error: TractandaError?
}

public enum ItemPath {
    /// Backslash escapes a literal dot or backslash; a segment list is also available in the API.
    public static func parse(_ path: String) throws -> [String] {
        var segments: [String] = []
        var current = ""
        var escaped = false
        for ch in path {
            if escaped {
                guard ch == "." || ch == "\\" else {
                    throw TractandaError("invalidPath", "Only dots and backslashes need escaping.")
                }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "." {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)
        guard !escaped, !segments.contains(""), segments.count <= 32 else {
            throw TractandaError("invalidPath", "Empty or excessive path segments.")
        }
        return segments
    }
    public static func resolve(
        _ root: ItemReference, segments: [String], at date: Date = Date(),
        read: (ItemReference) throws -> Revision
    ) -> Resolution {
        var visited: [ItemReference] = []
        func result(_ status: Resolution.Status, _ value: ItemValue? = nil, _ error: TractandaError? = nil)
            -> Resolution
        {
            Resolution(status: status, value: value, visited: visited, error: error)
        }
        guard !segments.isEmpty, segments.count <= 32, !segments.contains("") else {
            return result(
                .resolutionError, nil, TractandaError("invalidPath", "Supply 1–32 nonempty path segments."))
        }
        do {
            var record: Revision? = try read(root)
            visited.append(ItemReference(record!.itemID, revisionID: record!.revisionID))
            var fields = record!.fields
            for (i, segment) in segments.enumerated() {
                let value: ItemValue?
                if segment == "holder", let record, record.classID == "RoleItem" {
                    value = try RoleSemantics.holder(record, at: date).map(ItemValue.reference)
                    if value == nil { return result(.unsetReference) }
                } else {
                    value = fields[segment]
                }
                guard let value else { return result(.unsetField) }
                if i == segments.count - 1 { return result(.value, value) }
                switch value {
                case .object(let map):
                    fields = map
                    record = nil
                case .reference(let reference):
                    let target = try read(reference)
                    guard !target.isDeleted else {
                        throw TractandaError("targetDeleted", "The referenced item is deleted.")
                    }
                    record = target
                    fields = target.fields
                    visited.append(ItemReference(target.itemID, revisionID: target.revisionID))
                default:
                    throw TractandaError(
                        "invalidPath", "A scalar or list cannot be traversed as an item/object.")
                }
            }
            return result(.unsetField)
        } catch let error as TractandaError where error.code == "forbidden" {
            return result(.accessDenied)
        } catch let error as TractandaError { return result(.resolutionError, nil, error) } catch {
            return result(.resolutionError, nil, TractandaError("readError", String(describing: error)))
        }
    }
}
