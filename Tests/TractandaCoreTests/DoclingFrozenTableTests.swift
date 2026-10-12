import XCTest

@testable import TractandaCore

// Frozen native outputs: parser admission is separate from visual/table correctness.
final class DoclingFrozenTableTests: XCTestCase {
    func testSavedNativeTableOutputsParseWithoutChangingRecognitionGroundTruth() throws {
        // ruled-invoice; raw SHA256 99170678d28e4c2c731b80e71048f170b7951eea171995c16800bd849066d497
        do {
            let raw = """
                <doctag><section_header_level_1><loc_39><loc_26><loc_133><loc_36>INVOICE 10482</section_header_level_1>
                <text><loc_39><loc_41><loc_202><loc_47>Quarterly facilities service l issued 12 March 2026</text>
                <otsl><loc_39><loc_79><loc_461><loc_152><fcel>Service<fcel>Units<fcel>Amount<nl><fcel>Inspection<fcel>2<fcel>480.00<nl><fcel>Repair<fcel>1<fcel>125.50<nl></otsl>
                <text><loc_39><loc_377><loc_144><loc_383>SOURCE: INTERNAL REPORT</text>
                </doctag>
                """
            let page = try DoclingDocTagsParser.parse(raw)
            XCTAssertEqual(page.blocks.count, 4)
            XCTAssertEqual(page.blocks[0].kind, .sectionHeader)
            XCTAssertEqual(page.blocks[0].headingLevel, 1)
            XCTAssertEqual(
                page.blocks[2].table?.map { $0.map(\.text) },
                [["Service", "Units", "Amount"], ["Inspection", "2", "480.00"], ["Repair", "1", "125.50"]])
        }
        // financial-results; raw SHA256 9b4209be7c55f0aadd51adae6638abf2e2c3fc2fed56748612a1494ae88e17d3
        do {
            let raw = """
                <doctag><section_header_level_1><loc_39><loc_25><loc_180><loc_36>OPERATING RESULTS</section_header_level_1>
                <text><loc_39><loc_40><loc_200><loc_47>Management report | USD millions except margin</text>
                <otsl><loc_39><loc_79><loc_461><loc_176><fcel>Measure<fcel>FY2024<fcel>FY2025<nl><fcel>Revenue<fcel>84.2<fcel>91.6<nl><fcel>Operating income<fcel>11.8<fcel>13.1<nl><fcel>Margin (%)<fcel>14.0<fcel>14.3<nl></otsl>
                <text><loc_39><loc_377><loc_144><loc_384>SOURCE: INTERNAL REPORT</text>
                </doctag>
                """
            let page = try DoclingDocTagsParser.parse(raw)
            XCTAssertEqual(page.blocks.count, 4)
            XCTAssertEqual(page.blocks[0].kind, .sectionHeader)
            XCTAssertEqual(page.blocks[0].headingLevel, 1)
            XCTAssertEqual(
                page.blocks[2].table?.map { $0.map(\.text) },
                [
                    ["Measure", "FY2024", "FY2025"], ["Revenue", "84.2", "91.6"],
                    ["Operating income", "11.8", "13.1"], ["Margin (%)", "14.0", "14.3"],
                ])
        }
        // borderless-merged-header; raw SHA256 39d4fb5ef00461eb5bafe5abdacd80b46d8f2dad490a0e057f6a10eb3ac85d08
        do {
            let raw = """
                <doctag><section_header_level_1><loc_39><loc_25><loc_152><loc_36>REGIONAL SALES</section_header_level_1>
                <text><loc_39><loc_40><loc_162><loc_47>Illustrative report | Thousands of units</text>
                <otsl><loc_39><loc_80><loc_461><loc_174><fcel>FY2025 by quarter<ecel><ecel><ecel><nl><fcel>Region<fcel>Q1<ecel><fcel>Q2<nl><fcel>North<fcel>18.4<ecel><fcel>19.1<nl><fcel>South<fcel>12.7<ecel><fcel>13.5<nl></otsl>
                <text><loc_39><loc_376><loc_144><loc_383>SOURCE: INTERNAL REPORT</text>
                </doctag>
                """
            let page = try DoclingDocTagsParser.parse(raw)
            XCTAssertEqual(page.blocks.count, 4)
            XCTAssertEqual(page.blocks[0].kind, .sectionHeader)
            XCTAssertEqual(page.blocks[0].headingLevel, 1)
            XCTAssertEqual(
                page.blocks[2].table?.map { $0.map(\.text) },
                [
                    ["FY2025 by quarter", "", "", ""], ["Region", "Q1", "", "Q2"],
                    ["North", "18.4", "", "19.1"], ["South", "12.7", "", "13.5"],
                ])
            // Admission preserves the observed wrong 4-column grid; no span accuracy claim.
            XCTAssertEqual(page.blocks[2].table?.count, 4)
            XCTAssertEqual(page.blocks[2].table?.first?.count, 4)
        }
    }
}
