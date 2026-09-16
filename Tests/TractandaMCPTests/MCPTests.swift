import Foundation
import MCP
import TractandaCore
import XCTest

@testable import TractandaMCP

final class MCPTests: XCTestCase {
    func testInfoKeepsLocalBindingOnFailureWithoutCachedServerFacts() async throws {
        let gateway = NativeGateway(
            connection: ServerConnection(socketPath: "/tmp/retired-tractanda.sock", serverUser: "daemon"))
        let diagnostics = try await MCPAdapter.connectionDetails(gateway: gateway, status: "error")
        XCTAssertEqual(diagnostics["socketPath"]?.stringValue, "/tmp/retired-tractanda.sock")
        XCTAssertEqual(diagnostics["expectedServerUser"]?.stringValue, "daemon")
        XCTAssertEqual(diagnostics["status"]?.stringValue, "error")
        XCTAssertNotNil(diagnostics["adapter"]?.objectValue?["instanceID"])
        XCTAssertEqual(diagnostics["referenceRevision"]?.stringValue, ResourceCatalog.revision)
        let result = try MCPAdapter.toolFailure(
            TractandaError("connectionFailed", "Retired socket"), operationID: nil, connection: diagnostics)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["connection"]?.objectValue?["socketPath"]?.stringValue,
            "/tmp/retired-tractanda.sock")
        XCTAssertNil(result.structuredContent?.objectValue?["server"])
        let online = try await MCPAdapter.infoResult(
            data: Data(#"{"accessScope":"user:alice","server":{"instanceID":"native-instance"}}"#.utf8),
            gateway: gateway, resultFormat: .structured)
        XCTAssertEqual(
            online.structuredContent?.objectValue?["server"]?.objectValue?["instanceID"]?.stringValue,
            "native-instance")
        XCTAssertEqual(
            online.structuredContent?.objectValue?["connection"]?.objectValue?["status"]?.stringValue, "ready"
        )
        let embedded = NativeGateway(backend: { _ in Data() })
        let inProcess = await embedded.connectionDetails()
        XCTAssertEqual(inProcess["transport"]?.stringValue, "inProcess")
        XCTAssertNil(inProcess["socketPath"])
        XCTAssertNil(inProcess["profile"])
    }

    func testGetExplainsPluralIDGuessWithoutAddingAmbiguousAliases() throws {
        let get = try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == "tractanda_get" })
        for name in ["itemID", "itemIDs"] {
            XCTAssertThrowsError(try get.arguments(from: [name: .array([.string("id")])])) { error in
                let message = (error as? TractandaError)?.message ?? ""
                XCTAssertTrue(message.contains("Unknown argument keys: \(name)"))
                XCTAssertTrue(message.contains("Missing required argument keys: ids"))
                XCTAssertTrue(message.contains("batch operation"))
            }
        }
    }

    func testStructuredResultsPreserveInt64AndArbitraryText() throws {
        let data = Data(
            #"{"minimum":-9223372036854775808,"maximum":9223372036854775807,"body":"a\nb\\c","literal.key":"data:text/plain;base64,dGVzdA=="}"#
                .utf8)
        let result = try MCPAdapter.toolResult(data: data)
        let encoded = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let structured = try XCTUnwrap(json["structuredContent"] as? [String: Any])
        XCTAssertEqual((structured["maximum"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual((structured["minimum"] as? NSNumber)?.int64Value, Int64.min)
        XCTAssertEqual(structured["body"] as? String, "a\nb\\c")
        XCTAssertEqual(structured["literal.key"] as? String, "data:text/plain;base64,dGVzdA==")
        let content = try XCTUnwrap(json["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, String(decoding: data, as: UTF8.self))
    }

    func testNativeErrorsRetainConflictCodeAndRetryIdentity() throws {
        let result = try MCPAdapter.toolFailure(
            TractandaError("revisionConflict", "Read the current revision."), operationID: "stable-retry")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "revisionConflict")
        XCTAssertEqual(result.structuredContent?.objectValue?["operationID"]?.stringValue, "stable-retry")
    }

    func testRejectedMutationArgumentsExplainHowToReuseAnOperationID() throws {
        let result = try MCPAdapter.toolFailure(
            TractandaError("invalidArguments", "Missing required argument keys: classID."),
            operationID: "correct-after-rejection")
        let advice = result.structuredContent?.objectValue?["retryAdvice"]?.stringValue ?? ""
        XCTAssertTrue(advice.contains("Correct the rejected arguments"))
        XCTAssertTrue(advice.contains("earlier attempt"))
        XCTAssertTrue(advice.contains("corrected mutation with this operationID"))
        XCTAssertFalse(advice.contains("retry identical arguments"))
    }

    func testResultFormatsAndOutputSchemaContracts() throws {
        let data = Data(#"{"maximum":9223372036854775807}"#.utf8)
        let both = try MCPAdapter.toolResult(data: data, resultFormat: .both)
        XCTAssertEqual(both.content.count, 1)
        XCTAssertEqual(both.structuredContent?.objectValue?["maximum"]?.intValue, Int.max)

        let text = try MCPAdapter.toolResult(data: data, resultFormat: .text)
        XCTAssertEqual(text.content.count, 1)
        XCTAssertNil(text.structuredContent)
        let structured = try MCPAdapter.toolResult(data: data, resultFormat: .structured)
        XCTAssertTrue(structured.content.isEmpty)
        XCTAssertNotNil(structured.structuredContent)
        XCTAssertTrue(
            ToolCatalog.definitions(includesOutputSchema: false).allSatisfy { $0.tool.outputSchema == nil })
        XCTAssertTrue(ToolCatalog.definitions().allSatisfy { $0.tool.outputSchema != nil })

        let error = try MCPAdapter.toolFailure(
            TractandaError("invalidArguments", "Missing required argument keys: ids."), operationID: nil,
            resultFormat: .text)
        XCTAssertTrue(error.isError ?? false)
        XCTAssertNil(error.structuredContent)
        XCTAssertEqual(error.content.count, 1)
    }

    func testCatalogMatchesMCPRetrievalAndQueryContract() throws {
        let definitions = ToolCatalog.definitions()
        let query = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_query" })
        XCTAssertEqual(query.nativeMethod, "TractandaItem/query")
        XCTAssertEqual(
            query.tool.inputSchema.objectValue?["properties"]?.objectValue?["sort"]?.objectValue?["maxItems"]?
                .intValue, 4)
        XCTAssertNoThrow(
            try query.arguments(from: [
                "sort": .array([.object(["property": .string("modifiedAt"), "isAscending": .bool(false)])])
            ]))
        XCTAssertThrowsError(try query.arguments(from: ["sectionID": .string("id")]))
        XCTAssertThrowsError(try query.arguments(from: ["viewID": .string("id"), "sort": .array([])]))

        let get = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_get" })
        let getProperties = try XCTUnwrap(get.tool.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(getProperties["maxBytes"]?.objectValue?["maximum"]?.intValue, 524_288)
        XCTAssertNoThrow(
            try get.arguments(from: [
                "ids": .array([.string("id")]),
                "properties": .array([.string("subject"), .string("unknown.key")]),
                "maxBytes": .int(8_192),
            ]))
        XCTAssertThrowsError(
            try get.arguments(from: [
                "ids": .array([.string("id")]), "projection": .string("content"),
                "properties": .array([.string("subject")]),
            ]))
        XCTAssertThrowsError(try get.arguments(from: ["unexpected": .string("value")])) { error in
            XCTAssertEqual(
                (error as? TractandaError)?.message,
                "Unknown argument keys: unexpected. Missing required argument keys: ids.")
        }
        XCTAssertThrowsError(try query.arguments(from: ["excludedCategoryIDs": .array([.int(1)])])) { error in
            XCTAssertTrue((error as? TractandaError)?.message.contains("excludedCategoryIDs") == true)
        }

        let explain = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_explain" })
        let explainProperties = try XCTUnwrap(
            explain.tool.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(
            Set(explainProperties.keys),
            Set(["itemID", "categoryID"]))
    }

    func testWriteAndSemanticHintsMatchTheirActualEffects() throws {
        let tools = Dictionary(
            uniqueKeysWithValues: ToolCatalog.definitions().map { ($0.tool.name, $0.tool) })
        XCTAssertEqual(tools["tractanda_commit"]?.annotations.destructiveHint, true)
        XCTAssertEqual(tools["tractanda_commit"]?.annotations.idempotentHint, true)
        XCTAssertEqual(tools["tractanda_semantic_search"]?.annotations.readOnlyHint, false)
        XCTAssertEqual(tools["tractanda_semantic_search"]?.annotations.idempotentHint, false)
        XCTAssertEqual(tools["tractanda_semantic_configure"]?.annotations.idempotentHint, false)
        XCTAssertEqual(tools["tractanda_learning_train"]?.annotations.idempotentHint, false)
        XCTAssertEqual(tools["tractanda_learning_feedback"]?.annotations.idempotentHint, true)
        XCTAssertEqual(tools["tractanda_learning_settings"]?.annotations.idempotentHint, true)
        XCTAssertEqual(tools["tractanda_semantic_rebuild"]?.annotations.idempotentHint, true)
        XCTAssertEqual(tools["tractanda_semantic_reset"]?.annotations.idempotentHint, true)

        let conservativeMutation = ToolDefinition(
            "test_mutation", method: "Test/mutation", description: "test", properties: [:], readOnly: false)
        let ordinaryRead = ToolDefinition(
            "test_read", method: "Test/read", description: "test", properties: [:])
        XCTAssertFalse(conservativeMutation.tool.annotations.idempotentHint ?? true)
        XCTAssertTrue(ordinaryRead.tool.annotations.idempotentHint ?? false)
    }

    func testCurrentAndPinnedResourcesRequestContentProjection() throws {
        let itemID = "44444444-4444-4444-8444-444444444444"
        let revisionID = "55555555-5555-4555-8555-555555555555"
        let current = try ResourceCatalog.itemRequest(for: "tractanda://items/\(itemID)")
        XCTAssertEqual(current.arguments["projection"]?.stringValue, "content")
        let pinned = try ResourceCatalog.itemRequest(
            for: "tractanda://items/\(itemID)/revisions/\(revisionID)")
        XCTAssertEqual(pinned.arguments["projection"]?.stringValue, "content")
        XCTAssertTrue(ResourceCatalog.references.contains { $0.key == "intro" })
        let semantic = try XCTUnwrap(ResourceCatalog.references.first { $0.key == "semantic" })
        for tool in [
            "tractanda_semantic_status", "tractanda_semantic_search", "tractanda_semantic_results",
            "tractanda_semantic_configure", "tractanda_semantic_rebuild", "tractanda_semantic_reset",
        ] {
            XCTAssertTrue(semantic.text.contains(tool))
        }
        XCTAssertFalse(semantic.text.contains("subject-body-utf8-v1"))
        XCTAssertTrue(semantic.text.contains("item-text-utf8-v2"))
        XCTAssertTrue(semantic.text.contains("Current ACLs"))
        let query = try XCTUnwrap(ResourceCatalog.references.first { $0.key == "query" })
        XCTAssertTrue(query.text.contains("sectionID only with viewID"))
        XCTAssertTrue(query.text.contains("remainingIDs"))
    }

    func testResourceReferencesRejectNoncanonicalAndArbitraryPaths() throws {
        let itemID = "44444444-4444-4444-8444-444444444444"
        let request = try ResourceCatalog.itemRequest(for: "tractanda://items/\(itemID)")
        XCTAssertEqual(request.method, "TractandaItem/get")
        for invalid in [
            "file:///etc/passwd", "tractanda://items/../reference/items",
            "tractanda://items/\(itemID)/", "tractanda://items/\(itemID)?actor=admin",
            "tractanda://items/%34\(itemID.dropFirst())", "tractanda://items/\(itemID)/revisions/invalid",
        ] {
            XCTAssertThrowsError(try ResourceCatalog.itemRequest(for: invalid), invalid)
        }
    }
}
