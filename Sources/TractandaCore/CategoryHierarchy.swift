import Foundation

/// Category relationships are ordinary, versioned item properties. No category is reserved.
public struct CategoryHierarchy: Sendable {
    public let items: [String: Revision]
    public let children: [String: [String]]
    public let roots: [String]

    public static func excludedCategories(_ value: ItemValue?) throws -> [String] {
        guard let value else { return [] }
        guard let values = value.array, values.count <= 32 else {
            throw TractandaError("invalidCategory", "Use at most 32 excluded category references.")
        }
        let ids = try values.map { value -> String in
            guard let reference = value.link, reference.revisionID == nil else {
                throw TractandaError("invalidCategory", "Exclusions follow current category items.")
            }
            return reference.itemID
        }
        guard Set(ids).count == ids.count else {
            throw TractandaError("invalidCategory", "Exclusions must be distinct.")
        }
        return ids
    }

    public static func parents(of item: Revision) throws -> [String] {
        guard let value = item.fields["categoryParents"] else { return [] }
        guard let entries = value.array, entries.count <= 32 else {
            throw TractandaError("invalidCategory", "categoryParents must contain at most 32 references.")
        }
        let ids = try entries.map { entry -> String in
            guard let ref = entry.link, ref.revisionID == nil else {
                throw TractandaError("invalidCategory", "Category parents must be current item references.")
            }
            return ref.itemID
        }
        guard Set(ids).count == ids.count, !ids.contains(item.itemID) else {
            throw TractandaError("categoryCycle", "A category cannot contain itself or repeat a parent.")
        }
        return ids
    }

    /// Pass only readable heads when constructing a caller's navigation or membership graph.
    public init(_ revisions: [Revision]) throws {
        let categories = revisions.filter { !$0.isDeleted && $0.fields["selection"] != nil }
        let items = Dictionary(uniqueKeysWithValues: categories.map { ($0.itemID, $0) })
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for item in categories {
            let parents = try Self.parents(of: item).filter { items[$0] != nil }
            if parents.isEmpty { roots.append(item.itemID) }
            for parent in parents { children[parent, default: []].append(item.itemID) }
        }
        func ordered(_ ids: [String]) -> [String] {
            ids.sorted {
                let left = items[$0]!
                let right = items[$1]!
                let a = left.fields["categoryOrder"]?.integerValue ?? 0
                let b = right.fields["categoryOrder"]?.integerValue ?? 0
                if a != b { return a < b }
                let an = left.fields["subject"]?.string ?? ""
                let bn = right.fields["subject"]?.string ?? ""
                return an == bn ? $0 < $1 : an < bn
            }
        }
        let exclusions = try items.mapValues {
            try Self.excludedCategories($0.fields["selection"]?.map?["excludedCategoryIDs"]).filter {
                items[$0] != nil
            }
        }
        var visiting: Set<String> = []
        var depths: [String: Int] = [:]
        func depth(_ id: String, level: Int) throws -> Int {
            guard level <= 32, !visiting.contains(id) else {
                throw TractandaError(
                    "categoryCycle", "Category inheritance must be acyclic and at most 32 levels deep.")
            }
            if let known = depths[id] { return known }
            visiting.insert(id)
            var result = 1
            for child in (children[id] ?? []) + (exclusions[id] ?? []) {
                result = max(result, 1 + (try depth(child, level: level + 1)))
            }
            visiting.remove(id)
            guard result <= 32 else {
                throw TractandaError("categoryCycle", "Category inheritance exceeds 32 levels.")
            }
            depths[id] = result
            return result
        }
        for id in items.keys { _ = try depth(id, level: 1) }
        self.items = items
        self.children = children.mapValues(ordered)
        self.roots = ordered(roots)
    }
}

/// One authorized graph and one clock per query; memoization is per candidate item.
struct CategoryEvaluator {
    let hierarchy: CategoryHierarchy
    let rules: [String: SpotlightQuery]
    let windows: [String: CategoryTimeWindow]
    let calendars: [String: Calendar]
    let store: ItemStore?
    let date: Date
    let exclusions: [String: [String]]

    init(_ items: [Revision], store: ItemStore?, at date: Date) throws {
        hierarchy = try CategoryHierarchy(items)
        rules = try hierarchy.items.mapValues { try Categories.rule($0) }
        let readableIDs = Set(hierarchy.items.keys)
        exclusions = try hierarchy.items.mapValues {
            try CategoryHierarchy.excludedCategories($0.fields["selection"]?.map?["excludedCategoryIDs"])
                .filter { readableIDs.contains($0) }
        }
        windows = try hierarchy.items.compactMapValues {
            try $0.fields["selection"]?.map?["timeWindow"].map(CategoryTimeWindow.init)
        }
        calendars = try hierarchy.items.mapValues {
            try QueryCalendar.make(timeZone: $0.fields["selection"]?.map?["timeZone"]?.string ?? "UTC")
        }
        self.store = store
        self.date = date
    }

    func membership(
        _ item: Revision, categoryID: String, cache: inout [String: Membership], trace: Bool = false
    ) throws -> Membership {
        if let found = cache[categoryID] { return found }
        guard let rule = rules[categoryID] else {
            throw TractandaError("notCategory", "This item has no available selection criteria.")
        }
        let decision = try store?.categoryOverride(for: item, categoryID: categoryID)
        let override = decision?.decision ?? item.fields["categoryOverrides"]?.map?[categoryID]?.string
        let included: Bool
        let reason: String
        var childID: String?
        if let override {
            included = override == "include"
            reason = "\(decision?.origin.hasPrefix("personal:") == true ? "personal" : "manual") \(override)"
        } else if try (exclusions[categoryID] ?? []).contains(where: {
            try membership(item, categoryID: $0, cache: &cache, trace: trace).isIncluded
        }) {
            included = false
            reason = "excluded category"
        } else if rule.matches(item, at: date, calendar: calendars[categoryID]!)
            && (windows[categoryID]?.matches(item, at: date, calendar: calendars[categoryID]!) ?? true)
        {
            included = true
            reason = "selection rule"
        } else {
            for child in hierarchy.children[categoryID] ?? [] {
                if try membership(item, categoryID: child, cache: &cache, trace: trace).isIncluded {
                    childID = child
                    break
                }
            }
            included = childID != nil
            reason = childID.map { "inherited from \($0)" } ?? "selection rule"
        }
        let childTrace =
            trace
            ? try childID.map { try membership(item, categoryID: $0, cache: &cache, trace: true) }
            : nil
        let result = Membership(
            itemID: item.itemID, categoryID: categoryID, isIncluded: included, reason: reason,
            inheritancePath: trace && included
                ? [categoryID] + (childTrace?.inheritancePath ?? []) : nil,
            sourceReason: trace && included ? (childTrace?.sourceReason ?? reason) : nil)
        cache[categoryID] = result
        return result
    }
}
