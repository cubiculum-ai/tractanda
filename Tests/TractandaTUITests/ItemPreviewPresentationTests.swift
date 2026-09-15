import TractandaCore
import XCTest

@testable import TractandaTUI

final class ItemPreviewPresentationTests: XCTestCase {
    func testLongPreviewClampsScrollingAndKeepsEveryRowFocusable() throws {
        let item = try Revision(fields: [
            "itemID": .text(Identifier.make()), "revisionID": .text(Identifier.make()),
            "classID": .text("NoteItem"), "schemaVersion": .integer(1),
            "actor": .text("fixture"), "operationID": .text("fixture-preview"),
            "requestIdentity": .text("fixture"), "createdAt": .date("2026-09-13T00:00:00Z"),
            "modifiedAt": .date("2026-09-13T00:00:00Z"),
            "body": .text((0..<40).map { "Line \($0)" }.joined(separator: "\n")),
        ])
        let maximum = ItemPreviewPresentation.maximumOffset(item: item, width: 79)
        XCTAssertEqual(maximum, 37)
        let lines = ItemPreviewPresentation.lines(item: item, width: 79, offset: Int.max, focused: true)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[1].text.contains("Line 37"))
        XCTAssertTrue(lines[3].text.contains("Line 39"))
        XCTAssertEqual(lines.first?.hits, [MouseHit(columns: 0..<79, target: .previewDivider)])
        XCTAssertTrue(
            lines.dropFirst().allSatisfy { $0.hits == [MouseHit(columns: 0..<79, target: .itemPreview)] })
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.style == .activePane })
        let passive = ItemPreviewPresentation.lines(item: item, width: 79, offset: -1, focused: false)
        XCTAssertTrue(passive[1].text.contains("Line 0"))
        XCTAssertTrue(passive.allSatisfy { $0.style == .dimmed })
    }

    func testEmptyPreviewRetainsGeometryAndClickTargets() {
        let lines = ItemPreviewPresentation.lines(item: nil, width: 47, offset: 99, focused: false)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { !$0.hits.isEmpty && $0.cursorColumn == nil })
        XCTAssertEqual(ItemPreviewPresentation.maximumOffset(item: nil, width: 47), 0)
    }

    func testDividerDragUsesTerminalFooterGeometry() {
        // At 24 rows, moving the header nine rows upward from its default position requests 12,
        // not 14: the status and function-key rows are outside the workspace body.
        XCTAssertEqual(ItemPreviewPresentation.requestedContentRows(terminalRows: 24, dividerRow: 9), 12)
        XCTAssertEqual(ItemPreviewPresentation.requestedContentRows(terminalRows: 24, dividerRow: 40), 1)
    }
}
