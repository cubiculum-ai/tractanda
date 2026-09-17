import Foundation
import TractandaCore

/// A board is an ordinary saved view grouped by its category sections.
public final class KanbanRepository {
    public let client: ItemClient
    public init(client: ItemClient) { self.client = client }

    /// The web project's board is derived from ordinary category membership.  It deliberately
    /// has no saved-view or task-board identity: the selected project category and the status
    /// category root are the complete query definition.
    public struct ProjectBoardConfiguration: Codable, Equatable, Sendable {
        public let initialProjectID: String
        public let projectRootID: String
        public let statusRootID: String

        public init(initialProjectID: String, projectRootID: String, statusRootID: String) {
            self.initialProjectID = initialProjectID
            self.projectRootID = projectRootID
            self.statusRootID = statusRootID
        }
    }

    private func categories() throws -> (state: String, hierarchy: CategoryHierarchy) {
        let state = try client.state()
        // The native service applies ACL filtering before returning heads.  Build the hierarchy
        // only from that authorized set, never from a cached or configuration-supplied graph.
        let hierarchy = try CategoryHierarchy(client.revisions(matching: "selection == *"))
        guard try client.state() == state else {
            throw TractandaError("stateChanged", "The category graph changed during refresh.")
        }
        return (state, hierarchy)
    }

    private static func axisRoots(presentation: ViewPresentation, sort: [ItemSort]) throws -> [String] {
        var result: [String] = []
        for id in presentation.columns.compactMap(\.categoryRootID) + sort.compactMap(\.categoryRootID)
        where !result.contains(id) { result.append(id) }
        guard result.count <= 8 else {
            throw TractandaError("invalidView", "Use at most eight category axes.")
        }
        return result
    }

    private func categoryAxes(ids: [String], roots: [String], state: String) throws
        -> CategoryMembershipProjection?
    {
        guard !roots.isEmpty else { return nil }
        // The bounded endpoint also supplies root descriptors. Probe a readable root when the
        // board is empty, then discard its incidental membership from the board result.
        let batches =
            ids.isEmpty
            ? [[roots[0]]]
            : stride(from: 0, to: ids.count, by: 64).map {
                Array(ids[$0..<min($0 + 64, ids.count)])
            }
        var projection: CategoryMembershipProjection?
        var memberships: [String: [String: [String]]] = [:]
        for batch in batches {
            let result = try client.categoryMemberships(ids: batch, categoryRootIDs: roots)
            guard result.state == state, result.notFound.isEmpty else {
                throw TractandaError("stateChanged", "Categories changed while loading the board.")
            }
            if projection == nil { projection = result }
            memberships.merge(result.memberships) { _, newer in newer }
        }
        guard let projection else { return nil }
        return CategoryMembershipProjection(
            state: projection.state, roots: projection.roots, memberships: memberships, notFound: [])
    }

    private static func descendants(
        of rootID: String, hierarchy: CategoryHierarchy, includeRoot: Bool = true
    ) -> [(id: String, path: [String])] {
        guard hierarchy.items[rootID] != nil else { return [] }
        var results: [(String, [String])] = []
        var seen: Set<String> = []
        func visit(_ id: String, _ path: [String]) {
            guard seen.insert(id).inserted else { return }
            results.append((id, path))
            for child in hierarchy.children[id] ?? [] {
                let name = hierarchy.items[child]?.fields["subject"]?.string ?? "Category"
                visit(child, path + [name])
            }
        }
        let rootName = hierarchy.items[rootID]?.fields["subject"]?.string ?? "Category"
        if includeRoot {
            visit(rootID, [rootName])
        } else {
            for child in hierarchy.children[rootID] ?? [] {
                visit(child, [rootName, hierarchy.items[child]?.fields["subject"]?.string ?? "Category"])
            }
        }
        return results
    }

    /// A current, ACL-filtered project catalog.  The root is included as the implicit All
    /// projects choice; descendants retain one stable readable display path.
    public func projects(projectRootID: String) throws -> [[String: JSONValue]] {
        let graph = try categories()
        guard graph.hierarchy.items[projectRootID] != nil else {
            throw TractandaError("projectRootUnavailable", "The project root category is unavailable.")
        }
        return Self.descendants(of: projectRootID, hierarchy: graph.hierarchy).map { entry in
            let name = entry.id == projectRootID ? "All projects" : entry.path.joined(separator: " / ")
            return [
                "id": .string(entry.id), "name": .string(name),
                "path": .array(entry.path.map(JSONValue.string)),
            ]
        }
    }

    /// Snapshot for a category-derived project board.  The two native intersections are
    /// intentional: the board query proves project+status membership, while each leaf query
    /// decides its own inherited/manual membership and authorization.
    public func projectSnapshot(
        projectID: String, projectRootID: String, statusRootID: String
    ) throws -> [String: JSONValue] {
        for _ in 0..<3 {
            do {
                let graph = try categories()
                guard graph.hierarchy.items[projectRootID] != nil,
                    graph.hierarchy.items[statusRootID] != nil
                else {
                    throw TractandaError(
                        "boardRootUnavailable", "A configured board category is unavailable.")
                }
                let projectIDs = Set(
                    Self.descendants(of: projectRootID, hierarchy: graph.hierarchy).map(\.id))
                guard projectIDs.contains(projectID), let project = graph.hierarchy.items[projectID] else {
                    throw TractandaError(
                        "projectUnavailable", "The selected project category is unavailable.")
                }
                var statuses = Self.descendants(of: statusRootID, hierarchy: graph.hierarchy)
                    .filter { entry in
                        entry.id != statusRootID && (graph.hierarchy.children[entry.id] ?? []).isEmpty
                    }
                guard !statuses.isEmpty else {
                    throw TractandaError(
                        "invalidStatusRoot", "The status root needs at least one readable leaf category.")
                }
                let projectDefinition = project.fields["viewDefinition"].flatMap {
                    try? SavedViewDefinition($0)
                }
                let rootDefinition = graph.hierarchy.items[projectRootID]?.fields["viewDefinition"]
                    .flatMap { try? SavedViewDefinition($0) }
                let projectDefinitionFields = project.fields["viewDefinition"]?.map
                let presentation =
                    projectDefinitionFields?["presentation"] != nil
                    ? projectDefinition?.presentation : rootDefinition?.presentation
                if let presentation {
                    let available = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
                    let preferred = presentation.sectionIDs.compactMap { available[$0] }
                    let preferredIDs = Set(preferred.map(\.id))
                    statuses = preferred + statuses.filter { !preferredIDs.contains($0.id) }
                }
                let viewSort =
                    projectDefinitionFields?["sort"] != nil
                    ? projectDefinition?.sort ?? [] : rootDefinition?.sort ?? []
                var query: [String: Any] = ["categoryPath": [projectID, statusRootID]]
                if !viewSort.isEmpty {
                    query["sort"] = viewSort.map {
                        var descriptor: [String: Any] = ["isAscending": $0.isAscending]
                        if let property = $0.property { descriptor["property"] = property }
                        if let rootID = $0.categoryRootID { descriptor["categoryRootID"] = rootID }
                        return descriptor
                    }
                }
                let items = try client.revisions(query: query)
                let axisRootIDs = try Self.axisRoots(
                    presentation: presentation ?? ViewPresentation(), sort: viewSort)
                let axes = try categoryAxes(ids: items.map(\.itemID), roots: axisRootIDs, state: graph.state)
                var memberships: [String: [String]] = [:]
                for status in statuses {
                    for item in try client.revisions(query: ["categoryPath": [projectID, status.id]]) {
                        memberships[item.itemID, default: []].append(status.id)
                    }
                }
                let filterIDs = try Self.references(project.fields["filterCategories"])
                    .filter { graph.hierarchy.items[$0] != nil }
                var filters: [String: [String]] = [:]
                for filterID in filterIDs {
                    for item in try client.revisions(query: ["categoryPath": [projectID, filterID]]) {
                        filters[item.itemID, default: []].append(filterID)
                    }
                }
                guard try client.state() == graph.state else { continue }
                let statusIDs = Set(statuses.map(\.id))
                func validStatusReference(_ key: String) -> String? {
                    guard let id = project.fields[key]?.link?.itemID, statusIDs.contains(id) else {
                        return nil
                    }
                    return id
                }
                let statusRoot = graph.hierarchy.items[statusRootID]!
                let defaultID =
                    validStatusReference("defaultCategory")
                    ?? (statusRoot.fields["defaultCategory"]?.link?.itemID).flatMap {
                        statusIDs.contains($0) ? $0 : nil
                    }
                let completionID =
                    validStatusReference("completionCategory")
                    ?? (statusRoot.fields["completionCategory"]?.link?.itemID).flatMap {
                        statusIDs.contains($0) ? $0 : nil
                    }
                let duplicateStatusNames = Dictionary(grouping: statuses) {
                    graph.hierarchy.items[$0.id]?.fields["subject"]?.string ?? "Category"
                }.filter { $0.value.count > 1 }.map(\.key)
                var document: [String: JSONValue] = [
                    "schemaVersion": .integer(3), "projectID": .string(projectID),
                    "projectRootID": .string(projectRootID), "statusRootID": .string(statusRootID),
                    "serverState": .string(graph.state),
                    "title": .string(project.fields["subject"]?.string ?? "Project"),
                    "updatedAt": .string(Timestamp.now()),
                    "columns": .array(
                        statuses.map { entry in
                            .object([
                                "id": .string(entry.id),
                                "name": .string(
                                    duplicateStatusNames.contains(entry.path.last ?? "")
                                        ? entry.path.joined(separator: " / ")
                                        : (entry.path.last ?? "Category")),
                            ])
                        }),
                    "categoryAxes": .array(
                        (axes?.roots ?? []).map { root in
                            .object([
                                "id": .string(root.id), "name": .string(root.name),
                                "children": .array(
                                    root.children.map {
                                        .object(["id": .string($0.id), "name": .string($0.name)])
                                    }),
                            ])
                        }),
                    "filters": .array(
                        filterIDs.compactMap { id in
                            graph.hierarchy.items[id].map { category in
                                .object([
                                    "id": .string(id),
                                    "name": .string(category.fields["subject"]?.string ?? "Category"),
                                ])
                            }
                        }),
                    // Capture is deliberately just the selected project; the form supplies the
                    // chosen status.  Carrying arbitrary legacy capture categories can put a new
                    // item into another project.
                    "captureCategoryIDs": .array([.string(projectID)]),
                    "originalSequence": .array([]), "recommendedSequence": .array([]),
                ]
                if let defaultID { document["defaultCategoryID"] = .string(defaultID) }
                if let completionID { document["completionCategoryID"] = .string(completionID) }
                document["tasks"] = .array(
                    items.map {
                        .object(
                            Self.makeTask(
                                from: $0, categoryIDs: memberships[$0.itemID] ?? [],
                                filterCategoryIDs: filters[$0.itemID] ?? [], preferredScopes: [projectID],
                                axisCategoryIDs: axes?.memberships[$0.itemID] ?? [:]))
                    })
                return document
            } catch let error as TractandaError where error.code == "stateChanged" { continue }
        }
        throw TractandaError("stateChanged", "The project board changed during refresh. Try again.")
    }

    public static func references(_ value: ItemValue?) throws -> [String] {
        guard let value else { return [] }
        guard let list = value.array, list.count <= 32 else {
            throw TractandaError("invalidView", "Use at most 32 category references.")
        }
        let ids = try list.map { entry -> String in
            guard let reference = entry.link, reference.revisionID == nil else {
                throw TractandaError("invalidView", "Category configuration follows current items.")
            }
            return reference.itemID
        }
        guard Set(ids).count == ids.count else {
            throw TractandaError("invalidView", "Category references must be distinct.")
        }
        return ids
    }

    /// Native queries decide membership, including inherited/manual/personal decisions and ACLs.
    public func snapshot(for viewItemID: String) throws -> [String: JSONValue] {
        for _ in 0..<3 {
            do {
                let state = try client.state()
                let view = try client.revision(for: viewItemID)
                guard !view.isDeleted, let value = view.fields["viewDefinition"] else {
                    throw TractandaError("viewUnavailable", "Choose an available saved view.")
                }
                let definition = try SavedViewDefinition(value)
                let sectionIDs = definition.presentation.sectionIDs
                guard !sectionIDs.isEmpty else {
                    throw TractandaError("invalidView", "Choose category sections for this view first.")
                }
                let filterIDs = try Self.references(view.fields["filterCategories"])
                var categories: [String: Revision] = [:]
                for id in Set(sectionIDs + filterIDs) {
                    do {
                        let item = try client.revision(for: id)
                        if !item.isDeleted, item.fields["selection"] != nil { categories[id] = item }
                    } catch let error as TractandaError
                        where error.code == "notFound" || error.code == "forbidden"
                    {
                        continue
                    }
                }
                let items = try client.revisions(viewID: viewItemID)
                let axisRootIDs = try Self.axisRoots(
                    presentation: definition.presentation, sort: definition.sort)
                let axes = try categoryAxes(ids: items.map(\.itemID), roots: axisRootIDs, state: state)
                var memberships: [String: [String]] = [:]
                for id in sectionIDs where categories[id] != nil {
                    for item in try client.revisions(viewID: viewItemID, sectionID: id) {
                        memberships[item.itemID, default: []].append(id)
                    }
                }
                var filters: [String: [String]] = [:]
                for id in filterIDs where categories[id] != nil {
                    var arguments: [String: Any] = [
                        "categoryPath": Array(Set(definition.categoryPath + [id])).sorted()
                    ]
                    if let expression = definition.expression { arguments["expression"] = expression }
                    if let text = definition.text { arguments["text"] = text }
                    if !definition.excludedCategoryIDs.isEmpty {
                        arguments["excludedCategoryIDs"] = definition.excludedCategoryIDs
                    }
                    for item in try client.revisions(query: arguments) {
                        filters[item.itemID, default: []].append(id)
                    }
                }
                guard try client.state() == state else { continue }
                func descriptors(_ ids: [String]) -> JSONValue {
                    .array(
                        ids.compactMap { id in
                            guard let category = categories[id] else { return nil }
                            return .object([
                                "id": .string(id),
                                "name": .string(category.fields["subject"]?.string ?? "Category"),
                            ])
                        })
                }
                var document = view.fields.filter {
                    ["maintenance", "sequenceStatus", "originalSequence", "recommendedSequence", "activity"]
                        .contains($0.key)
                }.mapValues(JSONValue.init)
                document["schemaVersion"] = .integer(2)
                document["viewItemID"] = .string(view.itemID)
                document["viewRevisionID"] = .string(view.revisionID)
                document["serverState"] = .string(state)
                document["title"] = .string(view.fields["subject"]?.string ?? "Category view")
                document["updatedAt"] = .string(Timestamp.now())
                document["columns"] = descriptors(sectionIDs)
                document["categoryAxes"] = .array(
                    (axes?.roots ?? []).map { root in
                        .object([
                            "id": .string(root.id), "name": .string(root.name),
                            "children": .array(
                                root.children.map {
                                    .object(["id": .string($0.id), "name": .string($0.name)])
                                }),
                        ])
                    })
                document["filters"] = descriptors(filterIDs)
                document["captureCategoryIDs"] = .array(
                    try Self.references(
                        view.fields["captureCategories"]
                            ?? .list(definition.categoryPath.map { .reference(ItemReference($0)) })
                    ).map(JSONValue.string))
                document["completionCategoryID"] = view.fields["completionCategory"]?.link.map {
                    .string($0.itemID)
                }
                document["defaultCategoryID"] = view.fields["defaultCategory"]?.link.map {
                    .string($0.itemID)
                }
                document["originalSequence"] = document["originalSequence"] ?? .array([])
                document["recommendedSequence"] = document["recommendedSequence"] ?? .array([])
                document["tasks"] = .array(
                    items.map {
                        .object(
                            Self.makeTask(
                                from: $0, categoryIDs: memberships[$0.itemID] ?? [],
                                filterCategoryIDs: filters[$0.itemID] ?? [],
                                preferredScopes: definition.categoryPath,
                                axisCategoryIDs: axes?.memberships[$0.itemID] ?? [:]))
                    })
                return document
            } catch let error as TractandaError where error.code == "stateChanged" { continue }
        }
        throw TractandaError("stateChanged", "The view changed during refresh. Try again.")
    }

    public static func makeTask(
        from item: Revision, categoryIDs: [String], filterCategoryIDs: [String],
        preferredScopes: [String] = [], axisCategoryIDs: [String: [String]] = [:]
    )
        -> [String: JSONValue]
    {
        var task = item.fields.filter {
            [
                "optional", "rationale", "originalPosition", "requestedTitle", "acceptance", "evidence",
                "activityNotes",
            ].contains($0.key)
        }.mapValues(JSONValue.init)
        task["id"] = .string(item.itemID)
        task["reference"] = .string(ItemReferenceLabel.display(in: item, preferredScopes: preferredScopes))
        task["revisionID"] = .string(item.revisionID)
        task["title"] = .string(item.fields["subject"]?.string ?? "")
        task["summary"] = .string(item.fields["body"]?.string ?? "")
        task["updatedAt"] = .string(item.modifiedAt)
        task["categoryIDs"] = .array(categoryIDs.map(JSONValue.string))
        task["filterCategoryIDs"] = .array(filterCategoryIDs.map(JSONValue.string))
        task["axisCategoryIDs"] = .object(
            axisCategoryIDs.mapValues { .array($0.map(JSONValue.string)) })
        task["notes"] = .string(item.fields["workingNotes"]?.string ?? "")
        task["dependsOn"] = .array(
            (item.fields["dependencies"]?.array ?? []).compactMap { $0.link.map { .string($0.itemID) } })
        task["checklist"] = .array(
            (item.fields["checklist"]?.array ?? []).compactMap { value in
                guard let fields = value.map else { return nil }
                var result = fields.mapValues(JSONValue.init)
                result["done"] = .boolean(fields["isComplete"]?.booleanValue ?? false)
                result.removeValue(forKey: "isComplete")
                return .object(result)
            })
        task["history"] = task["activityNotes"] ?? .array([])
        task["acceptance"] = task["acceptance"] ?? .array([])
        task["evidence"] = task["evidence"] ?? .array([])
        return task
    }
}
