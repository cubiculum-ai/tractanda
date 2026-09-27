import Foundation

public struct CategoryDefinition: Sendable {
    public let itemID: String
    public let revisionID: String
    public let selection: [String: ItemValue]?
    public let parents: [ItemValue]
    public let order: Int64
    public let subject: String
    public let isDeleted: Bool

    init(_ revision: Revision) {
        self.init(
            itemID: revision.itemID, revisionID: revision.revisionID, fields: revision.fields,
            isDeleted: revision.isDeleted)
    }

    init(itemID: String, revisionID: String, fields: [String: ItemValue], isDeleted: Bool = false) {
        self.itemID = itemID
        self.revisionID = revisionID
        selection = fields["selection"]?.map
        parents = fields["categoryParents"]?.array ?? []
        order = fields["categoryOrder"]?.integerValue ?? 0
        subject = fields["subject"]?.string ?? ""
        self.isDeleted = isDeleted
    }
}

/// Category relationships are ordinary, versioned item properties. No category is reserved.
public struct CategoryHierarchy: Sendable {
    public let items: [String: CategoryDefinition]
    /// Complete source records only when built from client-owned Revisions. Server
    /// graphs built from compact definitions never invent partial Revision values.
    public let sourceRevisions: [String: Revision]
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
        let full = Dictionary(
            uniqueKeysWithValues: revisions.filter {
                !$0.isDeleted && $0.fields["selection"] != nil
            }.map { ($0.itemID, $0) })
        try self.init(definitions: revisions.map(CategoryDefinition.init), sourceRevisions: full)
    }

    init(definitions: [CategoryDefinition]) throws {
        try self.init(definitions: definitions, sourceRevisions: [:])
    }

    private init(definitions: [CategoryDefinition], sourceRevisions: [String: Revision]) throws {
        let categories = definitions.filter { !$0.isDeleted && $0.selection != nil }
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
                let a = left.order
                let b = right.order
                if a != b { return a < b }
                let an = left.subject
                let bn = right.subject
                return an == bn ? $0 < $1 : an < bn
            }
        }
        let exclusions = try items.mapValues {
            try Self.excludedCategories($0.selection?["excludedCategoryIDs"]).filter {
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
        self.sourceRevisions = sourceRevisions
        self.children = children.mapValues(ordered)
        self.roots = ordered(roots)
    }

    static func parents(of item: CategoryDefinition) throws -> [String] {
        guard item.parents.count <= 32 else {
            throw TractandaError("invalidCategory", "categoryParents must contain at most 32 references.")
        }
        let ids = try item.parents.map { entry -> String in
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
}

/// One authorized graph and one clock per query; memoization is per candidate item.
struct CategoryEvaluator {
    let hierarchy: CategoryHierarchy
    let rules: [String: SpotlightQuery]
    let windows: [String: CategoryTimeWindow]
    let calendars: [String: Calendar]
    let categoryOverrides: CategoryOverrideIndex?
    let date: Date
    let exclusions: [String: [String]]

    init(_ items: [Revision], store: ItemStore?, at date: Date) throws {
        try self.init(definitions: items.map(CategoryDefinition.init), store: store, at: date)
    }

    init(definitions: [CategoryDefinition], store: ItemStore?, at date: Date) throws {
        hierarchy = try CategoryHierarchy(definitions: definitions)
        rules = try hierarchy.items.mapValues { try Categories.rule($0) }
        let readableIDs = Set(hierarchy.items.keys)
        exclusions = try hierarchy.items.mapValues {
            try CategoryHierarchy.excludedCategories($0.selection?["excludedCategoryIDs"])
                .filter { readableIDs.contains($0) }
        }
        windows = try hierarchy.items.compactMapValues {
            try $0.selection?["timeWindow"].map(CategoryTimeWindow.init)
        }
        calendars = try hierarchy.items.mapValues {
            try QueryCalendar.make(timeZone: $0.selection?["timeZone"]?.string ?? "UTC")
        }
        categoryOverrides = try store?.categoryOverrideIndex(categoryIDs: readableIDs)
        self.date = date
    }

    func membership(
        _ item: Revision, categoryID: String, cache: inout [String: Membership], trace: Bool = false
    ) throws -> Membership {
        if let found = cache[categoryID] { return found }
        guard let rule = rules[categoryID] else {
            throw TractandaError("notCategory", "This item has no available selection criteria.")
        }
        let decision = try categoryOverrides?.decision(for: item, categoryID: categoryID)
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
