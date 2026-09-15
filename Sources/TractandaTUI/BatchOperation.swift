import TractandaCore

/// Marks are local selection state; overlapping sections still refer to one item.
struct MarkedItems {
    private(set) var items: [Revision] = []
    static let limit = 256
    func contains(_ id: String) -> Bool { items.contains { $0.itemID == id } }

    mutating func toggle(_ item: Revision) throws {
        if contains(item.itemID) {
            remove(item.itemID)
        } else {
            guard items.count < Self.limit else {
                throw TractandaError("limit", "Mark at most 256 items at a time.")
            }
            items.append(item)
        }
    }

    mutating func toggle(_ selection: [Revision]) throws {
        let ids = Set(selection.map(\.itemID))
        if ids.isSubset(of: Set(items.map(\.itemID))) {
            items.removeAll { ids.contains($0.itemID) }
        } else {
            guard Set(items.map(\.itemID)).union(ids).count <= Self.limit else {
                throw TractandaError("limit", "This section would exceed the 256 marked-item limit.")
            }
            for item in selection where !contains(item.itemID) { items.append(item) }
        }
    }

    mutating func remove(_ id: String) { items.removeAll { $0.itemID == id } }
    mutating func clear() { items = [] }
}

enum CommitFailure {
    static func isDefinitive(_ error: TractandaError) -> Bool {
        [
            "revisionConflict", "forbidden", "notFound", "operationMismatch", "limit",
            "unsupportedQuery", "notCategory", "notView", "unknownClass", "abstractClass",
            "invalidArguments", "invalidRecord", "invalidValue", "invalidKey", "invalidID",
            "invalidView", "invalidSelection", "invalidHolder", "invalidPermissions", "invalidRole",
            "invalidPendency",
            "categoryCycle", "invalidCategory",
            "invalidReferenceLabel",
            "invalidLearningSettings", "invalidLearningFeedback", "itemDeleted",
        ].contains(error.code)
    }
}

/// A frozen set of guarded edits and their individual outcomes, saved before sending.
struct BatchOperation: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case include, exclude, reset, done, delete
        var title: String {
            switch self {
            case .include: "Assign to category"
            case .exclude: "Exclude from category"
            case .reset: "Reset category decision"
            case .done: "Mark done"
            case .delete: "Delete items"
            }
        }
    }
    struct Outcome: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case saved, unchanged, rejected }
        let status: Status
        let detail: String
    }
    struct Entry: Codable, Equatable, Sendable {
        let itemID: String
        let revisionID: String
        let title: String
        let request: CommitRequest?
        var outcome: Outcome?
    }
    let action: Action
    let categoryName: String?
    var entries: [Entry]
    var isComplete: Bool { entries.allSatisfy { $0.outcome != nil } }

    init(action: Action, items: [Revision], category: Revision? = nil, replacingCategories: [String] = [])
        throws
    {
        guard !items.isEmpty, items.count <= MarkedItems.limit else {
            throw TractandaError("selection", "Mark between 1 and 256 items first.")
        }
        if [.include, .exclude, .reset, .done].contains(action), category == nil {
            throw TractandaError("selection", "Choose a category for the group operation.")
        }
        self.action = action
        categoryName = category?.fields["subject"]?.string
        let date = Timestamp.now()
        var seen: Set<String> = []
        entries = items.filter { seen.insert($0.itemID).inserted }.map { item in
            var changes: [String: ItemValue] = [:]
            switch action {
            case .include, .exclude, .reset:
                let old = item.fields["categoryOverrides"]?.map ?? [:]
                var overrides = old
                overrides[category!.itemID] = action == .reset ? nil : .text(action.rawValue)
                if overrides != old { changes["categoryOverrides"] = .object(overrides) }
            case .done:
                let old = item.fields["categoryOverrides"]?.map ?? [:]
                var overrides = old
                for id in replacingCategories where id != category!.itemID {
                    overrides[id] = .text("exclude")
                }
                overrides[category!.itemID] = .text("include")
                if overrides != old {
                    changes["categoryOverrides"] = .object(overrides)
                    changes["completedAt"] = .date(date)
                }
            case .delete:
                if !item.isDeleted { changes["isDeleted"] = .boolean(true) }
            }
            return Entry(
                itemID: item.itemID, revisionID: item.revisionID,
                title: item.fields["subject"]?.string ?? item.itemID,
                request: changes.isEmpty
                    ? nil
                    : CommitRequest(
                        action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                        changes: changes, operationID: Identifier.make()))
        }
    }

    /// Unknown outcomes leave the exact request pending. Known rejections are per item.
    mutating func performNext(using client: ItemClient) throws {
        guard let index = entries.firstIndex(where: { $0.outcome == nil }) else { return }
        let entry = entries[index]
        do {
            if let request = entry.request {
                let result = try client.commit(request)
                entries[index].outcome = Outcome(
                    status: .saved,
                    detail: result.isIndexReady ? result.revision.revisionID : "Saved; index needs recovery")
            } else {
                let current = try client.revision(for: entry.itemID)
                guard current.revisionID == entry.revisionID else {
                    throw TractandaError("revisionConflict", "Item changed since it was marked.")
                }
                entries[index].outcome = Outcome(status: .unchanged, detail: "Already in the requested state")
            }
        } catch let error as TractandaError where CommitFailure.isDefinitive(error) {
            entries[index].outcome = Outcome(status: .rejected, detail: error.description)
        }
    }

    var summary: String {
        let saved = entries.filter { $0.outcome?.status == .saved }.count
        let unchanged = entries.filter { $0.outcome?.status == .unchanged }.count
        let rejected = entries.filter { $0.outcome?.status == .rejected }.count
        return "\(saved) saved · \(unchanged) unchanged · \(rejected) rejected"
    }

    var report: String {
        summary + "\n\n"
            + entries.map { entry in
                "\(entry.title) — \(entry.outcome?.status.rawValue ?? "pending")\n  \(entry.outcome?.detail ?? "Not confirmed")"
            }.joined(separator: "\n")
    }
}
