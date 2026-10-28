import Foundation
import TractandaServer
import XCTest

@testable import TractandaCLI

final class PublicJMAPConfigurationTests: XCTestCase {
    func testExplicitPublicConfigKeepsExistingLoopbackDefaultAndLoadsWithoutStartingService() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "public-config-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: path) }
        let publicConfig = PublicJMAPConfiguration(
            baseURL: "https://localhost:9443",
            transport: .trustedProxyUnix(path: "/private/tmp/private-proxy/backend.sock"))
        try JSONEncoder().encode(publicConfig).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let configuration = try daemonConfiguration(from: [
            "daemon", "/private/fixture/store", "/private/fixture/native.sock", "--public-jmap-config",
            path.path,
        ])
        XCTAssertEqual(configuration.httpPort, 48728)
        XCTAssertEqual(configuration.publicJMAP?.baseURL, "https://localhost:9443")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/tmp/private-proxy/backend.sock"))
        XCTAssertThrowsError(
            try daemonConfiguration(from: [
                "daemon", "/private/fixture/store", "/private/fixture/native.sock", "--public-jmap-config",
                path.path, "--public-jmap-config", path.path,
            ]))
    }
}
