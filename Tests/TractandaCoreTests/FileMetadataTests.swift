import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class FileMetadataTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-metadata-\(Identifier.make())")
    }

    private func assertCode(_ code: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual((error as? TractandaError)?.code, code, "\(error)")
        }
    }

    func testLstatMetadataDistinguishesDirectoryFileAndSymlink() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("record")
        try Data("metadata".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let directoryMetadata = try FileMetadata.read(at: root)
        let fileMetadata = try FileMetadata.read(at: file)
        let linkMetadata = try FileMetadata.read(at: link)
        XCTAssertEqual(directoryMetadata.type, .directory)
        XCTAssertEqual(fileMetadata.type, .regular)
        XCTAssertEqual(linkMetadata.type, .symbolicLink)
        XCTAssertEqual(fileMetadata.uid, tractanda_uid())
        XCTAssertEqual(fileMetadata.mode & 0o777, 0o640)
        XCTAssertEqual(fileMetadata.size, 8)
        XCTAssertNotEqual(linkMetadata.inode, fileMetadata.inode)
    }

    func testMetadataRejectsMissingAndNULPaths() {
        XCTAssertThrowsError(try FileMetadata.read(path: "/tmp/tractanda-metadata-missing")) { error in
            guard case .some(.posix(let code)) = error as? FileMetadataError else {
                return XCTFail("Expected POSIX metadata error, got \(error)")
            }
            XCTAssertEqual(code, ENOENT)
        }
        XCTAssertThrowsError(try FileMetadata.read(path: "bad\0path")) { error in
            XCTAssertEqual(error as? FileMetadataError, .invalidPath)
        }
        XCTAssertThrowsError(try FileMetadata.read(path: "")) { error in
            XCTAssertEqual(error as? FileMetadataError, .invalidPath)
        }
    }

    func testPrivateConfigurationAndStoreStillRejectUnsafePaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("connections.json")
        try Data("{}".utf8).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configuration.path)
        assertCode("privateConfiguration") {
            try PrivateConfiguration.validate(configuration, directory: false)
        }

        let link = root.appendingPathComponent("configuration-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: configuration)
        assertCode("privateConfiguration") { try PrivateConfiguration.validate(link, directory: false) }

        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path)
        assertCode("unsafeStore") { _ = try ItemStore(root: store) }
    }

    func testStoreOpensAndRebuildsWithPOSIXMetadata() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        try store?.rebuildIndex()
        store = nil
        let reopened = try ItemStore(root: root)
        try reopened.rebuildIndex()
    }
}
