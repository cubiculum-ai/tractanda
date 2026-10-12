import Foundation
import XCTest

@testable import TractandaCore

final class DoclingDocTagsParserTests: XCTestCase {
    private let retainedSample = """
        <doctag><section_header_level_1><loc_28><loc_34><loc_266><loc_60>SYNTHETIC PAGE</section_header_level_1>
        <text><loc_28><loc_80><loc_175><loc_123>ALPHA-17</text>
        <text><loc_28><loc_127><loc_139><loc_155>BETA-29</text>
        <otsl><loc_28><loc_203><loc_470><loc_356><ched>LEFT<ched>RIGHT<nl><fcel>17<fcel>29<nl></otsl>
        </doctag>
        """

    func testParsesRetainedSuccessfulSampleAndTable() throws {
        let fixture = try String(
            contentsOfFile:
                "work/docling-integration-20261007/parser/retained-sample.doctags", encoding: .utf8)
        XCTAssertEqual(fixture, retainedSample)
        let page = try DoclingDocTagsParser.parse(fixture)
        XCTAssertEqual(page.rawDocTags.utf8.count, 320)
        XCTAssertEqual(page.blocks.count, 4)
        XCTAssertEqual(page.blocks[0].kind, .sectionHeader)
        XCTAssertEqual(page.blocks[0].headingLevel, 1)
        XCTAssertEqual(page.blocks[0].location?.left, 28)
        XCTAssertEqual(page.blocks[3].table?.map { $0.map(\.text) }, [["LEFT", "RIGHT"], ["17", "29"]])
        XCTAssertEqual(page.blocks[3].table?.first?.map(\.kind), [.columnHeader, .columnHeader])
        XCTAssertEqual(page.blocks.map(\.textByteStart), [0, 15, 24, 32])
        XCTAssertEqual(page.blocks.map(\.textByteEnd), [14, 23, 31, 48])
        XCTAssertEqual(page.text, "SYNTHETIC PAGE\nALPHA-17\nBETA-29\nLEFT\tRIGHT\n17\t29")
    }

    func testAcceptsEveryDeclaredFlatBlockTagAndSectionLevel() throws {
        let tags =
            ["title", "text", "caption", "footnote", "list_item", "page_header", "page_footer"]
            + (0...5).map { "section_header_level_\($0)" }
        let body = tags.map { "<\($0)>x</\($0)>" }.joined()
        let page = try DoclingDocTagsParser.parse("<doctag>\(body)</doctag>")
        XCTAssertEqual(page.blocks.count, tags.count)
        XCTAssertEqual(page.blocks.map(\.text), Array(repeating: "x", count: tags.count))
        XCTAssertEqual(page.blocks[7].headingLevel, 0)
        XCTAssertEqual(page.blocks[12].headingLevel, 5)
    }

    func testPreservesUnicodeTabsAndNewlinesWithUTF8Ranges() throws {
        let page = try DoclingDocTagsParser.parse(
            "<doctag><text>é🙂\tfirst\nsecond</text><caption>λ</caption></doctag>")
        XCTAssertEqual(page.text, "é🙂\tfirst\nsecond\nλ")
        XCTAssertEqual(page.blocks[0].textByteStart, 0)
        XCTAssertEqual(page.blocks[0].textByteEnd, "é🙂\tfirst\nsecond".utf8.count)
        XCTAssertEqual(page.blocks[1].textByteStart, "é🙂\tfirst\nsecond".utf8.count + 1)
        XCTAssertEqual(page.blocks[1].textByteEnd, page.text.utf8.count)
    }

    func testAcceptsEmptyRootNoLocationAndValidUTF8Data() throws {
        let empty = try DoclingDocTagsParser.parse(Data("<doctag></doctag>".utf8))
        XCTAssertTrue(empty.blocks.isEmpty)
        XCTAssertEqual(empty.text, "")
        let noLocation = try DoclingDocTagsParser.parse("  <doctag><text>ok</text></doctag> \n")
        XCTAssertNil(noLocation.blocks[0].location)
        XCTAssertEqual(noLocation.rawDocTags, "  <doctag><text>ok</text></doctag> \n")
    }

    func testRejectsInvalidUTF8AndByteOrderMark() {
        XCTAssertThrowsError(try DoclingDocTagsParser.parse(Data([0x3C, 0xFF, 0x3E])))
        XCTAssertThrowsError(try DoclingDocTagsParser.parse("\u{FEFF}<doctag></doctag>"))
        XCTAssertThrowsError(try DoclingDocTagsParser.parse(Data("\u{FEFF}<doctag></doctag>".utf8)))
    }

    func testUntrustedMarkerErrorsStayBoundedAndPrintable() {
        for marker in [String(repeating: "a", count: 200_000), "text\u{1B}[31m"] {
            XCTAssertThrowsError(try DoclingDocTagsParser.parse("<doctag><\(marker)></doctag>")) { error in
                let message = (error as? TractandaError)?.message ?? String(describing: error)
                XCTAssertLessThan(message.utf8.count, 256)
                XCTAssertFalse(message.contains("\u{1B}"))
            }
        }
    }

    func testRejectsUnknownNestedMismatchedTruncatedAndDuplicateMarkup() {
        let rejected = [
            "<doctag><picture>x</picture></doctag>",
            "<doctag><text>a<inline>b</inline></text></doctag>",
            "<doctag><text>x</caption></doctag>",
            "<doctag><text>x</text>",
            "<doctag><text>x</text></doctag><doctag></doctag>",
            "<doctag>stray<text>x</text></doctag>",
            "<doctag><text>x</text><",
        ]
        for raw in rejected { XCTAssertThrowsError(try DoclingDocTagsParser.parse(raw), raw) }
    }

    func testLocationExtremaAndRejectsMalformedOrReversedBoxes() throws {
        let valid = try DoclingDocTagsParser.parse(
            "<doctag><text><loc_0><loc_0><loc_499><loc_499>x</text></doctag>")
        XCTAssertEqual(valid.blocks[0].location?.right, 499)
        for raw in [
            "<doctag><text><loc_0><loc_0><loc_499>x</text></doctag>",
            "<doctag><text><loc_0><loc_0><loc_500><loc_499>x</text></doctag>",
            "<doctag><text><loc_-1><loc_0><loc_1><loc_1>x</text></doctag>",
            "<doctag><text><loc_2><loc_0><loc_1><loc_1>x</text></doctag>",
            "<doctag><text><loc_0></text></doctag>",
            "<doctag><text>x<loc_0><loc_0><loc_1><loc_1></text></doctag>",
        ] { XCTAssertThrowsError(try DoclingDocTagsParser.parse(raw), raw) }
    }

    func testSimpleTableCellKindsEmptyCellsAndRowSeparators() throws {
        let page = try DoclingDocTagsParser.parse(
            "<doctag><otsl><ched>H<rhed>R<nl><ecel><fcel>v<nl></otsl></doctag>")
        XCTAssertEqual(
            page.blocks[0].table?.map { $0.map(\.kind) },
            [[.columnHeader, .rowHeader], [.empty, .data]])
        XCTAssertEqual(page.blocks[0].text, "H\tR\n\tv")
        XCTAssertEqual(page.blocks[0].textByteEnd, page.text.utf8.count)
        let section = try DoclingDocTagsParser.parse(
            "<doctag><otsl><srow>Section<ecel><nl><fcel>v<ecel><nl></otsl></doctag>")
        XCTAssertEqual(section.blocks[0].table?.first?.map(\.kind), [.sectionRow, .empty])
    }

    func testRejectsSpansRaggedRowsEmptyCellsWithTextAndOverwideTables() {
        let rejected = [
            "<doctag><otsl><fcel>a<lcel><nl></otsl></doctag>",
            "<doctag><otsl><fcel>a<nl><fcel>b<fcel>c<nl></otsl></doctag>",
            "<doctag><otsl><ecel>x<nl></otsl></doctag>",
            "<doctag><otsl>\(String(repeating: "<fcel>x", count: 33))<nl></otsl></doctag>",
        ]
        for raw in rejected { XCTAssertThrowsError(try DoclingDocTagsParser.parse(raw), raw) }
    }

    func testEnforcesRawBlockAndPlainTextBudgetsWithSmallFixtures() {
        XCTAssertThrowsError(
            try DoclingDocTagsParser.parse(
                "<doctag>\(String(repeating: " ", count: 256 * 1024))</doctag>"))
        let manyBlocks = "<doctag>" + String(repeating: "<text></text>", count: 513) + "</doctag>"
        XCTAssertThrowsError(try DoclingDocTagsParser.parse(manyBlocks))
        let tooMuchText = "<doctag><text>\(String(repeating: "x", count: 64 * 1024 + 1))</text></doctag>"
        XCTAssertThrowsError(try DoclingDocTagsParser.parse(tooMuchText))
        let tooManyRows =
            "<doctag><otsl>" + String(repeating: "<fcel>x<nl>", count: 33)
            + "</otsl></doctag>"
        XCTAssertThrowsError(try DoclingDocTagsParser.parse(tooManyRows))
    }
}
