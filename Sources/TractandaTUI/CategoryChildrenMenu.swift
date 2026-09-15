import Foundation
import TractandaCore

/// A snapshot of readable roots, or one readable parent's immediate category children.
struct CategoryChildrenMenu: Sendable {
    let id = Identifier.make()
    let parentIndex: Int?
    let path: [String]
    let parent: Revision?
    let children: [Revision]
    let anchorColumn: Int
    var index = 0
    var firstVisibleRow = 0
    var selected: Revision? { children.indices.contains(index) ? children[index] : nil }
    var activeChildID: String? {
        let childIndex = parentIndex.map { $0 + 1 } ?? 0
        return path.indices.contains(childIndex) ? path[childIndex] : nil
    }
    var title: String {
        parent.map { "Children of " + ($0.fields["subject"]?.string ?? "Category") }
            ?? "Top-level categories"
    }

    mutating func move(_ delta: Int) { index = max(0, min(children.count - 1, index + delta)) }

    mutating func overlay(on lines: inout [ScreenLine], width: Int, height: Int) -> OverlayRect? {
        guard height >= 3, lines.count >= height - 1 else { return nil }
        let breadcrumbButtons = lines[1].hits.filter {
            if case .breadcrumbChildren = $0.target { true } else { false }
        }
        for row in 0..<(height - 1) { lines[row].hits = [] }
        lines[1].hits = breadcrumbButtons
        let names = children.map { TerminalText.safe($0.fields["subject"]?.string ?? "Category") }
        let largest = ([title] + names).map { $0.reduce(0) { $0 + TerminalText.width($1) } }.max() ?? 24
        let boxWidth = min(width, max(28, min(68, largest + 6)))
        let x = min(max(0, anchorColumn), width - boxWidth)
        let capacity = max(1, height - 6)
        firstVisibleRow = TerminalViewport.start(
            selected: index, count: children.count, capacity: capacity, previous: firstVisibleRow)
        let visible = firstVisibleRow..<min(children.count, firstVisibleRow + capacity)
        let heading = " " + title + (firstVisibleRow > 0 ? " ↑" : "")
        lines[2] = .popup(
            "┌" + TerminalText.fit(heading, columns: boxWidth - 2).replacingOccurrences(of: " ", with: "─")
                + "┐",
            over: lines[2].text, column: x, boxWidth: boxWidth, width: width)
        for (offset, childIndex) in visible.enumerated() {
            let child = children[childIndex]
            let mark = child.itemID == activeChildID ? "✓" : " "
            let label =
                "│" + (index == childIndex ? ">" : " ") + mark + " "
                + TerminalText.fit(names[childIndex], columns: boxWidth - 5) + "│"
            let row = offset + 3
            lines[row] = .popup(
                label, over: lines[row].text, column: x, boxWidth: boxWidth, width: width,
                style: index == childIndex ? .menuSelection : .menu)
            lines[row].hits.append(
                MouseHit(
                    columns: (x + 1)..<(x + boxWidth - 1), target: .childCategory(childIndex, child.itemID)))
        }
        let bottom = visible.upperBound < children.count ? " ↓ more " : ""
        let row = 3 + visible.count
        lines[row] = .popup(
            "└" + TerminalText.fit(bottom, columns: boxWidth - 2).replacingOccurrences(of: " ", with: "─")
                + "┘",
            over: lines[row].text, column: x, boxWidth: boxWidth, width: width)
        lines[height - 2] = ScreenLine(text: " Child categories · ↑/↓ choose · Enter open · Esc close")
        return OverlayRect(x: x, y: 2, width: boxWidth, height: visible.count + 2)
    }
}

extension ScreenLine {
    /// Shared menu overlay keeps clipped wide glyphs outside the box aligned to their cells.
    static func popup(
        _ text: String, over background: String, column x: Int, boxWidth: Int, width: Int,
        style: ScreenStyle = .menu
    ) -> ScreenLine {
        let base = TerminalText.fit(background, columns: width)
        var column = 0
        var prefix = ""
        var suffix = ""
        for character in base {
            let size = TerminalText.width(character)
            if column + size <= x { prefix.append(character) }
            if column >= x + boxWidth {
                suffix.append(character)
            } else if column + size > x + boxWidth {
                suffix += String(repeating: " ", count: column + size - x - boxWidth)
            }
            column += size
        }
        let segments = [
            ScreenSegment(text: TerminalText.fit(prefix, columns: x), style: .normal),
            ScreenSegment(text: TerminalText.fit(text, columns: boxWidth), style: style),
            ScreenSegment(text: TerminalText.fit(suffix, columns: width - x - boxWidth), style: .normal),
        ]
        return ScreenLine(
            text: segments.map(\.text).joined(), segments: segments,
            hits: [MouseHit(columns: x..<(x + boxWidth), target: .menuSurface)],
            borderColumns: [x..<(x + 1), (x + boxWidth - 1)..<(x + boxWidth)])
    }
}
