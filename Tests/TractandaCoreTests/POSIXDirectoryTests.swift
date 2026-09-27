import Foundation
import XCTest

@testable import TractandaCore

final class POSIXDirectoryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tractanda-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWithEntriesVisitsNamesOneAtATime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<24 {
            try Data().write(to: directory.appendingPathComponent("entry-\(index)"))
        }

        var visited = 0
        try POSIXDirectory.withEntries(at: directory) { name in
            XCTAssertTrue(name.hasPrefix("entry-"))
            visited += 1
            return true
        }

        XCTAssertEqual(visited, 24)
    }

    func testWithEntriesStopsWhenBodyReturnsFalse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<4 {
            try Data().write(to: directory.appendingPathComponent("entry-\(index)"))
        }

        var visited: [String] = []
        try POSIXDirectory.withEntries(at: directory) { name in
            visited.append(name)
            return false
        }

        XCTAssertEqual(visited.count, 1)
    }

    func testWithEntriesPropagatesBodyErrorAndCanReopenDirectory() throws {
        enum Stop: Error, Equatable { case requested }

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("entry"))

        XCTAssertThrowsError(
            try POSIXDirectory.withEntries(at: directory) { _ in
                throw Stop.requested
            }
        ) { error in
            XCTAssertEqual(error as? Stop, .requested)
        }

        var visited = 0
        try POSIXDirectory.withEntries(at: directory) { _ in
            visited += 1
            return true
        }
        XCTAssertEqual(visited, 1)
    }

    func testWithEntriesOpenFailurePropagates() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("regular-file")
        try Data().write(to: file)

        XCTAssertThrowsError(try POSIXDirectory.withEntries(at: file) { _ in true })
    }

    func testWithEntriesPropagatesCancellationBeforeReadingNames() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("entry"))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try POSIXDirectory.withEntries(at: directory) { _ in true }
        }

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
