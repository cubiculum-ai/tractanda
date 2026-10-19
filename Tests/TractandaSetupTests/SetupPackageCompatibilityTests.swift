import Foundation
import TractandaCore
import XCTest

@testable import TractandaSetup

final class SetupPackageCompatibilityTests: XCTestCase {
    private let semanticProfile = "tractanda.peer-exchange.v2"
    private let storeID = "00000000-0000-1000-8000-000000000001"

    private func declaration(
        support: CanonicalFormatSupport = .current,
        semanticProfile: String = "tractanda.peer-exchange.v2",
        upgrade: SetupPackageCompatibility.Upgrade = .compatible,
        embedding: EmbeddingPayload? = .granite,
        document: DocumentExtractionPayload? = .pinned,
        version: String = "0.1.0-poc.16",
        arch: String = "x86_64"
    ) -> SetupPackageCompatibility {
        SetupPackageCompatibility(
            manifestSHA256: String(repeating: "a", count: 64), version: version, arch: arch,
            canonicalFormats: support, semanticProfile: semanticProfile, upgrade: upgrade,
            embedding: embedding, documentExtraction: document)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedObject(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testCurrentDeclarationRoundTripsBoundedAndPreservesFullModelRecipes() throws {
        let value = declaration()
        let encoded = try value.encoded()
        XCTAssertLessThanOrEqual(encoded.count, SetupPackageCompatibility.maximumBytes)
        let decoded = try SetupPackageCompatibility.decode(encoded)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.profile, SetupPackageCompatibility.profileName)
        XCTAssertEqual(decoded.semanticProfile, semanticProfile)
        XCTAssertEqual(decoded.canonicalFormats, .current)
        XCTAssertEqual(decoded.embedding, .granite)
        XCTAssertEqual(decoded.documentExtraction, .pinned)
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(Data()))
        XCTAssertThrowsError(
            try SetupPackageCompatibility.decode(
                Data(repeating: 0x20, count: SetupPackageCompatibility.maximumBytes + 1)))
    }

    func testDecodeRejectsUnknownMissingDuplicateAndWrongTypedFields() throws {
        let encoded = try declaration().encoded()

        var unknown = try jsonObject(encoded)
        unknown["unreviewed"] = true
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(encodedObject(unknown)))

        var missing = try jsonObject(encoded)
        missing.removeValue(forKey: "canonicalFormats")
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(encodedObject(missing)))

        var wrongType = try jsonObject(encoded)
        wrongType["arch"] = 42
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(encodedObject(wrongType)))

        var wrongSupportType = try jsonObject(encoded)
        var support = try XCTUnwrap(wrongSupportType["canonicalFormats"] as? [String: Any])
        support["readerLevel"] = "14"
        wrongSupportType["canonicalFormats"] = support
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(encodedObject(wrongSupportType)))

        let text = String(decoding: encoded, as: UTF8.self)
        let duplicate = text.replacingOccurrences(
            of: "\"profile\":\"tractanda.linux-package.v1\"",
            with: "\"profile\":\"tractanda.linux-package.v1\",\"profile\":\"tractanda.linux-package.v1\"",
            options: .literal)
        XCTAssertNotEqual(duplicate, text)
        XCTAssertThrowsError(try SetupPackageCompatibility.decode(Data(duplicate.utf8)))

        let baseEmbedding = try jsonObject(JSONEncoder().encode(EmbeddingPayload.granite))
        var largeEmbedding = baseEmbedding
        largeEmbedding["modelRevision"] = String(
            repeating: "r", count: SetupPackageCompatibility.maximumBytes + 1)
        let oversizedRecipe = try JSONDecoder().decode(
            EmbeddingPayload.self, from: encodedObject(largeEmbedding))
        XCTAssertThrowsError(try declaration(embedding: oversizedRecipe).encoded())
    }

    func testCompatiblePackagesNeedMutualReaderWriterAndMatchingFeatureRecipes() throws {
        let old = declaration()
        let incoming = declaration(version: "0.1.0-poc.17")
        XCTAssertEqual(old.semanticProfile, incoming.semanticProfile)
        XCTAssertEqual(old.embedding, .granite)
        XCTAssertEqual(old.documentExtraction, .pinned)
        XCTAssertNoThrow(try incoming.requireRollingUpgrade(from: old))

        XCTAssertNoThrow(try CanonicalFormatSupport.current.requireWriter(.legacy))
        XCTAssertThrowsError(try CanonicalFormatSupport.legacy.requireWriter(.current))

        let legacyPackage = declaration(support: .legacy)
        XCTAssertThrowsError(try declaration().requireRollingUpgrade(from: legacyPackage))
        XCTAssertThrowsError(try legacyPackage.requireRollingUpgrade(from: declaration()))
    }

    func testBreakingUnknownSemanticAndChangedModelRecipesCannotRoll() throws {
        let old = declaration()
        let breaking = declaration(upgrade: .coordinatedMaintenance)
        XCTAssertThrowsError(try breaking.requireRollingUpgrade(from: old))

        let unknownProfile = declaration(semanticProfile: "tractanda.peer-exchange.v3")
        XCTAssertNoThrow(try unknownProfile.validate())
        XCTAssertThrowsError(try unknownProfile.requireRollingUpgrade(from: old))

        let oldEmbedding = try XCTUnwrap(old.embedding)
        let changedEmbedding = try JSONDecoder().decode(
            EmbeddingPayload.self,
            from: encodedObject(
                {
                    var value = try jsonObject(JSONEncoder().encode(oldEmbedding))
                    value["modelRevision"] = "changed-model-recipe"
                    return value
                }()))
        XCTAssertThrowsError(try declaration(embedding: changedEmbedding).requireRollingUpgrade(from: old))

        let oldDocument = try XCTUnwrap(old.documentExtraction)
        let changedDocument = try JSONDecoder().decode(
            DocumentExtractionPayload.self,
            from: encodedObject(
                {
                    var value = try jsonObject(JSONEncoder().encode(oldDocument))
                    value["runtimePatchSHA256"] = String(repeating: "b", count: 64)
                    return value
                }()))
        XCTAssertThrowsError(try declaration(document: changedDocument).requireRollingUpgrade(from: old))
    }

    func testPayloadCommitmentBindsDigestVersionArchitectureAndAllBundledRecipes() throws {
        let value = declaration()
        let manifest = BundleManifest(
            version: value.version, platform: "linux", arch: value.arch, files: [],
            embedding: value.embedding, documentExtraction: value.documentExtraction,
            canonicalFormats: value.canonicalFormats)
        XCTAssertNoThrow(try value.requirePayload(manifest, digest: value.manifestSHA256))
        XCTAssertThrowsError(try value.requirePayload(manifest, digest: String(repeating: "b", count: 64)))

        let wrongVersion = BundleManifest(
            version: "0.1.0-poc.15", platform: "linux", arch: value.arch, files: [],
            embedding: value.embedding, documentExtraction: value.documentExtraction,
            canonicalFormats: value.canonicalFormats)
        XCTAssertThrowsError(try value.requirePayload(wrongVersion, digest: value.manifestSHA256))

        let wrongArch = BundleManifest(
            version: value.version, platform: "linux", arch: "arm64", files: [],
            embedding: value.embedding, documentExtraction: value.documentExtraction,
            canonicalFormats: value.canonicalFormats)
        XCTAssertThrowsError(try value.requirePayload(wrongArch, digest: value.manifestSHA256))

        let wrongFeatures = BundleManifest(
            version: value.version, platform: "linux", arch: value.arch, files: [],
            embedding: nil, documentExtraction: nil, canonicalFormats: value.canonicalFormats)
        XCTAssertThrowsError(try value.requirePayload(wrongFeatures, digest: value.manifestSHA256))

        let wrongSupport = BundleManifest(
            version: value.version, platform: "linux", arch: value.arch, files: [],
            embedding: value.embedding, documentExtraction: value.documentExtraction,
            canonicalFormats: .legacy)
        XCTAssertThrowsError(try value.requirePayload(wrongSupport, digest: value.manifestSHA256))
    }

    func testOlderDebCannotOpenCurrentCanonicalRequirement() throws {
        let current = CanonicalFormatSupport.current
        let requirement = CanonicalReaderRequirement(
            storeID: storeID, minimumReaderLevel: current.writerLevel,
            recordFormats: current.write, capabilities: current.writeCapabilities)
        XCTAssertNoThrow(try current.require(requirement))

        let olderPackage = declaration(support: .legacy, version: "0.1.0-poc.14")
        XCTAssertThrowsError(try olderPackage.canonicalFormats.require(requirement))
        XCTAssertThrowsError(try olderPackage.requireRollingUpgrade(from: declaration()))
    }
}
