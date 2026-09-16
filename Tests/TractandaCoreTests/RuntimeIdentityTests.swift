import Crypto
import Foundation
import XCTest

@testable import TractandaCore

final class RuntimeIdentityTests: XCTestCase {
    func testExecutableDigestValidatesReleaseVersionAndMissingImageIsExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let image = bin.appendingPathComponent("tractanda")
        let bytes = Data("test image".utf8)
        try bytes.write(to: image)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = [
            "profile": "tractanda.bundle.v1", "version": "0.1.0-test",
            "files": [["path": "bin/tractanda", "sha256": digest]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: root.appendingPathComponent("bundle-manifest.json"))
        let build = RuntimeIdentity.capture(executable: image, location: image)
        XCTAssertEqual(build.version, "0.1.0-test")
        XCTAssertEqual(build.executableSHA256, digest)
        try Data("changed image".utf8).write(to: image)
        let changed = RuntimeIdentity.capture(executable: image, location: image)
        XCTAssertEqual(changed.version, "development")
        XCTAssertNotEqual(changed.executableSHA256, digest)
        XCTAssertNotEqual(changed.instanceID, build.instanceID)
        let missing = RuntimeIdentity.capture(executable: nil, location: nil)
        XCTAssertNil(missing.executableSHA256)
        XCTAssertEqual(missing.version, "development")
        XCTAssertEqual(RuntimeIdentity.current.instanceID, RuntimeIdentity.current.instanceID)
    }
}
