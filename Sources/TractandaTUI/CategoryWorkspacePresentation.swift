import TractandaCore

/// Renders only visible category placements and one native item page. Layout is independent of
/// navigation and edits; all mouse targets use the same cell origins as text and caret spans.
enum CategoryWorkspacePresentation {
    struct Result {
        var lines: [ScreenLine]
        let navigatorStart: Int
        let previewStart: Int
        let inspectorViewport: (field: Int, start: Int, maximum: Int)?
        let inspectorTextWidth: Int
    }

    static func inspectorTextWidth(paneWidth: Int) -> Int {
        max(1, paneWidth - min(18, max(10, paneWidth / 3)))
    }

    static func render(
        manager: CategoryWorkspace, rows: CategoryTree.Rows, selectedIndex: Int,
        firstVisibleIndex: Int, filter: TextBuffer, columns: [ViewColumn], columnOffset: Int,
        width: Int, height: Int, previewVisible: Bool,
        previewContentRows: Int = ItemPreviewPresentation.defaultContentRows,
        previewFocused: Bool = false, previewOffset: Int = 0,
        cursorLayout: CursorLayout,
        title: (Revision) -> String, rowKey: (Int) -> String?, categoriesWithChildren: Set<String>
    ) -> Result {
        let split = width >= 79 && !manager.isMaximized
        let leftWidth = split ? max(22, min(width - 28, Int(Double(width) * manager.splitWidth))) : width
        let rightWidth = split ? max(1, width - leftWidth - 1) : width
        let navigatorActive = manager.focus == .navigator && !previewFocused
        let leftStyle: ScreenStyle = navigatorActive ? .activePane : .dimmed
        let rightStyle: ScreenStyle = navigatorActive || previewFocused ? .dimmed : .activePane
        let leftSelection: ScreenStyle = navigatorActive ? .activeSelection : .inactiveSelection
        let rightSelection: ScreenStyle =
            navigatorActive || previewFocused ? .inactiveSelection : .activeSelection
        let effectivePreviewRows =
            previewVisible
            ? ItemPreviewPresentation.effectiveContentRows(
                preferred: previewContentRows, terminalRows: height) : 0
        let bodyHeight = max(1, height - (previewVisible ? effectivePreviewRows + 8 : 7))
        let rowCapacity = max(1, bodyHeight - 1)
        let navigatorStart = TerminalViewport.start(
            selected: manager.selectedAllItems ? 0 : selectedIndex, count: rows.count,
            capacity: rowCapacity, previous: firstVisibleIndex)
        let previewStart = TerminalViewport.start(
            selected: manager.previewIndex, count: manager.preview.rows.count,
            capacity: rowCapacity, previous: manager.previewFirstVisible)

        func line(_ text: String = "", style: ScreenStyle, hits: [MouseHit] = []) -> ScreenLine {
            ScreenLine(text: text, style: style, hits: hits)
        }
        func clippedHits(_ hits: [MouseHit], width: Int, shift: Int = 0) -> [MouseHit] {
            hits.compactMap { hit in
                let lower = max(0, hit.columns.lowerBound)
                let upper = min(width, hit.columns.upperBound)
                guard lower < upper else { return nil }
                return MouseHit(columns: (lower + shift)..<(upper + shift), target: hit.target)
            }
        }
        func combine(_ left: ScreenLine, _ right: ScreenLine) -> ScreenLine {
            guard split else {
                var visible = navigatorActive ? left : right
                visible.text = TerminalText.fit(visible.text, columns: width)
                visible.hits = clippedHits(visible.hits, width: width)
                if let cursor = visible.cursorColumn, cursor >= width { visible.cursorColumn = nil }
                return visible
            }
            let start = leftWidth + 1
            let a = TerminalText.fit(left.text, columns: leftWidth)
            let b = TerminalText.fit(right.text, columns: rightWidth)
            var selections = left.selectionColumns.compactMap { span -> Range<Int>? in
                let lower = max(0, span.lowerBound)
                let upper = min(leftWidth, span.upperBound)
                return lower < upper ? lower..<upper : nil
            }
            selections += right.selectionColumns.compactMap { span -> Range<Int>? in
                let lower = max(0, span.lowerBound)
                let upper = min(rightWidth, span.upperBound)
                return lower < upper ? (start + lower)..<(start + upper) : nil
            }
            let cursor: Int?
            if navigatorActive, let value = left.cursorColumn, (0..<leftWidth).contains(value) {
                cursor = value
            } else if !navigatorActive && !previewFocused, let value = right.cursorColumn,
                (0..<rightWidth).contains(value)
            {
                cursor = start + value
            } else {
                cursor = nil
            }
            return ScreenLine(
                text: a + "│" + b,
                segments: [
                    ScreenSegment(text: a, style: left.style),
                    ScreenSegment(text: "│", style: .dimmed),
                    ScreenSegment(text: b, style: right.style),
                ],
                hits: clippedHits(left.hits, width: leftWidth)
                    + [MouseHit(columns: leftWidth..<(leftWidth + 1), target: .categoryDivider)]
                    + clippedHits(right.hits, width: rightWidth, shift: start),
                selectionColumns: selections, cursorColumn: cursor)
        }

        var header = " Category manager · "
        var headerHits: [MouseHit] = []
        func headerControl(_ text: String, target: MouseTarget) {
            let start = header.reduce(0) { $0 + TerminalText.width($1) }
            header += text
            headerHits.append(MouseHit(columns: start..<(start + text.count), target: target))
        }
        headerControl(manager.rightMode == .items ? "[Items]" : "Items", target: .categoryModeItems)
        header += " | "
        headerControl(
            manager.rightMode == .category ? "[Category]" : "Category", target: .categoryModeInspector)
        if width >= 52 { header += " · Shift-F2/Meta-I toggle" }
        if width >= 65 {
            header += " · "
            headerControl(manager.connectedTree ? "Connected tree" : "Outline", target: .categoryToggleTree)
            header += " · "
            headerControl(manager.isMaximized ? "Split" : "Maximize", target: .categoryToggleMaximize)
        }
        if manager.hasDirtyInspector { header += " · unsaved draft" }
        var output = [line(header, style: .header, hits: clippedHits(headerHits, width: width))]
        output.append(
            Breadcrumbs.line(
                path: manager.selectedPath, width: width, categoriesWithChildren: categoriesWithChildren,
                categoryWorkspace: true))
        let search = filter.displayLines(
            columns: max(1, leftWidth - 7), marked: navigatorActive, flatten: true,
            cursorLayout: cursorLayout)
        let searchLine = search.first(where: \.containsCursor) ?? search[0]
        var searchRow = line(
            " Find: " + searchLine.text, style: leftStyle,
            hits: [
                MouseHit(columns: 0..<min(7, leftWidth), target: .pickerText([filter.cursor])),
                MouseHit(columns: 7..<max(8, leftWidth), target: .pickerText(searchLine.offsets)),
            ])
        if navigatorActive {
            searchRow.cursorColumn = searchLine.cursorColumn.map { 7 + $0 }
            searchRow.selectionColumns = searchLine.selectionColumns.map {
                (7 + $0.lowerBound)..<(7 + $0.upperBound)
            }
        }
        let range =
            manager.preview.rows.isEmpty
            ? "0/\(manager.preview.total)"
            : "\(manager.preview.position + 1)–\(manager.preview.position + manager.preview.rows.count)/\(manager.preview.total)"
        let rightHeading =
            manager.rightMode == .items
            ? " Items · \(range)" + (navigatorActive || previewFocused ? "" : " · focused")
            : " Edit item / Category" + (navigatorActive || previewFocused ? "" : " · focused")
        output.append(combine(searchRow, line(rightHeading, style: .header)))

        var leftRows = [
            line(
                (manager.selectedAllItems ? " > " : "   ") + "All items",
                style: manager.selectedAllItems ? leftSelection : leftStyle,
                hits: [MouseHit(columns: 0..<leftWidth, target: .categoryAllItems)])
        ]
        for offset in 0..<rowCapacity {
            let index = navigatorStart + offset
            guard rows.indices.contains(index) else {
                leftRows.append(
                    line(rows.isEmpty && offset == 0 ? " No matching entries." : "", style: leftStyle))
                continue
            }
            let row = rows[index]
            var connector: String
            if manager.connectedTree {
                let flags = rows.continuationFlags(at: index)
                connector =
                    flags.dropLast().map { $0 ? "│ " : "  " }.joined()
                    + (flags.last == true ? "├─" : "└─")
            } else {
                connector = String(repeating: "  ", count: max(0, row.path.count - 1))
            }
            let caption = title(row.item)
            let captionWidth = caption.reduce(0) { $0 + TerminalText.width($1) }
            let indentationLimit = max(0, leftWidth - 5 - min(24, max(12, captionWidth)))
            if connector.count > indentationLimit {
                // Indentation may be arbitrarily deep; keep the actual category name reachable.
                connector =
                    indentationLimit >= 2
                    ? "… " + String(connector.suffix(indentationLimit - 2))
                    : String(repeating: " ", count: indentationLimit)
            }
            let prefix = " " + (index == selectedIndex && !manager.selectedAllItems ? ">" : " ") + " "
            let disclosure = row.hasChildren ? (row.isExpanded ? "▾ " : "▸ ") : "  "
            var hits: [MouseHit] = []
            if let key = rowKey(index) {
                hits.append(MouseHit(columns: 0..<leftWidth, target: .pickerRow(index, key)))
                let origin = (prefix + connector).reduce(0) { $0 + TerminalText.width($1) }
                if row.hasChildren, origin < leftWidth {
                    hits.append(
                        MouseHit(
                            columns: origin..<min(origin + 2, leftWidth),
                            target: .pickerDisclosure(index, key)))
                }
            }
            leftRows.append(
                line(
                    prefix + connector + disclosure + caption,
                    style: index == selectedIndex && !manager.selectedAllItems ? leftSelection : leftStyle,
                    hits: hits))
        }

        var rightRows: [ScreenLine] = []
        var inspectorViewport: (field: Int, start: Int, maximum: Int)?
        let textWidth = inspectorTextWidth(paneWidth: rightWidth)
        if manager.rightMode == .items {
            switch manager.preview.status {
            case .idle, .loading: rightRows.append(line(" Loading category items…", style: rightStyle))
            case .failed(let message):
                rightRows.append(line(" Preview failed: " + message, style: rightStyle))
            case .loaded where manager.preview.rows.isEmpty:
                rightRows.append(line(" No matching items.", style: rightStyle))
            case .loaded:
                rightRows.append(
                    line(
                        TableLayout.line(
                            item: nil, columns: columns, offset: columnOffset, width: rightWidth),
                        style: .header))
                for index in previewStart..<min(manager.preview.rows.count, previewStart + rowCapacity) {
                    let item = manager.preview.rows[index]
                    rightRows.append(
                        line(
                            TableLayout.line(
                                item: item, columns: columns, offset: columnOffset, width: rightWidth,
                                preferredScopes: manager.selectedPath.map(\.itemID)),
                            style: index == manager.previewIndex ? rightSelection : rightStyle,
                            hits: [
                                MouseHit(
                                    columns: 0..<rightWidth, target: .categoryPreviewRow(index, item.itemID))
                            ]))
                }
            }
        } else if manager.selectedAllItems {
            rightRows = [
                line(" All items is the implicit root.", style: rightStyle),
                line(" It has no editable category record.", style: rightStyle),
            ]
        } else if let inspector = manager.inspector {
            let labels = ["Subject", "Body / note", "Class ↔", "Category rule"]
            let labelWidth = rightWidth - textWidth
            let focus = min(3, max(0, inspector.focus))
            func display(_ field: Int, multiline: Bool = false) -> [TextBuffer.DisplayLine] {
                inspector.fields[field].displayLines(
                    columns: textWidth, marked: field == focus, flatten: !multiline,
                    cursorLayout: cursorLayout)
            }
            func fieldRow(_ field: Int, value: TextBuffer.DisplayLine, label: String?) -> ScreenLine {
                let prefix = TerminalText.fit((label.map { " \($0):" } ?? ""), columns: labelWidth)
                var row = line(
                    prefix + value.text, style: field == focus ? rightSelection : rightStyle,
                    hits: [
                        MouseHit(
                            columns: 0..<labelWidth,
                            target: .categoryInspectorText(field, [inspector.fields[field].cursor])),
                        MouseHit(
                            columns: labelWidth..<rightWidth,
                            target: .categoryInspectorText(field, value.offsets)),
                    ])
                if !navigatorActive && !previewFocused, field == focus {
                    row.cursorColumn = value.cursorColumn.map { labelWidth + $0 }
                    row.selectionColumns = value.selectionColumns.map {
                        (labelWidth + $0.lowerBound)..<(labelWidth + $0.upperBound)
                    }
                }
                return row
            }
            func single(_ field: Int) -> ScreenLine {
                let values = display(field)
                return fieldRow(
                    field, value: values.first(where: \.containsCursor) ?? values[0], label: labels[field])
            }
            if bodyHeight < 9 {
                let values = display(focus, multiline: focus == 1 || focus == 3)
                let caret = values.firstIndex(where: \.containsCursor) ?? 0
                let maximum = max(0, values.count - bodyHeight)
                let start = min(maximum, max(0, manager.inspectorScroll ?? (caret - bodyHeight + 1)))
                inspectorViewport = (focus, start, maximum)
                for (offset, value) in values.dropFirst(start).prefix(bodyHeight).enumerated() {
                    rightRows.append(fieldRow(focus, value: value, label: offset == 0 ? labels[focus] : nil))
                }
            } else {
                rightRows.append(single(0))
                let expandedField = focus == 3 ? 3 : 1
                let count = bodyHeight - 4
                let values = display(expandedField, multiline: true)
                let caret = values.firstIndex(where: \.containsCursor) ?? 0
                let maximum = max(0, values.count - count)
                let start = min(maximum, max(0, manager.inspectorScroll ?? (caret - count + 1)))
                if focus == expandedField { inspectorViewport = (focus, start, maximum) }
                if expandedField == 3 { rightRows.append(single(1)) }
                for offset in 0..<count {
                    let index = start + offset
                    let value =
                        index < values.count
                        ? values[index]
                        : TextBuffer.DisplayLine(
                            text: "", offsets: [inspector.fields[expandedField].text.count],
                            containsCursor: false,
                            containsSelection: false, selectionColumns: [], cursorColumn: nil)
                    rightRows.append(
                        fieldRow(
                            expandedField, value: value, label: offset == 0 ? labels[expandedField] : nil))
                }
                rightRows.append(single(2))
                if expandedField != 3 { rightRows.append(single(3)) }
                let parent = manager.selectedPath.dropLast().last.map(title) ?? "All items"
                let parentCount = inspector.base.fields["categoryParents"]?.array?.count ?? 0
                rightRows.append(
                    line(
                        " Parent: \(parent)" + (parentCount > 1 ? " (+\(parentCount - 1))" : ""),
                        style: rightStyle))
            }
        } else {
            rightRows.append(line(" F2/Ctrl-E edits this category.", style: rightStyle))
        }
        for index in 0..<bodyHeight {
            output.append(
                combine(
                    index < leftRows.count ? leftRows[index] : line(style: leftStyle),
                    index < rightRows.count ? rightRows[index] : line(style: rightStyle)))
        }
        let leftFooter = line(" Enter open · Tab pane · Ctrl-T tree", style: leftStyle)
        var rightFooter: ScreenLine
        if manager.rightMode == .category {
            rightFooter = ScreenLine.controls(
                [("F8 Save", .save), ("Esc Cancel", .cancel)], style: rightStyle)
            if manager.selectedAllItems {
                rightFooter = line(" Tab navigator · F11 Preview", style: rightStyle)
            }
        } else {
            var text = " "
            var hits: [MouseHit] = []
            if manager.preview.position > 0 {
                text += "PgUp Previous"
                hits.append(MouseHit(columns: 1..<text.count, target: .categoryPreviewPrevious))
            }
            if manager.preview.position + manager.preview.rows.count < manager.preview.total {
                if text.count > 1 { text += " · " }
                let start = text.count
                text += "PgDn Next"
                hits.append(MouseHit(columns: start..<text.count, target: .categoryPreviewNext))
            }
            if text.count > 1 { text += " · " }
            text += "Tab pane"
            rightFooter = line(text, style: rightStyle, hits: hits)
        }
        output.append(combine(leftFooter, rightFooter))
        if previewVisible {
            let item =
                manager.preview.rows.indices.contains(manager.previewIndex)
                ? manager.preview.rows[manager.previewIndex] : nil
            output += ItemPreviewPresentation.lines(
                item: item, width: width, offset: previewOffset, focused: previewFocused,
                contentRows: effectivePreviewRows)
        }
        return Result(
            lines: output, navigatorStart: navigatorStart, previewStart: previewStart,
            inspectorViewport: inspectorViewport, inspectorTextWidth: textWidth)
    }
}
