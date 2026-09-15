import TractandaCore

/// Session-local selection/layout references, never cached item content or permission grants.
struct WorkspaceLocation: Equatable {
    let expression: String
    let text: String
    let categoryIDs: [String]
    let excludedCategoryIDs: [String]
    let view: ItemReference?
    let viewToUpdate: ItemReference?
    let columns: [ViewColumn]
    let sort: [ItemSort]
    let sectionIDs: [String]
    let collapsedSectionIDs: Set<String>
    var positions: [Int]

    func hasSameDestination(as other: Self) -> Bool {
        var left = self
        var right = other
        left.positions = []
        right.positions = []
        return left == right
    }
}

struct NavigationEntry {
    let location: WorkspaceLocation
    let selectedItemID: String?
    let selectedSectionID: String?
    let selectedRow: Int
    let firstVisibleRow: Int
    let columnOffset: Int
}

struct NavigationHistory {
    static let limit = 32
    private(set) var back: [NavigationEntry] = []
    private(set) var forward: [NavigationEntry] = []

    mutating func recordDeparture(_ entry: NavigationEntry, to destination: WorkspaceLocation) {
        guard !entry.location.hasSameDestination(as: destination) else { return }
        Self.append(entry, to: &back)
        forward.removeAll()
    }

    mutating func didRestore(backward: Bool, departing entry: NavigationEntry) {
        if backward {
            _ = back.popLast()
            Self.append(entry, to: &forward)
        } else {
            _ = forward.popLast()
            Self.append(entry, to: &back)
        }
    }

    mutating func discardUnavailable(backward: Bool) {
        if backward { _ = back.popLast() } else { _ = forward.popLast() }
    }

    private static func append(_ entry: NavigationEntry, to entries: inout [NavigationEntry]) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}
