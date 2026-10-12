import Foundation

extension ItemSort {
    /// Applies ordering to the full authorized result, before pagination. Empty order means
    /// most recently modified first. Missing/compound values sort last in either direction.
    public static func ordered(
        _ items: [Revision], by order: [ItemSort], categoryRanks: [String: [String: Int]] = [:]
    ) throws -> [Revision] {
        let order = try order.isEmpty ? [ItemSort(property: "modifiedAt", isAscending: false)] : order
        try validate(order)
        for sort in order where sort.categoryRootID != nil && categoryRanks[sort.categoryRootID!] == nil {
            throw TractandaError("invalidArguments", "Category sort ranks must be evaluated before ordering.")
        }
        let decorated = items.map { item in
            (item, key(item, by: order, categoryRanks: categoryRanks.mapValues { $0[item.itemID] }))
        }
        return decorated.sorted { isOrderedBefore($0.1, $1.1, by: order) }.map(\.0)
    }

    /// Only selected scalar comparator values and identity survive the candidate scan.
    struct SortKey: Encodable {
        let itemID: String
        fileprivate let values: [SortValue?]
    }

    static func key(
        _ item: Revision, by order: [ItemSort], categoryRanks: [String: Int?]
    ) -> SortKey {
        SortKey(
            itemID: item.itemID,
            values: order.map { sort in
                if let property = sort.property { return SortValue(item.fields[metadataKey(property)]) }
                guard let rootID = sort.categoryRootID else { return nil }
                return categoryRanks[rootID].flatMap { $0 }.map(SortValue.category)
            })
    }

    static func isOrderedBefore(_ lhs: SortKey, _ rhs: SortKey, by order: [ItemSort]) -> Bool {
        for index in order.indices {
            let a = lhs.values[index]
            let b = rhs.values[index]
            // Absent values stay at the bottom, including descending order.
            if a == nil || b == nil {
                if a == nil && b == nil { continue }
                return a != nil
            }
            let comparison = a!.compare(to: b!)
            if comparison != 0 { return order[index].isAscending ? comparison < 0 : comparison > 0 }
        }
        return lhs.itemID < rhs.itemID
    }

}

/// Query aliases also apply to sorting. Dots in any other key are literal, not reference traversal.
func metadataKey(_ property: String) -> String {
    [
        "kMDItemTitle": "subject", "kMDItemTextContent": "body",
        "kMDItemContentCreationDate": "createdAt", "kMDItemContentModificationDate": "modifiedAt",
        "kMDItemContentType": "classID",
    ][property] ?? property
}

private enum SortValue: Encodable {
    case category(Int)
    case number(ItemValue)
    case date(Date)
    case text(String)
    case boolean(Bool)
    init?(_ value: ItemValue?) {
        switch value {
        case .integer, .real: self = .number(value!)
        case .date(let timestamp):
            guard let date = Timestamp.parse(timestamp) else { return nil }
            self = .date(date)
        case .text(let text): self = .text(text)
        case .boolean(let boolean): self = .boolean(boolean)
        default: return nil
        }
    }
    var rank: Int {
        switch self {
        case .category: return -1
        case .number: return 0
        case .date: return 1
        case .text: return 2
        case .boolean: return 3
        }
    }
    func compare(to other: SortValue) -> Int {
        func compare<T: Comparable>(_ a: T, _ b: T) -> Int { a == b ? 0 : a < b ? -1 : 1 }
        switch (self, other) {
        case (.category(let a), .category(let b)): return compare(a, b)
        case (.number(.integer(let a)), .number(.integer(let b))): return compare(a, b)
        case (.number(.real(let a)), .number(.real(let b))): return compare(a, b)
        case (.number(.integer(let a)), .number(.real(let b))): return Self.compare(a, to: b)
        case (.number(.real(let a)), .number(.integer(let b))): return -Self.compare(b, to: a)
        case (.date(let a), .date(let b)): return compare(a, b)
        case (.text(let a), .text(let b)): return compare(a, b)
        case (.boolean(let a), .boolean(let b)): return a == b ? 0 : a ? 1 : -1
        default: return compare(rank, other.rank)
        }
    }
    // Do not round adjacent Int64 values to the same Double (notably beyond 2^53).
    private static func compare(_ integer: Int64, to real: Double) -> Int {
        if real >= 9_223_372_036_854_775_808.0 { return -1 }
        if real < -9_223_372_036_854_775_808.0 { return 1 }
        let truncated = Int64(real)
        if integer != truncated { return integer < truncated ? -1 : 1 }
        return Double(integer) == real ? 0 : Double(integer) < real ? -1 : 1
    }
}
