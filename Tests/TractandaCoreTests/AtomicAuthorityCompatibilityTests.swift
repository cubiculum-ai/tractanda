import CTractandaPlatform
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AtomicAuthorityCompatibilityTests: XCTestCase {
    private func id(_ n: Int) -> String { String(format: "%08x-0000-1000-8000-000000000001", n) }
    private struct Identity: Codable {
        let formatVersion: Int
        let storeID: String
    }
    private final class Fixture {
        let root: URL
        let storeID: String
        let prior: CanonicalReaderRequirement
        let writer: Int32
        init(
            capabilities: [String] = AtomicAuthorityCompatibility.support.capabilities.filter {
                $0 != AtomicAuthorityFormat.profile
            }, floor: Int = 14
        ) throws {
            try AttachmentFixtureCapacity.requireFree()
            root = try GuardedFixtureDirectory.create(
                prefix: "atomic-compatibility-", source: #filePath, test: #function)
            storeID = try UUID.makeVersion1().uuidString.lowercased()
            prior = .init(
                storeID: storeID, minimumReaderLevel: floor, recordFormats: [1, 2],
                capabilities: capabilities.sorted())
            let identity = try JSON.encode(Identity(formatVersion: 1, storeID: storeID))
            try identity.write(to: root.appendingPathComponent(".tractanda-store-identity.json"))
            try JSON.encode(prior).write(to: root.appendingPathComponent(CanonicalReaderRequirement.fileName))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: root.appendingPathComponent(".tractanda-store-identity.json").path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: root.appendingPathComponent(CanonicalReaderRequirement.fileName).path)
            writer = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            guard writer >= 0 else {
                throw TractandaError("fixture", "Cannot acquire real fixture writer flock")
            }
        }
        var marker: URL { root.appendingPathComponent(CanonicalReaderRequirement.fileName) }
        func activate(support: CanonicalFormatSupport = AtomicAuthorityCompatibility.support) throws
            -> CanonicalReaderRequirement
        {
            guard let current = try CanonicalReaderRequirement.load(root: root, ownerUID: tractanda_uid())
            else {
                throw TractandaError("fixture", "Existing canonical requirement is required")
            }
            return try CanonicalReaderRequirement.transitionToAtomicAuthority(
                root: root, ownerUID: tractanda_uid(), writerDescriptor: writer,
                expectedRequirement: current,
                expectedRequirementSHA256: AuthorityRecordCodec.sha256(Data(contentsOf: marker)),
                support: support)
        }
        deinit {
            tractanda_unlock(writer)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testDeclaredSupportStillRequiresExplicitFloor15Activation() throws {
        XCTAssertEqual(CanonicalFormatSupport.current.readerLevel, 18)
        XCTAssertEqual(CanonicalFormatSupport.current.writerLevel, 18)
        XCTAssertTrue(
            CanonicalFormatSupport.current.capabilities.contains(AtomicAuthorityCompatibility.capability))
        let support = AtomicAuthorityCompatibility.support
        XCTAssertEqual(support.readerLevel, 15)
        XCTAssertEqual(support.writerLevel, 15)
        XCTAssertEqual(support.read, [1, 2])
        XCTAssertEqual(support.write, [2])
        XCTAssertTrue(support.capabilities.contains(AtomicAuthorityFormat.profile))
        XCTAssertTrue(Set(support.capabilities).isSubset(of: CanonicalFormatSupport.current.capabilities))
        XCTAssertNoThrow(try support.validate())
        XCTAssertThrowsError(
            try CanonicalFormatSupport(
                readerLevel: 14, writerLevel: 14, read: [1, 2], write: [2],
                capabilities: [AtomicAuthorityCompatibility.capability]
            ).validate())
        XCTAssertThrowsError(
            try CanonicalReaderRequirement(
                storeID: id(1), minimumReaderLevel: 14, recordFormats: [1, 2],
                capabilities: [AtomicAuthorityCompatibility.capability]
            ).validate())
        let readOnly = CanonicalFormatSupport(
            readerLevel: 15, writerLevel: 14, read: [1, 2], write: [2],
            capabilities: support.capabilities,
            writeCapabilities: support.writeCapabilities.filter {
                $0 != AtomicAuthorityFormat.profile
            })
        XCTAssertNoThrow(try readOnly.validate())
        XCTAssertThrowsError(try AtomicAuthorityCompatibility.requireWriter(readOnly))
    }

    func testExplicitTransitionPreservesRequirementsRejectsOldReaderAndRetriesWithoutRewrite() throws {
        let f = try Fixture()
        let before = try Data(contentsOf: f.marker)
        let target = try f.activate()
        XCTAssertEqual(target.storeID, f.storeID)
        XCTAssertEqual(target.minimumReaderLevel, 15)
        XCTAssertEqual(target.recordFormats, f.prior.recordFormats)
        XCTAssertEqual(
            target.capabilities,
            Set(f.prior.capabilities + [AtomicAuthorityCompatibility.capability]).sorted())
        XCTAssertNotEqual(try Data(contentsOf: f.marker), before)
        XCTAssertThrowsError(
            try CanonicalFormatSupport(
                readerLevel: 14, writerLevel: 14, read: [1, 2], write: [2],
                capabilities: f.prior.capabilities, writeCapabilities: f.prior.capabilities
            ).require(target))
        XCTAssertNoThrow(try AtomicAuthorityCompatibility.support.require(target))
        let metadata = try FileMetadata.read(at: f.marker)
        XCTAssertEqual(metadata.mode & 0o777, 0o600)
        XCTAssertEqual(try f.activate(), target)
        XCTAssertEqual(try FileMetadata.read(at: f.marker), metadata)
        XCTAssertNoThrow(
            try CanonicalReaderRequirement.beforeAtomicAuthorityPublication(
                root: f.root, ownerUID: tractanda_uid(), support: AtomicAuthorityCompatibility.support))
    }

    func testPublicationGuardNeverCreatesOrRaisesMarker() throws {
        let f = try Fixture()
        let old = try Data(contentsOf: f.marker)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.beforeAtomicAuthorityPublication(
                root: f.root, ownerUID: tractanda_uid(), support: AtomicAuthorityCompatibility.support))
        XCTAssertEqual(try Data(contentsOf: f.marker), old)
        try FileManager.default.removeItem(at: f.marker)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.beforeAtomicAuthorityPublication(
                root: f.root, ownerUID: tractanda_uid(), support: AtomicAuthorityCompatibility.support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.marker.path))
    }

    func testExactPriorDigestValueAndWholeTargetSupportAreRequired() throws {
        let f = try Fixture(
            capabilities: AtomicAuthorityCompatibility.support.capabilities.filter {
                $0 != AtomicAuthorityFormat.profile
            } + ["tractanda.future-test.v1"])
        let before = try Data(contentsOf: f.marker)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
        let complete = CanonicalFormatSupport(
            readerLevel: 15, writerLevel: 15, read: [1, 2], write: [2],
            capabilities: Set(f.prior.capabilities + [AtomicAuthorityCompatibility.capability]).sorted(),
            writeCapabilities: AtomicAuthorityCompatibility.support.writeCapabilities)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.transitionToAtomicAuthority(
                root: f.root, ownerUID: tractanda_uid(), writerDescriptor: f.writer,
                expectedRequirement: f.prior,
                expectedRequirementSHA256: String(repeating: "f", count: 64), support: complete))
        let wrong = CanonicalReaderRequirement(
            storeID: f.storeID, minimumReaderLevel: 13, recordFormats: [1, 2],
            capabilities: f.prior.capabilities)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.transitionToAtomicAuthority(
                root: f.root, ownerUID: tractanda_uid(), writerDescriptor: f.writer,
                expectedRequirement: wrong,
                expectedRequirementSHA256: AuthorityRecordCodec.sha256(before), support: complete))
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
        let raised = try f.activate(support: complete)
        XCTAssertTrue(raised.capabilities.contains("tractanda.future-test.v1"))
    }

    func testTransitionRejectsDuplicatePriorFieldsWithoutChangingLegacyLoadBehavior() throws {
        let f = try Fixture()
        let original = try XCTUnwrap(String(data: Data(contentsOf: f.marker), encoding: .utf8))
        let duplicated = original.replacingOccurrences(
            of: "{\n", with: "{\n  \"minimumReaderLevel\" : 14,\n", options: .anchored)
        XCTAssertNotEqual(duplicated, original)
        let bytes = Data(duplicated.utf8)
        try bytes.write(to: f.marker)
        XCTAssertEqual(chmod(f.marker.path, 0o600), 0)
        // Only the explicit transition gains strict canonical framing; historical reads are unchanged.
        XCTAssertEqual(try CanonicalReaderRequirement.load(root: f.root, ownerUID: tractanda_uid()), f.prior)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(try Data(contentsOf: f.marker), bytes)
    }

    func testRaisedMarkerMustStillFitExistingMetadataWindowBeforePersistence() throws {
        let capabilities = (0..<63).map { String(format: "%03d", $0) + String(repeating: "x", count: 125) }
        let f = try Fixture(capabilities: capabilities, floor: 1024)
        var selected: CanonicalReaderRequirement?
        for count in 1...1024 {
            let prior = CanonicalReaderRequirement(
                storeID: f.storeID, minimumReaderLevel: 1024,
                recordFormats: Array(1...count), capabilities: capabilities)
            let raised = CanonicalReaderRequirement(
                storeID: f.storeID, minimumReaderLevel: 1024,
                recordFormats: prior.recordFormats,
                capabilities: Set(capabilities + [AtomicAuthorityCompatibility.capability]).sorted())
            if try JSON.encode(prior).count <= 16 * 1024 && JSON.encode(raised).count > 16 * 1024 {
                selected = prior
                break
            }
        }
        let prior = try XCTUnwrap(selected)
        let before = try JSON.encode(prior)
        try before.write(to: f.marker)
        XCTAssertEqual(chmod(f.marker.path, 0o600), 0)
        let support = CanonicalFormatSupport(
            readerLevel: 1024, writerLevel: 1024,
            read: prior.recordFormats, write: [1],
            capabilities: Set(capabilities + [AtomicAuthorityCompatibility.capability]).sorted(),
            writeCapabilities: [AtomicAuthorityCompatibility.capability])
        XCTAssertThrowsError(try f.activate(support: support)) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
    }

    func testSuppliedSupportCannotLowerHigherReaderFloor() throws {
        let f = try Fixture(floor: 16)
        let before = try Data(contentsOf: f.marker)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
        let support = CanonicalFormatSupport(
            readerLevel: 16, writerLevel: 16, read: [1, 2], write: [2],
            capabilities: AtomicAuthorityCompatibility.support.capabilities,
            writeCapabilities: AtomicAuthorityCompatibility.support.writeCapabilities)
        XCTAssertEqual(try f.activate(support: support).minimumReaderLevel, 16)
    }

    func testWrongClosedAndReplacedWriterDescriptorsFailWithoutChangingMarker() throws {
        let f = try Fixture()
        let before = try Data(contentsOf: f.marker)
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.transitionToAtomicAuthority(
                root: f.root, ownerUID: tractanda_uid(), writerDescriptor: -1, expectedRequirement: f.prior,
                expectedRequirementSHA256: AuthorityRecordCodec.sha256(before),
                support: AtomicAuthorityCompatibility.support))
        let wrong = tractanda_lock(f.root.appendingPathComponent("different.lock").path)
        XCTAssertGreaterThanOrEqual(wrong, 0)
        defer { tractanda_unlock(wrong) }
        XCTAssertThrowsError(
            try CanonicalReaderRequirement.transitionToAtomicAuthority(
                root: f.root, ownerUID: tractanda_uid(), writerDescriptor: wrong,
                expectedRequirement: f.prior,
                expectedRequirementSHA256: AuthorityRecordCodec.sha256(before),
                support: AtomicAuthorityCompatibility.support))
        let path = f.root.appendingPathComponent(".writer.lock")
        try FileManager.default.moveItem(at: path, to: f.root.appendingPathComponent("retained-writer.lock"))
        try Data().write(to: path)
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
    }

    func testMarkerHardlinkSymlinkAndChangedStoreIDFailClosed() throws {
        let f = try Fixture()
        let before = try Data(contentsOf: f.marker)
        let hardlink = f.root.appendingPathComponent("linked-marker")
        XCTAssertEqual(link(f.marker.path, hardlink.path), 0)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(unlink(hardlink.path), 0)
        let original = f.root.appendingPathComponent("retained-marker")
        try FileManager.default.moveItem(at: f.marker, to: original)
        XCTAssertEqual(symlink(original.path, f.marker.path), 0)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(unlink(f.marker.path), 0)
        try FileManager.default.moveItem(at: original, to: f.marker)
        let identity = f.root.appendingPathComponent(".tractanda-store-identity.json")
        try JSON.encode(Identity(formatVersion: 1, storeID: id(99))).write(to: identity)
        XCTAssertEqual(chmod(identity.path, 0o600), 0)
        XCTAssertThrowsError(try f.activate())
        XCTAssertEqual(try Data(contentsOf: f.marker), before)
    }

    func testLegacyImmutableOriginalBytesDecodeIdenticallyAfterExplicitFloorTransition() throws {
        let f = try Fixture()
        let record = try AuthorityRecord(
            recordID: id(1), storeID: f.storeID, originReplicaID: id(2), kind: .bootstrap,
            actorPrincipal: "user:admin", createdAt: "2026-10-23T10:00:00Z",
            payload: [
                "initial": .boolean(true),
                "pages": .list([
                    .object(["recordID": .text(id(3)), "sha256": .text(String(repeating: "a", count: 64))])
                ]), "administrationPolicies": .list([]),
            ])
        let bytes = try AuthorityRecordCodec.encode(record)
        let original = try CanonicalAuthorityOriginal(bytes)
        _ = try f.activate()
        let retained = try CanonicalAuthorityOriginal(bytes)
        XCTAssertEqual(retained.bytes, bytes)
        XCTAssertEqual(retained.sha256, original.sha256)
        XCTAssertEqual(retained.payload, original.payload)
        if case .legacy(let decoded) = retained.payload {
            XCTAssertEqual(decoded.record, record)
        } else {
            XCTFail("An old immutable original must remain a legacy original")
        }
    }
}
