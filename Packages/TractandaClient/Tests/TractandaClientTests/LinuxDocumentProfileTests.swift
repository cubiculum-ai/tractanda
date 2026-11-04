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
    func testUnknownBuildAndModelProvenanceIsReadableButNeverActive() throws {
        let value = try identity([
            "converter": "future.docling-build+linux-raster." + String(repeating: "f", count: 64),
            "model": "future-vendor/another-model", "modelRevision": String(repeating: "b", count: 64),
            "runtimeRevision": String(repeating: "c", count: 40),
        ])
        XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(try value.storedSemanticProfile(), .contentCropV2)
        XCTAssertThrowsError(try value.validateCurrent())
        let encoded = try JSONEncoder().encode(value)
        let roundTrip = try JSONDecoder().decode(DocumentConverterIdentity.self, from: encoded)
        XCTAssertEqual(roundTrip, value, "Provenance values are not normalized or rewritten")
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(
            Set(wire.keys),
            ["converter", "model", "modelRevision", "runtimeRevision", "preprocessing", "parser"])
    }
    func testUnsupportedStoredSemanticsAreStillRejected() throws {
        XCTAssertThrowsError(try identity(["parser": "unapproved-parser"]).validate())
        XCTAssertThrowsError(try identity(["preprocessing": "unapproved-preprocessing"]).validate())
        let historical = try identity([
            "converter": "different-build", "preprocessing": "opaque-rgb2048-17tiles-v1",
        ])
        XCTAssertEqual(try historical.storedSemanticProfile(), .legacyCanvasV1)
        XCTAssertNotEqual(
            try historical.storedSemanticProfile(), try DocumentConverterIdentity().storedSemanticProfile())
    }
    func testMalformedAndUnboundedProvenanceIsRejected() throws {
        for field in ["converter", "model"] {
            for value in ["", "bad identity", "../bad", "bad\0identity", String(repeating: "a", count: 257)] {
                XCTAssertThrowsError(
                    try identity([field: value]).validate(), field + ": " + value.debugDescription)
            }
        }
        for field in ["modelRevision", "runtimeRevision"] {
            for value in [
                "", "not-a-revision", String(repeating: "a", count: 39), String(repeating: "g", count: 40),
                String(repeating: "a", count: 65),
            ] {
                XCTAssertThrowsError(
                    try identity([field: value]).validate(), field + ": " + value.debugDescription)
            }
        }
    }
    func testCurrentPackageProfileConstructionRemainsFiniteAndStrict() throws {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            LinuxDocumentConverterProfiles.converterName(digest: digest),
            LinuxDocumentConverterProfiles.macConverter + "+linux-raster." + digest)
        for invalid in [nil, "", String(repeating: "g", count: 64), String(repeating: "a", count: 63)]
            as [String?]
        {
            XCTAssertNil(LinuxDocumentConverterProfiles.converterName(digest: invalid))
        }
        let historical = try identity(["converter": "a-different-runtime-build"])
        XCTAssertNoThrow(try historical.validate())
        XCTAssertThrowsError(try historical.validateCurrent())
    }
}
