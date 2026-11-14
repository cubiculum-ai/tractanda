import Foundation
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class MemoryImportCommandTests: XCTestCase {
    private func run(_ args: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = try currentBuiltTestCLI(anchor: Self.self)
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: out, as: UTF8.self),
            String(decoding: err, as: UTF8.self)
        )
    }

    func testPreviewIsLocalPrivateAndDoesNotPrintSourceBodies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("SECRET-MEMORY-BODY".utf8).write(to: source.appendingPathComponent("note.md"))
        let plan = root.appendingPathComponent("plan.json")
        let command = [
            "import", "preview", "--adapter", "directory", "--source", source.path,
            "--namespace", "fixture", "--out", plan.path,
        ]
        let first = try run(command)
        XCTAssertEqual(first.0, 0, first.2)
        XCTAssertFalse(first.1.contains("SECRET-MEMORY-BODY"))
        XCTAssertFalse(first.2.contains("SECRET-MEMORY-BODY"))
        var statValue = stat()
        XCTAssertEqual(stat(plan.path, &statValue), 0)
        XCTAssertEqual(statValue.st_mode & 0o777, 0o600)
        let saved = try Data(contentsOf: plan)
        let second = try run(command)
        XCTAssertNotEqual(second.0, 0)
        XCTAssertEqual(try Data(contentsOf: plan), saved)
    }

    func testMalformedCommandsFailBeforeConnecting() throws {
        for args in [
            ["import", "preview", "--adapter", "directory"],
            ["import", "resume"],
            ["export-memory", "--namespace", "fixture"],
        ] {
            let result = try run(args)
            XCTAssertNotEqual(result.0, 0)
            XCTAssertTrue(result.2.contains("usage"), result.2)
        }
    }

    func testLocalLimitsTemplateAndBoundedPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-limits-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try run(["import", "limits"])
        XCTAssertEqual(template.0, 0, template.2)
        var values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(template.1.utf8)) as? [String: Any])
        XCTAssertEqual(values["maximumRecords"] as? Int, 256)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("one".utf8).write(to: source.appendingPathComponent("one.md"))
        try Data("two".utf8).write(to: source.appendingPathComponent("two.md"))
        let limits = root.appendingPathComponent("limits.json")
        let plan = root.appendingPathComponent("plan.json")
        func saveLimits(_ maximum: Int) throws {
            values["maximumRecords"] = maximum
            try JSONSerialization.data(withJSONObject: values).write(to: limits)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: limits.path)
        }
        let args = [
            "import", "preview", "--adapter", "directory", "--source", source.path,
            "--namespace", "fixture", "--out", plan.path, "--limits", limits.path,
        ]
        try saveLimits(0)
        XCTAssertNotEqual(try run(args).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
        try saveLimits(1)
        XCTAssertNotEqual(try run(args).0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
        try saveLimits(2)
        let success = try run(args)
        XCTAssertEqual(success.0, 0, success.2)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: plan)) as? [String: Any])
        XCTAssertEqual((object["limits"] as? [String: Any])?["maximumRecords"] as? Int, 2)
    }
}
