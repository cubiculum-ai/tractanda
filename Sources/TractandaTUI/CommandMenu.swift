import Foundation

/// Presentation preference, independent of whether a terminal forwards F11/F12.
public enum FunctionKeyDisplay: String, CaseIterable, Codable, Sendable {
    case automatic = "auto"
    case ten = "10"
    case twelve = "12"

    func count(columns: Int) -> Int {
        switch self {
        case .automatic: columns >= 110 ? 12 : 10
        case .ten: 10
        case .twelve: 12
        }
    }
}

/// Menu placement refers to the same stable commands used by keyboard dispatch.
struct CommandMenu: Sendable {
    enum GroupID: String, CaseIterable, Sendable {
        case application, file, edit, view, window, item, category, help
    }
    enum Row: Equatable, Sendable {
        case command(TUICommand)
        case separator
    }
    struct Group: Sendable {
        let id: GroupID
        let title: String
        let sections: [[TUICommand]]
        var commands: [TUICommand] { sections.flatMap { $0 } }
        var rows: [Row] {
            sections.enumerated().flatMap { index, section in
                (index == 0 ? [] : [.separator]) + section.map { .command($0) }
            }
        }
    }

    let groups: [Group]
    var groupIndex: Int
    var commandIndex = 0
    var firstVisibleRow = 0
    var group: Group { groups[groupIndex] }
    var command: TUICommand? {
        group.commands.indices.contains(commandIndex) ? group.commands[commandIndex] : nil
    }

    init(keymap: Keymap, context: KeyContext) {
        _ = keymap
        _ = context
        groups = Self.definitions
        groupIndex =
            groups.firstIndex { $0.id == .file && !$0.commands.isEmpty }
            ?? groups.firstIndex { !$0.commands.isEmpty } ?? 0
    }

    mutating func moveGroup(_ delta: Int, isEnabled: (TUICommand) -> Bool) {
        guard !groups.isEmpty else { return }
        let step = delta >= 0 ? 1 : -1
        groupIndex = (groupIndex + step + groups.count) % groups.count
        firstVisibleRow = 0
        commandIndex = group.commands.firstIndex(where: isEnabled) ?? -1
    }

    mutating func moveCommand(_ delta: Int, isEnabled: (TUICommand) -> Bool) {
        let commands = group.commands
        guard !commands.isEmpty else { return }
        let direction = delta < 0 ? -1 : 1
        let start = commandIndex < 0 ? (direction > 0 ? -1 : commands.count) : commandIndex
        var index = start
        var remaining = max(1, abs(delta))
        while remaining > 0 {
            var next = index + direction
            while commands.indices.contains(next), !isEnabled(commands[next]) { next += direction }
            guard commands.indices.contains(next) else { break }
            index = next
            remaining -= 1
        }
        commandIndex = commands.indices.contains(index) && isEnabled(commands[index]) ? index : -1
    }

    mutating func selectBoundary(last: Bool, isEnabled: (TUICommand) -> Bool) {
        let indices = last ? Array(group.commands.indices.reversed()) : Array(group.commands.indices)
        commandIndex = indices.first(where: { isEnabled(group.commands[$0]) }) ?? -1
    }

    static let definitions: [Group] = [
        Group(
            id: .application, title: "Tractanda",
            sections: [[.about], [.appearance, .categoryPreferences], [.retry], [.quit]]),
        Group(
            id: .file, title: "File",
            sections: [[.newItem, .newView], [.views], [.save, .saveAs], [.cancel]]),
        Group(
            id: .edit, title: "Edit",
            sections: [
                [.undo, .redo], [.editItem, .editNote], [.cut, .copy, .paste],
                [.selectText, .selectAll, .unmarkAll, .setMark], [.addColumn, .editColumn, .deleteColumn],
                [.moveColumnEarlier, .moveColumnLater],
            ]),
        Group(
            id: .view, title: "View",
            sections: [
                [.refresh, .allItems, .parent], [.filter, .sections, .columns, .sort],
                [
                    .editView, .pinView, .toggleSelector, .togglePreview, .growPreview, .shrinkPreview,
                    .resetPreview,
                ],
                [.learningSuggestions, .learningExamples], [.previousResults, .nextResults],
                [.goBack, .goForward],
                [.mouseOn, .mouseOff],
                [.functionKeysAutomatic, .functionKeysTen, .functionKeysTwelve],
            ]),
        Group(
            id: .window, title: "Window",
            sections: [[.workspaceViews, .workspaceCategories, .switchWorkspace]]),
        Group(
            id: .item, title: "Item",
            sections: [
                [.properties, .history], [.mark, .reviewMarks, .group], [.done, .deleteItems],
                [
                    .acceptLearning, .rejectLearning, .dismissLearning, .excludeLearning,
                    .clearLearningFeedback,
                ],
            ]),
        Group(
            id: .category, title: "Category",
            sections: [
                [.categories, .childCategories], [.newChild, .newRoot],
                [.moveCategory, .detachCategory, .deleteCategory],
                [.categoryModeItems, .categoryModeInspector, .categoryToggleTree, .categoryToggleMaximize],
                [.include, .exclude, .reset, .explain], [.refineCategory],
                [.learning], [.trainLearning, .learningSettings, .resetLearning],
            ]),
        Group(id: .help, title: "Help", sections: [[.help]]),
    ]
}
