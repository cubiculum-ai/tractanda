import TractandaCore
import XCTest

@testable import TractandaTUI

final class ViewDefinitionFormTests: XCTestCase {
    func testRenamingSortPropertiesPreservesComparatorExtensionsAndTail() throws {
        let comparators = try ["subject", "createdAt", "rank"].map { try ItemSort(property: $0) }
        let raw = comparators.enumerated().map { index, sort -> ItemValue in
            var fields = sort.value.map!
            fields["foreign.option"] = .integer(Int64(index))
            return .object(fields)
        }
        var form = ViewDefinitionForm(
            name: "", description: "", expression: "", text: "", includedCategories: [],
            excludedCategories: [], sections: [], columns: ViewPresentation.defaultColumns,
            sort: comparators, originalSort: raw)
        form.primaryProperty = TextBuffer("modifiedAt")
        form.primaryDirection = TextBuffer("descending")
        form.secondaryProperty = TextBuffer("")
        let committed = try form.committedSortValues()
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed[0].map?["property"], .text("modifiedAt"))
        XCTAssertEqual(committed[0].map?["isAscending"], .boolean(false))
        XCTAssertEqual(committed[0].map?["foreign.option"], .integer(0))
        XCTAssertEqual(committed[1], raw[2])
    }

    func testFieldDisplayMarksOnlyFocusedCaretAndRetainsMultilineAndUnicodeOffsets() throws {
        let form = ViewDefinitionForm(
            name: "漢字abcdef", description: "first\nsecond", expression: "", text: "",
            includedCategories: [], excludedCategories: [], sections: [],
            columns: ViewPresentation.defaultColumns, sort: [])
        let inactive = form.displayLines(.name, columns: 5, marked: false)
        XCTAssertFalse(inactive.contains(where: \.containsCursor))
        XCTAssertFalse(inactive.contains { $0.text.contains("│") })
        let expected =
            Array(repeating: 0, count: TerminalText.width("漢"))
            + Array(repeating: 1, count: TerminalText.width("字"))
        XCTAssertEqual(Array(inactive[0].offsets.prefix(expected.count)), expected)
        let active = form.displayLines(.name, columns: 5)
        XCTAssertEqual(active.filter(\.containsCursor).count, 1)
        let description = form.displayLines(.description, columns: 20, marked: false, flatten: false)
        XCTAssertEqual(description.map(\.text), ["first", "second"])
    }
}
