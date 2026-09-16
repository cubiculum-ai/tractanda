import Foundation
import TractandaCore

struct ItemPage: Decodable {
    let ids: [String]
    let position: Int
    let total: Int
    let queryState: String
}

struct WorkspaceSection {
    let category: Revision?
    let items: [Revision]
    let position: Int
    let total: Int
}
struct WorkspaceRow {
    enum Content {
        case heading
        case item(Revision)
        case previousPage, nextPage
    }
    let sectionIndex: Int
    let content: Content
    var item: Revision? {
        if case .item(let item) = content { return item }
        return nil
    }
}

/// Presentation state only. Membership, authorization, ordering and writes remain native operations.
final class Workspace {
    let client: ItemClient
    var expression = ""
    var text = ""
    var categoryPath: [Revision] = []
    var excludedCategoryIDs: [String] = []
    private(set) var excludedCategoryNames: [String] = []
    var view: Revision?
    private(set) var viewToUpdate: Revision?
    var columns = ViewPresentation.defaultColumns
    var sort: [ItemSort] = []
    var sectionCategories: [Revision] = []
    var collapsedSectionIDs: Set<String> = []
    private(set) var sections: [WorkspaceSection] = []
    private(set) var queryState: String?
    private(set) var categoryNavigation: CategoryHierarchy?
    var categoriesWithChildren: Set<String> {
        Set(categoryNavigation?.children.filter { !$0.value.isEmpty }.keys.map { $0 } ?? [])
    }
    private var queryDate = Timestamp.now()
    static let pageSize = 64

    var items: [Revision] { sections.flatMap(\.items) }
    var total: Int { sections.reduce(0) { $0 + $1.total } }
    var rows: [WorkspaceRow] {
        sections.enumerated().flatMap { index, section -> [WorkspaceRow] in
            var rows: [WorkspaceRow] = []
            func append(_ content: WorkspaceRow.Content) {
                rows.append(WorkspaceRow(sectionIndex: index, content: content))
            }
            if let category = section.category {
                append(.heading)
                if collapsedSectionIDs.contains(category.itemID) { return rows }
            }
            if section.position > 0 { append(.previousPage) }
            for item in section.items { append(.item(item)) }
            if section.position + section.items.count < section.total { append(.nextPage) }
            return rows
        }
    }

    init(client: ItemClient) { self.client = client }

    var navigationLocation: WorkspaceLocation {
        func reference(_ item: Revision?) -> ItemReference? {
            item.map { ItemReference($0.itemID, revisionID: $0.revisionID) }
        }
        return WorkspaceLocation(
            expression: expression, text: text, categoryIDs: categoryPath.map(\.itemID),
            excludedCategoryIDs: excludedCategoryIDs,
            view: reference(view), viewToUpdate: reference(viewToUpdate), columns: columns, sort: sort,
            sectionIDs: sectionCategories.map(\.itemID), collapsedSectionIDs: collapsedSectionIDs,
            positions: sections.map(\.position))
    }

    /// Restores through current authorization. A changed named view uses its latest definition;
    /// an unsaved layout retains its original revision guard instead of silently rebasing Save.
    @discardableResult
    func restore(_ location: WorkspaceLocation) throws -> Bool {
        let restored = Workspace(client: client)
        do {
            let initialState = try client.state()
            func current(_ id: String, category: Bool = false) throws -> Revision {
                let item = try client.revision(for: id)
                guard !item.isDeleted, !category || item.fields["selection"] != nil else {
                    throw TractandaError("notFound", "This navigation entry is no longer available.")
                }
                return item
            }
            var viewChanged = false
            if let reference = location.view {
                let head = try current(reference.itemID)
                guard head.fields["viewDefinition"] != nil else {
                    throw TractandaError("notFound", "This item is no longer a saved view.")
                }
                viewChanged = head.revisionID != reference.revisionID
                try restored.openView(head)
                if !viewChanged {
                    try restored.loadSections(positions: location.positions, requiring: initialState)
                }
            } else {
                restored.expression = location.expression
                restored.text = location.text
                restored.categoryPath = try location.categoryIDs.map { try current($0, category: true) }
                restored.excludedCategoryIDs = location.excludedCategoryIDs
                restored.sectionCategories = try location.sectionIDs.map { try current($0, category: true) }
                restored.columns = location.columns
                restored.sort = location.sort
                restored.collapsedSectionIDs = location.collapsedSectionIDs
                if let reference = location.viewToUpdate, let revisionID = reference.revisionID {
                    _ = try current(reference.itemID)
                    struct Response: Decodable { let revision: Revision }
                    let base = try JSON.decode(
                        Response.self,
                        client.call(
                            "TractandaRevision/get",
                            arguments: ["itemID": reference.itemID, "revisionID": revisionID])
                    ).revision
                    guard base.itemID == reference.itemID, base.revisionID == revisionID else {
                        throw TractandaError("protocolError", "Unexpected saved-view revision.")
                    }
                    restored.viewToUpdate = base
                }
                try restored.loadSections(positions: location.positions, requiring: initialState)
            }
            guard restored.queryState == initialState, try client.state() == initialState else {
                throw TractandaError("stateChanged", "Items changed while returning. Try again.")
            }
            expression = restored.expression
            text = restored.text
            categoryPath = restored.categoryPath
            excludedCategoryIDs = restored.excludedCategoryIDs
            excludedCategoryNames = restored.excludedCategoryNames
            view = restored.view
            viewToUpdate = restored.viewToUpdate
            columns = restored.columns
            sort = restored.sort
            sectionCategories = restored.sectionCategories
            collapsedSectionIDs = restored.collapsedSectionIDs
            sections = restored.sections
            categoryNavigation = restored.categoryNavigation
            queryState = restored.queryState
            queryDate = restored.queryDate
            return viewChanged
        } catch {
            sections = []
            excludedCategoryNames = []
            categoryNavigation = nil
            queryState = nil
            throw error
        }
    }

    func refresh(position: Int? = nil) throws {
        queryDate = Timestamp.now()
        try loadSections(positions: sections.map { position ?? $0.position })
    }

    /// A failed current read must never leave rows from an earlier authorized view on screen.
    func clearResults() {
        expression = ""
        text = ""
        categoryPath = []
        excludedCategoryIDs = []
        excludedCategoryNames = []
        view = nil
        viewToUpdate = nil
        columns = ViewPresentation.defaultColumns
        sort = []
        sectionCategories = []
        collapsedSectionIDs = []
        sections = []
        queryState = nil
        categoryNavigation = nil
    }

    private func queryArguments(category: Revision?, position: Int, limit: Int) -> [String: Any] {
        var arguments: [String: Any] = ["position": position, "limit": limit, "at": queryDate]
        if let view {
            arguments["viewID"] = view.itemID
            if let category { arguments["sectionID"] = category.itemID }
        } else {
            if !expression.isEmpty { arguments["expression"] = expression }
            if !text.isEmpty { arguments["text"] = text }
            var path = categoryPath.map(\.itemID)
            if let category, !path.contains(category.itemID) { path.append(category.itemID) }
            arguments["categoryPath"] = path
            if !excludedCategoryIDs.isEmpty { arguments["excludedCategoryIDs"] = excludedCategoryIDs }
            if !sort.isEmpty {
                arguments["sort"] = sort.map {
                    ["property": $0.property, "isAscending": $0.isAscending]
                }
            }
        }
        return arguments
    }

    /// Mark the whole authorized section, never silently just its loaded page.
    func items(inSectionAt index: Int) throws -> [Revision] {
        guard sections.indices.contains(index) else { return [] }
        let page = try JSON.decode(
            ItemPage.self,
            client.call(
                "TractandaItem/query",
                arguments: queryArguments(
                    category: sections[index].category, position: 0, limit: MarkedItems.limit)))
        guard page.total <= MarkedItems.limit, page.ids.count == page.total else {
            throw TractandaError(
                "limit", "This section exceeds 256 items. Narrow the view before marking it.")
        }
        guard page.queryState == queryState else {
            throw TractandaError("stateChanged", "Items changed; refresh before marking the section.")
        }
        struct Response: Decodable {
            let list: [Revision]
            let notFound: [String]
            let state: String
        }
        let result = try JSON.decode(
            Response.self, client.call("TractandaItem/get", arguments: ["ids": page.ids]))
        guard result.state == page.queryState, result.notFound.isEmpty else {
            throw TractandaError("stateChanged", "Items changed while marking; refresh first.")
        }
        let byID = Dictionary(uniqueKeysWithValues: result.list.map { ($0.itemID, $0) })
        guard page.ids.allSatisfy({ byID[$0] != nil }) else {
            throw TractandaError("protocolError", "Missing section item.")
        }
        return page.ids.compactMap { byID[$0] }
    }

    private func loadSections(positions: [Int], requiring state: String? = nil) throws {
        struct Response: Decodable {
            let list: [Revision]
            let notFound: [String]
            let state: String
        }
        do {
            // Refresh names through authorization too; a hidden category must not remain a heading.
            let excludedNames = try excludedCategoryIDs.map {
                try client.revision(for: $0).fields["subject"]?.string ?? "Category"
            }
            let categories = try sectionCategories.map { try client.revision(for: $0.itemID) }
            let targets: [Revision?] = categories.isEmpty ? [nil] : categories.map { $0 }
            var loaded: [WorkspaceSection] = []
            var initialState = state
            for (index, category) in targets.enumerated() {
                var offset = positions.indices.contains(index) ? max(0, positions[index]) : 0
                func query(_ position: Int) throws -> ItemPage {
                    return try JSON.decode(
                        ItemPage.self,
                        client.call(
                            "TractandaItem/query",
                            arguments: queryArguments(
                                category: category, position: position, limit: Self.pageSize)))
                }
                var page = try query(offset)
                if offset > 0 && page.ids.isEmpty {
                    offset = 0
                    page = try query(0)
                }
                if let initialState, initialState != page.queryState {
                    throw TractandaError("stateChanged", "Items changed; refresh from the first page.")
                }
                initialState = page.queryState
                let result = try JSON.decode(
                    Response.self, client.call("TractandaItem/get", arguments: ["ids": page.ids]))
                guard result.state == page.queryState, result.notFound.isEmpty else {
                    throw TractandaError("stateChanged", "Items changed while loading; refresh the view.")
                }
                let byID = Dictionary(uniqueKeysWithValues: result.list.map { ($0.itemID, $0) })
                guard page.ids.allSatisfy({ byID[$0] != nil }) else {
                    throw TractandaError("protocolError", "Missing query result.")
                }
                loaded.append(
                    WorkspaceSection(
                        category: category, items: page.ids.compactMap { byID[$0] }, position: offset,
                        total: page.total))
            }
            let navigation = try categoryPath.isEmpty ? nil : CategoryHierarchy(self.categories())
            if navigation != nil, try client.state() != initialState {
                throw TractandaError("stateChanged", "Categories changed while loading. Refresh the view.")
            }
            sections = loaded
            excludedCategoryNames = excludedNames
            categoryNavigation = navigation
            sectionCategories = categories
            queryState = initialState
        } catch {
            sections = []
            excludedCategoryNames = []
            categoryNavigation = nil
            throw error
        }
    }

    func loadPage(in sectionIndex: Int, forward: Bool) throws {
        guard sections.indices.contains(sectionIndex) else { return }
        var positions = sections.map(\.position)
        positions[sectionIndex] = max(0, positions[sectionIndex] + (forward ? Self.pageSize : -Self.pageSize))
        try loadSections(positions: positions, requiring: queryState)
    }

    func toggleSection(_ index: Int, isCollapsed: Bool? = nil) throws {
        guard sections.indices.contains(index), let category = sections[index].category else { return }
        let collapse = isCollapsed ?? !collapsedSectionIDs.contains(category.itemID)
        let wasCollapsed = collapsedSectionIDs.contains(category.itemID)
        if collapse {
            collapsedSectionIDs.insert(category.itemID)
        } else {
            // Expansion rechecks permissions and membership before revealing cached content.
            try refresh()
            collapsedSectionIDs.remove(category.itemID)
        }
        if collapse != wasCollapsed { view = nil }
    }

    func categories() throws -> [Revision] { try client.revisions(matching: "selection == *") }
    func views() throws -> [Revision] { try client.revisions(matching: "viewDefinition == *") }

    /// Completion is optional view/category configuration, not an item class or status field.
    func completionCategory() throws -> Revision? {
        for source in [view].compactMap({ $0 }) + categoryPath.reversed() {
            let head = try client.revision(for: source.itemID)
            if let reference = head.fields["completionCategory"]?.link {
                let category = try client.revision(for: reference.itemID)
                guard !category.isDeleted, category.fields["selection"] != nil else {
                    throw TractandaError("notCategory", "Choose an available completion category.")
                }
                return category
            }
        }
        return nil
    }

    func completionAlternatives(for category: Revision) throws -> [String] {
        for source in [view].compactMap({ $0 }) + categoryPath.reversed() {
            let head = try client.revision(for: source.itemID)
            guard head.fields["completionCategory"]?.link?.itemID == category.itemID,
                let definition = head.fields["viewDefinition"]
            else { continue }
            let sections = try SavedViewDefinition(definition).presentation.sectionIDs
            if sections.contains(category.itemID) { return sections.filter { $0 != category.itemID } }
        }
        return []
    }

    func openView(_ view: Revision) throws {
        guard let value = view.fields["viewDefinition"] else {
            throw TractandaError("notView", "This item has no saved view definition.")
        }
        let definition = try SavedViewDefinition(value)
        let categories = try definition.categoryPath.map { try client.revision(for: $0) }
        let sections = try definition.presentation.sectionIDs.map { try client.revision(for: $0) }
        self.view = view
        viewToUpdate = view
        expression = definition.expression ?? ""
        text = definition.text ?? ""
        categoryPath = categories
        excludedCategoryIDs = definition.excludedCategoryIDs
        sort = definition.sort
        columns = definition.presentation.columns
        sectionCategories = sections
        collapsedSectionIDs = definition.presentation.collapsedSectionIDs
        try refresh(position: 0)
    }

    func enter(_ category: Revision) throws {
        guard categoryPath.count < 32, !categoryPath.contains(where: { $0.itemID == category.itemID }) else {
            throw TractandaError(
                "categoryPath", "This category is already in the path, or the path has 32 levels.")
        }
        view = nil
        categoryPath.append(category)
        try refresh(position: 0)
    }

    func enter(path: [Revision]) throws {
        let additions = path.filter { item in !categoryPath.contains { $0.itemID == item.itemID } }
        guard categoryPath.count + additions.count <= 32 else {
            throw TractandaError("categoryPath", "The combined filter path exceeds 32 levels.")
        }
        view = nil
        categoryPath += additions
        try refresh(position: 0)
    }

    /// Ordinary navigation replaces the selection; enter(path:) explicitly adds filters.
    func browse(path: [Revision]) throws {
        guard path.count <= 32, Set(path.map(\.itemID)).count == path.count else {
            throw TractandaError("categoryPath", "Choose a path of at most 32 distinct categories.")
        }
        expression = ""
        text = ""
        categoryPath = path
        excludedCategoryIDs = []
        view = nil
        viewToUpdate = nil
        sectionCategories = []
        collapsedSectionIDs = []
        try refresh(position: 0)
    }

    func allItems() throws {
        expression = ""
        text = ""
        categoryPath = []
        excludedCategoryIDs = []
        view = nil
        viewToUpdate = nil
        columns = ViewPresentation.defaultColumns
        sort = []
        sectionCategories = []
        collapsedSectionIDs = []
        try refresh(position: 0)
    }

    /// Reopen the displayed prefix, retaining layout but clearing other selection filters.
    func browse(toCategoryAt index: Int, expectedPath: [String]) throws {
        guard categoryPath.map(\.itemID) == expectedPath, categoryPath.indices.contains(index) else {
            throw TractandaError("stateChanged", "The category path changed. Choose a current breadcrumb.")
        }
        do {
            // Resolve the prefix through current authorization and pick up renamed categories.
            let path = try categoryPath.prefix(index + 1).map { try client.revision(for: $0.itemID) }
            try browse(path: path)
        } catch {
            sections = []
            excludedCategoryNames = []
            categoryNavigation = nil
            throw error
        }
    }

    /// Fetch an authorized node graph without expanding paths. Nil selects roots from All items.
    func childCategories(at index: Int?, expectedPath: [String]) throws -> [Revision] {
        guard categoryPath.map(\.itemID) == expectedPath,
            index.map({ categoryPath.indices.contains($0) }) ?? categoryPath.isEmpty
        else {
            throw TractandaError("stateChanged", "The category path changed. Choose a current breadcrumb.")
        }
        do {
            let graph = try CategoryHierarchy(categories())
            guard expectedPath.prefix(index.map { $0 + 1 } ?? 0).allSatisfy({ graph.items[$0] != nil }) else {
                throw TractandaError("notFound", "This category path is no longer available.")
            }
            categoryNavigation = graph
            let ids = index.map { graph.children[expectedPath[$0]] ?? [] } ?? graph.roots
            return ids.compactMap { graph.items[$0] }
        } catch {
            categoryNavigation = nil
            sections = []
            throw error
        }
    }

    func browse(childID: String, at index: Int?, expectedPath: [String]) throws {
        let children = try childCategories(at: index, expectedPath: expectedPath)
        guard let child = children.first(where: { $0.itemID == childID }), let graph = categoryNavigation
        else {
            sections = []
            throw TractandaError(
                "stateChanged", "This category is no longer an available child. Open the list again.")
        }
        // Explicitly combined paths can already include this child. Keep one filter per identity.
        let prefix = expectedPath.prefix(index.map { $0 + 1 } ?? 0)
            .filter { $0 != childID }.compactMap { graph.items[$0] }
        try browse(path: prefix + [child])
    }

    func leaveCategory() throws {
        guard !categoryPath.isEmpty else { return }
        view = nil
        categoryPath.removeLast()
        try refresh(position: 0)
    }

    func history(of item: Revision) throws -> [Revision] {
        struct Response: Decodable {
            let list: [Revision]
            let total: Int
        }
        return try JSON.decode(
            Response.self,
            client.call(
                "TractandaItem/history",
                arguments: [
                    "itemID": item.itemID, "position": 0, "limit": 64,
                ])
        ).list
    }

    func assignment(_ decision: String?, item: Revision, category: Revision) -> CommitRequest {
        var overrides = item.fields["categoryOverrides"]?.map ?? [:]
        overrides[category.itemID] = decision.map(ItemValue.text)
        return CommitRequest(
            action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
            changes: ["categoryOverrides": .object(overrides)], operationID: Identifier.make())
    }

    var viewDefinition: ItemValue {
        makeViewDefinition(
            categoryPath: categoryPath, excludedCategoryIDs: excludedCategoryIDs, expression: expression,
            text: text, sort: sort, columns: columns, sectionCategories: sectionCategories,
            collapsedSectionIDs: collapsedSectionIDs)
    }

    func makeViewDefinition(
        categoryPath: [Revision], excludedCategoryIDs: [String], expression: String, text: String,
        sort: [ItemSort], columns: [ViewColumn], sectionCategories: [Revision],
        collapsedSectionIDs: Set<String>, sortValues: [ItemValue]? = nil, preservingBase: Bool = true
    ) -> ItemValue {
        var definition = preservingBase ? viewToUpdate?.fields["viewDefinition"]?.map ?? [:] : [:]
        definition["language"] = .text(SpotlightQuery.profile)
        definition["categoryPath"] = .list(categoryPath.map { .reference(ItemReference($0.itemID)) })
        definition["excludedCategoryIDs"] =
            excludedCategoryIDs.isEmpty
            ? nil : .list(excludedCategoryIDs.map { .reference(ItemReference($0)) })
        definition["expression"] = expression.isEmpty ? nil : .text(expression)
        definition["text"] = text.isEmpty ? nil : .text(text)
        // Retain unknown comparator options on keys the user has kept.
        let oldSort = definition["sort"]?.array ?? []
        definition["sort"] = .list(
            sortValues
                ?? sort.map { comparator in
                    var map = oldSort.first { $0.map?["property"]?.string == comparator.property }?.map ?? [:]
                    map.merge(comparator.value.map!) { _, new in new }
                    return .object(map)
                })
        var presentation = definition["presentation"]?.map ?? [:]
        presentation["profile"] = .text(ViewPresentation.profile)
        presentation["columns"] = .list(columns.map(\.value))
        presentation["sections"] = .list(sectionCategories.map { .reference(ItemReference($0.itemID)) })
        presentation["collapsedSections"] = .list(
            sectionCategories.filter {
                collapsedSectionIDs.contains($0.itemID)
            }.map { .reference(ItemReference($0.itemID)) })
        definition["presentation"] = .object(presentation)
        return .object(definition)
    }

    func viewRequest(
        name: String, body: String? = nil, replacing: Bool = false, definition: ItemValue? = nil
    ) -> CommitRequest {
        let base = replacing ? viewToUpdate : nil
        var changes: [String: ItemValue] = [
            "subject": .text(name), "viewDefinition": definition ?? viewDefinition,
        ]
        if let body, body != base?.fields["body"]?.string ?? "" { changes["body"] = .text(body) }
        return CommitRequest(
            action: base == nil ? .create : .revise, itemID: base?.itemID,
            expectedRevisionID: base?.revisionID,
            // A view is defined by this property, not by a special item subtype.
            classID: base == nil ? "Item" : nil,
            changes: changes,
            operationID: Identifier.make())
    }
}

struct ItemDraft {
    static let supportedClassIDs = Set(ItemTypes.parents.keys).union(["Item"]).filter {
        !ItemTypes.abstract.contains($0) && $0 != "PersonalStateItem" && $0 != "AccessConfigurationItem"
    }.sorted()
    let base: Revision?
    let assignedCategories: [String]
    let isCategory: Bool
    var subject: TextBuffer
    var body: TextBuffer
    var className: TextBuffer
    var rule: TextBuffer
    var parentIDs: [String] = []

    init(base: Revision? = nil, categories: [String] = [], isCategory: Bool = false) throws {
        self.base = base
        assignedCategories = categories
        self.isCategory = isCategory
        subject = TextBuffer(base?.fields["subject"]?.string ?? "")
        body = TextBuffer(base?.fields["body"]?.string ?? "")
        className = TextBuffer(base?.classID ?? "Item")
        rule = TextBuffer(
            base?.fields["selection"]?.map?["expression"]?.string ?? (isCategory ? "itemID == \"\"" : ""))
        guard
            [subject.text, body.text, rule.text].allSatisfy({ $0.utf8.count <= TerminalInput.maximumPaste })
        else {
            throw TractandaError(
                "editLimit",
                "This item exceeds the TUI's 64 KiB per-field editor limit. Use the CLI for this edit.")
        }
    }

    mutating func cycleClass(forward: Bool) {
        // A new category starts as an ordinary Item. An existing category is still an item
        // and must retain (or deliberately change) its real class rather than being coerced.
        guard !(isCategory && base == nil), !Self.supportedClassIDs.isEmpty else { return }
        let index = Self.supportedClassIDs.firstIndex(of: className.text) ?? -1
        let next = (index + (forward ? 1 : Self.supportedClassIDs.count - 1)) % Self.supportedClassIDs.count
        className = TextBuffer(Self.supportedClassIDs[next])
    }

    func request() -> CommitRequest? {
        var changes: [String: ItemValue] = [:]
        var unset: [String] = []
        for (key, value) in [("subject", subject.text), ("body", body.text)] {
            if value != (base?.fields[key]?.string ?? "") || base == nil { changes[key] = .text(value) }
        }
        let originalRule = base?.fields["selection"]?.map?["expression"]?.string ?? ""
        if rule.text != originalRule {
            if rule.text.isEmpty {
                unset.append("selection")
            } else {
                var selection = base?.fields["selection"]?.map ?? [:]
                selection["language"] = .text(SpotlightQuery.profile)
                selection["expression"] = .text(rule.text)
                changes["selection"] = .object(selection)
            }
        }
        if base == nil && !assignedCategories.isEmpty {
            changes["categoryOverrides"] = .object(
                Dictionary(uniqueKeysWithValues: assignedCategories.map { ($0, .text("include")) }))
        }
        if base == nil && !parentIDs.isEmpty {
            changes["categoryParents"] = .list(parentIDs.map { .reference(ItemReference($0)) })
        }
        let isRetype = base != nil && className.text != base?.classID
        if base != nil, changes.isEmpty, unset.isEmpty, !isRetype { return nil }
        return CommitRequest(
            action: base == nil ? .create : isRetype ? .retype : .revise,
            itemID: base?.itemID, expectedRevisionID: base?.revisionID,
            classID: base == nil || isRetype ? className.text : nil, changes: changes, unset: unset,
            operationID: Identifier.make())
    }
}

/// Frozen pending intent: retries never silently receive a new operation ID or revision guard.
final class PendingEdit {
    let request: CommitRequest
    init(_ request: CommitRequest) { self.request = request }
    func send(using client: ItemClient) throws -> CommitResult { try client.commit(request) }
}
