import Foundation

/// The local editing clipboard is shared by fields, never exported to a remote clipboard.
final class TextClipboard {
    var text = ""
}

struct TextBuffer {
    var text: String
    private(set) var cursor: Int
    private var anchor: Int?
    private var isMarkActive = false
    private var localClipboard = ""
    private struct Snapshot {
        let text: String
        let cursor: Int
        let anchor: Int?
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(_ text: String = "") {
        self.text = text
        cursor = text.count
    }
    var selection: Range<Int>? {
        guard let anchor, anchor != cursor else { return nil }
        return min(anchor, cursor)..<max(anchor, cursor)
    }
    var markedText: String {
        let characters = Array(text)
        var display = ""
        for index in 0...characters.count {
            if selection?.lowerBound == index { display += "⟦" }
            if selection?.upperBound == index { display += "⟧" }
            if cursor == index { display += "│" }
            if index < characters.count { display.append(characters[index]) }
        }
        return display
    }

    struct DisplayLine {
        let text: String
        /// One insertion offset per display cell, plus the offset just after the line.
        let offsets: [Int]
        let containsCursor: Bool
        let containsSelection: Bool
        let selectionColumns: [Range<Int>]
        /// The physical cursor cell in this line.  This is independent of any visible glyph.
        let cursorColumn: Int?
    }

    /// Keep hit testing in grapheme coordinates.  A gap cursor reserves one blank cell; the native
    /// cursor merely records its terminal coordinate and never changes the rendered text.
    func displayLines(
        columns: Int, marked: Bool = true, flatten: Bool = false, cursorLayout: CursorLayout = .gap
    ) -> [DisplayLine] {
        let width = max(1, columns)
        var lines: [DisplayLine] = []
        var text = ""
        var offsets: [Int] = []
        var end = 0
        var containsCursor = false
        var cursorColumn: Int?
        func finish() {
            let selected =
                selection.map { range in
                    offsets.enumerated().compactMap { index, offset in range.contains(offset) ? index : nil }
                } ?? []
            var spans: [Range<Int>] = []
            for cell in selected {
                if let last = spans.indices.last, spans[last].upperBound == cell {
                    spans[last] = spans[last].lowerBound..<(cell + 1)
                } else {
                    spans.append(cell..<(cell + 1))
                }
            }
            lines.append(
                DisplayLine(
                    text: text, offsets: offsets + [end], containsCursor: containsCursor,
                    containsSelection: selection.map { range in offsets.contains { range.contains($0) } }
                        ?? false,
                    selectionColumns: spans,
                    cursorColumn: cursorColumn))
            text = ""
            offsets = []
            containsCursor = false
            cursorColumn = nil
        }
        func append(_ character: Character, offset: Int, after: Int, isCursor: Bool = false) {
            if character == "\n" && !flatten {
                end = offset
                finish()
                end = after
                return
            }
            let safe = character == "\n" ? "↵" : TerminalText.safe(String(character))
            for glyph in safe {
                let size = TerminalText.width(glyph)
                if offsets.count + size > width { finish() }
                if isCursor { cursorColumn = offsets.count }
                text.append(glyph)
                offsets += Array(repeating: offset, count: size)
                end = after
                containsCursor = containsCursor || isCursor
            }
        }
        let characters = Array(self.text)
        for index in 0...characters.count {
            if marked, cursor == index {
                if cursorLayout == .gap {
                    append(" ", offset: index, after: index, isCursor: true)
                } else {
                    // A caret before a glyph that wraps belongs to that glyph's next row. At a
                    // full EOF it belongs to a stable virtual final row, never over a glyph.
                    if index == characters.count, offsets.count >= width {
                        finish()
                    } else if index < characters.count, characters[index] != "\n",
                        offsets.count > 0, offsets.count + TerminalText.width(characters[index]) > width
                    {
                        finish()
                    }
                    containsCursor = true
                    cursorColumn = offsets.count
                }
            }
            if index < characters.count { append(characters[index], offset: index, after: index + 1) }
        }
        if !text.isEmpty, offsets.count >= width, characters.last != "\n" { finish() }
        finish()
        return lines
    }

    mutating func placeCursor(at offset: Int, extendingSelection: Bool = false) {
        if extendingSelection { if anchor == nil { anchor = cursor } } else { anchor = nil }
        cursor = max(0, min(text.count, offset))
        isMarkActive = false
    }

    mutating func handle(
        _ key: TerminalKey, multiline: Bool = false, columns: Int = 80,
        clipboard: TextClipboard? = nil, keymap: Keymap = .standard
    ) {
        let before = Snapshot(text: text, cursor: cursor, anchor: anchor)
        var chord = KeyChord(event: key)
        var command = keymap.command(for: key, in: .text)
        var extending = false
        if command == nil, chord?.modifiers.contains(.shift) == true {
            chord!.modifiers.remove(.shift)
            if let shifted = keymap.command(for: chord!, in: .text), Self.movements.contains(shifted) {
                command = shifted
                extending = true
            }
        }
        if let command {
            perform(
                command, multiline: multiline, columns: columns, clipboard: clipboard, extending: extending)
        } else {
            switch key {
            case .text(let value), .paste(let value):
                replaceSelection(
                    with: TerminalText.safe(
                        value.replacingOccurrences(of: "\r\n", with: "\n"), multiline: multiline))
            case .enter where multiline: replaceSelection(with: "\n")
            default: break
            }
        }
        record(before, for: command)
    }

    mutating func handle(
        command: TUICommand, multiline: Bool = false, columns: Int = 80, clipboard: TextClipboard? = nil
    ) {
        let before = Snapshot(text: text, cursor: cursor, anchor: anchor)
        perform(command, multiline: multiline, columns: columns, clipboard: clipboard)
        record(before, for: command)
    }

    private mutating func record(_ before: Snapshot, for command: TUICommand?) {
        if before.text != text && command != .undo && command != .redo {
            undoStack.append(before)
            redoStack = []
            while undoStack.count > 64 || undoStack.reduce(0, { $0 + $1.text.utf8.count }) > 1_048_576 {
                undoStack.removeFirst()
            }
        }
    }

    private static let movements: Set<TUICommand> = [
        .moveLeft, .moveRight, .moveUp, .moveDown, .lineStart, .lineEnd,
        .wordLeft, .wordRight, .documentStart, .documentEnd,
    ]

    private mutating func perform(
        _ command: TUICommand, multiline: Bool, columns: Int, clipboard: TextClipboard?,
        extending: Bool = false
    ) {
        var characters = Array(text)
        cursor = min(cursor, characters.count)
        let start = cursor
        if Self.movements.contains(command) {
            if extending || isMarkActive { if anchor == nil { anchor = start } } else { anchor = nil }
        }
        func isWord(_ character: Character) -> Bool {
            character == "_"
                || character.unicodeScalars.contains {
                    $0.properties.isAlphabetic || $0.properties.numericType != nil
                }
        }
        func wordBoundary(forward: Bool) -> Int {
            var index = cursor
            if forward {
                while index < characters.count && !isWord(characters[index]) { index += 1 }
                while index < characters.count && isWord(characters[index]) { index += 1 }
            } else {
                while index > 0 && !isWord(characters[index - 1]) { index -= 1 }
                while index > 0 && isWord(characters[index - 1]) { index -= 1 }
            }
            return index
        }
        func lineStart() -> Int { characters[..<cursor].lastIndex(of: "\n").map { $0 + 1 } ?? 0 }
        func lineEnd() -> Int { characters[cursor...].firstIndex(of: "\n") ?? characters.count }
        switch command {
        case .moveLeft: cursor = max(0, cursor - 1)
        case .moveRight: cursor = min(characters.count, cursor + 1)
        case .lineStart: cursor = lineStart()
        case .lineEnd: cursor = lineEnd()
        case .documentStart: cursor = 0
        case .documentEnd: cursor = characters.count
        case .wordLeft: cursor = wordBoundary(forward: false)
        case .wordRight: cursor = wordBoundary(forward: true)
        case .moveUp, .moveDown:
            guard multiline else { return }
            var positions: [(row: Int, column: Int)] = [(0, 0)]
            var row = 0
            var column = 0
            for character in characters {
                if character == "\n" {
                    row += 1
                    column = 0
                } else {
                    let size = TerminalText.width(character)
                    if column + size > max(1, columns) {
                        row += 1
                        column = 0
                    }
                    column += size
                }
                positions.append((row, column))
            }
            let origin = positions[cursor]
            let targetRow = origin.row + (command == .moveUp ? -1 : 1)
            if let target = positions.indices.last(where: {
                positions[$0].row == targetRow && positions[$0].column <= origin.column
            }) {
                cursor = target
            }
        case .deleteBackward, .deleteForward:
            if selection != nil {
                replaceSelection(with: "")
            } else if command == .deleteBackward && cursor > 0 {
                anchor = cursor - 1
                replaceSelection(with: "")
            } else if command == .deleteForward && cursor < characters.count {
                anchor = cursor + 1
                replaceSelection(with: "")
            }
        case .deleteWordBackward, .deleteWordForward, .killLine:
            if selection == nil {
                if command == .killLine {
                    let end = lineEnd()
                    anchor = end == cursor ? min(characters.count, cursor + 1) : end
                } else {
                    anchor = wordBoundary(forward: command == .deleteWordForward)
                }
            }
            if let selection {
                localClipboard = String(characters[selection])
                clipboard?.text = localClipboard
                replaceSelection(with: "")
            }
        case .clearField:
            anchor = 0
            cursor = characters.count
            localClipboard = text
            clipboard?.text = text
            replaceSelection(with: "")
        case .openLine where multiline:
            replaceSelection(with: "\n")
            cursor = max(0, cursor - 1)
        case .transpose:
            guard characters.count >= 2, cursor > 0 else { return }
            let right = min(cursor, characters.count - 1)
            characters.swapAt(right - 1, right)
            text = String(characters)
            cursor = right + 1
            anchor = nil
            isMarkActive = false
        case .setMark:
            isMarkActive.toggle()
            anchor = isMarkActive ? cursor : nil
        case .selectText:
            anchor = 0
            cursor = characters.count
            isMarkActive = false
        case .copy, .cut:
            guard let selection else { return }
            localClipboard = String(characters[selection])
            clipboard?.text = localClipboard
            if command == .cut { replaceSelection(with: "") } else { isMarkActive = false }
        case .paste, .yank:
            let contents = clipboard?.text ?? localClipboard
            guard !contents.isEmpty else { return }
            replaceSelection(with: TerminalText.safe(contents, multiline: multiline))
        case .undo:
            guard let previous = undoStack.popLast() else { return }
            redoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor))
            restore(previous)
        case .redo:
            guard let next = redoStack.popLast() else { return }
            undoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor))
            restore(next)
        default: break
        }
    }

    private mutating func restore(_ snapshot: Snapshot) {
        text = snapshot.text
        cursor = snapshot.cursor
        anchor = snapshot.anchor
        isMarkActive = false
    }

    private mutating func replaceSelection(with value: String) {
        var characters = Array(text)
        let range = selection ?? cursor..<cursor
        let removed = String(characters[range]).utf8.count
        guard text.utf8.count - removed + value.utf8.count <= TerminalInput.maximumPaste else { return }
        let prefix = String(characters.prefix(range.lowerBound)) + value
        characters.replaceSubrange(range, with: Array(value))
        text = String(characters)
        cursor = prefix.count
        anchor = nil
        isMarkActive = false
    }
}
