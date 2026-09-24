import Foundation
import XCTest

@testable import TractandaCore

final class ExternalIndexDirectoryTests: XCTestCase {
    private static let bindingName = ".tractanda-index-binding.json"
    private static let identityName = ".tractanda-store-identity.json"

    private func directory(_ name: String = "external-index") -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "\(name)-\(Identifier.make())")
    }

    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    private func bindingURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(Self.bindingName)
    }

    private func identityURL(_ root: URL) -> URL {
        root.appendingPathComponent(Self.identityName)
    }

    private func binding(_ directory: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: bindingURL(directory))) as? [String: Any])
    }

    private func writeBinding(_ value: [String: Any], to directory: URL) throws {
        try PrivateConfiguration.write(
            JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: bindingURL(directory))
    }

    func testExternalDirectoryKeepsCanonicalHistoryAndConfigurationWhenRecreated() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        let revision = try store!.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("retained")], operationID: "note")
        )
        .revision
        let configuration = SemanticConfiguration(
            operationID: "semantic", endpoint: "http://127.0.0.1:11434/v1/embeddings",
            model: "test", modelRevision: "one", dimensions: 2, documentPrefix: "d: ", queryPrefix: "q: ")
        _ = try SemanticConfigurationStore(storeRoot: root).configure(
            configuration, expectedConfigurationID: nil)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: external.appendingPathComponent("items.sqlite").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("index/items.sqlite").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent(".tractanda-index-binding.json").path))
        let canonicalIdentity = try Data(contentsOf: identityURL(root))
        XCTAssertNotNil(
            UUID(
                uuidString: try XCTUnwrap(
                    (try JSONSerialization.jsonObject(with: canonicalIdentity) as? [String: Any])?["storeID"]
                        as? String))?.version1Components)
        store = nil

        try FileManager.default.removeItem(at: external)
        store = try ItemStore(root: root, indexDirectory: external)
        XCTAssertEqual(try Data(contentsOf: identityURL(root)), canonicalIdentity)
        XCTAssertEqual(try store!.get(revision.itemID).revisionID, revision.revisionID)
        XCTAssertEqual(try store!.history(revision.itemID).count, 1)
        XCTAssertEqual(
            try SemanticConfigurationStore(storeRoot: root).load()?.configurationID,
            configuration.configurationID)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: external.appendingPathComponent("items.sqlite").path))
    }

    func testCanonicalAndExternalWriterLocksAreIndependent() throws {
        let root = directory("canonical")
        let otherRoot = directory("other")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
            try? FileManager.default.removeItem(at: external)
        }
        var first: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        assertCode("storeBusy") { _ = try ItemStore(root: root) }
        assertCode("indexBusy") { _ = try ItemStore(root: otherRoot, indexDirectory: external) }
        XCTAssertNotNil(try first?.commit(CommitRequest(classID: "Item", operationID: "still-usable")))
        first = nil

        assertCode("indexBindingMismatch") { _ = try ItemStore(root: otherRoot, indexDirectory: external) }
        let reopened = try ItemStore(root: root, indexDirectory: external)
        XCTAssertEqual(try reopened.candidates().count, 1)
    }

    func testExternalV2BindingIgnoresChangedDeviceDiagnostic() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        let initial = try binding(external)
        XCTAssertEqual(initial["formatVersion"] as? Int, 2)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(initial["storeID"] as? String))?.version1Components)
        store = nil

        var stale = initial
        stale["canonicalDevice"] = (try FileMetadata.read(at: root)).device &+ 1
        try writeBinding(stale, to: external)

        store = try ItemStore(root: root, indexDirectory: external)
        let refreshed = try binding(external)
        XCTAssertEqual(refreshed["canonicalDevice"] as? UInt64, try FileMetadata.read(at: root).device)
    }

    func testExternalV2BindingFollowsCanonicalStoreMoveAndCopyRestore() throws {
        let root = directory("canonical")
        let moved = directory("moved")
        let restored = directory("restored")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: restored)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        let original = try binding(external)
        let revision = try store!.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("retained")], operationID: "move")
        )
        .revision
        let identity = try Data(contentsOf: identityURL(root))
        store = nil

        try FileManager.default.moveItem(at: root, to: moved)
        store = try ItemStore(root: moved, indexDirectory: external)
        XCTAssertEqual(try store!.get(revision.itemID).revisionID, revision.revisionID)
        XCTAssertEqual(try Data(contentsOf: identityURL(moved)), identity)
        var refreshed = try binding(external)
        XCTAssertEqual(refreshed["canonicalPath"] as? String, moved.path)
        XCTAssertEqual(refreshed["canonicalInode"] as? UInt64, try FileMetadata.read(at: moved).inode)
        store = nil

        try FileManager.default.copyItem(at: moved, to: restored)
        store = try ItemStore(root: restored, indexDirectory: external)
        XCTAssertEqual(try store!.get(revision.itemID).revisionID, revision.revisionID)
        XCTAssertEqual(try Data(contentsOf: identityURL(restored)), identity)
        refreshed = try binding(external)
        XCTAssertEqual(refreshed["canonicalPath"] as? String, restored.path)
        XCTAssertEqual(refreshed["canonicalInode"] as? UInt64, try FileMetadata.read(at: restored).inode)
        XCTAssertNotEqual(
            try FileMetadata.read(at: moved).inode, try FileMetadata.read(at: restored).inode)
        XCTAssertEqual(refreshed["storeID"] as? String, original["storeID"] as? String)
    }

    func testExternalV2BindingRejectsChangedStoreIdentityAtSameLocation() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        let original = try binding(external)
        store = nil

        var changedIdentity = original
        changedIdentity["storeID"] = try UUID.makeVersion1().uuidString.lowercased()
        try writeBinding(changedIdentity, to: external)
        assertCode("indexBindingMismatch") { _ = try ItemStore(root: root, indexDirectory: external) }
    }

    func testCanonicalIdentityIsCreatedForDefaultIndexAndRejectsUnsafeIdentityFiles() throws {
        let root = directory("canonical")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        XCTAssertNotNil(store)
        let identity = identityURL(root)
        let identityData = try Data(contentsOf: identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: identity.path))
        XCTAssertNotNil(
            UUID(
                uuidString: try XCTUnwrap(
                    (try JSONSerialization.jsonObject(with: identityData) as? [String: Any])?["storeID"]
                        as? String))?.version1Components)
        store = nil

        try FileManager.default.removeItem(at: identity)
        let target = root.appendingPathComponent("identity-target")
        try PrivateConfiguration.write(Data("{}".utf8), to: target)
        try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: target)
        assertCode("privateConfiguration") { _ = try ItemStore(root: root) }

        try FileManager.default.removeItem(at: identity)
        try identityData.write(to: identity)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: identity.path)
        assertCode("privateConfiguration") { _ = try ItemStore(root: root) }
    }

    func testBoundV2IndexFailsClosedWhenCanonicalIdentityIsMissing() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        store = nil
        try FileManager.default.removeItem(at: identityURL(root))

        assertCode("indexBindingMismatch") { _ = try ItemStore(root: root, indexDirectory: external) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: identityURL(root).path))
    }

    func testExactV1BindingMigratesButMismatchRequiresRebuild() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        XCTAssertNotNil(store)
        store = nil
        let metadata = try FileMetadata.read(at: root)
        let legacy: [String: Any] = [
            "formatVersion": 1, "canonicalPath": root.path, "canonicalDevice": metadata.device,
            "canonicalInode": metadata.inode,
        ]
        try writeBinding(legacy, to: external)
        try FileManager.default.removeItem(at: identityURL(root))

        store = try ItemStore(root: root, indexDirectory: external)
        XCTAssertEqual((try binding(external))["formatVersion"] as? Int, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: identityURL(root).path))
        store = nil

        try FileManager.default.removeItem(at: identityURL(root))
        var staleLegacy = legacy
        staleLegacy["canonicalDevice"] = metadata.device &+ 1
        try writeBinding(staleLegacy, to: external)
        assertCode("indexBindingMismatch") { _ = try ItemStore(root: root, indexDirectory: external) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: identityURL(root).path))
    }

    func testUnsafeOrUnboundExternalPathsDoNotDamageExistingStore() throws {
        let originalRoot = directory("original")
        let rejectedRoot = directory("rejected")
        let linked = directory("linked")
        let nonPrivate = directory("nonprivate")
        let unbound = directory("unbound")
        defer {
            for url in [originalRoot, rejectedRoot, linked, nonPrivate, unbound] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        var original: ItemStore? = try ItemStore(root: originalRoot)
        let record = try original!.commit(
            CommitRequest(classID: "Item", changes: ["subject": .text("safe")], operationID: "safe")
        )
        .revision

        let target = directory("link-target")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        assertCode("unsafeIndexDirectory") { _ = try ItemStore(root: rejectedRoot, indexDirectory: linked) }

        try FileManager.default.createDirectory(
            at: nonPrivate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonPrivate.path)
        assertCode("unsafeStore") { _ = try ItemStore(root: rejectedRoot, indexDirectory: nonPrivate) }

        try FileManager.default.createDirectory(
            at: unbound, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let foreign = unbound.appendingPathComponent("foreign.sqlite")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreign.path)
        assertCode("indexBindingRequired") { _ = try ItemStore(root: rejectedRoot, indexDirectory: unbound) }

        original = nil
        assertCode("invalidIndexDirectory") {
            _ = try ItemStore(
                root: originalRoot, indexDirectory: originalRoot.appendingPathComponent("items/cache"))
        }
        original = try ItemStore(root: originalRoot)
        XCTAssertEqual(try original!.get(record.itemID).revisionID, record.revisionID)
        XCTAssertEqual(try original!.candidates(text: "safe").map(\.itemID), [record.itemID])
    }
}
