import Foundation
import XCTest
import TractandaCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class FreshStoreCommandTests: XCTestCase {
    private func capacity() throws {
        var value = statvfs()
        guard statvfs(FileManager.default.temporaryDirectory.path, &value) == 0, value.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot inspect CLI fixture capacity.")
        }
        let free = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
        guard !free.overflow, free.partialValue >= 10 * 1024 * 1024 * 1024 + 32 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "CLI fixture requires 10 GiB reserve plus 32 MiB cap.")
        }
    }
    private func process(_ args: [String]) throws -> (Process, Pipe, Pipe) {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: ".build/debug/tractanda").standardizedFileURL
        process.arguments = args
        process.standardOutput = output; process.standardError = error
        try process.run()
        return (process, output, error)
    }
    private func run(_ args: [String]) throws -> (Int32, Data, Data) {
        let (process, output, error) = try process(args)
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, bytes, diagnostics)
    }
    func testCLIInitCreatesCanonicalMetadataAndNormalQueryUsesStrictServe() throws {
        try capacity()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tcf-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("store"), socket = parent.appendingPathComponent("s")
        let initialized = try run(["init", root.path])
        XCTAssertEqual(initialized.0, 0, String(decoding: initialized.2, as: UTF8.self))
        let identity = try Data(contentsOf: root.appendingPathComponent(".tractanda-replica-identity.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".tractanda-first-source-complete.json").path))
        XCTAssertEqual(try run(["init", root.path]).0, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".tractanda-replica-identity.json")), identity)
        let (server, _, diagnostics) = try process(["serve", root.path, socket.path, "--max-requests", "1"])
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket.path), server.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        let result = try run(["query", socket.path, "itemID == *"])
        XCTAssertEqual(result.0, 0, String(decoding: result.2, as: UTF8.self))
        let allItems = try XCTUnwrap(JSONSerialization.jsonObject(with: result.1) as? [String: Any])
        XCTAssertEqual(allItems["total"] as? Int, 1, "An unfiltered normal query includes the canonical policy item")
        if result.0 != 0, server.isRunning { server.terminate() }
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0, String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    func testCLIServeDoesNotCreateMissingStoreOrAdoptLegacyRoot() throws {
        try capacity()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tractanda-cli-strict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("missing"), legacy = parent.appendingPathComponent("legacy")
        do { _ = try ItemStore(root: legacy) }
        for root in [missing, legacy] {
            XCTAssertNotEqual(try run(["serve", root.path, parent.appendingPathComponent("s").path, "--max-requests", "1"]).0, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("authority").path))
    }
}
