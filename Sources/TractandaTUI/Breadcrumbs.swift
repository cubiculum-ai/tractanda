import TractandaCore

/// Category labels and hit regions are built together in terminal cells, never parsed from names.
enum Breadcrumbs {
    static func line(
        path: [Revision], width: Int, categoriesWithChildren: Set<String> = [],
        categoryWorkspace: Bool = false
    ) -> ScreenLine {
        guard width > 0 else { return ScreenLine(text: "") }
        let ids = path.map(\.itemID)
        let names =
            path.isEmpty
            ? ["All items"]
            : path.map {
                let name = $0.fields["subject"]?.string ?? ""
                return TerminalText.safe(name.isEmpty ? "Category" : name)
            }
        let fullWidth =
            1
            + names.reduce(0) { sum, name in
                sum + name.reduce(0) { $0 + TerminalText.width($1) }
            } + max(0, names.count - 1) * 3
            + (path.isEmpty ? 2 : path.filter { categoriesWithChildren.contains($0.itemID) }.count * 2)
        let hasOverflow = !path.isEmpty && fullWidth > width && width >= 4
        let limit = width - (hasOverflow ? 3 : 0)
        var segments = [ScreenSegment(text: " ", style: .normal)]
        var hits: [MouseHit] = []
        var x = 1
        for (index, name) in names.enumerated() {
            let separator = index == 0 ? "" : " / "
            // The virtual All items entry discovers readable roots only when its menu is opened.
            let hasChildren = path.isEmpty || categoriesWithChildren.contains(path[index].itemID)
            let available = max(0, limit - x - separator.count - (hasChildren ? 2 : 0))
            var visible = ""
            var length = 0
            for character in name {
                let size = TerminalText.width(character)
                guard length + size <= available else { break }
                visible.append(character)
                length += size
            }
            guard !visible.isEmpty else { break }
            segments.append(ScreenSegment(text: separator, style: .normal))
            x += separator.count
            segments.append(ScreenSegment(text: visible, style: .link))
            hits.append(
                MouseHit(
                    columns: x..<(x + length),
                    target: categoryWorkspace
                        ? .categoryBreadcrumb(index, ids)
                        : path.isEmpty ? .command(.allItems) : .breadcrumb(index, ids)))
            x += length
            if hasChildren {
                segments.append(ScreenSegment(text: " ▾", style: .link))
                hits.append(
                    MouseHit(
                        columns: x..<(x + 2),
                        target: categoryWorkspace
                            ? .categoryBreadcrumbChildren(path.isEmpty ? nil : index, ids)
                            : .breadcrumbChildren(path.isEmpty ? nil : index, ids)))
                x += 2
            }
            if visible != name { break }
        }
        segments.append(ScreenSegment(text: String(repeating: " ", count: max(0, limit - x)), style: .normal))
        if hasOverflow {
            segments += [
                ScreenSegment(text: " ", style: .normal), ScreenSegment(text: "…", style: .link),
                ScreenSegment(text: " ", style: .normal),
            ]
            hits.append(
                MouseHit(
                    columns: limit..<width,
                    target: categoryWorkspace ? .categoryBreadcrumbChooser(ids) : .breadcrumbChooser(ids)))
        }
        return ScreenLine(text: segments.map(\.text).joined(), segments: segments, hits: hits)
    }
}
