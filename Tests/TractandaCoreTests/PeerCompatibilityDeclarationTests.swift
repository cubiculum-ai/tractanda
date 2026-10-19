import Foundation
import XCTest

@testable import TractandaCore

final class PeerCompatibilityDeclarationTests: XCTestCase {
    private let storeID = "00000000-0000-1000-8000-000000000101"
    private let otherStoreID = "00000000-0000-1000-8000-000000000102"
    private let capability = "tractanda.test.peer-capability.v1"

    private func support(
        readerLevel: Int = 14,
        writerLevel: Int = 14,
        read: [Int] = [1, 2],
        write: [Int] = [2],
        capabilities: [String]? = nil,
        writeCapabilities: [String]? = nil
    ) -> CanonicalFormatSupport {
        let caps = (capabilities ?? [capability]).sorted()
        return CanonicalFormatSupport(
            readerLevel: readerLevel,
            writerLevel: writerLevel,
            read: read,
            write: write,
            capabilities: caps,
            writeCapabilities: (writeCapabilities ?? caps).sorted())
    }

    private func requirement(
        storeID: String? = nil,
        minimumReaderLevel: Int = 13,
        recordFormats: [Int] = [1, 2],
        capabilities: [String]? = nil
    ) -> CanonicalReaderRequirement {
        CanonicalReaderRequirement(
            storeID: storeID ?? self.storeID,
            minimumReaderLevel: minimumReaderLevel,
            recordFormats: recordFormats,
            capabilities: capabilities ?? [capability])
    }

    private func declaration(
        support: CanonicalFormatSupport? = nil,
        requirement: CanonicalReaderRequirement? = nil
    ) throws -> PeerCompatibilityDeclaration {
        try PeerCompatibilityDeclaration(
            support: support ?? self.support(),
            requirement: requirement ?? self.requirement())
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func duplicateTopLevelProfile(_ data: Data) throws -> Data {
        let canonical = String(decoding: data, as: UTF8.self)
        let start = try XCTUnwrap(canonical.range(of: "{\n"))
        let duplicate = canonical.replacingCharacters(
            in: start, with: "{\n  \"profile\": \"tractanda.peer-exchange.v2\",\n")
        return Data(duplicate.utf8)
    }

    func testCompatibleDeclarationsRoundTripAndPermitDifferentSupport() throws {
        let first = try declaration()
        let second = try declaration(support: support(writerLevel: 13))

        XCTAssertNotEqual(first.support, second.support)
        XCTAssertNoThrow(try first.requireCompatible(with: second))
        XCTAssertNoThrow(try second.requireCompatible(with: first))

        let bytes = try first.encoded()
        XCTAssertLessThanOrEqual(bytes.count, PeerCompatibilityDeclaration.maximumBytes)
        XCTAssertEqual(try PeerCompatibilityDeclaration.decode(bytes), first)
    }

    func testRejectsInsufficientReaderLevelFormatsAndCapabilities() throws {
        let required = try declaration()
        let lowerReader = try declaration(
            support: support(readerLevel: 12, writerLevel: 12),
            requirement: requirement(minimumReaderLevel: 12))
        XCTAssertThrowsError(try lowerReader.requireCompatible(with: required))

        let missingFormat = try declaration(
            support: support(readerLevel: 14, writerLevel: 14, read: [1], write: [1]),
            requirement: requirement(minimumReaderLevel: 1, recordFormats: [1]))
        XCTAssertThrowsError(try missingFormat.requireCompatible(with: required))

        let missingCapability = try declaration(
            support: support(capabilities: [], writeCapabilities: []),
            requirement: requirement(capabilities: []))
        XCTAssertThrowsError(try missingCapability.requireCompatible(with: required))
    }

    func testRejectsPossibleWriterFormatsAndCapabilitiesTheOtherCannotRead() throws {
        let reader = try declaration(
            support: support(
                readerLevel: 3, writerLevel: 2, read: [1, 2], write: [2]),
            requirement: requirement(minimumReaderLevel: 2, recordFormats: [1, 2]))
        let formatWriter = try declaration(
            support: support(
                readerLevel: 3, writerLevel: 3, read: [1, 2, 3], write: [3]),
            requirement: requirement(minimumReaderLevel: 2, recordFormats: [1, 2]))
        XCTAssertThrowsError(try reader.requireCompatible(with: formatWriter))

        let capabilityReader = try declaration(
            support: support(
                capabilities: [capability], writeCapabilities: [capability]))
        let capabilityWriter = try declaration(
            support: support(
                capabilities: [capability, "tractanda.test.new-writer-semantics.v1"],
                writeCapabilities: ["tractanda.test.new-writer-semantics.v1"]))
        XCTAssertThrowsError(try capabilityReader.requireCompatible(with: capabilityWriter))
    }

    func testRejectsDifferentStoresAndSemanticProfile() throws {
        let local = try declaration()
        let otherStore = try declaration(requirement: requirement(storeID: otherStoreID))
        XCTAssertThrowsError(try local.requireCompatible(with: otherStore))

        var object = try jsonObject(local.encoded())
        object["profile"] = "tractanda.peer-exchange.v3"
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(encodedObject(object)))
    }

    func testStrictCanonicalDecodeRejectsUnknownDuplicateMalformedAndOversizedInput() throws {
        let bytes = try declaration().encoded()

        var unknownTop = try jsonObject(bytes)
        unknownTop["future"] = true
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(encodedObject(unknownTop)))

        var unknownRequirement = try jsonObject(bytes)
        var requirementObject = try XCTUnwrap(unknownRequirement["requirement"] as? [String: Any])
        requirementObject["future"] = true
        unknownRequirement["requirement"] = requirementObject
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(encodedObject(unknownRequirement)))

        var unknownSupport = try jsonObject(bytes)
        var supportObject = try XCTUnwrap(unknownSupport["support"] as? [String: Any])
        supportObject["future"] = true
        unknownSupport["support"] = supportObject
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(encodedObject(unknownSupport)))

        var malformedSupport = try jsonObject(bytes)
        var malformedSupportObject = try XCTUnwrap(malformedSupport["support"] as? [String: Any])
        malformedSupportObject.removeValue(forKey: "writeCapabilities")
        malformedSupport["support"] = malformedSupportObject
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(encodedObject(malformedSupport)))

        let duplicate = try duplicateTopLevelProfile(bytes)
        XCTAssertNotEqual(duplicate, bytes)
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(duplicate))

        let canonical = String(decoding: bytes, as: UTF8.self)
        let noncanonical = Data(canonical.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(noncanonical))
        XCTAssertThrowsError(try PeerCompatibilityDeclaration.decode(Data(repeating: 32, count: 65_537)))
    }

    func testAcknowledgementBindsExactCanonicalDeclarationDigest() throws {
        let first = try declaration()
        let other = try declaration(support: support(writerLevel: 13))
        let acknowledgement = try PeerCompatibilityAcknowledgement(declaration: first)
        let bytes = try acknowledgement.encoded()

        XCTAssertEqual(acknowledgement.profile, PeerCompatibilityDeclaration.semanticProfile)
        XCTAssertEqual(acknowledgement.declarationSHA256.count, 64)
        XCTAssertEqual(
            acknowledgement.declarationSHA256,
            AuthorityRecordCodec.sha256(try first.encoded()))
        XCTAssertLessThanOrEqual(bytes.count, 4096)
        XCTAssertEqual(try PeerCompatibilityAcknowledgement.decode(bytes), acknowledgement)
        XCTAssertNoThrow(try acknowledgement.matches(declaration: first))
        XCTAssertThrowsError(try acknowledgement.matches(declaration: other))
    }

    func testAcknowledgementDecodeRejectsWrongShapeDigestAndOversize() throws {
        let acknowledgement = try PeerCompatibilityAcknowledgement(declaration: declaration())
        let bytes = try acknowledgement.encoded()

        var unknown = try jsonObject(bytes)
        unknown["future"] = true
        XCTAssertThrowsError(try PeerCompatibilityAcknowledgement.decode(encodedObject(unknown)))

        var wrongProfile = try jsonObject(bytes)
        wrongProfile["profile"] = "tractanda.peer-exchange.v3"
        XCTAssertThrowsError(try PeerCompatibilityAcknowledgement.decode(encodedObject(wrongProfile)))

        var malformedDigest = try jsonObject(bytes)
        malformedDigest["declarationSHA256"] = String(repeating: "A", count: 64)
        XCTAssertThrowsError(try PeerCompatibilityAcknowledgement.decode(encodedObject(malformedDigest)))

        XCTAssertThrowsError(try PeerCompatibilityAcknowledgement.decode(duplicateTopLevelProfile(bytes)))
        XCTAssertThrowsError(try PeerCompatibilityAcknowledgement.decode(Data(repeating: 32, count: 4097)))
    }
}
