import Foundation
import TractandaCore
import XCTest

@testable import TractandaCLI
@testable import TractandaSetup

final class SetupDaemonParserContractTests: XCTestCase {
    func testGeneratedLaunchdAndSystemdArgumentsUseActualDaemonParser() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "argv", source: "SetupDaemonParserContractTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        for platform in [SetupPlatform.macos, .linux] {
            let roots = SetupRoots(
                platform: platform, software: root.appendingPathComponent("software"),
                configuration: root.appendingPathComponent("configuration"),
                launchDefinitions: root.appendingPathComponent("jobs"),
                runtime: root.appendingPathComponent("run"), data: root.appendingPathComponent("data"),
                indexes: root.appendingPathComponent("indexes"),
                commands: root.appendingPathComponent("commands"))
            let engine = SetupEngine(roots: roots, rootCheck: { true }, trustedOwnership: false)
            let release = roots.software.appendingPathComponent("current")
            for configured in [false, true] {
                var receipt = try InstallationReceipt(
                    options: .init(name: "preview", bundle: release), roots: roots,
                    owner: "fixture", release: release, manifestSHA256: String(repeating: "a", count: 64))
                if configured {
                    receipt.peerRuntimeConfiguration = try ManagedPeerConfiguration(
                        path: engine.peerConfigurationURL("preview").path,
                        bytes: PeerRuntimeConfiguration().encoded())
                    receipt.documentExtraction = .pinned
                    receipt.documentScratchDirectory =
                        roots.configuration
                        .appendingPathComponent("document-state/preview/scratch").path
                    receipt.board = [
                        "projectRootID": "01010101-0101-1101-8101-010101010101",
                        "statusRootID": "02020202-0202-1202-8202-020202020202",
                        "projectID": "03030303-0303-1303-8303-030303030303",
                    ]
                }
                let definition = try engine.serviceDefinition(receipt)
                let argv: [String]
                if platform == .macos {
                    let plist = try XCTUnwrap(
                        PropertyListSerialization.propertyList(from: definition, format: nil)
                            as? [String: Any])
                    argv = try XCTUnwrap(plist["ProgramArguments"] as? [String])
                } else {
                    // Every emitted systemd token is quoted. Decode these literal fixture tokens,
                    // retaining the complete ExecStart rather than selecting known flag names.
                    let line = try XCTUnwrap(
                        String(decoding: definition, as: UTF8.self)
                            .split(separator: "\n").first { $0.hasPrefix("ExecStart=") })
                    let tokens = String(line.dropFirst("ExecStart=".count))
                    let pattern = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
                    let matches = pattern.matches(
                        in: tokens, range: NSRange(tokens.startIndex..., in: tokens))
                    argv = try matches.map {
                        let range = try XCTUnwrap(Range($0.range, in: tokens))
                        return try JSONDecoder().decode(String.self, from: Data(tokens[range].utf8))
                    }
                    XCTAssertEqual(
                        tokens,
                        try argv.map {
                            try SetupServiceBackend.quoted($0, executableArgument: true)
                        }.joined(separator: " "))
                }
                XCTAssertEqual(argv.first, release.appendingPathComponent("bin/tractanda").path)
                let parsed = try daemonConfiguration(from: Array(argv.dropFirst()))
                XCTAssertEqual(parsed.storePath, receipt.store)
                XCTAssertEqual(parsed.socketPath, receipt.socket)
                XCTAssertEqual(parsed.indexDirectory, receipt.indexDirectory)
                XCTAssertEqual(parsed.httpPort, receipt.port)
                XCTAssertTrue(parsed.managed)
                XCTAssertEqual(parsed.peerRuntimeConfigurationPath, receipt.peerRuntimeConfiguration?.path)
                XCTAssertEqual(parsed.projectRootID, receipt.board["projectRootID"])
                XCTAssertEqual(parsed.statusRootID, receipt.board["statusRootID"])
                XCTAssertEqual(parsed.initialProjectID, receipt.board["projectID"])
                XCTAssertEqual(parsed.documentConverter?.scratchDirectory, receipt.documentScratchDirectory)
                XCTAssertEqual(
                    parsed.documentConverter?.executablePath,
                    configured
                        ? release.appendingPathComponent(DocumentExtractionPayload.pinned.converterPath).path
                        : nil)
                XCTAssertEqual(
                    parsed.documentConverter?.modelDirectory,
                    configured
                        ? release.appendingPathComponent(DocumentExtractionPayload.pinned.modelDirectory).path
                        : nil)
                if configured {
                    var obsolete = argv
                    let index = try XCTUnwrap(obsolete.firstIndex(of: "--peer-runtime-config"))
                    obsolete[index] = "--peer-runtime-configuration"
                    XCTAssertThrowsError(try daemonConfiguration(from: Array(obsolete.dropFirst())))
                }
            }
        }
    }
}
