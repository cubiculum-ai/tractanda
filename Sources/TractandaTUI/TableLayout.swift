import Foundation
import TractandaCore

struct ColumnEditor {
    var columns: [ViewColumn]
    var index = 0
}

/// Terminal width allocation never changes the saved preferred widths.
enum TableLayout {
    static func line(
        item: Revision?, columns: [ViewColumn], offset: Int, width: Int, preferredScopes: [String] = []
    ) -> String {
        let visible = Array(columns.dropFirst(offset))
        var remaining = width
        var cells: [String] = []
        for (index, column) in visible.enumerated() {
            guard remaining > 0 else { break }
            let cellWidth = index == visible.count - 1 ? remaining : min(column.width, remaining)
            let text =
                item.map {
                    column.property == "referenceLabels"
                        ? ItemReferenceLabel.display(in: $0, preferredScopes: preferredScopes)
                        : display($0.fields[column.property])
                } ?? column.title
            cells.append(TerminalText.fit(text, columns: cellWidth))
            remaining -= cellWidth + 1
        }
        return cells.joined(separator: " ")
    }

    static func display(_ value: ItemValue?) -> String {
        switch value {
        case .text(let text), .date(let text): return String(text.prefix(1024))
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .boolean(let flag): return flag ? "Yes" : "No"
        case .reference(let reference): return reference.itemID
        case .list(let values): return "[\(values.count) values]"
        case .object(let values): return "[\(values.count) fields]"
        case .bytes(let data): return "[\(data.count) bytes]"
        case nil: return "—"
        }
    }
}
