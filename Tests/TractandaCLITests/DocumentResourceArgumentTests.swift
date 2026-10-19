import Foundation
import XCTest
import TractandaCore
import TractandaServer
@testable import TractandaCLI

final class DocumentResourceArgumentTests: XCTestCase {
    func testSlowHardwareOverridesRoundTripWithoutChangingModelIdentity() throws {
        let configuration = try daemonConfiguration(from: ["daemon", "/tmp/resource-store", "/tmp/resource.sock",
            "--document-inspect-seconds", "120", "--document-model-load-seconds", "7200",
            "--document-page-seconds", "86400", "--document-no-progress-seconds", "3600",
            "--document-termination-grace-seconds", "5"])
        let resources = try XCTUnwrap(configuration.documentJobResources)
        XCTAssertEqual(resources.inspectSeconds, 120)
        XCTAssertEqual(resources.modelLoadSeconds, 7200)
        XCTAssertEqual(resources.pageSeconds, 86400)
        XCTAssertEqual(resources.noProgressSeconds, 3600)
        XCTAssertEqual(resources.terminationGraceSeconds, 5)
        let restored = try JSONDecoder().decode(DaemonConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.documentJobResources?.pageSeconds, 86400)
        XCTAssertNil(restored.documentConverter)
    }
    func testResourceFlagsRejectDuplicatesInvalidAndUnaddressableLimits() throws {
        let base = ["daemon", "/tmp/resource-store", "/tmp/resource.sock"]
        for value in ["0", "-1", "nan", "inf", "1e99"] {
            XCTAssertThrowsError(try daemonConfiguration(from: base + ["--document-page-seconds", value]))
        }
        XCTAssertThrowsError(try daemonConfiguration(from: base + ["--document-page-seconds", "1000", "--document-page-seconds", "2000"]))
        XCTAssertThrowsError(try daemonConfiguration(from: base + ["--document-termination-grace-seconds", "61"]))
        XCTAssertNil(try daemonConfiguration(from: base).documentJobResources)
    }
}
