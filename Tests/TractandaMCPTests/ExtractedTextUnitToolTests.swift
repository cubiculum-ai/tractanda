import Foundation
import MCP
import XCTest

@testable import TractandaCore
@testable import TractandaMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ExtractedTextUnitToolTests: XCTestCase, @unchecked Sendable {
    func testSingularSchemaBoundsAndFreshFeatureGate() throws {
        let tool = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_extracted_text_unit" })
        XCTAssertEqual(tool.requiredFeature, ServerFeature.extractedTextUnits.rawValue)
        XCTAssertEqual(tool.required, ["itemID", "expectedRevisionID", "unit"])
        XCTAssertTrue(tool.readOnly)
        let arguments: [String: Value] = [
            "itemID": .string("item"), "expectedRevisionID": .string("revision"), "unit": .int(0),
        ]
        XCTAssertNoThrow(try tool.arguments(from: arguments))
        for change: [String: Value] in [
            ["ids": .array([])], ["unit": .int(-1)], ["offset": .int(-1)],
            ["limit": .int(0)], ["limit": .int(262_145)], ["maxBytes": .int(8191)],
        ] {
            XCTAssertThrowsError(try tool.arguments(from: arguments.merging(change) { _, new in new }))
        }
        let oldInfo = try JSONEncoder().encode(
            Value.object(["features": .array([.string("tractanda.extracted-text.v1")])]))
        XCTAssertThrowsError(
            try MCPAdapter.requireFeature(ServerFeature.extractedTextUnits.rawValue, serverInfoData: oldInfo))
        XCTAssertTrue(
            ResourceCatalog.requiredServerFeatures.contains(ServerFeature.extractedTextUnits.rawValue))
        XCTAssertTrue(
            ResourceCatalog.references.contains {
                $0.text.contains("global placement") || $0.text.contains("globalPlacementVerified")
            })
    }
    func testSerializedWrapperBudgetIncludesEscapingAndDuplicatedContent() throws {
        let small = try MCPAdapter.toolResult(data: Data("{\"unit\":{\"text\":\"ok\"}}".utf8))
        XCTAssertNoThrow(try MCPAdapter.checkedPageToolResult(small))
        let data = try JSONEncoder().encode(
            Value.object(["unit": .object(["text": .string(String(repeating: "\"", count: 130_000))])]))
        XCTAssertLessThan(data.count, NativeGateway.maximumResultSize)
        let result = try MCPAdapter.toolResult(data: data)
        XCTAssertThrowsError(try MCPAdapter.checkedPageToolResult(result)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "responseTooLarge")
        }
    }
    func testNativeAndMCPUnwrapPreserveBOMOnlyAndLeadingBOM() async throws {
        for text in ["\u{FEFF}", "\u{FEFF}é"] {
            let result: Value = .object([
                "unit": .object(["text": .string(text)]),
                "arbitrary": .array([.string(text), .string("ordinary")]),
            ])
            let envelope = try JSONEncoder().encode(
                Value.object([
                    "methodResponses": .array([
                        .array([.string("TractandaItem/extractedTextUnit"), result, .string("client")])
                    ]),
                    "sessionState": .string("state"),
                ]))
            let client = ItemClient(transport: { _ in envelope })
            let native = try client.call("TractandaItem/extractedTextUnit")
            let nativeValue = try JSONDecoder().decode(Value.self, from: native)
            XCTAssertEqual(nativeValue.objectValue?["unit"]?.objectValue?["text"]?.stringValue, text)
            let gateway = NativeGateway(backend: { request in
                let object = try JSONDecoder().decode(Value.self, from: request)
                let method = object.objectValue?["methodCalls"]?.arrayValue?.first?.arrayValue?.first?
                    .stringValue
                if method == "TractandaStore/info" {
                    return try JSONEncoder().encode(
                        Value.object([
                            "methodResponses": .array([
                                .array([
                                    .string("TractandaStore/info"),
                                    .object([
                                        "features": .array([
                                            .string(ServerFeature.extractedTextUnits.rawValue)
                                        ])
                                    ]),
                                    .string("client"),
                                ])
                            ]), "sessionState": .string("state"),
                        ]))
                }
                return envelope
            })
            let definition = try XCTUnwrap(
                ToolCatalog.definitions().first { $0.tool.name == "tractanda_extracted_text_unit" })
            let data = try await MCPAdapter.callNativeTool(
                definition: definition,
                supplied: [
                    "itemID": .string("item"), "expectedRevisionID": .string("revision"), "unit": .int(0),
                ], gateway: gateway)
            let adapted = try JSONDecoder().decode(Value.self, from: data)
            XCTAssertEqual(adapted.objectValue?["unit"]?.objectValue?["text"]?.stringValue, text)
            let wrapped = try MCPAdapter.checkedPageToolResult(MCPAdapter.toolResult(data: data))
            XCTAssertEqual(
                wrapped.structuredContent?.objectValue?["unit"]?.objectValue?["text"]?.stringValue, text)
        }
    }
    func testGenericNativeEnvelopePreservesValuesAndChecksIdentityAndErrors() throws {
        let data = Data(
            "{\"methodResponses\":[[\"ordinary\",{\"minimum\":-9223372036854775808,\"maximum\":18446744073709551615,\"real\":1.25,\"flag\":true,\"empty\":null,\"nested\":[\"\u{FEFF}\"]},\"client\"]]}"
                .utf8)
        struct Result: Decodable {
            let minimum: Int64
            let maximum: UInt64
            let real: Double
            let flag: Bool
            let empty: String?
            let nested: [String]
        }
        let result = try JSON.decode(Result.self, NativeMethodResult.unwrap(data, method: "ordinary"))
        XCTAssertEqual(result.minimum, Int64.min)
        XCTAssertEqual(result.maximum, UInt64.max)
        XCTAssertEqual(result.real, 1.25)
        XCTAssertTrue(result.flag)
        XCTAssertNil(result.empty)
        XCTAssertEqual(result.nested, ["\u{FEFF}"])
        XCTAssertThrowsError(try NativeMethodResult.unwrap(data, method: "wrong"))
        XCTAssertThrowsError(try NativeMethodResult.unwrap(data, method: "ordinary", callID: "wrong"))
        let failure = Data(
            "{\"methodResponses\":[[\"error\",{\"type\":\"forbidden\",\"description\":\"denied\"},\"client\"]]}"
                .utf8)
        XCTAssertThrowsError(try NativeMethodResult.unwrap(failure, method: "ordinary")) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
    }

    private actor DirectBackend {
        private var service: ItemService?
        private var unitCalls = 0
        init(root: URL) throws {
            service = ItemService(
                store: try ItemStore(
                    root: root, revisionProjectionEnabled: true, authorityIntakeEnabled: true))
        }
        func send(_ data: Data) throws -> Data {
            guard let service else { throw TractandaError("serviceClosed", "Fixture closed") }
            let request = try JSONDecoder().decode(Value.self, from: data)
            if request.objectValue?["methodCalls"]?.arrayValue?.first?.arrayValue?.first?.stringValue
                == "TractandaItem/extractedTextUnit"
            {
                unitCalls += 1
            }
            return service.handle(data, peerUID: service.store.ownerUID)
        }
        func count() -> Int { unitCalls }
        func close() { service = nil }
    }
    func testFreshCapabilityGateRejectsDirectBackendAndAcceptsCoordinatorRoute() async throws {
        let cap: Int64 = 16 * 1024 * 1024
        let reserve: Int64 = 10 * 1024 * 1024 * 1024
        let policy = try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve)
        try policy.check(at: FileManager.default.temporaryDirectory, additionalBytes: 2 * 1024 * 1024)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "unit-capability-" + Identifier.make())
        defer { try? FileManager.default.removeItem(at: root) }
        let revision: Revision
        let uid: UInt32
        do {
            _ = try ItemStore.initializeFresh(root: root)
            let store = try ItemStore(
                root: root, attachmentUploadPolicy: .init(maximumStagedBytes: cap, minimumFreeBytes: reserve),
                revisionProjectionEnabled: true, authorityIntakeEnabled: true)
            uid = store.ownerUID
            revision = try store.commit(
                .init(classID: "Item", changes: ["body": .text("gated source")], operationID: "source")
            ).revision
        }
        let definition = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_extracted_text_unit" })
        let arguments: [String: Value] = [
            "itemID": .string(revision.itemID), "expectedRevisionID": .string(revision.revisionID),
            "unit": .int(0),
        ]
        let direct = try DirectBackend(root: root)
        let synchronous = NativeGateway(backend: { try await direct.send($0) })
        do {
            _ = try await MCPAdapter.callNativeTool(
                definition: definition, supplied: arguments, gateway: synchronous)
            XCTFail("Absent installed route must fail the fresh feature gate")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "unsupportedCapability") }
        let invoked = await direct.count()
        XCTAssertEqual(invoked, 0, "The gate must stop before the unsupported source method")
        await direct.close()
        let coordinator = try await ServiceCoordinator(opening: root)
        let asynchronous = NativeGateway(backend: { try await coordinator.handle($0, forUID: uid) })
        do {
            let data = try await MCPAdapter.callNativeTool(
                definition: definition, supplied: arguments, gateway: asynchronous)
            let result = try JSONDecoder().decode(Value.self, from: data)
            XCTAssertEqual(result.objectValue?["unit"]?.objectValue?["text"]?.stringValue, "gated source")
            XCTAssertEqual(
                result.objectValue?["canonicalVerification"]?.objectValue?["status"]?.stringValue, "verified")
        } catch {
            await coordinator.close()
            throw error
        }
        await coordinator.close()
        try policy.check(at: root, additionalBytes: 0)
        try checkFixtureAllocation(root, cap: cap)
    }
    private func checkFixtureAllocation(_ root: URL, cap: Int64) throws {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Unknown tiny capability fixture allocation")
        }
        var allocated: Int64 = 0
        var count = 0
        for case let url as URL in entries {
            count += 1
            var info = stat()
            guard count <= 4096, lstat(url.path, &info) == 0, info.st_blocks >= 0 else {
                throw TractandaError("resourceLimit", "Unknown capability fixture allocation")
            }
            let bytes = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            let total = allocated.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !total.overflow, total.partialValue <= cap else {
                throw TractandaError("resourceLimit", "Capability fixture exceeds16MiB")
            }
            allocated = total.partialValue
        }
    }
}
