import Foundation
import XCTest

@testable import TractandaCore

final class ExternalIndexDirectoryTests: XCTestCase {
    private func directory(_ name: String = "external-index") -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "\(name)-\(Identifier.make())")
    }

    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    func testExternalDirectoryKeepsCanonicalHistoryAndConfigurationWhenRecreated() throws {
        let root = directory("canonical")
        let external = directory("derived")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        var store: ItemStore? = try ItemStore(root: root, indexDirectory: external)
        let revision = try store!.commit(
            CommitRequest(classID: "NoteItem", changes: ["subject": .text("retained")], operationID: "note")
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
        store = nil

        try FileManager.default.removeItem(at: external)
        store = try ItemStore(root: root, indexDirectory: external)
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
        XCTAssertNotNil(try first?.commit(CommitRequest(classID: "NoteItem", operationID: "still-usable")))
        first = nil

        assertCode("indexBindingMismatch") { _ = try ItemStore(root: otherRoot, indexDirectory: external) }
        let reopened = try ItemStore(root: root, indexDirectory: external)
        XCTAssertEqual(try reopened.candidates().count, 1)
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
            CommitRequest(classID: "NoteItem", changes: ["subject": .text("safe")], operationID: "safe")
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
