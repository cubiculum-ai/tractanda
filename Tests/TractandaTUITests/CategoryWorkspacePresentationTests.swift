import Foundation
import TractandaCore
import XCTest

@testable import TractandaTUI

final class CategoryWorkspacePresentationTests: XCTestCase {
    private func item(_ number: Int, name: String, body: String = "", parents: [Revision] = []) throws
        -> Revision
    {
        try Revision(fields: [
            "itemID": .text(String(format: "%08x-0000-1000-8000-010000000001", number)),
            "revisionID": .text(String(format: "%08x-0000-1000-8001-010000000001", number)),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "actor": .text("fixture"), "operationID": .text("fixture-\(number)"),
            "requestIdentity": .text("fixture"), "createdAt": .date("2026-09-13T00:00:00Z"),
            "modifiedAt": .date("2026-09-13T00:00:00Z"),
            "subject": .text(name), "body": .text(body),
            "selection": .object(["expression": .text("itemID == *")]),
            "categoryParents": .list(parents.map { .reference(ItemReference($0.itemID)) }),
        ])
    }

    private func render(_ state: CategoryWorkspace, items: [Revision], width: Int = 79, height: Int = 25)
        throws -> CategoryWorkspacePresentation.Result
    {
        let tree = try CategoryTree(items)
        let rows = tree.rows(filter: "", expanded: tree.initialExpansion)
        return CategoryWorkspacePresentation.render(
            manager: state, rows: rows, selectedIndex: 0, firstVisibleIndex: 0,
            filter: TextBuffer(), columns: [try ViewColumn(property: "subject", title: "Subject", width: 40)],
            columnOffset: 0, width: width, height: height, previewVisible: true, cursorLayout: .native,
            title: { $0.fields["subject"]?.string ?? "" },
            rowKey: { rows[$0].key + ":" + rows[$0].item.revisionID },
            categoriesWithChildren: [])
    }

    func testConnectedBranchesDescribePlacementsWithoutAnExtraStoredRoot() throws {
        let a = try item(1, name: "Alpha")
        let b = try item(2, name: "Beta")
        let shared = try item(3, name: "Shared", parents: [a, b])
        var state = CategoryWorkspace(preferences: ViewWorkspacePreferences())
        state.connectedTree = true
        let result = try render(state, items: [a, b, shared], width: 131, height: 35)
        let text = result.lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("├─▾ Alpha"), text)
        XCTAssertTrue(text.contains("│ └─  Shared"), text)
        XCTAssertTrue(text.contains("└─▾ Beta"), text)
        XCTAssertEqual(result.lines.filter { $0.text.contains("Shared") }.count, 2)
        XCTAssertEqual(result.lines.filter { $0.hits.contains { $0.target == .categoryAllItems } }.count, 1)
        XCTAssertEqual(result.lines.count, 32)
    }

    func testMultilineCaretAndSelectionStayInsideTheirPaneAtEverySize() throws {
        let body = "First café 文 │ text\n" + (0..<40).map { "Body line \($0)" }.joined(separator: "\n")
        let category = try item(1, name: "Category", body: body)
        var state = CategoryWorkspace(preferences: ViewWorkspacePreferences())
        state.selectedAllItems = false
        state.preview.path = [category]
        state.rightMode = .category
        state.focus = .right
        state.inspector = try CategoryInspectorDraft(base: category)
        state.inspector?.focus = 1
        state.inspector?.fields[1].placeCursor(at: 0)
        state.inspector?.fields[1].placeCursor(at: body.count, extendingSelection: true)
        for (width, height) in [(79, 25), (47, 12), (131, 35)] {
            let result = try render(state, items: [category], width: width, height: height)
            XCTAssertEqual(result.lines.count, height - 3)
            XCTAssertTrue(result.lines.contains { $0.text.contains("Body line 39") })
            let caretLine = try XCTUnwrap(result.lines.first { $0.cursorColumn != nil })
            let caret = try XCTUnwrap(caretLine.cursorColumn)
            let hit = try XCTUnwrap(caretLine.hits.last { $0.columns.contains(caret) })
            guard case .categoryInspectorText(let field, let offsets) = hit.target else {
                return XCTFail("Caret has no matching field hit")
            }
            XCTAssertEqual(field, 1)
            XCTAssertEqual(offsets[caret - hit.columns.lowerBound], body.count)
            for row in result.lines {
                let cells = TerminalANSI.cells(row, columns: width)
                if let divider = row.hits.first(where: { $0.target == .categoryDivider }) {
                    XCTAssertEqual(cells[divider.columns.lowerBound].style, .dimmed)
                    XCTAssertTrue(row.selectionColumns.allSatisfy { !$0.overlaps(divider.columns) })
                    if let cursor = row.cursorColumn {
                        XCTAssertGreaterThan(cursor, divider.columns.lowerBound)
                    }
                }
                XCTAssertTrue(
                    row.hits.allSatisfy { $0.columns.lowerBound >= 0 && $0.columns.upperBound <= width })
            }
        }
    }

    func testInactiveInspectorDoesNotStealSearchCaretAndManualScrollCanHideBodyCaret() throws {
        let category = try item(
            1, name: "Category", body: (0..<50).map { "Line \($0)" }.joined(separator: "\n"))
        var state = CategoryWorkspace(preferences: ViewWorkspacePreferences())
        state.selectedAllItems = false
        state.preview.path = [category]
        state.rightMode = .category
        state.inspector = try CategoryInspectorDraft(base: category)
        state.inspector?.focus = 1
        let passive = try render(state, items: [category])
        XCTAssertEqual(passive.lines.compactMap(\.cursorColumn).count, 1)
        XCTAssertLessThan(try XCTUnwrap(passive.lines.compactMap(\.cursorColumn).first), 26)
        state.focus = .right
        state.inspectorScroll = 0
        let scrolled = try render(state, items: [category])
        XCTAssertEqual(scrolled.inspectorViewport?.start, 0)
        XCTAssertTrue(scrolled.lines.contains { $0.text.contains("Line 0") })
        XCTAssertTrue(scrolled.lines.compactMap(\.cursorColumn).isEmpty)
        state.inspectorScroll = nil
        let keyboard = try render(state, items: [category])
        XCTAssertTrue(keyboard.lines.contains { $0.text.contains("Line 49") })
        XCTAssertEqual(keyboard.lines.compactMap(\.cursorColumn).count, 1)
    }

    func testLastPreviewRowsAreReachableAndMouseHitsMatchTheirCurrentIDs() throws {
        let records = try (1...64).map { try item($0, name: "Preview \($0)") }
        var state = CategoryWorkspace(preferences: ViewWorkspacePreferences())
        state.preview.rows = records
        state.preview.total = 70
        state.preview.status = .loaded
        state.previewIndex = 63
        state.focus = .right
        let result = try render(state, items: [])
        XCTAssertGreaterThan(result.previewStart, 0)
        XCTAssertTrue(result.lines.contains { $0.text.contains("Preview 64") })
        XCTAssertFalse(result.lines.contains { $0.text.contains("Preview 1 ") })
        let hits = result.lines.flatMap(\.hits)
        XCTAssertTrue(hits.contains { $0.target == .categoryPreviewRow(63, records[63].itemID) })
        XCTAssertTrue(hits.contains { $0.target == .categoryPreviewNext })
        state.isMaximized = true
        let large = try render(state, items: [])
        XCTAssertFalse(large.lines.flatMap(\.hits).contains { $0.target == .categoryDivider })
    }
}
