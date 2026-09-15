import Foundation

extension ItemSort {
    /// Applies ordering to the full authorized result, before pagination. Empty order means
    /// most recently modified first. Missing/compound values sort last in either direction.
    public static func ordered(_ items: [Revision], by order: [ItemSort]) throws -> [Revision] {
        let order = try order.isEmpty ? [ItemSort(property: "modifiedAt", isAscending: false)] : order
        try validate(order)
        let decorated = items.map { item in
            (item, order.map { SortValue(item.fields[metadataKey($0.property)]) })
        }
        return decorated.sorted { lhs, rhs in
            for index in order.indices {
                let a = lhs.1[index]
                let b = rhs.1[index]
                // Absent values stay at the bottom, including descending order.
                if a == nil || b == nil {
                    if a == nil && b == nil { continue }
                    return a != nil
                }
                let comparison = a!.compare(to: b!)
                if comparison != 0 { return order[index].isAscending ? comparison < 0 : comparison > 0 }
            }
            return lhs.0.itemID < rhs.0.itemID
        }.map(\.0)
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

private enum SortValue {
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
        case .number: return 0
        case .date: return 1
        case .text: return 2
        case .boolean: return 3
        }
    }
    func compare(to other: SortValue) -> Int {
        func compare<T: Comparable>(_ a: T, _ b: T) -> Int { a == b ? 0 : a < b ? -1 : 1 }
        switch (self, other) {
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
