import Foundation
import TractandaCore
import XCTest
@testable import TractandaSetup

final class SetupLayout17CompatibilityTests: XCTestCase {
    func testOnlyTheBoundPhysicalTransitionIsAdmitted() throws {
        let capability = "tractanda.physical-layout.flat-items.v1"
        let message = "tractanda.message-items.v1"
        let oldSupport = CanonicalFormatSupport(
            readerLevel: 18, writerLevel: 18, read: [1, 2], write: [2],
            capabilities: ["tractanda.personal-workgroup.v1"],
            writeCapabilities: ["tractanda.personal-workgroup.v1"])
        func support(_ extras: [String] = [capability, message], level: Int = 20) -> CanonicalFormatSupport {
            CanonicalFormatSupport(
                readerLevel: level, writerLevel: level, read: [1, 2], write: [2],
                capabilities: (["tractanda.personal-workgroup.v1"] + extras).sorted(),
                writeCapabilities: (["tractanda.personal-workgroup.v1"] + extras).sorted())
        }
        func declaration(_ version: String, _ format: CanonicalFormatSupport,
                         _ upgrade: SetupPackageCompatibility.Upgrade,
                         arch: String = "x86_64", semantic: String = "tractanda.peer-exchange.v2",
                         embedding: EmbeddingPayload? = .granite,
                         document: DocumentExtractionPayload? = .pinned) -> SetupPackageCompatibility {
            SetupPackageCompatibility(
                manifestSHA256: String(repeating: "a", count: 64), version: version,
                arch: arch, canonicalFormats: format, semanticProfile: semantic, upgrade: upgrade,
                embedding: embedding, documentExtraction: document)
        }
        let old = declaration("0.1.0-poc.16.2", oldSupport, .compatible)
        let bridge = declaration("0.1.0-poc.17", support(), .coordinatedMaintenance)
        XCTAssertNoThrow(try bridge.requireLayout17Transition(from: old))
        XCTAssertThrowsError(try bridge.requireRollingUpgrade(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.18", support(), .coordinatedMaintenance)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(), .compatible)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support([capability, message, "extra"]), .coordinatedMaintenance)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(level: 19), .coordinatedMaintenance)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support([capability]), .coordinatedMaintenance)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(), .coordinatedMaintenance, arch: "arm64")
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(), .coordinatedMaintenance,
                                             semantic: "tractanda.peer-exchange.v3")
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(), .coordinatedMaintenance,
                                             embedding: nil)
            .requireLayout17Transition(from: old))
        XCTAssertThrowsError(try declaration("0.1.0-poc.17", support(), .coordinatedMaintenance,
                                             document: nil)
            .requireLayout17Transition(from: old))
    }
}
