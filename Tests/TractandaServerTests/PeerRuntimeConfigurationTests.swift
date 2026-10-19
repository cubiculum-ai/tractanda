import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaServer

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerRuntimeConfigurationTests: XCTestCase {
    func testPrivateConfigLoaderRejectsSymlinkModeAndOversize() throws {
        let directory = try GuardedFixtureDirectory.create(
            prefix: "f", source: "PeerRuntimeConfigurationTests", test: name)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("runtime.json")
        try Data(#"{"version":1,"peers":[]}"#.utf8).write(to: valid)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.path)
        let loaded = try PeerRuntimeConfiguration.load(from: valid.path)
        XCTAssertTrue(loaded.peers.isEmpty)
        XCTAssertFalse(loaded.synchronization.enabled)
        XCTAssertEqual(loaded, try PeerRuntimeConfiguration.decode(Data(#"{"version":1,"peers":[]}"#.utf8)))

        let loose = directory.appendingPathComponent("loose.json")
        try Data(#"{"version":1}"#.utf8).write(to: loose)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loose.path)
        XCTAssertThrowsError(try PeerRuntimeConfiguration.load(from: loose.path))

        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        XCTAssertThrowsError(try PeerRuntimeConfiguration.load(from: link.path))

        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: PeerRuntimeConfiguration.maximumFileBytes + 1).write(to: oversized)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
        XCTAssertThrowsError(try PeerRuntimeConfiguration.load(from: oversized.path))
    }
}
