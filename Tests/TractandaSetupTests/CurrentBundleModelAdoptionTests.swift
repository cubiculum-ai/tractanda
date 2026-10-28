import Foundation
import XCTest

@testable import TractandaSetup

final class CurrentBundleModelAdoptionTests: XCTestCase {
    func testSlimCurrentBundleNeverSearchesPriorReceiptedReleases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "current-model-adoption-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = SetupRoots(
            platform: .macos, software: root.appendingPathComponent("Software"),
            configuration: root.appendingPathComponent("Configuration"))
        let old = roots.software.appendingPathComponent("releases/old")
        let current = roots.software.appendingPathComponent("releases/current")
        let file = old.appendingPathComponent(
            "models/granite-embedding-311m-multilingual-r2/model.safetensors")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        var receipt = try InstallationReceipt(
            options: .init(name: "test", owner: "test", bundle: current), roots: roots,
            owner: "test", release: current, manifestSHA256: String(repeating: "1", count: 64))
        receipt.releases[old.path] = String(repeating: "2", count: 64)
        let engine = SetupEngine(roots: roots, trustedOwnership: false)
        XCTAssertNil(try engine.modelAdoptionDirectory(receipt))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }
    func testFullCurrentBundleRemainsAvailableForVerifiedOfflineAdoption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "current-model-adoption-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for platform in [SetupPlatform.macos, .linux] {
            let roots = SetupRoots(
                platform: platform, software: root.appendingPathComponent(platform.rawValue + "/Software"),
                configuration: root.appendingPathComponent(platform.rawValue + "/Configuration"))
            let current = roots.software.appendingPathComponent(
                platform == .linux ? "current" : "releases/current")
            let models = current.appendingPathComponent("models")
            let file = models.appendingPathComponent(
                "granite-embedding-311m-multilingual-r2/model.safetensors")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            let receipt = try InstallationReceipt(
                options: .init(name: "test", owner: "test", bundle: current), roots: roots,
                owner: "test", release: current, manifestSHA256: String(repeating: "1", count: 64))
            XCTAssertEqual(
                try SetupEngine(roots: roots, trustedOwnership: false).modelAdoptionDirectory(receipt),
                models.path)
        }
    }
}
