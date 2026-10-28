import Foundation
import TractandaCore
import XCTest

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
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = try currentBuiltTestCLI(anchor: Self.self)
        process.arguments = args
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return (process, output, error)
    }
    private func run(_ args: [String]) throws -> (Int32, Data, Data) {
        let (process, output, error) = try process(args)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, bytes, diagnostics)
    }
    func testCLIInitAndConfigureAccessPersistPersonalPolicy() throws {
        try capacity()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tcf-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("store")
        let initialized = try run(["init", root.path])
        XCTAssertEqual(initialized.0, 0, String(decoding: initialized.2, as: UTF8.self))
        let identity = try Data(contentsOf: root.appendingPathComponent(".tractanda-replica-identity.json"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".tractanda-personal-profile.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path))
        XCTAssertEqual(try run(["init", root.path]).0, 0)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(".tractanda-replica-identity.json")), identity)
        let account = try SystemAccountDirectory().user(forUID: getuid())
        let policy: ItemValue = .object([
            "profile": .text(AccessConfiguration.profile),
            "users": .list([.text(account.name)]), "groups": .list([.text(account.primaryGroupName)]),
        ])
        let policyURL = parent.appendingPathComponent("policy.json")
        try JSONEncoder().encode(policy).write(to: policyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policyURL.path)
        let configured = try run(["configure-access", root.path, policyURL.path, "private-fixture"])
        XCTAssertEqual(configured.0, 0, String(decoding: configured.2, as: UTF8.self))
        let acknowledgement = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configured.1) as? [String: Any])
        XCTAssertEqual(acknowledgement["configured"] as? Bool, true)
        XCTAssertEqual(acknowledgement["persistenceProfile"] as? String, "personal-workgroup")
        struct Profile: Decodable { let accessConfiguration: ItemValue }
        let persisted = try JSONDecoder().decode(
            Profile.self,
            from: Data(contentsOf: root.appendingPathComponent(".tractanda-personal-profile.json")))
        XCTAssertEqual(persisted.accessConfiguration, policy)
        let store = try ItemStore.openInitialized(root: root)
        XCTAssertTrue(store.isPersonalWorkgroup)
        XCTAssertTrue(try store.candidates().isEmpty, "Local policy is not a canonical item")
    }
    func testCLIServeDoesNotCreateMissingStoreOrAdoptLegacyRoot() throws {
        try capacity()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-cli-strict-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("missing")
        let legacy = parent.appendingPathComponent("legacy")
        do { _ = try ItemStore(root: legacy) }
        for root in [missing, legacy] {
            XCTAssertNotEqual(
                try run(["serve", root.path, parent.appendingPathComponent("s").path, "--max-requests", "1"])
                    .0, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("authority").path))
    }
}
