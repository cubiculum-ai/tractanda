import TractandaCore

/// An authorized category graph, projected into rows only where the user opens branches.
struct CategoryTree {
    struct Row {
        let item: Revision
        let path: [Revision]
        let hasChildren: Bool
        let isExpanded: Bool
        var key: String { path.map(\.itemID).joined(separator: "/") }
    }

    /// Indexes sibling ranges without allocating a Revision path for every visible placement.
    /// Closed branches have no child index. Seeking to the last row never walks hidden descendants.
    struct Rows: RandomAccessCollection {
        typealias Index = Int
        fileprivate struct Branch {
            var ids: [String] = []
            var ends: [Int] = []
            var branches: [Int: Branch] = [:]
            var count: Int { ends.last ?? 0 }

            func slot(at offset: Int) -> Int {
                var lower = 0
                var upper = ends.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if ends[middle] <= offset { lower = middle + 1 } else { upper = middle }
                }
                return lower
            }
        }
        fileprivate var items: [String: Revision] = [:]
        fileprivate var children: [String: [String]] = [:]
        fileprivate var root = Branch()
        var startIndex: Int { 0 }
        var endIndex: Int { root.count }
        func index(after i: Int) -> Int { i + 1 }
        func index(before i: Int) -> Int { i - 1 }

        subscript(index: Int) -> Row {
            precondition(indices.contains(index))
            var branch = root
            var offset = index
            var path: [Revision] = []
            while true {
                let slot = branch.slot(at: offset)
                let item = items[branch.ids[slot]]!
                path.append(item)
                offset -= slot == 0 ? 0 : branch.ends[slot - 1]
                if offset == 0 {
                    return Row(
                        item: item, path: path, hasChildren: !(children[item.itemID] ?? []).isEmpty,
                        isExpanded: branch.branches[slot] != nil)
                }
                offset -= 1
                branch = branch.branches[slot]!
            }
        }

        /// For a visible placement, flags for whether each ancestor has a following sibling.
        /// Connected rendering can therefore draw branch continuations without walking closed
        /// descendants or expanding another path through a shared category.
        func continuationFlags(at index: Int) -> [Bool] {
            precondition(indices.contains(index))
            var branch = root
            var offset = index
            var flags: [Bool] = []
            while true {
                let slot = branch.slot(at: offset)
                flags.append(slot < branch.ids.count - 1)
                offset -= slot == 0 ? 0 : branch.ends[slot - 1]
                if offset == 0 { return flags }
                offset -= 1
                branch = branch.branches[slot]!
            }
        }

        func index(ofPath path: [String]) -> Int? {
            var branch = root
            var offset = 0
            for (depth, id) in path.enumerated() {
                guard let slot = branch.ids.firstIndex(of: id) else { return nil }
                offset += slot == 0 ? 0 : branch.ends[slot - 1]
                if depth == path.count - 1 { return offset }
                guard let next = branch.branches[slot] else { return nil }
                offset += 1
                branch = next
            }
            return nil
        }
    }

    private let graph: CategoryHierarchy
    private let searchParents: [String: String]
    private let searchChildren: [String: [String]]
    private let searchOrder: [String]
    let initialExpansion: Set<String>
    let categoriesWithChildren: Set<String>

    init(_ items: [Revision], preferredPath: [String] = []) throws {
        let graph = try CategoryHierarchy(items)
        self.graph = graph
        categoriesWithChildren = Set(graph.children.filter { !$0.value.isEmpty }.map(\.key))
        // Search uses a deterministic shortest readable path per category. This visits graph
        // nodes/edges, never all paths through a DAG. Retain the caller's chosen placement.
        var order = graph.roots
        var seen = Set(order)
        var parents: [String: String] = [:]
        var next = 0
        while next < order.count {
            let id = order[next]
            next += 1
            for child in graph.children[id] ?? [] where seen.insert(child).inserted {
                parents[child] = id
                order.append(child)
            }
        }
        var expanded = Set(graph.roots)
        if let root = preferredPath.first, graph.roots.contains(root),
            zip(preferredPath, preferredPath.dropFirst()).allSatisfy({
                graph.children[$0.0]?.contains($0.1) == true
            })
        {
            for (parent, child) in zip(preferredPath, preferredPath.dropFirst()) {
                parents[child] = parent
            }
            for depth in 1..<preferredPath.count {
                expanded.insert(preferredPath.prefix(depth).joined(separator: "/"))
            }
        }
        searchParents = parents
        searchChildren = graph.children.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.filter { parents[$0] == entry.key }
        }
        searchOrder = order
        initialExpansion = expanded
    }

    func rows(filter: String, expanded: Set<String>) -> Rows {
        let roots: [String]
        let children: [String: [String]]
        let searching = !filter.isEmpty
        if searching {
            var included: Set<String> = []
            for id in searchOrder
            where (graph.items[id]?.fields["subject"]?.string ?? "")
                .localizedCaseInsensitiveContains(filter)
            {
                var ancestor: String? = id
                while let current = ancestor, included.insert(current).inserted {
                    ancestor = searchParents[current]
                }
            }
            roots = graph.roots.filter { included.contains($0) }
            children = searchChildren.mapValues { $0.filter { included.contains($0) } }
        } else {
            roots = graph.roots
            children = graph.children
        }
        func branch(_ ids: [String], prefix: String) -> Rows.Branch {
            var result = Rows.Branch(ids: ids)
            var count = 0
            for (slot, id) in ids.enumerated() {
                let key = prefix.isEmpty ? id : prefix + "/" + id
                count += 1
                if let descendants = children[id], !descendants.isEmpty,
                    searching || expanded.contains(key)
                {
                    let nested = branch(descendants, prefix: key)
                    count += nested.count
                    result.branches[slot] = nested
                }
                result.ends.append(count)
            }
            return result
        }
        return Rows(items: graph.items, children: graph.children, root: branch(roots, prefix: ""))
    }
}
