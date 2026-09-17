import Foundation
import MCP
import TractandaCore
import XCTest

@testable import TractandaMCP

final class ReferenceCompatibilityTests: XCTestCase {
    func testFreshFeatureDeclarationDistinguishesSkewFromServerFailure() async throws {
        let gateway = NativeGateway(socketPath: "/tmp/fixture.sock")
        let requirements = ResourceCatalog.requiredServerFeatures.map(Value.string)
        let examples: [([String: Value], String)] = [
            (["features": .array(requirements)], "satisfied"),
            (["features": .array(requirements + [.string("future.feature.v1")])], "satisfied"),
            (["features": .array([.string(ServerFeature.runtimeIdentity.rawValue)])], "missingFeatures"),
            (["features": .array([])], "missingFeatures"),
            ([:], "unverified"),
            (["features": .null], "unverified"),
            (["features": .string(ServerFeature.semanticJobTiming.rawValue)], "unverified"),
            (["features": .array(requirements + [.int(1)])], "unverified"),
        ]
        for format in MCPResultFormat.allCases {
            for (info, expected) in examples {
                let result = try await MCPAdapter.infoResult(
                    data: JSONEncoder().encode(Value.object(info)), gateway: gateway, resultFormat: format)
                let payload: Value
                if format == .text {
                    guard case .text(let text, _, _) = result.content[0] else {
                        return XCTFail("Missing JSON text result")
                    }
                    payload = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
                } else {
                    payload = try XCTUnwrap(result.structuredContent)
                }
                XCTAssertEqual(
                    result.isError, false, "Skew must not turn successful native info into an error")
                let connection = try XCTUnwrap(payload.objectValue?["connection"]?.objectValue)
                XCTAssertEqual(connection["status"]?.stringValue, "ready")
                let assessment = try XCTUnwrap(connection["referenceCompatibility"]?.objectValue)
                XCTAssertEqual(assessment["status"]?.stringValue, expected)
                if expected == "unverified" {
                    XCTAssertNil(assessment["missingServerFeatures"], "Unknown is distinct from unsupported")
                }
                XCTAssertEqual(
                    payload.objectValue?["features"], info["features"], "Do not fabricate native features")
            }
        }
        let disconnected = try await MCPAdapter.connectionDetails(gateway: gateway, status: "error")
        XCTAssertEqual(
            disconnected["referenceCompatibility"]?.objectValue?["status"]?.stringValue, "unavailable")
        XCTAssertNil(disconnected["features"], "Do not retain a prior server declaration on failure")
        let missing = ResourceCatalog.compatibility(serverInfo: [
            "features": .array([.string(ServerFeature.runtimeIdentity.rawValue)])
        ])
        XCTAssertEqual(
            missing["missingServerFeatures"]?.arrayValue,
            ResourceCatalog.requiredServerFeatures.filter { $0 != ServerFeature.runtimeIdentity.rawValue }
                .map(Value.string))
    }

    func testUnsupportedCapabilityMarksInfoAsProtocolMismatchWithoutServerFacts() async throws {
        let gateway = NativeGateway(socketPath: "/tmp/fixture.sock")
        let diagnostics = try await MCPAdapter.connectionDetails(
            gateway: gateway, status: "error",
            nativeError: TractandaError("unsupportedCapability", "Missing local capability."))
        let compatibility = try XCTUnwrap(diagnostics["referenceCompatibility"]?.objectValue)
        XCTAssertEqual(compatibility["status"]?.stringValue, "protocolMismatch")
        XCTAssertEqual(
            compatibility["requiredServerFeatures"]?.arrayValue,
            ResourceCatalog.requiredServerFeatures.map(Value.string))
        XCTAssertNil(diagnostics["server"])
        XCTAssertNil(diagnostics["features"])
        XCTAssertTrue(compatibility["message"]?.stringValue?.contains("matching protocol") == true)

        let malformed = try await MCPAdapter.connectionDetails(
            gateway: gateway, status: "error",
            nativeError: TractandaError("invalidRequest", "Malformed envelope."))
        XCTAssertEqual(
            malformed["referenceCompatibility"]?.objectValue?["status"]?.stringValue, "unavailable")
    }
}
