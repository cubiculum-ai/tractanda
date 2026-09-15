import TractandaCore

/// Shared read-only preview for both primary workspaces. Blank rows remain hit-testable so focus
/// and scrolling do not depend on how much text the selected item happens to contain.
enum ItemPreviewPresentation {
    static let defaultContentRows = 3

    /// Keep a usable upper workspace while retaining the user's requested size for later resize.
    static func effectiveContentRows(preferred: Int, terminalRows: Int) -> Int {
        min(max(1, preferred), max(1, terminalRows - 16))
    }

    /// A terminal mouse row includes the status and function-key rows below the workspace.
    static func requestedContentRows(terminalRows: Int, dividerRow: Int) -> Int {
        max(1, terminalRows - dividerRow - 3)
    }

    static func textLines(item: Revision?, width: Int) -> [String] {
        TerminalText.lines(
            String((item?.fields["body"]?.string ?? "").prefix(65_536)), columns: max(1, width - 2))
    }

    static func maximumOffset(item: Revision?, width: Int, contentRows: Int = defaultContentRows) -> Int {
        max(0, textLines(item: item, width: width).count - max(1, contentRows))
    }

    static func lines(
        item: Revision?, width: Int, offset: Int, focused: Bool, contentRows: Int = defaultContentRows
    ) -> [ScreenLine] {
        let contentRows = max(1, contentRows)
        let text = textLines(item: item, width: width)
        let start = min(max(0, offset), max(0, text.count - contentRows))
        let hit = MouseHit(columns: 0..<width, target: .itemPreview)
        var result = [
            ScreenLine(
                text: " Preview" + (focused ? " · focused" : ""),
                style: focused ? .header : .dimmed,
                hits: [MouseHit(columns: 0..<width, target: .previewDivider)])
        ]
        result += (0..<contentRows).map { row in
            ScreenLine(
                text: " " + (text.indices.contains(start + row) ? text[start + row] : ""),
                style: focused ? .activePane : .dimmed, hits: [hit])
        }
        return result
    }
}
