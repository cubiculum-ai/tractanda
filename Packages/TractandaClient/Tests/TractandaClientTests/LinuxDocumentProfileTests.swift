import Foundation
import XCTest

@testable import TractandaClient

final class LinuxDocumentProfileTests: XCTestCase {
    private func identity(_ values: [String: String]) throws -> DocumentConverterIdentity {
        var object =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(DocumentConverterIdentity()))
            as! [String: String]
        object.merge(values) { _, value in value }
        return try JSONDecoder().decode(
            DocumentConverterIdentity.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testFinitePackageLookupRejectsUnknownArchitecture() throws {
        XCTAssertNotNil(DocumentConverterIdentity.approvedLinuxConverter(architecture: "arm64"))
        XCTAssertEqual(
            DocumentConverterIdentity.approvedLinuxConverter(architecture: "amd64"),
            DocumentConverterIdentity.approvedLinuxConverter(architecture: "x86_64"))
        XCTAssertNil(DocumentConverterIdentity.approvedLinuxConverter(architecture: "riscv64"))
        XCTAssertNil(DocumentConverterIdentity.approvedLinuxConverter(architecture: ""))
    }
    func testCurrentProfileIsStrict() throws {
        try DocumentConverterIdentity().validate()
        try DocumentConverterIdentity().validateCurrent()
    }
    func testHistoricalMacV2RemainsReadable() throws {
        let value = try identity(["converter": "tractanda.docling-native.v2-idefics3-gelu-f32"])
        try value.validate()
        if value != DocumentConverterIdentity() { XCTAssertThrowsError(try value.validateCurrent()) }
    }
    func testHistoricalV1RemainsReadableButNotCurrent() throws {
        let value = try identity([
            "converter": "tractanda.docling-native.v1", "preprocessing": "opaque-rgb2048-17tiles-v1",
        ])
        try value.validate()
        XCTAssertThrowsError(try value.validateCurrent())
    }
    func testUnapprovedWellFormedRendererDigestIsRejected() throws {
        let known = Set(LinuxDocumentConverterProfiles.knownConverters)
        let candidate = (0..<16).map {
            "tractanda.docling-native.v2-idefics3-gelu-f32+linux-raster."
                + String(repeating: String($0, radix: 16), count: 64)
        }.first { !known.contains($0) }!
        XCTAssertThrowsError(try identity(["converter": candidate]).validate())
    }
    func testProfileDoesNotAuthorizeDifferentModelOrParser() throws {
        XCTAssertThrowsError(try identity(["modelRevision": String(repeating: "0", count: 40)]).validate())
        XCTAssertThrowsError(try identity(["parser": "unapproved-parser"]).validate())
        XCTAssertThrowsError(try identity(["preprocessing": "unapproved-preprocessing"]).validate())
    }
    func testHistoricalLinuxProfilesSurviveCurrentDigestReplacement() throws {
        let old = String(repeating: "a", count: 64)
        let replacement = String(repeating: "b", count: 64)
        let prefix = LinuxDocumentConverterProfiles.macConverter + "+linux-raster."
        let known = LinuxDocumentConverterProfiles.converterNames(
            currentDigests: [replacement, nil], historicalDigests: [old])
        XCTAssertEqual(Set(known), Set([prefix + old, prefix + replacement]))
        XCTAssertFalse(known.contains(prefix + String(repeating: "c", count: 64)))
        // History recognition does not alter the actual current-result contract.
        let historical = try identity(["converter": prefix + old])
        if historical != DocumentConverterIdentity() {
            XCTAssertThrowsError(try historical.validateCurrent())
        }
    }
}
