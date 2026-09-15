import Foundation

struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int
    static let shift = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let control = Self(rawValue: 4)
    static let command = Self(rawValue: 8)
}

struct KeyChord: Hashable, Codable, Sendable {
    enum Key: Hashable, Codable, Sendable {
        case character(String)
        case function(Int)
        case up, down, left, right, home, end, pageUp, pageDown, tab
        case enter, backspace, delete, insert, escape
    }
    var key: Key
    var modifiers: KeyModifiers = []

    init(_ key: Key, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(event: TerminalKey) {
        switch event {
        case .modified(let base, let modifiers):
            guard var chord = Self(event: base) else { return nil }
            chord.modifiers.formUnion(modifiers)
            self = chord
        case .text(let text) where text.count == 1:
            let lower = text.lowercased()
            self.init(.character(lower), lower == text ? [] : .shift)
        case .control(let code):
            let character: String
            switch code {
            case 0: character = " "
            case 1...26: character = String(UnicodeScalar(Int(code) + 96)!)
            case 28: character = "\\"
            case 29: character = "]"
            case 30: character = "^"
            case 31: character = "_"
            default: return nil
            }
            self.init(.character(character), .control)
        case .function(let number): self.init(.function(number))
        case .up: self.init(.up)
        case .down: self.init(.down)
        case .left: self.init(.left)
        case .right: self.init(.right)
        case .home: self.init(.home)
        case .end: self.init(.end)
        case .pageUp: self.init(.pageUp)
        case .pageDown: self.init(.pageDown)
        case .tab: self.init(.tab)
        case .backTab: self.init(.tab, .shift)
        case .enter: self.init(.enter)
        case .backspace: self.init(.backspace)
        case .delete: self.init(.delete)
        case .insert: self.init(.insert)
        case .escape: self.init(.escape)
        default: return nil
        }
    }

    var label: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "Ctrl-" }
        if modifiers.contains(.option) { prefix += "Meta-" }
        if modifiers.contains(.shift) { prefix += "Shift-" }
        if modifiers.contains(.command) { prefix += "Cmd-" }
        let name: String
        switch key {
        case .character(let value): name = value == " " ? "Space" : value.uppercased()
        case .function(let number): name = "F\(number)"
        case .up: name = "Up"
        case .down: name = "Down"
        case .left: name = "Left"
        case .right: name = "Right"
        case .home: name = "Home"
        case .end: name = "End"
        case .pageUp: name = "PgUp"
        case .pageDown: name = "PgDn"
        case .tab: name = "Tab"
        case .enter: name = "Return"
        case .backspace: name = "Backspace"
        case .delete: name = "Delete"
        case .insert: name = "Insert"
        case .escape: name = "Esc"
        }
        return prefix + name
    }
}

enum KeyContext: String, CaseIterable, Codable, Sendable {
    case browser, categories, picker, sections, history, editor, form, columns, group, menu, reader, help
    case pending, smallScreen, text
    case learning
    case viewWorkspace
    case viewDefinition
    case categoryEditor
}

/// Stable command identities are independent of the keys chosen to invoke them.
enum TUICommand: String, CaseIterable, Codable, Sendable {
    case help, commands, cancel, quit, retry
    case moveUp, moveDown, moveLeft, moveRight, first, last, pageUp, pageDown, activate, toggle
    case nextField, previousField
    case newItem, editItem, editNote, properties, categories, views, filter, sections, columns, sort
    case include, exclude, reset, explain, history, refresh, allItems, parent
    case mark, unmarkAll, selectAll, group, reviewMarks, done, deleteItems
    case save, saveAs, deleteAppearancePreset, previousColumn, nextColumn
    case newChild, newRoot, moveCategory, detachCategory, deleteCategory, refineCategory
    case addColumn, editColumn, deleteColumn, moveColumnEarlier, moveColumnLater
    case lineStart, lineEnd, wordLeft, wordRight, documentStart, documentEnd
    case deleteBackward, deleteForward, deleteWordBackward, deleteWordForward, killLine, yank, clearField
    case openLine, transpose, setMark, copy, cut, paste, undo, redo, selectText
    case functionKeysAutomatic, functionKeysTen, functionKeysTwelve
    case appearance, categoryPreferences
    case learning, learningExamples, learningSuggestions, trainLearning, resetLearning, learningSettings
    case acceptLearning, rejectLearning, dismissLearning, excludeLearning, clearLearningFeedback
    case previousResults, nextResults
    case mouseOn, mouseOff
    case childCategories
    case goBack, goForward
    case newView, editView, pinView, toggleSelector, focusReport
    case switchWorkspace, workspaceViews, workspaceCategories, togglePreview, growPreview, shrinkPreview,
        resetPreview
    case categoryModeItems, categoryModeInspector, categoryToggleTree, categoryToggleMaximize

    var title: String {
        switch self {
        case .help: "Help"
        case .commands: "Commands"
        case .cancel: "Close / cancel"
        case .quit: "Quit"
        case .retry: "Resume saved operation"
        case .newItem: "New item"
        case .editItem: "Edit item"
        case .editNote: "Edit note"
        case .properties: "Properties"
        case .categories: "Category manager"
        case .views: "Open saved view"
        case .filter: "Find / filter items"
        case .sections: "Configure sections"
        case .columns: "Configure columns"
        case .sort: "Sort items"
        case .include: "Include in category"
        case .exclude: "Exclude from category"
        case .reset: "Reset category decision"
        case .explain: "Explain assignment"
        case .history: "Item history"
        case .refresh: "Refresh"
        case .allItems: "All items"
        case .parent: "Remove last category filter"
        case .mark: "Mark / unmark item or section"
        case .unmarkAll: "Unmark all items"
        case .selectAll: "Mark all items in this view"
        case .group: "Group operations"
        case .reviewMarks: "Review marked items"
        case .done: "Mark done"
        case .deleteItems: "Delete items"
        case .save: "Save / apply"
        case .saveAs: "Save view as"
        case .deleteAppearancePreset: "Delete appearance preset"
        case .newChild: "New child category"
        case .newRoot: "New root category"
        case .moveCategory: "Move category under a parent"
        case .detachCategory: "Detach category to root"
        case .deleteCategory: "Delete category"
        case .refineCategory: "Add category filter"
        case .addColumn: "Add column"
        case .editColumn: "Edit column"
        case .deleteColumn: "Remove column"
        case .moveColumnEarlier: "Move column earlier"
        case .moveColumnLater: "Move column later"
        case .setMark: "Mark text"
        case .copy: "Copy text locally"
        case .cut: "Cut text locally"
        case .paste: "Paste local text"
        case .undo: "Undo text edit"
        case .redo: "Redo text edit"
        case .selectText: "Select all text"
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .moveLeft: "Move left"
        case .moveRight: "Move right"
        case .first: "First entry"
        case .last: "Last entry"
        case .pageUp: "Page up"
        case .pageDown: "Page down"
        case .activate: "Open / confirm selection"
        case .toggle: "Toggle section"
        case .nextField: "Next field"
        case .previousField: "Previous field"
        case .previousColumn: "Previous column"
        case .nextColumn: "Next column"
        case .lineStart: "Beginning of line"
        case .lineEnd: "End of line"
        case .wordLeft: "Previous word"
        case .wordRight: "Next word"
        case .documentStart: "Beginning of field"
        case .documentEnd: "End of field"
        case .deleteBackward: "Delete previous character"
        case .deleteForward: "Delete next character"
        case .deleteWordBackward: "Kill previous word"
        case .deleteWordForward: "Kill next word"
        case .killLine: "Kill to end of line"
        case .yank: "Yank local text"
        case .clearField: "Clear field"
        case .openLine: "Insert line at cursor"
        case .transpose: "Transpose characters"
        case .functionKeysAutomatic: "Function keys: Automatic"
        case .functionKeysTen: "Function keys: 10"
        case .functionKeysTwelve: "Function keys: 12"
        case .appearance: "Settings / Appearance…"
        case .categoryPreferences: "Settings / Categories…"
        case .learning: "Learning…"
        case .learningExamples: "Teach from items"
        case .learningSuggestions: "Review suggestions"
        case .trainLearning: "Train / retrain model"
        case .resetLearning: "Reset model…"
        case .learningSettings: "Learning settings…"
        case .acceptLearning: "Accept / assign to category"
        case .rejectLearning: "Reject (negative example)"
        case .dismissLearning: "Dismiss suggestion"
        case .excludeLearning: "Exclude from category"
        case .clearLearningFeedback: "Clear feedback only"
        case .previousResults: "Previous result page"
        case .nextResults: "Next result page"
        case .mouseOn: "Mouse: On"
        case .mouseOff: "Mouse: Off"
        case .childCategories: "Child categories…"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .newView: "New view"
        case .editView: "Edit view definition"
        case .pinView: "Pin / unpin view"
        case .toggleSelector: "Focus selector / items"
        case .focusReport: "Focus report"
        case .switchWorkspace: "Switch workspace"
        case .workspaceViews: "Views workspace"
        case .workspaceCategories: "Categories workspace"
        case .togglePreview: "Show / hide item preview"
        case .growPreview: "Grow item preview"
        case .shrinkPreview: "Shrink item preview"
        case .resetPreview: "Reset item preview height"
        case .categoryModeItems: "Category workspace: Items"
        case .categoryModeInspector: "Category workspace: Category"
        case .categoryToggleTree: "Category workspace: Outline / connected tree"
        case .categoryToggleMaximize: "Category workspace: Split / maximize"
        }
    }

    var functionLabel: String {
        switch self {
        case .save: "Save"
        case .toggle: "Mode"
        case .toggleSelector: "Focus"
        case .help: "Help"
        case .commands: "Menu"
        case .editItem: "Edit"
        case .include: "Choices"
        case .done: "Done"
        case .editNote: "Note"
        case .properties: "Props"
        case .mark, .setMark: "Mark"
        case .views: "Views"
        case .categories: "Cats"
        case .cancel: "Return"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .allItems: "All"
        case .refresh: "Refresh"
        case .learningSettings: "Settings"
        case .moveColumnEarlier: "Earlier"
        case .moveColumnLater: "Later"
        case .categoryModeItems: "Items"
        case .categoryModeInspector: "Category"
        case .categoryToggleTree: "Tree"
        case .categoryToggleMaximize: "Max"
        case .switchWorkspace: "Switch"
        case .togglePreview: "Preview"
        case .growPreview: "Grow preview"
        case .shrinkPreview: "Shrink preview"
        case .resetPreview: "Reset preview"
        default: title
        }
    }

    var isMenuAction: Bool {
        switch self {
        case .help, .cancel, .quit, .retry, .newItem, .editItem, .editNote, .properties,
            .categories, .views, .filter, .sections, .columns, .sort, .include, .exclude, .reset,
            .explain, .history, .refresh, .allItems, .parent, .mark, .unmarkAll, .selectAll, .group,
            .reviewMarks, .done, .deleteItems, .save, .saveAs, .newChild, .newRoot, .moveCategory,
            .detachCategory, .deleteCategory, .refineCategory, .addColumn, .editColumn, .deleteColumn,
            .moveColumnEarlier, .moveColumnLater,
            .setMark, .copy, .cut, .paste, .undo, .redo, .selectText,
            .functionKeysAutomatic, .functionKeysTen, .functionKeysTwelve,
            .appearance, .categoryPreferences,
            .learning, .learningExamples, .learningSuggestions, .trainLearning, .resetLearning,
            .learningSettings, .acceptLearning, .rejectLearning, .dismissLearning, .excludeLearning,
            .clearLearningFeedback, .previousResults, .nextResults, .mouseOn, .mouseOff, .childCategories,
            .goBack, .goForward:
            true
        case .categoryModeItems, .categoryModeInspector, .categoryToggleTree, .categoryToggleMaximize:
            true
        case .switchWorkspace, .workspaceViews, .workspaceCategories, .togglePreview, .growPreview,
            .shrinkPreview,
            .resetPreview:
            true
        default: false
        }
    }
}

struct KeyBinding: Hashable, Codable, Sendable {
    let context: KeyContext
    let chord: KeyChord?
    let command: TUICommand
}

/// Dispatch, help, command menus and the function bar use this same table.
struct Keymap: Sendable {
    let bindings: [KeyBinding]
    private let lookup: [KeyContext: [KeyChord: TUICommand]]

    init(bindings: [KeyBinding]) throws {
        var lookup: [KeyContext: [KeyChord: TUICommand]] = [:]
        for binding in bindings {
            guard let chord = binding.chord else { continue }
            guard lookup[binding.context]?[chord] == nil else {
                throw KeymapError.duplicate(binding.context, chord)
            }
            lookup[binding.context, default: [:]][chord] = binding.command
        }
        self.bindings = bindings
        self.lookup = lookup
    }
    enum KeymapError: Error { case duplicate(KeyContext, KeyChord) }

    func command(for event: TerminalKey, in context: KeyContext) -> TUICommand? {
        KeyChord(event: event).flatMap { lookup[context]?[$0] }
    }
    func command(for chord: KeyChord, in context: KeyContext) -> TUICommand? {
        lookup[context]?[chord]
    }
    func keys(for command: TUICommand, in context: KeyContext) -> [KeyChord] {
        bindings.filter { $0.context == context && $0.command == command }.compactMap(\.chord)
    }
    /// Terminal Control chords are the portable primary spelling.  Command remains useful when a
    /// terminal forwards it, while shifted-Control sequences are deliberately a last resort.
    func preferredKeys(for command: TUICommand, in context: KeyContext) -> [KeyChord] {
        keys(for: command, in: context).enumerated().sorted { left, right in
            func rank(_ chord: KeyChord) -> Int {
                if chord.modifiers.contains(.control) && !chord.modifiers.contains(.shift) { return 0 }
                if case .function = chord.key { return 1 }
                if chord.modifiers.contains(.option) { return 2 }
                if chord.modifiers.isEmpty { return 3 }
                if chord.modifiers.contains(.command) { return 4 }
                return 5
            }
            let leftRank = rank(left.element)
            let rightRank = rank(right.element)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }
    func commands(in context: KeyContext) -> [TUICommand] {
        var seen: Set<TUICommand> = []
        return bindings.filter { $0.context == context }.map(\.command).filter {
            $0.isMenuAction && seen.insert($0).inserted
        }
    }
    func help(in context: KeyContext) -> String {
        var seen: Set<TUICommand> = []
        return bindings.filter { $0.context == context }.map(\.command).filter { seen.insert($0).inserted }
            .map { command in
                let keys = preferredKeys(for: command, in: context).map(\.label).joined(separator: ", ")
                return (keys.isEmpty ? "Menu" : keys) + "  " + command.title
            }.joined(separator: "\n")
    }

    static let standard: Keymap = {
        var bindings: [KeyBinding] = []
        func bind(_ command: TUICommand, _ contexts: [KeyContext], _ chords: [KeyChord]) {
            for context in contexts {
                for chord in chords {
                    bindings.append(KeyBinding(context: context, chord: chord, command: command))
                }
            }
        }
        func letter(_ value: String, _ modifiers: KeyModifiers = []) -> KeyChord {
            KeyChord(
                .character(value.lowercased()),
                value == value.lowercased() ? modifiers : modifiers.union(.shift))
        }
        func primary(_ value: String) -> [KeyChord] { [letter(value, .control), letter(value, .command)] }
        func fn(_ value: Int, _ modifiers: KeyModifiers = []) -> KeyChord {
            KeyChord(.function(value), modifiers)
        }
        let ordinary = KeyContext.allCases.filter { ![.text, .pending, .smallScreen, .menu].contains($0) }
        bind(.help, ordinary, [fn(1)])
        bind(.commands, KeyContext.allCases.filter { ![.text, .smallScreen, .menu].contains($0) }, [fn(10)])
        for context in ordinary.filter({ ![.reader, .help].contains($0) }) {
            for command in [
                TUICommand.mouseOn, .mouseOff, .functionKeysAutomatic, .functionKeysTen, .functionKeysTwelve,
            ] {
                bindings.append(KeyBinding(context: context, chord: nil, command: command))
            }
        }
        bind(.quit, ordinary, primary("q"))
        bind(
            .cancel, ordinary.filter { ![.browser, .viewWorkspace].contains($0) },
            [KeyChord(.escape), letter("w", .command), letter("g", .control)])
        bind(
            .cancel, ordinary.filter { ![.browser, .editor, .form, .viewDefinition].contains($0) },
            [letter("w", .control)])
        bind(.allItems, [.browser], [letter("a")] + primary("w"))
        // Main workspaces share F9. Editors and transient tools retain their local cancel mapping.
        bind(.switchWorkspace, [.browser, .viewWorkspace, .categories], [fn(9)])
        bind(.cancel, [.picker, .sections, .history, .columns, .reader, .help, .group], [fn(9)])
        bind(.togglePreview, [.browser, .viewWorkspace, .categories], [fn(11)])
        bind(.togglePreview, [.browser, .viewWorkspace, .categories], [letter("P", .control)])
        bind(.growPreview, [.browser, .viewWorkspace, .categories], [letter("=", .option)])
        bind(.shrinkPreview, [.browser, .viewWorkspace, .categories], [letter("-", .option)])
        bind(.resetPreview, [.browser, .viewWorkspace, .categories], [letter("0", .option)])
        bind(.newView, [.viewWorkspace], primary("n") + [letter("n", .option)])
        bind(.editView, [.viewWorkspace], primary("e") + [letter("e", .option), fn(2)])
        bind(.editNote, [.viewWorkspace], [fn(5)])
        bind(.properties, [.viewWorkspace], [fn(6)])
        bind(.refresh, [.viewWorkspace], [fn(12)])
        bind(.pinView, [.viewWorkspace], [letter("m", .command), letter("m", .option)])
        bind(.toggleSelector, [.viewWorkspace, .browser], [fn(8), KeyChord(.escape)])
        bind(.focusReport, [.viewWorkspace], [KeyChord(.tab), KeyChord(.enter)])
        bind(.appearance, [.browser, .viewWorkspace], [letter(",", .command)])

        let lists: [KeyContext] = [
            .browser, .categories, .picker, .sections, .history, .columns, .menu, .reader, .help, .learning,
            .viewWorkspace,
            .viewDefinition,
        ]
        for (command, key) in [
            (TUICommand.moveUp, KeyChord.Key.up), (.moveDown, .down), (.first, .home), (.last, .end),
            (.pageUp, .pageUp), (.pageDown, .pageDown),
        ] {
            bind(command, lists, [KeyChord(key)])
        }
        // In pickers/readers these move the choice or scroll; in editors they move text.
        bind(.moveUp, lists, [letter("p", .control)])
        bind(
            .moveDown,
            lists.filter { ![.browser, .columns, .categories, .viewWorkspace].contains($0) },
            [letter("n", .control)])
        bind(.pageUp, lists, [letter("v", .option)])
        bind(.pageDown, lists, [letter("v", .control)])
        bind(
            .moveLeft, [.browser, .categories, .picker, .sections, .columns, .menu, .viewDefinition],
            [KeyChord(.left)])
        bind(
            .moveRight, [.browser, .categories, .picker, .sections, .columns, .menu, .viewDefinition],
            [KeyChord(.right)])
        bind(.moveRight, [.menu], [KeyChord(.tab)])
        bind(.moveLeft, [.menu], [KeyChord(.tab, .shift)])
        bind(
            .activate,
            [
                .browser, .categories, .picker, .sections, .history, .columns, .menu, .learning,
                .viewDefinition,
            ],
            [KeyChord(.enter)])
        bind(.nextField, [.editor, .form, .viewDefinition], [KeyChord(.tab)])
        bind(.previousField, [.editor, .form, .viewDefinition], [KeyChord(.tab, .shift)])
        bind(.moveDown, [.categories, .picker, .sections, .history], [KeyChord(.tab)])
        bind(.moveUp, [.categories, .picker, .sections, .history], [KeyChord(.tab, .shift)])
        bind(.toggle, [.browser, .sections, .picker], [letter(" ")])
        bind(.activate, [.editor, .form], [KeyChord(.enter)])

        let browser: [(TUICommand, String)] = [
            (.newItem, "n"), (.editItem, "e"), (.categories, "c"), (.views, "v"), (.filter, "f"),
            (.sections, "g"), (.columns, "l"), (.sort, "o"), (.include, "i"), (.exclude, "x"),
            (.reset, "u"), (.explain, "w"), (.history, "h"), (.refresh, "r"), (.mark, "m"),
            (.unmarkAll, "M"), (.group, "b"), (.done, "d"), (.save, "s"), (.saveAs, "S"),
            (.help, "?"), (.quit, "q"), (.commands, "/"), (.commands, ":"),
        ]
        for (command, key) in browser { bind(command, [.browser], [letter(key)]) }
        for (command, key) in [
            (TUICommand.newItem, "n"), (.views, "o"), (.filter, "f"), (.save, "s"), (.saveAs, "S"),
            (.selectAll, "a"), (.unmarkAll, "A"),
        ] {
            bind(command, [.browser], primary(key))
        }
        bind(.saveAs, [.browser], [letter("S", .option)])
        bind(.editItem, [.browser], primary("e"))
        bind(.parent, [.browser], [KeyChord(.backspace), KeyChord(.up, .command)])
        bind(.childCategories, [.browser], [KeyChord(.down, .command), KeyChord(.down, .option)])
        bind(.childCategories, [.categories], [KeyChord(.down, .command), KeyChord(.down, .option)])
        bind(.previousColumn, [.browser], [letter("[")])
        bind(.nextColumn, [.browser], [letter("]")])
        bind(.goBack, [.browser], [letter("[", .command), KeyChord(.left, .option), fn(8, .option)])
        bind(.goForward, [.browser], [letter("]", .command), KeyChord(.right, .option)])
        for (command, number) in [
            (TUICommand.editItem, 2), (.include, 3), (.done, 4), (.editNote, 5), (.properties, 6), (.mark, 7),
        ] {
            bind(command, [.browser], [fn(number)])
        }
        bind(.unmarkAll, [.browser], [fn(7, .option)])
        bind(.refresh, [.browser], [fn(12)])
        bind(
            .deleteItems, [.browser, .group],
            [fn(4, .option), KeyChord(.backspace, .command), KeyChord(.delete, .control)])

        bind(.editItem, [.categories], [fn(2)])
        bind(.include, [.categories], [fn(3)])
        bind(.done, [.categories], [fn(4)])
        bind(.editNote, [.categories], [fn(5)])
        bind(.properties, [.categories], [fn(6)])
        bind(.mark, [.categories], [fn(7)])
        bind(.newItem, [.categories], primary("n"))
        bind(.save, [.categories], [letter("s", .control), letter("s", .command)])
        bind(.toggleSelector, [.categories], [fn(8)])
        bind(.editItem, [.categories], primary("e"))
        bindings.append(KeyBinding(context: .categories, chord: nil, command: .categoryModeInspector))
        bindings.append(KeyBinding(context: .categories, chord: nil, command: .categoryModeItems))
        bind(.toggle, [.categories], [fn(2, .shift), letter("i", .option)])
        bind(.refresh, [.categories], [fn(12)])
        bind(.categoryToggleTree, [.categories], [letter("t", .control)])
        bind(.newChild, [.categories], [letter("n", .option), KeyChord(.insert)])
        bind(.newRoot, [.categories], [letter("N", .control), letter("N", .command), letter("N", .option)])
        bind(.moveCategory, [.categories], [letter("m", .option)])
        bind(.detachCategory, [.categories], [letter("M", .option)])
        bind(
            .deleteCategory, [.categories],
            [fn(4, .option), KeyChord(.backspace, .command), KeyChord(.delete, .control)])
        bind(.refineCategory, [.categories], [KeyChord(.enter, .option)])

        bind(.learning, [.browser, .categories], [letter("l", .option)])
        for (command, key) in [
            (TUICommand.learningExamples, "e"), (.learningSuggestions, "s"), (.trainLearning, "t"),
            (.resetLearning, "u"), (.learningSettings, "o"), (.acceptLearning, "a"),
            (.rejectLearning, "n"), (.dismissLearning, "d"), (.excludeLearning, "x"),
            (.clearLearningFeedback, "c"), (.refresh, "r"), (.filter, "f"),
            (.previousResults, "["), (.nextResults, "]"), (.commands, "/"), (.help, "?"),
        ] { bind(command, [.learning], [letter(key)]) }
        bind(.learningSettings, [.learning], [fn(6)])
        bind(.cancel, [.learning], [fn(9)])

        bind(.save, [.editor, .form, .sections, .picker, .columns], primary("s"))
        bind(.save, [.form], [fn(8)])
        bind(.cancel, [.form], [fn(9)])
        // The definition form is a text-first modal.  Plain letters must always reach the focused
        // buffer, including F/G/L/O/S, so only explicit modifiers and function keys are commands.
        bind(.save, [.viewDefinition], [fn(8), letter("s", .command), letter("s", .control)])
        bind(
            .saveAs, [.viewDefinition],
            [fn(3), letter("S", .command), letter("S", .control), letter("S", .option)])
        bind(.cancel, [.viewDefinition], [fn(9)])
        bind(.addColumn, [.viewDefinition], [fn(5, .option)])
        bind(.deleteColumn, [.viewDefinition], [fn(6, .option)])
        bind(.moveColumnEarlier, [.viewDefinition], [fn(7, .option)])
        bind(.moveColumnLater, [.viewDefinition], [fn(8, .option)])
        bind(.cancel, [.menu], [KeyChord(.escape), letter("g", .control), fn(10)])
        bind(.cancel, [.reader, .help], [letter("q")])
        bind(.pageDown, [.reader, .help], [KeyChord(.enter), letter(" ")])
        bind(.help, [.menu], [fn(1)])
        bind(.reviewMarks, [.group], [letter("v")])
        for (command, key) in [(TUICommand.include, "i"), (.exclude, "x"), (.reset, "u"), (.done, "d")] {
            bind(command, [.group], [letter(key)])
        }
        bind(.deleteItems, [.group], [KeyChord(.delete)])
        bind(.addColumn, [.columns], [letter("n")] + primary("n"))
        bind(.editColumn, [.columns], [letter("e"), fn(2)])
        bind(.deleteColumn, [.columns], [letter("x"), KeyChord(.delete)])
        bind(.retry, [.pending], [letter("r"), letter("R"), letter("r", .control)])
        bind(.quit, [.pending], [letter("q"), letter("Q")] + primary("q"))
        bind(.quit, [.smallScreen], primary("q"))
        bind(.help, [.pending], [fn(1), letter("?")])
        bind(.cancel, [.pending], [KeyChord(.escape)])

        // Editing commands are also data; the editor's map adds terminal function keys.
        let text: [KeyContext] = [.text]
        for (command, keys) in [
            (TUICommand.moveLeft, [KeyChord(.left), letter("b", .control)]),
            (.moveRight, [KeyChord(.right), letter("f", .control)]),
            (.moveUp, [KeyChord(.up), letter("p", .control)]),
            (.moveDown, [KeyChord(.down), letter("n", .control)]),
            (.lineStart, [KeyChord(.home), letter("a", .control), KeyChord(.left, .command)]),
            (.lineEnd, [KeyChord(.end), letter("e", .control), KeyChord(.right, .command)]),
            (.wordLeft, [letter("b", .option), KeyChord(.left, .option)]),
            (.wordRight, [letter("f", .option), KeyChord(.right, .option)]),
            (
                .documentStart,
                [KeyChord(.up, .command), letter("<", .option), letter(",", [.option, .shift])]
            ),
            (
                .documentEnd,
                [KeyChord(.down, .command), letter(">", .option), letter(".", [.option, .shift])]
            ),
            (.deleteBackward, [KeyChord(.backspace), letter("h", .control)]),
            (.deleteForward, [KeyChord(.delete), letter("d", .control)]),
            (.deleteWordBackward, [KeyChord(.backspace, .option)]),
            (.deleteWordForward, [letter("d", .option), KeyChord(.delete, .option)]),
            (.killLine, [letter("k", .control)]), (.yank, [letter("y", .control)]),
            (.clearField, [letter("u", .control)]), (.openLine, [letter("o", .control)]),
            (.transpose, [letter("t", .control)]),
            (.setMark, [letter(" ", .control)]),
            (.copy, [letter("c", .command), letter("c", .control), letter("w", .option)]),
            (.cut, [letter("x", .command), letter("x", .control), letter("w", .control)]),
            (.paste, [letter("v", .command), letter("v", .control)]),
            (.undo, primary("z") + [letter("_", .control)]),
            (.redo, primary("Z")), (.selectText, [letter("a", .command)]),
        ] { bind(command, text, keys) }
        // Shift modifies movement into a range selection; lookup uses the base movement.
        let textActions: [TUICommand] = [.copy, .cut, .paste, .undo, .redo, .selectText, .setMark]
        for binding in bindings.filter({ $0.context == .text && textActions.contains($0.command) }) {
            if let chord = binding.chord { bind(binding.command, [.editor, .form], [chord]) }
        }
        bind(.paste, [.editor], [fn(2)])
        bind(.copy, [.editor], [fn(3)])
        bind(.cut, [.editor], [fn(4)])
        bind(.setMark, [.editor], [fn(7)])
        bind(.save, [.editor], [fn(8)])
        bind(.cancel, [.editor], [fn(9)])
        // Inline category fields retain their workspace shortcuts, with Save on F8 while editing.
        for binding in bindings.filter({ $0.context == .categories }) {
            if bindings.contains(where: { $0.context == .categoryEditor && $0.chord == binding.chord }) {
                continue
            }
            bindings.append(
                KeyBinding(
                    context: .categoryEditor, chord: binding.chord,
                    command: binding.chord == fn(8) ? .save : binding.command))
        }
        return try! Keymap(bindings: bindings)
    }()
}
