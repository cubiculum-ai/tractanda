import Foundation

func savedViewClockKey(at date: Date, timeZone: String) -> String {
    String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16) + "\0" + timeZone
}

/// The initial portable profile is deliberately smaller than Spotlight's grammar.
/// It evaluates typed metadata; lexical phrase retrieval uses SQLite FTS5 separately.
public struct SpotlightQuery: Sendable {
    public static let profile = "tractanda.spotlight.v0"
    private let expression: Expression
    public init(_ text: String) throws {
        var parser = try Parser(text)
        expression = try parser.parse()
    }
    public func matches(_ revision: Revision, at date: Date = Date(), calendar: Calendar = QueryCalendar.utc)
        -> Bool
    {
        expression.matches(revision, at: date, calendar: calendar)
    }
    /// A safe candidate restriction only. The full expression is still evaluated on each
    /// candidate, so type and wildcard semantics remain those of SpotlightQuery.
    var indexClassEquals: String? { expression.indexClassEquals }
    var indexExactClassEquals: String? {
        if case .comparison = expression { return expression.indexClassEquals }
        return nil
    }
    var indexDependencies: (fields: Set<String>, usesClock: Bool) { expression.indexDependencies }
    var indexCandidatePlan: IndexCandidatePlan { expression.indexCandidatePlan }
    var indexCandidateRestrictions: [IndexCandidateRestriction] { expression.legacyRestrictions }
    var boundedIndexCandidatePlan: IndexCandidatePlan {
        let plan = expression.indexCandidatePlan
        return plan.atomCount <= 16 ? plan : .all
    }
    /// A request-clock-specific safe superset for relative date ranges. Only `$time.now`
    /// has an exact absolute boundary here; calendar windows retain exact fallback.
    func boundedIndexCandidatePlan(at date: Date, calendar: Calendar) -> IndexCandidatePlan {
        let plan = expression.indexCandidatePlan(at: date, calendar: calendar)
        return plan.atomCount <= 16 ? plan : .all
    }
    /// One exact, non-clock equality atom has a selective indexed candidate source and
    /// can be maintained per changed item. More complex expressions stay on the exact path.
    var supportsPersistentSavedViewMaterialization: Bool {
        guard case .comparison(_, let operation, let flags, let literal) = expression,
            operation == "==", flags.isEmpty, !indexDependencies.usesClock,
            !boundedIndexCandidatePlan.isAll
        else { return false }
        if case .text(let value) = literal {
            return !value.contains("*") && !value.contains("?") && !value.contains("\\")
        }
        switch literal {
        case .integer, .number, .boolean, .date: return true
        case .text, .exists, .relative: return false
        }
    }
    /// True only when the parsed expression proves that no canonical item can match.
    /// Item IDs are validated nonempty, so this exact comparison is impossible.
    var isManualOnlyImpossible: Bool { expression.isManualOnlyImpossible }

    private enum Literal: Sendable {
        case text(String)
        case integer(Int64)
        case number(Double)
        case boolean(Bool)
        case exists
        case relative(String, Int)
        case date(Date)
    }
    struct IndexCandidateRestriction: Sendable {
        let field: String
        let operation: String
        let value: String
        let kind: String
        init(field: String, operation: String, value: String, kind: String = "") {
            self.field = field
            self.operation = operation
            self.value = value
            self.kind = kind
        }
    }
    indirect enum IndexCandidatePlan: Sendable {
        case all
        case atom(IndexCandidateRestriction)
        case categoryIncludes(Set<String>)
        case categoryDecisions(Set<String>)
        case personalCategoryDeltas(Set<String>)
        case savedViewBase(String)
        case and(IndexCandidatePlan, IndexCandidatePlan)
        case or(IndexCandidatePlan, IndexCandidatePlan)
        var isAll: Bool {
            if case .all = self { return true }
            return false
        }
        var containsSavedViewBase: Bool {
            switch self {
            case .savedViewBase: true
            case .and(let left, let right), .or(let left, let right):
                left.containsSavedViewBase || right.containsSavedViewBase
            default: false
            }
        }
        var atomCount: Int {
            switch self {
            case .all: 0
            case .atom: 1
            case .categoryIncludes, .categoryDecisions, .personalCategoryDeltas, .savedViewBase: 1
            case .and(let left, let right), .or(let left, let right): left.atomCount + right.atomCount
            }
        }
    }
    private indirect enum Expression: Sendable {
        case and(Expression, Expression)
        case or(Expression, Expression)
        case comparison(String, String, String, Literal)
        var indexClassEquals: String? {
            switch self {
            case .and(let left, let right):
                return left.indexClassEquals ?? right.indexClassEquals
            case .or:
                return nil
            case .comparison(let field, let op, let flags, let literal):
                guard ["classID", "kMDItemContentType"].contains(field), op == "==", flags.isEmpty,
                    case .text(let value) = literal,
                    !value.contains("*"), !value.contains("?"), !value.contains("\\")
                else { return nil }
                return value
            }
        }
        var indexDependencies: (fields: Set<String>, usesClock: Bool) {
            switch self {
            case .and(let left, let right), .or(let left, let right):
                let a = left.indexDependencies
                let b = right.indexDependencies
                return (a.fields.union(b.fields), a.usesClock || b.usesClock)
            case .comparison(let field, _, _, let literal):
                let key = field == "kMDItemContentTypeTree" ? "classID" : metadataKey(field)
                if case .relative = literal { return ([key], true) }
                return ([key], false)
            }
        }
        var indexCandidatePlan: IndexCandidatePlan {
            switch self {
            case .and(let left, let right):
                let a = left.indexCandidatePlan
                let b = right.indexCandidatePlan
                if case .all = a { return b }
                if case .all = b { return a }
                return .and(a, b)
            case .or(let left, let right):
                let a = left.indexCandidatePlan
                let b = right.indexCandidatePlan
                guard !a.isAll, !b.isAll else { return .all }
                return .or(a, b)
            case .comparison(let field, let op, let flags, let literal):
                guard flags.isEmpty else { return .all }
                // This Spotlight property is synthesized from the item class, not stored
                // as a top-level field_presence row.
                if field == "kMDItemContentTypeTree" { return .all }
                if field == "itemID", op == "==", case .text(let value) = literal,
                    let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value
                {
                    return .atom(.init(field: "itemID", operation: "=", value: value, kind: ""))
                }
                let key = metadataKey(field)
                guard !key.isEmpty else { return .all }
                if case .exists = literal, ["==", "!="].contains(op) {
                    return .atom(.init(field: key, operation: op, value: "", kind: "exists"))
                }
                guard ["==", "!=", "<", "<=", ">", ">="].contains(op) else { return .all }
                switch literal {
                case .boolean(let value) where op == "==":
                    return .atom(.init(field: key, operation: "=", value: value ? "1" : "0", kind: "boolean"))
                case .integer(let value):
                    return .atom(.init(field: key, operation: op, value: String(value), kind: "integer"))
                case .number(let value) where value.isFinite:
                    return .atom(.init(field: key, operation: op, value: String(value), kind: "real"))
                case .date(let value) where value.timeIntervalSinceReferenceDate.isFinite:
                    return .atom(
                        .init(
                            field: key, operation: op, value: String(value.timeIntervalSinceReferenceDate),
                            kind: "date"))
                case .text(let value)
                where op == "=="
                    && !value.contains("*") && !value.contains("?") && !value.contains("\\"):
                    // The text comparator folds Unicode. Presence is a safe superset;
                    // exact matching remains in SpotlightQuery.
                    return .atom(.init(field: key, operation: op, value: "", kind: "exists"))
                default: return .all
                }
            }
        }
        func indexCandidatePlan(at date: Date, calendar: Calendar) -> IndexCandidatePlan {
            switch self {
            case .and(let left, let right):
                let a = left.indexCandidatePlan(at: date, calendar: calendar)
                let b = right.indexCandidatePlan(at: date, calendar: calendar)
                if a.isAll { return b }
                if b.isAll { return a }
                return .and(a, b)
            case .or(let left, let right):
                let a = left.indexCandidatePlan(at: date, calendar: calendar)
                let b = right.indexCandidatePlan(at: date, calendar: calendar)
                guard !a.isAll, !b.isAll else { return .all }
                return .or(a, b)
            case .comparison(let field, let operation, let flags, .relative(let name, let offset)):
                guard name == "$time.now", flags.isEmpty,
                    field != "kMDItemContentTypeTree",
                    ["==", "<", "<=", ">", ">="].contains(operation),
                    let boundary = calendar.date(byAdding: .second, value: offset, to: date),
                    boundary.timeIntervalSinceReferenceDate.isFinite
                else { return .all }
                return .atom(
                    .init(
                        field: metadataKey(field), operation: operation,
                        value: String(boundary.timeIntervalSinceReferenceDate), kind: "date"))
            case .comparison:
                return indexCandidatePlan
            }
        }
        var legacyRestrictions: [IndexCandidateRestriction] {
            switch self {
            case .and(let left, let right): return left.legacyRestrictions + right.legacyRestrictions
            case .or: return []
            case .comparison(let field, let op, let flags, let literal):
                guard flags.isEmpty else { return [] }
                if field == "itemID", op == "==", case .text(let value) = literal,
                    let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value
                {
                    return [.init(field: "itemID", operation: "=", value: value, kind: "")]
                }
                let key = metadataKey(field)
                guard ["createdAt", "modifiedAt"].contains(key),
                    ["==", "<", "<=", ">", ">="].contains(op), case .date(let date) = literal,
                    date.timeIntervalSinceReferenceDate.isFinite
                else { return [] }
                return [
                    .init(
                        field: key, operation: op == "==" ? "=" : op,
                        value: String(date.timeIntervalSinceReferenceDate), kind: "date")
                ]
            }
        }
        var isManualOnlyImpossible: Bool {
            switch self {
            case .and(let left, let right):
                return left.isManualOnlyImpossible || right.isManualOnlyImpossible
            case .or:
                return false
            case .comparison(let field, let op, let flags, let literal):
                guard field == "itemID", op == "==", flags.isEmpty,
                    case .text(let value) = literal
                else { return false }
                return value.isEmpty
            }
        }
        func matches(_ revision: Revision, at date: Date, calendar: Calendar) -> Bool {
            switch self {
            case .and(let a, let b):
                return a.matches(revision, at: date, calendar: calendar)
                    && b.matches(revision, at: date, calendar: calendar)
            case .or(let a, let b):
                return a.matches(revision, at: date, calendar: calendar)
                    || b.matches(revision, at: date, calendar: calendar)
            case .comparison(let field, let op, let flags, let literal):
                let value: ItemValue?
                if field == "kMDItemContentTypeTree" {
                    value = .list(ItemTypes.ancestry(revision.classID).map(ItemValue.text))
                } else {
                    value = revision.fields[metadataKey(field)]
                }
                if case .exists = literal { return op == "==" ? value != nil : value == nil }
                // Missing fields do not satisfy comparisons, including !=.
                guard let value else { return false }
                let values = value.array ?? [value]
                if op == "!=" {
                    return !values.contains { Self.compare($0, "==", flags, literal, date, calendar) }
                }
                return values.contains { Self.compare($0, op, flags, literal, date, calendar) }
            }
        }
        private static func compare(
            _ value: ItemValue, _ op: String, _ flags: String, _ literal: Literal, _ date: Date,
            _ calendar: Calendar
        ) -> Bool {
            if case .integer(let actual) = value, case .integer(let expected) = literal {
                // Preserve all Int64 bits; converting both sides to Double would
                // make adjacent integers above 2^53 appear equal.
                return ordered(actual, op, expected)
            }
            if case .text(let pattern) = literal, case .text(let actual) = value {
                guard op == "==" else { return false }
                var options: String.CompareOptions = []
                if flags.contains("c") { options.insert(.caseInsensitive) }
                if flags.contains("d") { options.insert(.diacriticInsensitive) }
                let locale = Locale(identifier: "en_US_POSIX")
                return glob(
                    actual.folding(options: options, locale: locale),
                    pattern.folding(options: options, locale: locale))
            }
            if case .boolean(let expected) = literal, case .boolean(let actual) = value {
                return op == "==" && actual == expected
            }
            let actual: Double
            switch value {
            case .integer(let n): actual = Double(n)
            case .real(let n): actual = n
            case .date(let s):
                guard let d = Timestamp.parse(s) else { return false }
                actual = d.timeIntervalSinceReferenceDate
            default: return false
            }
            let expected: Double
            switch literal {
            case .integer(let n): expected = Double(n)
            case .number(let n): expected = n
            case .relative(let name, let offset):
                let component: Calendar.Component
                switch name {
                case "$time.now": component = .second
                case "$time.this_week": component = .weekOfYear
                case "$time.this_month": component = .month
                case "$time.this_year": component = .year
                default: component = .day
                }
                let anchor =
                    name == "$time.now" ? date : calendar.dateInterval(of: component, for: date)!.start
                guard
                    let relative = calendar.date(
                        byAdding: component, value: offset + (name == "$time.yesterday" ? -1 : 0), to: anchor)
                else { return false }
                expected = relative.timeIntervalSinceReferenceDate
            case .date(let d): expected = d.timeIntervalSinceReferenceDate
            default: return false
            }
            return ordered(actual, op, expected)
        }
        private static func ordered<T: Comparable>(_ actual: T, _ op: String, _ expected: T) -> Bool {
            switch op {
            case "==": return actual == expected
            case "<": return actual < expected
            case "<=": return actual <= expected
            case ">": return actual > expected
            case ">=": return actual >= expected
            default: return false
            }
        }
    }

    private enum Token: Equatable {
        case word(String)
        case string(String)
        case symbol(String)
        case end
    }
    private struct Parser {
        var tokens: [Token] = []
        var position = 0
        init(_ text: String) throws {
            guard !text.isEmpty, text.utf8.count <= 4096 else {
                throw Self.error("Expression must contain 1–4096 bytes.")
            }
            let chars = Array(text)
            var p = 0
            while p < chars.count {
                let ch = chars[p]
                if ch.isWhitespace {
                    p += 1
                    continue
                }
                if ch == "\"" || ch == "'" {
                    let quote = ch
                    p += 1
                    var value = ""
                    var closed = false
                    while p < chars.count {
                        let c = chars[p]
                        p += 1
                        if c == quote {
                            closed = true
                            break
                        }
                        if c == "\\" {
                            guard p < chars.count else { throw Self.error("Incomplete string escape.") }
                            let escaped = chars[p]
                            p += 1
                            guard escaped == quote || escaped == "\\" || escaped == "*" || escaped == "?"
                            else {
                                throw Self.error("Unsupported string escape.")
                            }
                            if escaped != quote { value.append("\\") }
                            value.append(escaped)
                        } else {
                            value.append(c)
                        }
                    }
                    guard closed else { throw Self.error("Unterminated quoted string.") }
                    tokens.append(.string(value))
                    continue
                }
                if p + 1 < chars.count {
                    let pair = String(chars[p...p + 1])
                    if ["==", "!=", "<=", ">=", "&&", "||"].contains(pair) {
                        tokens.append(.symbol(pair))
                        p += 2
                        continue
                    }
                }
                if "()[]<>*".contains(ch) {
                    tokens.append(.symbol(String(ch)))
                    p += 1
                    continue
                }
                if ch.isASCII && (ch.isLetter || ch.isNumber || "_.$-+".contains(ch)) {
                    var word = ""
                    while p < chars.count, chars[p].isASCII,
                        chars[p].isLetter || chars[p].isNumber || "_.$-+".contains(chars[p])
                    {
                        word.append(chars[p])
                        p += 1
                    }
                    tokens.append(.word(word))
                    continue
                }
                throw Self.error("Unsupported character: \(ch)")
            }
            guard tokens.count <= 512 else { throw Self.error("Too many query tokens.") }
            tokens.append(.end)
        }
        static func error(_ text: String) -> TractandaError { TractandaError("unsupportedQuery", text) }
        var peek: Token { tokens[position] }
        mutating func take() -> Token {
            defer { position += 1 }
            return tokens[position]
        }
        mutating func consume(_ symbol: String) -> Bool {
            if peek == .symbol(symbol) {
                position += 1
                return true
            }
            return false
        }
        mutating func require(_ symbol: String) throws {
            guard consume(symbol) else { throw Self.error("Expected \(symbol).") }
        }
        mutating func parse() throws -> Expression {
            let result = try disjunction(0)
            guard peek == .end else { throw Self.error("Unexpected trailing query syntax.") }
            return result
        }
        mutating func disjunction(_ depth: Int) throws -> Expression {
            var result = try conjunction(depth)
            while consume("||") { result = .or(result, try conjunction(depth)) }
            return result
        }
        mutating func conjunction(_ depth: Int) throws -> Expression {
            var result = try primary(depth)
            while consume("&&") { result = .and(result, try primary(depth)) }
            return result
        }
        mutating func primary(_ depth: Int) throws -> Expression {
            guard depth < 32 else { throw Self.error("Query nesting exceeds 32 levels.") }
            if consume("(") {
                let result = try disjunction(depth + 1)
                try require(")")
                return result
            }
            guard case .word(let field) = take(),
                field.first?.isLetter == true || field.first == "_",
                field.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else {
                throw Self.error("Expected an attribute name. Reference paths are a separate API in v0.")
            }
            guard case .symbol(let op) = take(), ["==", "!=", "<", ">", "<=", ">="].contains(op) else {
                throw Self.error("Expected a comparison operator.")
            }
            var flags = ""
            if consume("[") {
                guard case .word(let modifiers) = take(), ["c", "d", "cd", "dc"].contains(modifiers) else {
                    throw Self.error("Only [c], [d] and [cd] modifiers are supported.")
                }
                flags = modifiers
                try require("]")
            }
            let literal: Literal
            switch take() {
            case .string(let s): literal = .text(s)
            case .symbol("*"): literal = .exists
            case .word("true"): literal = .boolean(true)
            case .word("false"): literal = .boolean(false)
            case .word(let name)
            where [
                "$time.now", "$time.today", "$time.yesterday", "$time.this_week", "$time.this_month",
                "$time.this_year",
            ].contains(name):
                var offset = 0
                if consume("(") {
                    guard case .word(let text) = take(), let number = Int(text),
                        (-120000...120000).contains(number)
                    else {
                        throw Self.error("A relative time offset must be a bounded integer.")
                    }
                    offset = number
                    try require(")")
                }
                literal = .relative(name, offset)
            case .word("$time.iso"):
                try require("(")
                guard case .string(let s) = take(), let date = Timestamp.parse(s) else {
                    throw Self.error("Invalid ISO timestamp.")
                }
                try require(")")
                literal = .date(date)
            case .word(let s):
                guard let number = Double(s), number.isFinite else {
                    throw Self.error("Expected a quoted string, number or supported time value.")
                }
                literal = Int64(s).map(Literal.integer) ?? .number(number)
            default: throw Self.error("Expected a comparison value.")
            }
            switch literal {
            case .text, .boolean, .exists:
                guard op == "==" || op == "!=" else {
                    throw Self.error("Ordering is available for numbers and dates only.")
                }
            default: break
            }
            if !flags.isEmpty, case .text = literal {
            } else if !flags.isEmpty {
                throw Self.error("String modifiers require a string value.")
            }
            return .comparison(field, op, flags, literal)
        }
    }
    private enum GlobToken {
        case literal(Character)
        case one, many
    }
    private static func glob(_ text: String, _ pattern: String) -> Bool {
        var tokens: [GlobToken] = []
        var escaped = false
        for c in pattern {
            if escaped {
                tokens.append(.literal(c))
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "*" {
                tokens.append(.many)
            } else if c == "?" {
                tokens.append(.one)
            } else {
                tokens.append(.literal(c))
            }
        }
        let chars = Array(text)
        var i = 0
        var j = 0
        var star: Int?
        var checkpoint = 0
        while i < chars.count {
            if j < tokens.count {
                switch tokens[j] {
                case .literal(let c) where c == chars[i]:
                    i += 1
                    j += 1
                    continue
                case .one:
                    i += 1
                    j += 1
                    continue
                case .many:
                    star = j
                    checkpoint = i
                    j += 1
                    continue
                default: break
                }
            }
            guard let s = star else { return false }
            checkpoint += 1
            i = checkpoint
            j = s + 1
        }
        while j < tokens.count { if case .many = tokens[j] { j += 1 } else { break } }
        return j == tokens.count
    }
}

/// Parsed, immutable work for a bounded ad hoc query. Evaluation touches only the
/// caller-authorized revisions captured on the coordinator queue.
struct PreparedReadQuery: Sendable {
    let expression: SpotlightQuery?
    let sort: [ItemSort]
    let evaluatedAt: Date
    let timeZone: String
    let position: Int
    let limit: Int

    init(
        expression: String?, sort: [ItemSort], evaluatedAt: Date, timeZone: String,
        position: Int, limit: Int
    ) throws {
        guard !sort.isEmpty, sort.allSatisfy({ $0.property != nil && $0.categoryRootID == nil }),
            position >= 0, (1...256).contains(limit)
        else {
            throw TractandaError(
                "invalidArguments", "Prepared reads require a custom property sort and bounded page.")
        }
        try ItemSort.validate(sort)
        self.expression = try expression.map(SpotlightQuery.init)
        self.sort = sort
        self.evaluatedAt = evaluatedAt
        self.timeZone = timeZone
        self.position = position
        self.limit = limit
    }

    func evaluate(_ snapshot: ImmutableReadSnapshot) throws -> PreparedReadPage {
        let calendar = try QueryCalendar.make(timeZone: timeZone)
        let matching = snapshot.revisions.filter {
            expression?.matches($0, at: evaluatedAt, calendar: calendar) ?? true
        }
        let ordered = try ItemSort.ordered(matching, by: sort)
        return PreparedReadPage(
            ids: Array(ordered.dropFirst(position).prefix(limit).map(\.itemID)), total: ordered.count,
            state: snapshot.state, evaluatedAt: evaluatedAt, timeZone: timeZone)
    }
}

struct PreparedReadPage: Sendable {
    let ids: [String]
    let total: Int
    let state: String
    let evaluatedAt: Date
    let timeZone: String
}

public struct Membership: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case itemID, categoryID, reason, inheritancePath, sourceReason
        case isIncluded = "included"
    }
    public let itemID: String
    public let categoryID: String
    public let isIncluded: Bool
    public let reason: String
    /// Only `explain` requests a trace, so routine queries do not allocate paths.
    public let inheritancePath: [String]?
    public let sourceReason: String?
    public init(
        itemID: String, categoryID: String, isIncluded: Bool, reason: String,
        inheritancePath: [String]? = nil, sourceReason: String? = nil
    ) {
        self.itemID = itemID
        self.categoryID = categoryID
        self.isIncluded = isIncluded
        self.reason = reason
        self.inheritancePath = inheritancePath
        self.sourceReason = sourceReason
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        isIncluded = try container.decode(Bool.self, forKey: .isIncluded)
        reason = try container.decode(String.self, forKey: .reason)
        inheritancePath = try container.decodeIfPresent([String].self, forKey: .inheritancePath)
        sourceReason = try container.decodeIfPresent(String.self, forKey: .sourceReason)
    }
}
public struct SavedViewDefinition: Sendable {
    public let expression: String?
    public let text: String?
    public let categoryPath: [String]
    public let excludedCategoryIDs: [String]
    public let sort: [ItemSort]
    public let presentation: ViewPresentation
    public init(_ value: ItemValue) throws {
        guard let map = value.map, map["language"]?.string == SpotlightQuery.profile else {
            throw TractandaError("invalidView", "viewDefinition must declare the supported query language.")
        }
        for key in ["expression", "text"] where map[key] != nil && map[key]?.string == nil {
            throw TractandaError("invalidView", "\(key) must be text.")
        }
        expression = map["expression"]?.string
        excludedCategoryIDs = try CategoryHierarchy.excludedCategories(map["excludedCategoryIDs"])
        text = map["text"]?.string
        if let expression { _ = try SpotlightQuery(expression) }
        if let value = map["sort"] {
            guard let list = value.array else {
                throw TractandaError("invalidView", "sort must be a list of comparators.")
            }
            sort = try list.map { value in
                guard let comparator = value.map,
                    comparator["isAscending"] == nil || comparator["isAscending"]?.booleanValue != nil
                else { throw TractandaError("invalidView", "Invalid sort comparator.") }
                let ascending = comparator["isAscending"]?.booleanValue ?? true
                switch (comparator["property"], comparator["categoryRootID"]) {
                case (.some(.text(let property)), nil):
                    return try ItemSort(property: property, isAscending: ascending)
                case (nil, .some(.reference(let reference))) where reference.revisionID == nil:
                    return try ItemSort(categoryRootID: reference.itemID, isAscending: ascending)
                default: throw TractandaError("invalidView", "Invalid sort comparator.")
                }
            }
            try ItemSort.validate(sort)
        } else {
            sort = []
        }
        presentation = try ViewPresentation(map["presentation"])
        if let value = map["categoryPath"] {
            guard let refs = value.array, refs.count <= 32 else {
                throw TractandaError("invalidView", "categoryPath must be a list of at most 32 references.")
            }
            categoryPath = try refs.map {
                guard let reference = $0.link, reference.revisionID == nil else {
                    throw TractandaError("invalidView", "Saved views follow current categories by ItemID.")
                }
                return reference.itemID
            }
        } else {
            categoryPath = []
        }
    }
}

private func categorySortRank(
    _ item: Revision, rootID: String, evaluator: CategoryEvaluator, cache: inout [String: Membership]
) throws -> Int? {
    // Root membership is the authorization-aware effective decision. In particular, an
    // excluded root must not acquire a branch rank through an otherwise matching child.
    guard try evaluator.membership(item, categoryID: rootID, cache: &cache).isIncluded else { return nil }
    let children = evaluator.hierarchy.children[rootID] ?? []
    guard !children.isEmpty else { return 0 }
    for (rank, childID) in children.enumerated() {
        if try evaluator.membership(item, categoryID: childID, cache: &cache).isIncluded { return rank }
    }
    // A direct root decision has no branch when the root has children.
    return nil
}

private func readableCategoryRoot(_ store: ItemStore, _ id: String) throws -> Revision {
    do { return try store.get(id) } catch let error as TractandaError
        where error.code == "notFound" || error.code == "forbidden"
    { throw TractandaError("notFound", "Category is unavailable.") }
}

public struct CategoryMembershipRoot: Codable, Equatable, Sendable {
    public struct Child: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
    }
    public let id: String
    public let name: String
    public let children: [Child]
}

public struct CategoryMembershipProjection: Codable, Equatable, Sendable {
    public let state: String
    public let roots: [CategoryMembershipRoot]
    /// Each listed category is an immediate matching child; a childless root returns itself.
    public let memberships: [String: [String: [String]]]
    public let notFound: [String]
    public init(
        state: String, roots: [CategoryMembershipRoot], memberships: [String: [String: [String]]],
        notFound: [String]
    ) {
        self.state = state
        self.roots = roots
        self.memberships = memberships
        self.notFound = notFound
    }
}

public enum Categories {
    private static func streamedCategoryPage(
        store: ItemStore, expression: String?, predicate: SpotlightQuery?, text: String?,
        categoryPath: [String],
        excludedCategoryIDs: [String], sort: [ItemSort], order: ItemIndex.IndexedOrder,
        position: Int, limit: Int, at date: Date, timeZone: String, savedViewID: String? = nil
    ) throws -> ItemIndex.Page {
        let calendar = try QueryCalendar.make(timeZone: timeZone)
        let requested = Set(categoryPath + excludedCategoryIDs)
        var cacheKey: String?
        var cacheDependencies: Set<String> = []
        if let savedViewID, !store.hasLivePersonalStateItems() {
            let clockDependent =
                predicate?.indexDependencies.usesClock == true || store.savedViewRulesUseClock
            let timeKey = clockDependent ? savedViewClockKey(at: date, timeZone: timeZone) : "static"
            let selectionValue: [String: ItemValue] = [
                "hasExpression": .boolean(expression != nil),
                "expression": .text(expression ?? ""),
                "hasText": .boolean(text != nil), "text": .text(text ?? ""),
                "categoryPath": .list(categoryPath.map(ItemValue.text)),
                "excludedCategoryIDs": .list(excludedCategoryIDs.map(ItemValue.text)),
                "sort": .list(sort.map(\.value)),
            ]
            let selectionKey = String(
                decoding: try JSON.encode(selectionValue), as: UTF8.self)
            let reusable = try categoryCacheDependencies(
                store: store, categoryPath: categoryPath, excludedCategoryIDs: excludedCategoryIDs)
            if let reusable {
                cacheDependencies.formUnion(reusable)
                cacheDependencies.formUnion(
                    predicate?.indexDependencies.fields.map { "filter:field:" + $0 } ?? [])
                if sort.isEmpty { cacheDependencies.insert("sort:field:modifiedAt") }
                for comparator in sort {
                    if let field = comparator.property {
                        cacheDependencies.insert("sort:field:" + metadataKey(field))
                    }
                }
                if text != nil { cacheDependencies.insert("text:corpus") }
            }
            let key = store.savedViewPageKey(
                savedViewID, selectionKey: selectionKey, timeKey: timeKey,
                reusableAcrossCommits: reusable != nil)
            if let cached = try store.cachedSavedViewPage(key: key, position: position, limit: limit) {
                return cached
            }
            cacheKey = key
        }
        let definitions = try store.readableCategoryDefinitions(requestedCategoryIDs: requested)
        let evaluator = try CategoryEvaluator(definitions: definitions, store: store, at: date)
        let positiveSeeds: SpotlightQuery.IndexCandidatePlan?
        if categoryPath.isEmpty {
            positiveSeeds = nil
        } else {
            positiveSeeds = try manualCategoryPositiveSeeds(
                store: store, definitions: definitions, requested: requested)
        }
        var results = try BoundedQueryResults<String>(
            strategy: .orderedStream(position: position, limit: limit),
            maximumRetainedBytes: ItemStore.exactQueryByteLimit,
            estimateBytes: { $0.utf8.count },
            isOrderedBefore: { $0 < $1 })
        var completeCacheIDs: [String]? = cacheKey == nil ? nil : []
        // Deliberately stream the full safe indexed candidate superset. Manual and personal
        // decisions, incomplete category graphs, and hidden related categories can never
        // remove a candidate before exact membership and current ACL checks.
        var usePersistedBase = false
        if let savedViewID,
            positiveSeeds != nil,
            try store.categoryGraphIsFullyReadable(requestedCategoryIDs: requested),
            try store.savedViewIndexIsReady(savedViewID),
            try store.savedViewCategorySelectionMatches(
                id: savedViewID, expression: expression, text: text, categoryPath: categoryPath,
                excludedCategoryIDs: excludedCategoryIDs, sort: sort)
        {
            usePersistedBase = true
        }
        let categoryCandidatePlan: SpotlightQuery.IndexCandidatePlan
        if usePersistedBase, let savedViewID {
            let categoryIDs = Set(definitions.map(\.itemID))
            categoryCandidatePlan = .or(
                .savedViewBase(savedViewID),
                .or(.categoryDecisions(categoryIDs), .personalCategoryDeltas(categoryIDs)))
        } else {
            categoryCandidatePlan = positiveSeeds ?? .all
        }
        try store.forEachReadableCandidate(
            text: text,
            candidatePlan: .and(
                predicate?.boundedIndexCandidatePlan(at: date, calendar: calendar) ?? .all,
                categoryCandidatePlan),
            order: order
        ) { item in
            guard predicate?.matches(item, at: date, calendar: calendar) ?? true else { return }
            var cache: [String: Membership] = [:]
            for id in categoryPath
            where
                try evaluator.membership(item, categoryID: id, cache: &cache).isIncluded != true
            { return }
            for id in excludedCategoryIDs
            where
                try evaluator.membership(item, categoryID: id, cache: &cache).isIncluded == true
            { return }
            try results.append(item.itemID)
            if completeCacheIDs != nil {
                if completeCacheIDs!.count < 8_192 {
                    completeCacheIDs!.append(item.itemID)
                } else {
                    completeCacheIDs = nil
                }
            }
        }
        let page = try results.finish()
        if let cacheKey, let completeCacheIDs, completeCacheIDs.count == page.totalCount {
            store.saveViewPageIDs(completeCacheIDs, key: cacheKey, dependencies: cacheDependencies)
        }
        return .init(ids: page.elements, total: page.totalCount)
    }

    /// Returns an indexed positive superset only when the caller can see the complete
    /// relevant graph and every rule has a bounded indexed candidate plan. Exact membership
    /// and current ACL checks still run for every candidate.
    static func manualCategoryPositiveSeeds(
        store: ItemStore, definitions: [CategoryDefinition], requested: Set<String>
    ) throws -> SpotlightQuery.IndexCandidatePlan? {
        guard !definitions.isEmpty,
            try store.categoryGraphIsFullyReadable(requestedCategoryIDs: requested)
        else { return nil }
        let hierarchy = try CategoryHierarchy(definitions: definitions)
        guard hierarchy.items.count <= 32 else { return nil }
        var rulePlans: [SpotlightQuery.IndexCandidatePlan] = []
        var atomCount = 0
        for category in hierarchy.items.values {
            guard let expression = category.selection?["expression"]?.string,
                category.selection?["timeWindow"] == nil,
                let rule = try? SpotlightQuery(expression), !rule.indexDependencies.usesClock
            else { return nil }
            let plan = rule.boundedIndexCandidatePlan
            guard !plan.isAll else { return nil }
            atomCount += plan.atomCount
            guard atomCount <= 16 else { return nil }
            rulePlans.append(plan)
        }
        let categoryIDs = Set(hierarchy.items.keys)
        var candidates = rulePlans
        candidates.append(.categoryIncludes(categoryIDs))
        candidates.append(.categoryDecisions(categoryIDs))
        candidates.append(.personalCategoryDeltas(categoryIDs))
        return candidates.dropFirst().reduce(candidates[0]) { .or($0, $1) }
    }

    private static func categoryCacheDependencies(
        store: ItemStore, categoryPath: [String], excludedCategoryIDs: [String]
    ) throws -> Set<String>? {
        guard !categoryPath.isEmpty || !excludedCategoryIDs.isEmpty,
            !store.hasLivePersonalStateItems()
        else { return nil }
        let hierarchy: CategoryHierarchy
        do {
            hierarchy = try CategoryHierarchy(
                definitions: store.readableCategoryDefinitions(
                    requestedCategoryIDs: Set(categoryPath + excludedCategoryIDs)))
        } catch { return nil }
        var pending = categoryPath + excludedCategoryIDs
        var visited: Set<String> = []
        var dependencies: Set<String> = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let category = hierarchy.items[id],
                let rule = try? Categories.rule(category), !rule.indexDependencies.usesClock,
                category.selection?["timeWindow"] == nil,
                (try? QueryCalendar.make(
                    timeZone: category.selection?["timeZone"]?.string ?? "UTC")) != nil
            else { return nil }
            dependencies.formUnion(rule.indexDependencies.fields.map { "filter:field:" + $0 })
            dependencies.insert("override:\(id)")
            pending.append(contentsOf: hierarchy.children[id] ?? [])
            guard
                let exclusions = try? CategoryHierarchy.excludedCategories(
                    category.selection?["excludedCategoryIDs"]),
                exclusions.allSatisfy({ hierarchy.items[$0] != nil }),
                (try? CategoryHierarchy.parents(of: category))?.allSatisfy({ hierarchy.items[$0] != nil })
                    == true
            else { return nil }
            pending.append(contentsOf: exclusions)
        }
        return dependencies
    }

    static func page(
        store: ItemStore, expression: String?, text: String?, categoryPath: [String],
        excludedCategoryIDs: [String], sort: [ItemSort], position: Int, limit: Int,
        at date: Date, timeZone: String, savedViewID: String? = nil
    ) throws -> ItemIndex.Page {
        let indexedOrder: ItemIndex.IndexedOrder?
        if sort.isEmpty {
            indexedOrder = .modifiedAt
        } else if sort.count == 1, sort[0].categoryRootID == nil, !sort[0].isAscending {
            switch sort[0].property.map(metadataKey) {
            case "modifiedAt": indexedOrder = .modifiedAt
            case "createdAt": indexedOrder = .createdAt
            default: indexedOrder = nil
            }
        } else {
            indexedOrder = nil
        }
        let defaultOrder = indexedOrder != nil
        if let savedViewID { try store.advanceSavedViewMaterialization(id: savedViewID) }
        guard defaultOrder, categoryPath.isEmpty, excludedCategoryIDs.isEmpty
        else {
            _ = try QueryCalendar.make(timeZone: timeZone)
            for id in categoryPath + excludedCategoryIDs {
                _ = try rule(store.get(id))
            }
            if defaultOrder,
                !categoryPath.isEmpty || !excludedCategoryIDs.isEmpty,
                !sort.contains(where: { $0.categoryRootID != nil })
            {
                return try streamedCategoryPage(
                    store: store, expression: expression,
                    predicate: try expression.map(SpotlightQuery.init), text: text,
                    categoryPath: categoryPath, excludedCategoryIDs: excludedCategoryIDs,
                    sort: sort, order: indexedOrder!, position: position, limit: limit,
                    at: date, timeZone: timeZone,
                    savedViewID: savedViewID)
            }
            let manualCategoryDependencies: Set<String>?
            if savedViewID != nil {
                manualCategoryDependencies = try categoryCacheDependencies(
                    store: store, categoryPath: categoryPath, excludedCategoryIDs: excludedCategoryIDs)
            } else {
                manualCategoryDependencies = nil
            }
            let clockDependent =
                expression?.contains("$time.") == true
                || ((!categoryPath.isEmpty || !excludedCategoryIDs.isEmpty
                    || sort.contains {
                        $0.categoryRootID != nil
                    }) && manualCategoryDependencies == nil && store.savedViewRulesUseClock)
            let timeKey = clockDependent ? savedViewClockKey(at: date, timeZone: timeZone) : "static"
            let selectionValue: [String: ItemValue] = [
                "hasExpression": .boolean(expression != nil),
                "expression": .text(expression ?? ""),
                "hasText": .boolean(text != nil), "text": .text(text ?? ""),
                "categoryPath": .list(categoryPath.map(ItemValue.text)),
                "excludedCategoryIDs": .list(excludedCategoryIDs.map(ItemValue.text)),
                "sort": .list(sort.map(\.value)),
            ]
            let selectionKey = String(
                decoding: (try? JSON.encode(selectionValue)) ?? Data(), as: UTF8.self)
            let parsedExpression = expression.flatMap { try? SpotlightQuery($0) }
            let expressionIsSupported = expression == nil || parsedExpression != nil
            var cacheDependencies: Set<String>
            if expressionIsSupported,
                !sort.contains(where: { $0.categoryRootID != nil }),
                categoryPath.isEmpty && excludedCategoryIDs.isEmpty || manualCategoryDependencies != nil
            {
                cacheDependencies = Set(
                    parsedExpression?.indexDependencies.fields.map { "filter:field:" + $0 } ?? []
                )
                .union(sort.compactMap(\.property).map { "sort:field:" + metadataKey($0) })
                if sort.isEmpty { cacheDependencies.insert("sort:field:modifiedAt") }
                cacheDependencies.formUnion(manualCategoryDependencies ?? [])
                if text != nil { cacheDependencies.insert("text:corpus") }
            } else {
                cacheDependencies = []
            }
            let reusableAcrossCommits =
                savedViewID != nil
                && !sort.contains(where: { $0.categoryRootID != nil })
                && expressionIsSupported
                && (categoryPath.isEmpty && excludedCategoryIDs.isEmpty
                    || manualCategoryDependencies != nil)
            let cacheKey = savedViewID.map {
                store.savedViewPageKey(
                    $0, selectionKey: selectionKey, timeKey: timeKey,
                    reusableAcrossCommits: reusableAcrossCommits)
            }
            if let cacheKey,
                let cached = try store.cachedSavedViewPage(key: cacheKey, position: position, limit: limit)
            {
                return cached
            }
            let result = try query(
                store: store, expression: expression, text: text, categoryPath: categoryPath,
                excludedCategoryIDs: excludedCategoryIDs, sort: sort, at: date, timeZone: timeZone)
            let ids = result.map(\.itemID)
            if let cacheKey { store.saveViewPageIDs(ids, key: cacheKey, dependencies: cacheDependencies) }
            return .init(ids: Array(ids.dropFirst(position).prefix(limit)), total: ids.count)
        }
        let predicate = try expression.map(SpotlightQuery.init)
        let calendar = try QueryCalendar.make(timeZone: timeZone)
        let candidatePlan = predicate?.boundedIndexCandidatePlan(at: date, calendar: calendar) ?? .all
        let materializedView = try savedViewID.map { try store.savedViewIndexIsReady($0) } ?? false
        return try store.indexedPage(
            text: text, classEquals: predicate?.indexClassEquals, order: indexedOrder!,
            position: position, limit: limit,
            exactIndexPredicate: (predicate == nil || predicate?.indexExactClassEquals != nil
                || materializedView) && (candidatePlan.isAll || materializedView),
            needsFullRevision: predicate != nil && predicate?.indexExactClassEquals == nil
                && !materializedView || !candidatePlan.isAll && !materializedView,
            candidatePlan: candidatePlan, savedViewID: savedViewID
        ) { revision in
            predicate?.matches(revision, at: date, calendar: calendar) ?? true
        }
    }
    static func savedViewPage(
        store: ItemStore, id: String, sectionID: String?, position: Int, limit: Int,
        at date: Date, timeZone: String
    ) throws -> ItemIndex.Page {
        let item = try store.get(id)
        guard !item.isDeleted, let value = item.fields["viewDefinition"] else {
            throw TractandaError("notView", "Item has no available saved view definition.")
        }
        let definition = try SavedViewDefinition(value)
        var path = definition.categoryPath
        if let sectionID {
            guard definition.presentation.sectionIDs.contains(sectionID) else {
                throw TractandaError("invalidArguments", "The category is not a section of this view.")
            }
            if !path.contains(sectionID) { path.append(sectionID) }
        }
        return try page(
            store: store, expression: definition.expression, text: definition.text,
            categoryPath: path, excludedCategoryIDs: definition.excludedCategoryIDs,
            sort: definition.sort, position: position, limit: limit, at: date, timeZone: timeZone,
            savedViewID: id)
    }
    static func rule(_ category: Revision) throws -> SpotlightQuery {
        guard !category.isDeleted, let selection = category.fields["selection"]?.map,
            let expression = selection["expression"]?.string
        else {
            throw TractandaError("notCategory", "This item has no active selection criteria.")
        }
        return try SpotlightQuery(expression)
    }
    static func rule(_ category: CategoryDefinition) throws -> SpotlightQuery {
        guard !category.isDeleted, let expression = category.selection?["expression"]?.string else {
            throw TractandaError("notCategory", "This item has no active selection criteria.")
        }
        return try SpotlightQuery(expression)
    }
    public static func explain(
        _ item: Revision, category: Revision, store: ItemStore? = nil, at date: Date = Date()
    ) throws
        -> Membership
    {
        _ = try rule(category)
        let definitions =
            try store?.readableCategoryDefinitions(requestedCategoryIDs: [category.itemID])
            ?? [CategoryDefinition(category)]
        let evaluator = try CategoryEvaluator(
            definitions: definitions,
            store: store, at: date)
        var cache: [String: Membership] = [:]
        return try evaluator.membership(item, categoryID: category.itemID, cache: &cache, trace: true)
    }

    public static func savedView(
        store: ItemStore, id: String, sectionID: String? = nil, at date: Date = Date(),
        timeZone: String = "UTC"
    ) throws -> [Revision] {
        let item = try store.get(id)
        guard !item.isDeleted, let value = item.fields["viewDefinition"] else {
            throw TractandaError("notView", "Item has no available saved view definition.")
        }
        let definition = try SavedViewDefinition(value)
        var path = definition.categoryPath
        if let sectionID {
            guard definition.presentation.sectionIDs.contains(sectionID) else {
                throw TractandaError("invalidArguments", "The category is not a section of this view.")
            }
            if !path.contains(sectionID) { path.append(sectionID) }
        }
        return try query(
            store: store, expression: definition.expression, text: definition.text,
            categoryPath: path, excludedCategoryIDs: definition.excludedCategoryIDs, sort: definition.sort,
            at: date, timeZone: timeZone)
    }
    public static func query(
        store: ItemStore, expression: String? = nil, text: String? = nil,
        categoryPath: [String] = [], excludedCategoryIDs: [String] = [], sort: [ItemSort] = [],
        at date: Date = Date(), timeZone: String = "UTC"
    ) throws -> [Revision] {
        guard categoryPath.count <= 32, excludedCategoryIDs.count <= 32 else {
            throw TractandaError("limit", "Category path exceeds 32 levels.")
        }
        let query = try expression.map(SpotlightQuery.init)
        let calendar = try QueryCalendar.make(timeZone: timeZone)
        for id in categoryPath + excludedCategoryIDs { _ = try rule(store.get(id)) }
        let categorySortIDs = sort.compactMap(\.categoryRootID)
        try ItemSort.validate(sort)
        for id in categorySortIDs { _ = try readableCategoryRoot(store, id) }
        let evaluator =
            try categoryPath.isEmpty && excludedCategoryIDs.isEmpty && categorySortIDs.isEmpty
            ? nil
            : CategoryEvaluator(
                definitions: try store.readableCategoryDefinitions(
                    requestedCategoryIDs: Set(categoryPath + excludedCategoryIDs + categorySortIDs)),
                store: store, at: date)
        // Avoid materializing a category decision or personal-target ID set as a prepass.
        // Every fallback candidate is checked by the exact evaluator below; the restricted
        // candidate sources remain an optimization only for separately bounded APIs.
        let queryCandidates = try store.candidates(
            text: text, restrictedTo: nil,
            candidatePlan: query?.boundedIndexCandidatePlan(at: date, calendar: calendar) ?? .all)
        let evaluated = try queryCandidates.compactMap {
            item -> (Revision, [String: Membership])? in
            if let query, !query.matches(item, at: date, calendar: calendar) { return nil }
            var cache: [String: Membership] = [:]
            for id in categoryPath {
                if try evaluator?.membership(item, categoryID: id, cache: &cache).isIncluded != true {
                    return nil
                }
            }
            for id in excludedCategoryIDs {
                if try evaluator?.membership(item, categoryID: id, cache: &cache).isIncluded == true {
                    return nil
                }
            }
            return (item, cache)
        }
        let result = evaluated.map(\.0)
        var categoryRanks: [String: [String: Int]] = [:]
        if !categorySortIDs.isEmpty {
            guard let evaluator else { fatalError("Category sorting requires an evaluator.") }
            for rootID in categorySortIDs where evaluator.hierarchy.items[rootID] == nil {
                throw TractandaError("notCategory", "This item has no available selection criteria.")
            }
            for rootID in categorySortIDs { categoryRanks[rootID] = [:] }
            for (item, initialCache) in evaluated {
                var cache = initialCache
                for rootID in categorySortIDs {
                    if let rank = try categorySortRank(
                        item, rootID: rootID, evaluator: evaluator, cache: &cache)
                    {
                        categoryRanks[rootID]![item.itemID] = rank
                    }
                }
            }
        }
        return try ItemSort.ordered(result, by: sort, categoryRanks: categoryRanks)
    }

    public static func memberships(
        store: ItemStore, ids: [String], categoryRootIDs: [String], at date: Date
    ) throws -> CategoryMembershipProjection {
        guard (1...64).contains(ids.count), Set(ids).count == ids.count,
            (1...8).contains(categoryRootIDs.count), Set(categoryRootIDs).count == categoryRootIDs.count
        else {
            throw TractandaError(
                "invalidArguments", "Supply 1–64 distinct items and 1–8 distinct category roots.")
        }
        // `get` keeps an unreadable root indistinguishable from an unavailable item before
        // constructing the caller-authorized graph.
        for rootID in categoryRootIDs { _ = try readableCategoryRoot(store, rootID) }
        let evaluator = try CategoryEvaluator(
            definitions: store.readableCategoryDefinitions(requestedCategoryIDs: Set(categoryRootIDs)),
            store: store, at: date)
        var roots: [CategoryMembershipRoot] = []
        for rootID in categoryRootIDs {
            guard let root = evaluator.hierarchy.items[rootID] else {
                throw TractandaError("notCategory", "This item has no available selection criteria.")
            }
            let children = (evaluator.hierarchy.children[rootID] ?? []).compactMap {
                childID -> CategoryMembershipRoot.Child? in
                guard let child = evaluator.hierarchy.items[childID] else { return nil }
                return .init(id: childID, name: child.subject.isEmpty ? childID : child.subject)
            }
            roots.append(
                .init(id: rootID, name: root.subject.isEmpty ? rootID : root.subject, children: children))
        }
        var memberships: [String: [String: [String]]] = [:]
        var notFound: [String] = []
        for id in ids {
            let item: Revision
            do { item = try store.get(id) } catch let error as TractandaError
                where error.code == "notFound" || error.code == "forbidden"
            {
                notFound.append(id)
                continue
            }
            var cache: [String: Membership] = [:]
            var itemMemberships: [String: [String]] = [:]
            for root in roots {
                guard try evaluator.membership(item, categoryID: root.id, cache: &cache).isIncluded else {
                    continue
                }
                if root.children.isEmpty {
                    itemMemberships[root.id] = [root.id]
                    continue
                }
                let matches = try root.children.filter {
                    try evaluator.membership(item, categoryID: $0.id, cache: &cache).isIncluded
                }.map(\.id)
                if !matches.isEmpty { itemMemberships[root.id] = matches }
            }
            if !itemMemberships.isEmpty { memberships[id] = itemMemberships }
        }
        return .init(state: store.state, roots: roots, memberships: memberships, notFound: notFound)
    }
}
