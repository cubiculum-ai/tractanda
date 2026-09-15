import Foundation
import XCTest

@testable import TractandaTUI

final class ViewWorkspacePreferencesTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func id() -> String { UUID().uuidString.lowercased() }

    func testMissingPreferencesAreAnEmptyFirstRun() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            try ViewWorkspacePreferences.load(from: root.appendingPathComponent("missing/views.json")),
            ViewWorkspacePreferences())
    }

    func testRoundTripAndPrivateModes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        let value = ViewWorkspacePreferences(pinnedViewIDs: [id()])
        try value.save(to: url)
        XCTAssertEqual(try ViewWorkspacePreferences.load(from: url), value)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber)
                .intValue & 0o077, 0)
    }

    func testPreviewHeightMigratesAndTemporarilyClampsWithoutLosingRequest() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        try Data(
            #"{"version":3,"pinnedViewIDs":[],"categoryConnectedTree":false,"categoryRightMode":"items","categorySplitWidth":0.333,"selectorSplitWidth":0.333,"previewVisible":true}"#
                .utf8
        ).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try ViewWorkspacePreferences.load(from: url).previewContentHeight, 3)
        XCTAssertEqual(ItemPreviewPresentation.effectiveContentRows(preferred: 40, terminalRows: 24), 8)
        XCTAssertEqual(ItemPreviewPresentation.effectiveContentRows(preferred: 40, terminalRows: 60), 40)
    }

    func testInvalidValuesAndLargeFilesAreRejected() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        for data in [
            #"{"version":5,"pinnedViewIDs":[]}"#,
            #"{"version":1,"pinnedViewIDs":["bad"]}"#,
            #"{"version":1,"pinnedViewIDs":["00000000-0000-0000-0000-000000000000","00000000-0000-0000-0000-000000000000"]}"#,
        ] {
            try Data(data.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: url))
        }
        try Data(repeating: 0, count: 1_048_577).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: url))
        XCTAssertThrowsError(
            try ViewWorkspacePreferences(pinnedViewIDs: Array(repeating: id(), count: 1_025)).save(to: url))
    }

    func testUnsafePathsAndFailedSavePreserveOriginal() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        try ViewWorkspacePreferences(pinnedViewIDs: [id()]).save(to: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ViewWorkspacePreferences(pinnedViewIDs: ["bad"]).save(to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: url))
    }

    func testSymlinksAndPublicFilesNeverRedirectReadsOrWrites() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original.json")
        let value = ViewWorkspacePreferences(pinnedViewIDs: [id()])
        try value.save(to: target)
        let original = try Data(contentsOf: target)
        for (name, destination) in [
            ("linked.json", target), ("dangling.json", root.appendingPathComponent("absent.json")),
        ] {
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: link))
            XCTAssertThrowsError(try value.save(to: link))
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType,
                .typeSymbolicLink)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("absent.json").path))
        let parentLink = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        XCTAssertThrowsError(
            try ViewWorkspacePreferences.load(from: parentLink.appendingPathComponent("original.json")))
        XCTAssertThrowsError(try value.save(to: parentLink.appendingPathComponent("original.json")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: target))
        XCTAssertThrowsError(try value.save(to: target))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testInvalidWritesKeepTheLastValidPreferenceFile() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("views.json")
        try ViewWorkspacePreferences(pinnedViewIDs: [id()]).save(to: url)
        let original = try Data(contentsOf: url)
        let duplicate = id()
        for invalid in [
            ViewWorkspacePreferences(version: 5),
            ViewWorkspacePreferences(pinnedViewIDs: [duplicate, duplicate]),
            ViewWorkspacePreferences(pinnedViewIDs: (0..<1025).map { _ in id() }),
        ] {
            XCTAssertThrowsError(try invalid.save(to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
            try JSONEncoder().encode(invalid).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertThrowsError(try ViewWorkspacePreferences.load(from: url))
            try original.write(to: url)
        }
    }
}
