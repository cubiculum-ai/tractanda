import TractandaCore

/// The editable, local-only state for a saved view.  Keeping this separate from `Workspace`
/// means an incomplete expression, width, or sort never changes the visible report or sends a
/// request.  `commitDefinition()` performs the complete validation at Save time.
struct ViewDefinitionForm {
    enum Control {
        case name, description, expression, text
        case includedCategories, excludedCategories, sections
        case primaryProperty, primaryDirection, secondaryProperty, secondaryDirection
        case column(Int, ColumnPart)

        enum ColumnPart { case property, title, width }

        var label: String {
            switch self {
            case .name: "Name"
            case .description: "Description"
            case .expression: "Expression"
            case .text: "Text search"
            case .includedCategories: "Included categories"
            case .excludedCategories: "Excluded categories"
            case .sections: "Section categories"
            case .primaryProperty: "Primary sort target"
            case .primaryDirection: "Primary direction"
            case .secondaryProperty: "Secondary sort target"
            case .secondaryDirection: "Secondary direction"
            case .column(_, .property): "Column key or category:<UUID>"
            case .column(_, .title): "Column title"
            case .column(_, .width): "Column width"
            }
        }
    }

    struct Column {
        var property: TextBuffer
        var title: TextBuffer
        var width: TextBuffer
        /// The original object carries extensions which `ViewColumn` preserves on commit.
        let original: ItemValue?

        init(_ value: ViewColumn) {
            property = TextBuffer(Self.target(value))
            title = TextBuffer(value.title)
            width = TextBuffer(String(value.width))
            original = value.value
        }

        init() {
            property = TextBuffer()
            title = TextBuffer()
            width = TextBuffer("20")
            original = nil
        }

        func value() throws -> ViewColumn {
            guard let parsedWidth = Int(width.text) else {
                throw TractandaError("invalidView", "Enter a column width from 6 to 120.")
            }
            if let rootID = Self.categoryRootID(property.text) {
                return try ViewColumn(
                    categoryRootID: rootID, title: title.text, width: parsedWidth, preserving: original)
            }
            return try ViewColumn(
                property: property.text, title: title.text, width: parsedWidth, preserving: original)
        }

        private static func target(_ value: ViewColumn) -> String {
            value.categoryRootID.map { "category:\($0)" } ?? value.property ?? ""
        }
        private static func categoryRootID(_ target: String) -> String? {
            guard target.hasPrefix("category:") else { return nil }
            return String(target.dropFirst("category:".count))
        }
    }

    var name: TextBuffer
    var description: TextBuffer
    var expression: TextBuffer
    var text: TextBuffer
    var includedCategories: [Revision]
    var excludedCategories: [Revision]
    var sections: [Revision]
    var primaryProperty: TextBuffer
    var primaryDirection: TextBuffer
    var secondaryProperty: TextBuffer
    var secondaryDirection: TextBuffer
    var columns: [Column]
    /// Sort comparators beyond the two exposed rows remain lossless.
    let retainedSort: [ItemSort]
    let originalSort: [ItemValue]

    init(
        name: String, description: String, expression: String, text: String,
        includedCategories: [Revision], excludedCategories: [Revision], sections: [Revision],
        columns: [ViewColumn], sort: [ItemSort], originalSort: [ItemValue] = []
    ) {
        self.name = TextBuffer(name)
        self.description = TextBuffer(description)
        self.expression = TextBuffer(expression)
        self.text = TextBuffer(text)
        self.includedCategories = includedCategories
        self.excludedCategories = excludedCategories
        self.sections = sections
        primaryProperty = TextBuffer(sort.indices.contains(0) ? Self.sortTarget(sort[0]) : "")
        primaryDirection = TextBuffer(
            sort.indices.contains(0) && !sort[0].isAscending ? "descending" : "ascending")
        secondaryProperty = TextBuffer(sort.indices.contains(1) ? Self.sortTarget(sort[1]) : "")
        secondaryDirection = TextBuffer(
            sort.indices.contains(1) && !sort[1].isAscending ? "descending" : "ascending")
        self.columns = columns.map(Column.init)
        retainedSort = Array(sort.dropFirst(2))
        self.originalSort = originalSort
    }

    var controls: [Control] {
        [
            .name, .description, .expression, .text, .includedCategories, .excludedCategories, .sections,
            .primaryProperty, .primaryDirection, .secondaryProperty, .secondaryDirection,
        ]
            + columns.indices.flatMap { [.column($0, .property), .column($0, .title), .column($0, .width)] }
    }

    func isText(_ control: Control) -> Bool {
        switch control {
        case .includedCategories, .excludedCategories, .sections, .primaryDirection, .secondaryDirection:
            false
        default: true
        }
    }

    func isMultiline(_ control: Control) -> Bool { if case .description = control { true } else { false } }

    func display(_ control: Control) -> String {
        switch control {
        case .name: name.text
        case .description: description.text
        case .expression: expression.text
        case .text: text.text
        case .includedCategories: names(includedCategories)
        case .excludedCategories: names(excludedCategories)
        case .sections: names(sections)
        case .primaryProperty: primaryProperty.text
        case .primaryDirection: primaryDirection.text
        case .secondaryProperty: secondaryProperty.text
        case .secondaryDirection: secondaryDirection.text
        case .column(let index, .property): columns[index].property.text
        case .column(let index, .title): columns[index].title.text
        case .column(let index, .width): columns[index].width.text
        }
    }

    /// The renderer uses this same cell-aware representation for text, cursor and mouse placement.
    /// Non-text controls have a synthetic buffer because their values are selected rather than typed.
    func displayLines(
        _ control: Control, columns displayColumns: Int, marked: Bool = true, flatten: Bool = true,
        cursorLayout: CursorLayout = .gap
    ) -> [TextBuffer
        .DisplayLine]
    {
        switch control {
        case .name:
            name.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .description:
            description.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .expression:
            expression.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .text:
            text.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .primaryProperty:
            primaryProperty.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .secondaryProperty:
            secondaryProperty.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .column(let index, .property):
            columns[index].property.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .column(let index, .title):
            columns[index].title.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        case .column(let index, .width):
            columns[index].width.displayLines(
                columns: displayColumns, marked: marked, flatten: flatten, cursorLayout: cursorLayout)
        default:
            TextBuffer(display(control)).displayLines(
                columns: displayColumns, marked: false, flatten: flatten)
        }
    }

    mutating func edit(
        _ control: Control, key: TerminalKey, command: TUICommand?, columns availableColumns: Int,
        clipboard: TextClipboard?, keymap: Keymap
    ) {
        func apply(_ buffer: inout TextBuffer, multiline: Bool = false) {
            if let command, [.copy, .cut, .paste, .undo, .redo, .selectText, .setMark].contains(command) {
                buffer.handle(
                    command: command, multiline: multiline, columns: availableColumns, clipboard: clipboard)
            } else {
                buffer.handle(
                    key, multiline: multiline, columns: availableColumns, clipboard: clipboard, keymap: keymap
                )
            }
        }
        switch control {
        case .name: apply(&name)
        case .description: apply(&description, multiline: true)
        case .expression: apply(&expression)
        case .text: apply(&text)
        case .primaryProperty: apply(&primaryProperty)
        case .secondaryProperty: apply(&secondaryProperty)
        case .column(let index, .property): apply(&columns[index].property)
        case .column(let index, .title): apply(&columns[index].title)
        case .column(let index, .width): apply(&columns[index].width)
        case .includedCategories, .excludedCategories, .sections, .primaryDirection, .secondaryDirection:
            break
        }
    }

    mutating func cycleDirection(_ control: Control, forward: Bool) {
        let replacement = forward ? "descending" : "ascending"
        switch control {
        case .primaryDirection: primaryDirection = TextBuffer(replacement)
        case .secondaryDirection: secondaryDirection = TextBuffer(replacement)
        default: break
        }
    }

    mutating func placeCursor(_ control: Control, at offset: Int, extending: Bool) {
        switch control {
        case .name: name.placeCursor(at: offset, extendingSelection: extending)
        case .description: description.placeCursor(at: offset, extendingSelection: extending)
        case .expression: expression.placeCursor(at: offset, extendingSelection: extending)
        case .text: text.placeCursor(at: offset, extendingSelection: extending)
        case .primaryProperty: primaryProperty.placeCursor(at: offset, extendingSelection: extending)
        case .secondaryProperty: secondaryProperty.placeCursor(at: offset, extendingSelection: extending)
        case .column(let index, .property):
            columns[index].property.placeCursor(at: offset, extendingSelection: extending)
        case .column(let index, .title):
            columns[index].title.placeCursor(at: offset, extendingSelection: extending)
        case .column(let index, .width):
            columns[index].width.placeCursor(at: offset, extendingSelection: extending)
        default: break
        }
    }

    mutating func addColumn() throws {
        guard columns.count < 8 else {
            throw TractandaError("invalidView", "A view can display at most eight columns.")
        }
        columns.append(Column())
    }

    mutating func removeColumn(at index: Int) throws {
        guard columns.count > 1 else {
            throw TractandaError("invalidView", "A view needs at least one column.")
        }
        columns.remove(at: index)
    }

    mutating func moveColumn(at index: Int, forward: Bool) -> Int {
        let destination = index + (forward ? 1 : -1)
        guard columns.indices.contains(index), columns.indices.contains(destination) else { return index }
        columns.swapAt(index, destination)
        return destination
    }

    func committedColumns() throws -> [ViewColumn] { try columns.map { try $0.value() } }

    func committedSort() throws -> [ItemSort] {
        var value: [ItemSort] = []
        for (property, direction) in [
            (primaryProperty.text, primaryDirection.text), (secondaryProperty.text, secondaryDirection.text),
        ]
        where !property.isEmpty {
            let normalized = direction.lowercased()
            guard ["ascending", "descending", "asc", "desc"].contains(normalized) else {
                throw TractandaError("invalidArguments", "Order must be ascending or descending.")
            }
            if property.hasPrefix("category:") {
                value.append(
                    try ItemSort(
                        categoryRootID: String(property.dropFirst("category:".count)),
                        isAscending: normalized.hasPrefix("asc")))
            } else {
                value.append(try ItemSort(property: property, isAscending: normalized.hasPrefix("asc")))
            }
        }
        value.append(contentsOf: retainedSort)
        try ItemSort.validate(value)
        return value
    }

    /// Extensions belong to the comparator being edited, even when its property changes.
    func committedSortValues() throws -> [ItemValue] {
        let comparators = try committedSort()
        let indices =
            [primaryProperty.text, secondaryProperty.text].enumerated()
            .filter { !$0.element.isEmpty }.map(\.offset)
            + Array(2..<(2 + retainedSort.count))
        return zip(indices, comparators).map { index, comparator in
            var fields = originalSort.indices.contains(index) ? originalSort[index].map ?? [:] : [:]
            fields["property"] = nil
            fields["categoryRootID"] = nil
            fields.merge(comparator.value.map!) { _, new in new }
            return .object(fields)
        }
    }

    private func names(_ values: [Revision]) -> String {
        let value = values.map { $0.fields["subject"]?.string ?? $0.itemID }.joined(separator: ", ")
        return value.isEmpty ? "(none)" : value
    }

    private static func sortTarget(_ sort: ItemSort) -> String {
        sort.categoryRootID.map { "category:\($0)" } ?? sort.property ?? ""
    }
}
