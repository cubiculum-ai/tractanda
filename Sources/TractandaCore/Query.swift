import Foundation

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

    private enum Literal: Sendable {
        case text(String)
        case integer(Int64)
        case number(Double)
        case boolean(Bool)
        case exists
        case relative(String, Int)
        case date(Date)
    }
    private indirect enum Expression: Sendable {
        case and(Expression, Expression)
        case or(Expression, Expression)
        case comparison(String, String, String, Literal)
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
                guard let comparator = value.map, let property = comparator["property"]?.string,
                    comparator["isAscending"] == nil || comparator["isAscending"]?.booleanValue != nil
                else { throw TractandaError("invalidView", "Invalid sort comparator.") }
                return try ItemSort(
                    property: property, isAscending: comparator["isAscending"]?.booleanValue ?? true)
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
public enum Categories {
    static func rule(_ category: Revision) throws -> SpotlightQuery {
        guard !category.isDeleted, let selection = category.fields["selection"]?.map,
            let expression = selection["expression"]?.string
        else {
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
        let evaluator = try CategoryEvaluator(store?.candidates() ?? [category], store: store, at: date)
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
        let evaluator =
            try categoryPath.isEmpty && excludedCategoryIDs.isEmpty
            ? nil : CategoryEvaluator(store.candidates(), store: store, at: date)
        // Each level intersects the candidates from the preceding level.
        let result = try store.candidates(text: text).filter { item in
            if let query, !query.matches(item, at: date, calendar: calendar) { return false }
            var cache: [String: Membership] = [:]
            for id in categoryPath {
                if try evaluator?.membership(item, categoryID: id, cache: &cache).isIncluded != true {
                    return false
                }
            }
            for id in excludedCategoryIDs {
                if try evaluator?.membership(item, categoryID: id, cache: &cache).isIncluded == true {
                    return false
                }
            }
            return true
        }
        return try ItemSort.ordered(result, by: sort)
    }
}
