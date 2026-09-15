import Foundation
import XCTest

@testable import TractandaTUI

final class GlobalCommandMenuTests: XCTestCase {
    func testMenuCatalogIsGlobalAcrossAllContexts() {
        let menu = CommandMenu(keymap: .standard, context: .browser)
        let expectedGroups = menu.groups
        let expectedCommands = expectedGroups.flatMap(\.commands)

        for context in KeyContext.allCases {
            let contextMenu = CommandMenu(keymap: .standard, context: context)
            XCTAssertEqual(contextMenu.groups.map(\.id), expectedGroups.map(\.id), context.rawValue)
            XCTAssertEqual(contextMenu.groups.map(\.title), expectedGroups.map(\.title), context.rawValue)
            XCTAssertEqual(contextMenu.groups.count, expectedGroups.count, context.rawValue)
            for index in contextMenu.groups.indices {
                XCTAssertEqual(
                    contextMenu.groups[index].sections, expectedGroups[index].sections, context.rawValue)
            }
            let contextCommands = contextMenu.groups.flatMap(\.commands)
            XCTAssertEqual(contextCommands, expectedCommands, context.rawValue)
        }
    }

    func testRetainedEntriesIncludeCommandsNotBoundInContext() {
        let menu = CommandMenu(keymap: .standard, context: .reader)
        let menuCommands = menu.groups.flatMap(\.commands)
        let boundInContext = Set(Keymap.standard.commands(in: .reader))

        XCTAssertEqual(menuCommands.count, CommandMenu.definitions.flatMap(\.commands).count)
        XCTAssertTrue(menuCommands.contains(.newItem))
        XCTAssertTrue(menuCommands.contains(.redo))
        XCTAssertTrue(menuCommands.contains(.appearance))
        XCTAssertEqual(menuCommands.count, Set(menuCommands).count)
        XCTAssertTrue(menuCommands.contains { !boundInContext.contains($0) })
    }

    func testMenuGroupMovementVisitsAdjacentGroupsWithNoEnabledCommands() {
        var menu = CommandMenu(keymap: .standard, context: .browser)
        let disabled: (TUICommand) -> Bool = { _ in false }
        var visited: [CommandMenu.GroupID] = []
        for _ in 0..<menu.groups.count {
            menu.moveGroup(1, isEnabled: disabled)
            visited.append(menu.group.id)
            XCTAssertNil(menu.command)
        }
        XCTAssertEqual(visited, [.edit, .view, .window, .item, .category, .help, .application, .file])
        XCTAssertEqual(menu.group.id, .file)
    }

    func testMenuMovementSkipsDisabledCommandsAndHandlesBoundaryStates() {
        var menu = CommandMenu(keymap: .standard, context: .browser)
        menu.groupIndex = menu.groups.firstIndex(where: { $0.id == .edit }) ?? 0
        let sparseEnabled: (TUICommand) -> Bool = {
            switch $0 {
            case .undo, .setMark, .moveColumnLater:
                return true
            default:
                return false
            }
        }

        menu.commandIndex = -1
        menu.moveCommand(1, isEnabled: sparseEnabled)
        XCTAssertEqual(menu.command, .undo)
        menu.commandIndex = -1
        menu.moveCommand(-1, isEnabled: sparseEnabled)
        XCTAssertEqual(menu.command, .moveColumnLater)

        let enabled: (TUICommand) -> Bool = {
            switch $0 {
            case .undo, .setMark, .moveColumnLater:
                return true
            default:
                return false
            }
        }

        menu.commandIndex = 1
        menu.moveCommand(1, isEnabled: enabled)
        XCTAssertEqual(menu.command, .setMark)
        menu.moveCommand(-1, isEnabled: enabled)
        XCTAssertEqual(menu.command, .undo)
        menu.moveCommand(-1, isEnabled: enabled)
        XCTAssertEqual(menu.command, .undo)

        let terminalOnlyEnabled: (TUICommand) -> Bool = { $0 == .undo }
        menu.commandIndex = 0
        menu.moveCommand(1, isEnabled: terminalOnlyEnabled)
        XCTAssertEqual(menu.command, .undo)
        menu.moveCommand(1, isEnabled: terminalOnlyEnabled)
        XCTAssertEqual(menu.command, .undo)
        menu.moveCommand(-1, isEnabled: terminalOnlyEnabled)
        XCTAssertEqual(menu.command, .undo)

        menu.selectBoundary(last: true, isEnabled: enabled)
        XCTAssertEqual(menu.command, .moveColumnLater)
        menu.selectBoundary(last: false, isEnabled: enabled)
        XCTAssertEqual(menu.command, .undo)

        let noneEnabled: (TUICommand) -> Bool = { _ in false }
        menu.selectBoundary(last: false, isEnabled: noneEnabled)
        XCTAssertEqual(menu.command, nil)
        XCTAssertEqual(menu.commandIndex, -1)
        menu.moveCommand(1, isEnabled: noneEnabled)
        XCTAssertEqual(menu.command, nil)
    }
}
