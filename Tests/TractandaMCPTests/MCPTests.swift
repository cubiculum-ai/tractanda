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

final class MCPTests: XCTestCase {
    private struct CapturedNativeCall: Sendable {
        let method: String
        let itemID: String?
        let revisionID: String?
        let attachmentID: String?
        let operationID: String?
        let offset: Int?
        let limit: Int?
        let pageNumber: Int?
    }
    private actor NativeCallCapture {
        private(set) var calls: [CapturedNativeCall] = []
        func append(_ call: CapturedNativeCall) { calls.append(call) }
        func snapshot() -> [CapturedNativeCall] { calls }
    }
    private final class AttachmentAccounts: AccountDirectory {
        let alice: UInt32 = 80_001
        let bob: UInt32 = 80_002

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case UInt32(getuid()): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [80_003])
        }

        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: UInt32(getuid()))
            case "alice": return try user(forUID: alice)
            case "bob": return try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user.")
            }
        }

        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group.")
            }
            return 80_003
        }
    }
    private final class NativeServiceBridge: @unchecked Sendable {
        private let service: ItemService
        private let peerUID: UInt32
        init(service: ItemService, peerUID: UInt32) {
            self.service = service
            self.peerUID = peerUID
        }
        func handle(_ data: Data) -> Data { service.handle(data, peerUID: peerUID) }
    }

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

    func testRevisionProjectionToolsDeclareFeatureAndRequireStateCAS() throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: ToolCatalog.definitions().map { ($0.tool.name, $0) })
        let state = try XCTUnwrap(definitions["tractanda_state"])
        let conflicts = try XCTUnwrap(definitions["tractanda_conflicts"])
        let resolve = try XCTUnwrap(definitions["tractanda_resolve_conflict"])
        for definition in [state, conflicts, resolve] {
            XCTAssertEqual(definition.requiredFeature, ServerFeature.revisionProjection.rawValue)
        }
        XCTAssertNoThrow(
            try state.arguments(from: [
                "ids": .array([.string("11111111-1111-1111-8111-111111111111")])
            ]))
        XCTAssertThrowsError(try state.arguments(from: ["ids": .array([.string("invalid")])]))
        XCTAssertThrowsError(try conflicts.arguments(from: ["limit": .int(257)]))
        let first = "11111111-1111-1111-8111-111111111111"
        let second = "22222222-2222-1222-8222-222222222222"
        let valid: [String: Value] = [
            "itemID": .string(first), "expectedStateToken": .string("token"),
            "reviewedFrontier": .array([.string(first), .string(second)]),
            "changes": .object(["subject": .object(["type": .string("text"), "value": .string("chosen")])]),
            "unset": .array([]), "operationID": .string("review-op"),
        ]
        XCTAssertNoThrow(try resolve.arguments(from: valid))
        var legacyCAS = valid
        legacyCAS["expectedRevisionID"] = .string(first)
        XCTAssertThrowsError(try resolve.arguments(from: legacyCAS))
        var repeatedFrontier = valid
        repeatedFrontier["reviewedFrontier"] = .array([.string(first), .string(first)])
        XCTAssertThrowsError(try resolve.arguments(from: repeatedFrontier))
    }

    func testResolveConflictToolGatesFeatureAndRetainsProjectionInCompactReceipt() async throws {
        let itemID = "11111111-1111-1111-8111-111111111111"
        let revisionID = "22222222-2222-1222-8222-222222222222"
        let frontierID = "33333333-3333-1333-8333-333333333333"
        let backend = NativeGateway(backend: { requestData in
            let envelope = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            let calls = envelope["methodCalls"] as! [[Any]]
            let method = calls[0][0] as! String
            let result: [String: Any]
            if method == "TractandaStore/info" {
                result = ["features": [ServerFeature.revisionProjection.rawValue]]
            } else {
                result = [
                    "revision": [
                        "formatVersion": 2,
                        "fields": [
                            "itemID": itemID, "revisionID": revisionID, "requestIdentity": "private",
                        ],
                    ],
                    "replayed": false, "indexReady": true, "warnings": [],
                    "itemState": [
                        "itemID": itemID, "stateToken": "ready-token", "status": "ready",
                        "representativeRevisionID": revisionID, "detailsComplete": true,
                    ],
                ]
            }
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [[method, result, "client"]]
            ])
        })
        let definition = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_resolve_conflict" })
        let arguments: [String: Value] = [
            "itemID": .string(itemID), "expectedStateToken": .string("review-token"),
            "reviewedFrontier": .array([.string(frontierID)]),
            "changes": .object(["subject": .object(["type": .string("text"), "value": .string("chosen")])]),
            "unset": .array([]), "operationID": .string("resolve-op"),
        ]
        let result = try await MCPAdapter.callNativeTool(
            definition: definition, supplied: arguments, gateway: backend)
        let decoded = try JSONDecoder().decode(Value.self, from: result)
        XCTAssertNil(
            decoded.objectValue?["revision"]?.objectValue?["fields"]?.objectValue?["requestIdentity"])
        XCTAssertEqual(
            decoded.objectValue?["itemState"]?.objectValue?["stateToken"]?.stringValue, "ready-token")
    }

    func testRevisionProjectionToolsExposeFeatureAndGuardConflictCASArguments() throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: ToolCatalog.definitions().map { ($0.tool.name, $0) })
        let state = try XCTUnwrap(definitions["tractanda_state"])
        let conflicts = try XCTUnwrap(definitions["tractanda_conflicts"])
        let resolve = try XCTUnwrap(definitions["tractanda_resolve_conflict"])
        for tool in [state, conflicts, resolve] {
            XCTAssertEqual(tool.requiredFeature, ServerFeature.revisionProjection.rawValue)
        }
        XCTAssertEqual(state.nativeMethod, "TractandaItem/state")
        XCTAssertEqual(conflicts.nativeMethod, "TractandaItem/conflicts")
        XCTAssertEqual(resolve.nativeMethod, "TractandaItem/resolveConflict")

        let first = "11111111-1111-1111-8111-111111111111"
        let second = "22222222-2222-1222-8222-222222222222"
        XCTAssertNoThrow(try state.arguments(from: ["ids": .array([.string(first)])]))
        XCTAssertThrowsError(try state.arguments(from: ["ids": .array([.string(first), .string(first)])]))
        XCTAssertThrowsError(try state.arguments(from: ["ids": .array([.string("bad-id")])]))
        let defaults = try conflicts.arguments(from: [:])
        XCTAssertEqual(defaults["limit"], .int(64))
        XCTAssertThrowsError(try conflicts.arguments(from: ["limit": .int(257)]))

        let request: [String: Value] = [
            "itemID": .string(first), "expectedStateToken": .string("state-token"),
            "reviewedFrontier": .array([.string(first), .string(second)]),
            "changes": .object(["subject": .object(["type": .string("text"), "value": .string("selected")])]),
            "unset": .array([]), "operationID": .string("resolution-op"),
        ]
        XCTAssertNoThrow(try resolve.arguments(from: request))
        var staleCAS = request
        staleCAS["expectedRevisionID"] = .string(first)
        XCTAssertThrowsError(try resolve.arguments(from: staleCAS))
        var incompleteFrontier = request
        incompleteFrontier["reviewedFrontier"] = .array([.string(first), .string(first)])
        XCTAssertThrowsError(try resolve.arguments(from: incompleteFrontier))
        XCTAssertTrue(resolve.idempotent)
        XCTAssertFalse(resolve.readOnly)
    }

    func testInlineCaptureToolsDeclareFrozenPlanAndFeature() throws {
        let definitions = ToolCatalog.definitions()
        let preview = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_capture_preview" })
        let commit = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_capture_commit" })
        XCTAssertEqual(preview.nativeMethod, "TractandaItem/prepareCapture")
        XCTAssertEqual(commit.nativeMethod, "TractandaItem/commitCapture")
        for definition in [preview, commit] {
            XCTAssertEqual(definition.requiredFeature, ServerFeature.inlineCapture.rawValue)
        }
        XCTAssertTrue(preview.readOnly)
        XCTAssertFalse(commit.readOnly)
        XCTAssertTrue(commit.idempotent)
        XCTAssertEqual(
            commit.required,
            ["request", "evaluatedAt", "commitRequest", "categoryRevisionIDs", "mentions", "issues"])
        XCTAssertThrowsError(try commit.arguments(from: ["request": .object([:])]))
        let reference = try XCTUnwrap(ResourceCatalog.references.first { $0.key == "items" })
        XCTAssertTrue(reference.text.contains("Retain the full plan through uncertainty"))
        XCTAssertTrue(reference.text.contains("YYYY-MM-DD date-only"))
    }

    func testInlineCaptureMCPPreviewCommitAndReplayUseOneNativeRevision() async throws {
        let parent = FileManager.default.temporaryDirectory
        var capacity = statvfs()
        guard statvfs(parent.path, &capacity) == 0, capacity.f_frsize > 0 else {
            throw TractandaError("fixtureCapacity", "Cannot inspect tiny capture fixture capacity.")
        }
        let bytes = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        guard !bytes.overflow, bytes.partialValue >= 10 * 1024 * 1024 * 1024 + 4 * 1024 * 1024 else {
            throw TractandaError("fixtureCapacity", "Tiny capture fixture needs 10GiB reserve plus 4MiB cap.")
        }
        // Three records with a few short revisions estimate <1MiB; no models or external services.
        let root = parent.appendingPathComponent("capture-mcp-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore.initializeFresh(root: root)
        let category = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("Tomorrow"),
                    "selection": .object([
                        "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                    ]),
                    "captureDate": .object([
                        "property": .text("plannedDate"), "dayOffset": .integer(1),
                        "timeZone": .text("UTC"),
                    ]),
                ], operationID: "category")
        ).revision
        let bridge = NativeServiceBridge(service: ItemService(store: store), peerUID: store.ownerUID)
        let gateway = NativeGateway(backend: { bridge.handle($0) })
        let preview = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_capture_preview" })
        let commit = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_capture_commit" })
        let request = CommitRequest(
            classID: "Item", changes: ["body": .text("#tomorrow")], operationID: "capture")
        let arguments = try JSONDecoder().decode(
            Value.self,
            from: JSON.encode(
                CapturePreparation(
                    request: request,
                    at: "2026-03-28T23:30:00Z"))
        ).objectValue!
        let planData = try await MCPAdapter.callNativeTool(
            definition: preview, supplied: arguments, gateway: gateway)
        let plan = try JSON.decode(CapturePlan.self, planData)
        XCTAssertTrue(plan.canCommit)
        XCTAssertNil(plan.commitRequest.changes["categoryOverrides"]?.map?[category.itemID])
        let frozen = try JSONDecoder().decode(Value.self, from: planData).objectValue!
        let result = try await MCPAdapter.callNativeTool(
            definition: commit, supplied: frozen, gateway: gateway)
        let saved = try JSONDecoder().decode(Value.self, from: result).objectValue!
        let fields = saved["revision"]!.objectValue!["fields"]!.objectValue!
        XCTAssertEqual(fields["plannedDate"]?.objectValue?["value"]?.stringValue, "2026-03-29")
        XCTAssertNil(fields["requestIdentity"], "MCP write results omit the server receipt payload")
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: category.itemID,
                expectedRevisionID: category.revisionID, changes: ["subject": .text("Renamed")],
                operationID: "rename"))
        let replayData = try await MCPAdapter.callNativeTool(
            definition: commit, supplied: frozen, gateway: gateway)
        let replay = try JSONDecoder().decode(Value.self, from: replayData).objectValue!
        let replayFields = replay["revision"]!.objectValue!["fields"]!.objectValue!
        XCTAssertEqual(replay["replayed"]?.boolValue, true)
        XCTAssertEqual(replayFields["revisionID"], fields["revisionID"])
        let itemID = fields["itemID"]!.objectValue!["value"]!.stringValue!
        XCTAssertEqual(try store.history(itemID).count, 1)
    }

    func testAttachmentToolsAdvertiseReadOnlyBoundsAndRejectInvalidByteRanges() throws {
        let definitions = ToolCatalog.definitions()
        let list = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_attachments" })
        let content = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_attachment_content" })
        XCTAssertEqual(list.nativeMethod, "TractandaAttachment/list")
        XCTAssertEqual(content.nativeMethod, "TractandaAttachment/content")
        XCTAssertEqual(list.requiredFeature, ServerFeature.attachmentLifecycle.rawValue)
        XCTAssertEqual(content.requiredFeature, ServerFeature.attachmentLifecycle.rawValue)
        XCTAssertEqual(content.tool.annotations.readOnlyHint, true)
        XCTAssertEqual(content.tool.annotations.idempotentHint, true)
        XCTAssertEqual(content.tool.annotations.destructiveHint, false)
        XCTAssertEqual(content.tool.annotations.openWorldHint, false)
        XCTAssertEqual(
            content.tool.inputSchema.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?[
                "maximum"]?
                .intValue,
            65_536)
        XCTAssertEqual(
            content.tool.inputSchema.objectValue?["properties"]?.objectValue?["offset"]?.objectValue?[
                "maximum"]?
                .intValue,
            Int.max)
        let itemID = "11111111-1111-4111-8111-111111111111"
        let attachmentID = "22222222-2222-4222-8222-222222222222"
        XCTAssertEqual(
            try content.arguments(from: ["itemID": .string(itemID), "attachmentID": .string(attachmentID)])[
                "limit"], .int(4_096))
        XCTAssertThrowsError(
            try content.arguments(from: [
                "itemID": .string(itemID), "attachmentID": .string(attachmentID), "limit": .int(65_537),
            ]))
        for badOffset in [Value.bool(true), .double(1.5), .double(Double(Int64.max)), .int(-1)] {
            XCTAssertThrowsError(
                try content.arguments(from: [
                    "itemID": .string(itemID), "attachmentID": .string(attachmentID), "offset": badOffset,
                ]))
        }
        XCTAssertEqual(
            try content.arguments(from: [
                "itemID": .string(itemID), "attachmentID": .string(attachmentID),
                "offset": .int(Int(exactly: Int64.max)!),
            ])["offset"],
            .int(Int(exactly: Int64.max)!))
        XCTAssertThrowsError(
            try content.arguments(from: [
                "itemID": .string(itemID), "attachmentID": .string(attachmentID), "unknown": .bool(false),
            ]))
    }

    func testAttachmentContentForwardsLargeOffsetsWithoutAllocatingOriginalBytes() async throws {
        let offsets = [1_073_741_825, 1_099_511_627_776]
        let capture = NativeCallCapture()
        let gateway = NativeGateway(backend: { envelope in
            let request = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
            let call = (request["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = call[1] as! [String: Any]
            if method == "TractandaStore/info" {
                return try JSONSerialization.data(withJSONObject: [
                    "methodResponses": [
                        [
                            method,
                            [
                                "features": [ServerFeature.attachmentLifecycle.rawValue]
                            ], call[2],
                        ]
                    ]
                ])
            }
            let offset = (args["offset"] as! NSNumber).intValue
            await capture.append(
                CapturedNativeCall(
                    method: method, itemID: args["itemID"] as? String,
                    revisionID: args["revisionID"] as? String,
                    attachmentID: args["attachmentID"] as? String,
                    operationID: args["operationID"] as? String, offset: offset,
                    limit: (args["limit"] as? NSNumber)?.intValue, pageNumber: nil))
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [
                    [
                        method,
                        [
                            "attachment": ["attachmentID": "22222222-2222-4222-8222-222222222222"],
                            "offset": offset, "nextOffset": offset + 1, "isComplete": false,
                            "data": Data([0xA5]).base64EncodedString(),
                        ], call[2],
                    ]
                ]
            ])
        })
        let definition = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_attachment_content" })
        for offset in offsets {
            let response = try await MCPAdapter.callNativeTool(
                definition: definition,
                supplied: [
                    "itemID": .string("11111111-1111-4111-8111-111111111111"),
                    "attachmentID": .string("22222222-2222-4222-8222-222222222222"),
                    "offset": .int(offset), "limit": .int(1),
                ], gateway: gateway)
            let value = try JSONDecoder().decode(Value.self, from: response)
            XCTAssertEqual(value.objectValue?["offset"]?.intValue, offset)
            XCTAssertEqual(value.objectValue?["nextOffset"]?.intValue, offset + 1)
        }
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.compactMap(\.offset), offsets)
    }

    func testAttachmentContentPassesThroughAndReconstructsByteExactChunks() async throws {
        let capture = NativeCallCapture()
        let original = Data((0..<9_000).map { UInt8(($0 * 73) % 256) })
        let gateway = NativeGateway(backend: { envelope in
            let request = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
            let call = (request["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = call[1] as! [String: Any]
            await capture.append(
                CapturedNativeCall(
                    method: method, itemID: args["itemID"] as? String,
                    revisionID: args["revisionID"] as? String,
                    attachmentID: args["attachmentID"] as? String,
                    operationID: args["operationID"] as? String, offset: args["offset"] as? Int,
                    limit: args["limit"] as? Int, pageNumber: nil))
            let result: [String: Any]
            if method == "TractandaStore/info" {
                result = ["features": [ServerFeature.attachmentLifecycle.rawValue]]
            } else {
                let offset = (args["offset"] as! NSNumber).intValue
                let limit = (args["limit"] as! NSNumber).intValue
                let end = min(original.count, offset + limit)
                let bytes = original.subdata(in: offset..<end)
                result = [
                    "attachment": ["attachmentID": "22222222-2222-4222-8222-222222222222"],
                    "offset": offset, "nextOffset": end, "isComplete": end == original.count,
                    "data": bytes.base64EncodedString(),
                ]
            }
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [[method, result, call[2]]]
            ])
        })
        let definition = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_attachment_content" })
        let prefix: [String: Value] = [
            "itemID": .string("11111111-1111-4111-8111-111111111111"),
            "revisionID": .string("33333333-3333-4333-8333-333333333333"),
            "attachmentID": .string("22222222-2222-4222-8222-222222222222"),
        ]
        var reconstructed = Data()
        var offset = 0
        while offset < original.count {
            var supplied = prefix
            if offset > 0 { supplied["offset"] = .int(offset) }
            let response = try await MCPAdapter.callNativeTool(
                definition: definition, supplied: supplied, gateway: gateway)
            let value = try JSONDecoder().decode(Value.self, from: response)
            let object = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(object["offset"]?.intValue, offset)
            let chunk = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["data"]?.stringValue)))
            reconstructed.append(chunk)
            offset = try XCTUnwrap(object["nextOffset"]?.intValue)
            XCTAssertEqual(object["isComplete"]?.boolValue, offset == original.count)
        }
        XCTAssertEqual(reconstructed, original)
        let calls = await capture.snapshot()
        XCTAssertEqual(calls.filter { $0.method == "TractandaStore/info" }.count, 3)
        let contentCalls = calls.filter { $0.method == "TractandaAttachment/content" }
        XCTAssertEqual(contentCalls.count, 3)
        XCTAssertTrue(
            contentCalls.allSatisfy {
                $0.itemID == prefix["itemID"]?.stringValue
                    && $0.revisionID == prefix["revisionID"]?.stringValue
                    && $0.limit == 4_096
            })
        XCTAssertEqual(contentCalls[0].offset, 0)
        XCTAssertEqual(contentCalls[1].offset, 4_096)
        XCTAssertEqual(contentCalls[2].offset, 8_192)
    }

    func testAttachmentFeatureGateDistinguishesMissingAndUnverifiedDeclarations() throws {
        XCTAssertNoThrow(
            try MCPAdapter.requireFeature(
                ServerFeature.attachmentLifecycle.rawValue,
                serverInfoData: Data(#"{"features":["tractanda.attachment-lifecycle.v1"]}"#.utf8)))
        XCTAssertThrowsError(
            try MCPAdapter.requireFeature(
                ServerFeature.attachmentLifecycle.rawValue, serverInfoData: Data(#"{"features":[]}"#.utf8))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "unsupportedCapability")
        }
        XCTAssertThrowsError(
            try MCPAdapter.requireFeature(
                ServerFeature.attachmentLifecycle.rawValue, serverInfoData: Data("{}".utf8))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "featureUnverified")
        }
    }

    func testAttachmentMCPReadsUseNativeACLAndDoNotDiscloseAfterRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-mcp-attachment-" + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = AttachmentAccounts()
        let store = try ItemStore.initializeFresh(
            root: root, accounts: accounts,
            initialAccessConfiguration: .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]))
        let body = Data("tiny-original".utf8)
        let sha256 = "5ce819276cba11f0ced8df8de3c75ad66f4caaaeefa87317eb75b12129b3b6bb"
        let base = try store.commit(
            CommitRequest(
                classID: "Item",
                changes: [
                    "subject": .text("private attachment"),
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("alice"),
                        "group": .text("staff"), "mode": .integer(0o640), "acl": .object([:]),
                    ]),
                ], operationID: "fixture-item")
        ).revision
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "fixture-attach",
                filename: "private-name.png", mediaType: "image/png", byteCount: Int64(body.count),
                sha256: sha256))
        let uploadID = try XCTUnwrap(upload.uploadID)
        _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: body)
        let attached = try store.finishAttachment(uploadID: uploadID).revision
        let descriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.fields).first)
        let admission = try store.prepareAttachmentDocument(
            itemID: base.itemID, expectedRevisionID: attached.revisionID,
            attachmentID: descriptor.attachmentID, operationID: "fixture-document", identity: .init())
        guard case .prepared(let snapshot) = admission else {
            throw TractandaError("fixture", "Expected a prepared saved document page.")
        }
        let geometry = try DocumentPageGeometry(
            sourceWidth: 512, sourceHeight: 256, sourceUnit: "pixel",
            displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
            contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024)
        let parsed = try DoclingDocTagsParser.parse(
            Data("<doctag><text><loc_10><loc_20><loc_100><loc_80>MCP saved citation</text></doctag>".utf8))
        let page = try AttachmentDocumentPage(
            pageNumber: 1, geometry: geometry, rasterSHA256: String(repeating: "b", count: 64),
            parsed: parsed, generatedTokens: 4, stopReason: "stop")
        let documentCommit = try store.finishAttachmentDocument(snapshot, pages: [page])
        let savedRevision = try store.get(documentCommit.itemID)
        let service = ItemService(store: store)
        let bridge = NativeServiceBridge(service: service, peerUID: accounts.alice)
        let gateway = NativeGateway(backend: { request in
            bridge.handle(request)
        })
        let tools = ToolCatalog.definitions()
        let listTool = try XCTUnwrap(tools.first { $0.tool.name == "tractanda_attachments" })
        let contentTool = try XCTUnwrap(tools.first { $0.tool.name == "tractanda_attachment_content" })
        let savedPageTool = try XCTUnwrap(
            tools.first { $0.tool.name == "tractanda_attachment_document_page" })
        let listArgs: [String: Value] = [
            "itemID": .string(base.itemID), "revisionID": .string(savedRevision.revisionID),
        ]
        let listed = try await MCPAdapter.callNativeTool(
            definition: listTool, supplied: listArgs, gateway: gateway)
        let listedValue = try JSONDecoder().decode(Value.self, from: listed)
        XCTAssertEqual(
            listedValue.objectValue?["attachments"]?.arrayValue?.first?.objectValue?["filename"]?.stringValue,
            "private-name.png")

        let savedPageArgs: [String: Value] = [
            "itemID": .string(base.itemID), "revisionID": .string(savedRevision.revisionID),
            "attachmentID": .string(descriptor.attachmentID), "pageNumber": .int(1),
        ]
        let savedPageResponse = try await MCPAdapter.callNativeTool(
            definition: savedPageTool, supplied: savedPageArgs, gateway: gateway)
        let savedPageValue = try JSONDecoder().decode(Value.self, from: savedPageResponse)
        XCTAssertEqual(savedPageValue.objectValue?["itemID"]?.stringValue, base.itemID)
        XCTAssertEqual(savedPageValue.objectValue?["revisionID"]?.stringValue, savedRevision.revisionID)
        XCTAssertEqual(savedPageValue.objectValue?["selectedPageNumber"]?.intValue, 1)
        XCTAssertEqual(savedPageValue.objectValue?["totalPageCount"]?.intValue, 1)
        let savedPageObject = try XCTUnwrap(
            savedPageValue.objectValue?["pages"]?.arrayValue?.first?.objectValue)
        let parsedPage = try XCTUnwrap(savedPageObject["parsed"]?.objectValue)
        XCTAssertTrue(parsedPage["text"]?.stringValue?.contains("MCP saved citation") == true)

        let contentArgs: [String: Value] = [
            "itemID": .string(base.itemID), "revisionID": .string(savedRevision.revisionID),
            "attachmentID": .string(descriptor.attachmentID), "limit": .int(3),
        ]
        var rebuilt = Data()
        var offset = 0
        while offset < body.count {
            var args = contentArgs
            args["offset"] = .int(offset)
            let result = try await MCPAdapter.callNativeTool(
                definition: contentTool, supplied: args, gateway: gateway)
            let value = try JSONDecoder().decode(Value.self, from: result)
            let object = try XCTUnwrap(value.objectValue)
            rebuilt.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["data"]?.stringValue))))
            offset = try XCTUnwrap(object["nextOffset"]?.intValue)
            XCTAssertEqual(object["isComplete"]?.boolValue, offset == body.count)
        }
        XCTAssertEqual(rebuilt, body)

        let missingArgs: [String: Value] = [
            "itemID": .string(base.itemID), "revisionID": .string(attached.revisionID),
            "attachmentID": .string("44444444-4444-4444-8444-444444444444"),
        ]
        do {
            _ = try await MCPAdapter.callNativeTool(
                definition: contentTool, supplied: missingArgs, gateway: gateway)
            XCTFail("Expected missing attachment to be hidden.")
        } catch {
            let failure = try MCPAdapter.toolFailure(error, operationID: nil)
            let encoded = try JSONEncoder().encode(failure)
            let text = String(decoding: encoded, as: UTF8.self)
            XCTAssertTrue(text.contains("notFound"))
            XCTAssertFalse(text.contains("private-name.png"))
            XCTAssertFalse(text.contains(body.base64EncodedString()))
        }

        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: base.itemID, expectedRevisionID: savedRevision.revisionID,
                changes: [
                    "permissions": .object([
                        "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                        "group": .text("staff"), "mode": .integer(0o600), "acl": .object([:]),
                    ])
                ], operationID: "fixture-revoke"))
        for definition in [listTool, contentTool, savedPageTool] {
            do {
                let supplied: [String: Value]
                switch definition.nativeMethod {
                case "TractandaAttachment/list": supplied = listArgs
                case "TractandaAttachment/content": supplied = contentArgs
                default: supplied = savedPageArgs
                }
                _ = try await MCPAdapter.callNativeTool(
                    definition: definition, supplied: supplied, gateway: gateway)
                XCTFail("Expected current ACL revocation to deny historical attachment access.")
            } catch {
                let failure = try MCPAdapter.toolFailure(error, operationID: nil)
                let encoded = try JSONEncoder().encode(failure)
                let text = String(decoding: encoded, as: UTF8.self)
                XCTAssertTrue(text.contains("forbidden"))
                XCTAssertFalse(text.contains("private-name.png"))
                XCTAssertFalse(text.contains(body.base64EncodedString()))
            }
        }

        let largest = Data(repeating: 0xA5, count: 65_536)
        let largestResult = try JSONEncoder().encode(
            Value.object([
                "data": .string(largest.base64EncodedString()), "isComplete": .bool(true),
            ]))
        for format in [MCPResultFormat.both, .text, .structured] {
            let framed = try MCPAdapter.toolResult(data: largestResult, resultFormat: format)
            XCTAssertLessThan(try JSONEncoder().encode(framed).count, NativeGateway.maximumResultSize)
        }
    }

    func testDocumentJobCatalogHintsAndStrictBoundedArguments() throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: ToolCatalog.definitions().map { ($0.tool.name, $0) })
        let itemID = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        let revisionID = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
        let attachmentID = "6ba7b812-9dad-11d1-80b4-00c04fd430c8"
        let jobID = "6ba7b813-9dad-11d1-80b4-00c04fd430c8"
        let start = try XCTUnwrap(definitions["tractanda_document_job_start"])
        XCTAssertEqual(start.nativeMethod, "TractandaDocumentJob/start")
        XCTAssertEqual(start.requiredFeature, "tractanda.document-jobs.v1")
        XCTAssertFalse(start.readOnly)
        XCTAssertTrue(start.idempotent)
        let startArgs: [String: Value] = [
            "itemID": .string(itemID), "expectedRevisionID": .string(revisionID),
            "attachmentID": .string(attachmentID), "operationID": .string("stable-job-start"),
        ]
        XCTAssertNoThrow(try start.arguments(from: startArgs))
        XCTAssertThrowsError(try start.arguments(from: ["itemID": .string(itemID)]))
        XCTAssertThrowsError(
            try start.arguments(from: startArgs.merging(["extra": .bool(false)]) { _, v in v }))
        XCTAssertThrowsError(
            try start.arguments(
                from: startArgs.merging(["itemID": .string("44444444-4444-4444-8444-444444444444")]) { _, v in
                    v
                }))
        XCTAssertThrowsError(
            try start.arguments(
                from: startArgs.merging(["operationID": .string(String(repeating: "x", count: 201))]) {
                    _, v in v
                }))

        for (name, method) in [
            ("tractanda_document_job_status", "TractandaDocumentJob/status"),
            ("tractanda_document_job_cancel", "TractandaDocumentJob/cancel"),
            ("tractanda_document_job_resume", "TractandaDocumentJob/resume"),
            ("tractanda_document_job_rebase", "TractandaDocumentJob/rebase"),
            ("tractanda_document_job_page", "TractandaDocumentJob/page"),
            ("tractanda_document_job_discard", "TractandaDocumentJob/discard"),
            ("tractanda_document_jobs", "TractandaDocumentJob/list"),
        ] {
            let definition = try XCTUnwrap(definitions[name])
            XCTAssertEqual(definition.nativeMethod, method)
            XCTAssertEqual(definition.requiredFeature, "tractanda.document-jobs.v1")
        }
        let status = try XCTUnwrap(definitions["tractanda_document_job_status"])
        XCTAssertTrue(status.readOnly)
        XCTAssertTrue(status.idempotent)
        for name in [
            "tractanda_document_job_cancel", "tractanda_document_job_resume", "tractanda_document_job_rebase",
        ] {
            let definition = try XCTUnwrap(definitions[name])
            XCTAssertFalse(definition.readOnly)
            XCTAssertFalse(definition.idempotent)
            XCTAssertFalse(definition.destructive)
        }
        let discard = try XCTUnwrap(definitions["tractanda_document_job_discard"])
        XCTAssertTrue(discard.tool.annotations.destructiveHint == true)
        XCTAssertFalse(discard.idempotent)

        let page = try XCTUnwrap(definitions["tractanda_document_job_page"])
        XCTAssertTrue(page.readOnly)
        XCTAssertTrue(page.description.contains("provisional"))
        XCTAssertTrue(page.description.contains("no canonical revision identity or citation"))
        XCTAssertNoThrow(try page.arguments(from: ["jobID": .string(jobID), "pageNumber": .int(Int.max)]))
        for bad in [Value.bool(true), .double(1.0), .double(Double(Int64.max)), .int(0), .int(-1)] {
            XCTAssertThrowsError(try page.arguments(from: ["jobID": .string(jobID), "pageNumber": bad]))
        }
        XCTAssertThrowsError(
            try page.arguments(from: ["jobID": .string("not-a-uuid"), "pageNumber": .int(1)]))

        let jobs = try XCTUnwrap(definitions["tractanda_document_jobs"])
        XCTAssertEqual(try jobs.arguments(from: [:])["limit"], .int(32))
        XCTAssertEqual(try jobs.arguments(from: ["limit": .int(64)])["limit"], .int(64))
        for bad in [Value.bool(true), .double(2.0), .int(0), .int(65)] {
            XCTAssertThrowsError(try jobs.arguments(from: ["limit": bad]))
        }
        XCTAssertThrowsError(
            try jobs.arguments(from: ["afterJobID": .string("44444444-4444-4444-8444-444444444444")]))

        let saved = try XCTUnwrap(definitions["tractanda_attachment_document_page"])
        XCTAssertEqual(saved.nativeMethod, "TractandaAttachment/document")
        XCTAssertEqual(saved.requiredFeature, ServerFeature.attachmentDocument.rawValue)
        XCTAssertTrue(saved.readOnly)
        XCTAssertTrue(saved.description.contains("never reads a whole representation"))
        let savedArgs: [String: Value] = [
            "itemID": .string(itemID), "attachmentID": .string(attachmentID), "pageNumber": .int(101),
        ]
        XCTAssertEqual(try saved.arguments(from: savedArgs)["maxBytes"], .int(65_536))
        XCTAssertNoThrow(
            try saved.arguments(from: savedArgs.merging(["maxBytes": .int(262_144)]) { _, v in v }))
        for bad in [Value.bool(true), .double(101.0), .int(0)] {
            XCTAssertThrowsError(
                try saved.arguments(from: savedArgs.merging(["pageNumber": bad]) { _, v in v }))
        }
        XCTAssertThrowsError(
            try saved.arguments(from: savedArgs.merging(["maxBytes": .int(262_145)]) { _, v in v }))
    }

    func testDocumentJobBridgeUsesFreshFeatureAndForwardsPageOver100() async throws {
        let itemID = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
        let revisionID = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
        let attachmentID = "6ba7b812-9dad-11d1-80b4-00c04fd430c8"
        let jobID = "6ba7b813-9dad-11d1-80b4-00c04fd430c8"
        let capture = NativeCallCapture()
        let gateway = NativeGateway(backend: { envelope in
            let request = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
            let call = (request["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = call[1] as! [String: Any]
            if method == "TractandaStore/info" {
                return try JSONSerialization.data(withJSONObject: [
                    "methodResponses": [
                        [
                            method,
                            [
                                "features": [
                                    "tractanda.document-jobs.v1", ServerFeature.attachmentDocument.rawValue,
                                ],
                                "documentExtraction": "unavailable",
                            ], call[2],
                        ]
                    ]
                ])
            }
            await capture.append(
                CapturedNativeCall(
                    method: method, itemID: args["itemID"] as? String,
                    revisionID: args["expectedRevisionID"] as? String ?? args["revisionID"] as? String,
                    attachmentID: args["attachmentID"] as? String,
                    operationID: args["operationID"] as? String,
                    offset: nil, limit: (args["limit"] as? NSNumber)?.intValue,
                    pageNumber: (args["pageNumber"] as? NSNumber)?.intValue))
            let result: [String: Any]
            if method == "TractandaDocumentJob/list" {
                result = ["jobs": [], "nextJobID": NSNull()]
            } else if method == "TractandaDocumentJob/page" {
                result = ["jobID": jobID, "provisional": true, "outcome": ["pageNumber": 101]]
            } else if method == "TractandaAttachment/document" {
                result = [
                    "itemID": itemID, "revisionID": revisionID, "attachmentID": attachmentID,
                    "selectedPageNumber": 101, "totalPageCount": 101,
                    "pages": [["pageNumber": 101, "citation": "saved-canonical-page"]],
                ]
            } else {
                result = ["jobID": jobID, "state": method.hasSuffix("/start") ? "queued" : "paused"]
            }
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [[method, result, call[2]]]
            ])
        })
        let inputs: [(String, [String: Value])] = [
            (
                "tractanda_document_job_start",
                [
                    "itemID": .string(itemID), "expectedRevisionID": .string(revisionID),
                    "attachmentID": .string(attachmentID), "operationID": .string("mcp-job-start"),
                ]
            ),
            ("tractanda_document_job_status", ["jobID": .string(jobID)]),
            ("tractanda_document_job_cancel", ["jobID": .string(jobID)]),
            ("tractanda_document_job_resume", ["jobID": .string(jobID)]),
            (
                "tractanda_document_job_rebase",
                [
                    "jobID": .string(jobID), "expectedRevisionID": .string(revisionID),
                ]
            ),
            ("tractanda_document_job_page", ["jobID": .string(jobID), "pageNumber": .int(101)]),
            ("tractanda_document_job_discard", ["jobID": .string(jobID)]),
            ("tractanda_document_jobs", [:]),
            (
                "tractanda_attachment_document_page",
                [
                    "itemID": .string(itemID), "attachmentID": .string(attachmentID),
                    "revisionID": .string(revisionID), "pageNumber": .int(101),
                ]
            ),
        ]
        for (name, supplied) in inputs {
            let definition = try XCTUnwrap(ToolCatalog.definitions().first { $0.tool.name == name })
            let response = try await MCPAdapter.callNativeTool(
                definition: definition, supplied: supplied, gateway: gateway)
            let value = try JSONDecoder().decode(Value.self, from: response)
            if name == "tractanda_document_job_page" {
                XCTAssertEqual(value.objectValue?["provisional"]?.boolValue, true)
                XCTAssertEqual(value.objectValue?["outcome"]?.objectValue?["pageNumber"]?.intValue, 101)
            }
            if name == "tractanda_attachment_document_page" {
                XCTAssertEqual(value.objectValue?["selectedPageNumber"]?.intValue, 101)
                XCTAssertEqual(value.objectValue?["revisionID"]?.stringValue, revisionID)
            }
        }
        let calls = await capture.snapshot()
        XCTAssertEqual(
            calls.map(\.method),
            [
                "TractandaDocumentJob/start", "TractandaDocumentJob/status", "TractandaDocumentJob/cancel",
                "TractandaDocumentJob/resume", "TractandaDocumentJob/rebase", "TractandaDocumentJob/page",
                "TractandaDocumentJob/discard", "TractandaDocumentJob/list", "TractandaAttachment/document",
            ])
        XCTAssertEqual(calls[0].itemID, itemID)
        XCTAssertEqual(calls[0].revisionID, revisionID)
        XCTAssertEqual(calls[0].attachmentID, attachmentID)
        XCTAssertEqual(calls[0].operationID, "mcp-job-start")
        XCTAssertEqual(calls[5].limit, nil)
        XCTAssertEqual(calls[5].pageNumber, 101)
        XCTAssertEqual(calls[8].pageNumber, 101)
        XCTAssertEqual(calls[7].limit, 32)
    }

    func testDocumentJobFeatureMismatchIsFreshAndConfigurationIndependent() async throws {
        let jobID = "6ba7b813-9dad-11d1-80b4-00c04fd430c8"
        let calls = NativeCallCapture()
        let unsupported = NativeGateway(backend: { envelope in
            let request = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
            let call = (request["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            await calls.append(
                CapturedNativeCall(
                    method: method, itemID: nil, revisionID: nil, attachmentID: nil,
                    operationID: nil, offset: nil, limit: nil, pageNumber: nil))
            let result: [String: Any] =
                method == "TractandaStore/info"
                ? ["features": [], "documentExtraction": "unavailable"] : ["jobID": jobID]
            return try JSONSerialization.data(withJSONObject: [
                "methodResponses": [[method, result, call[2]]]
            ])
        })
        let status = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_document_job_status" })
        do {
            _ = try await MCPAdapter.callNativeTool(
                definition: status, supplied: ["jobID": .string(jobID)], gateway: unsupported)
            XCTFail("Expected a fresh feature mismatch.")
        } catch let error as TractandaError {
            XCTAssertEqual(error.code, "unsupportedCapability")
        }
        let capturedCalls = await calls.snapshot()
        let calledMethods = capturedCalls.map(\.method)
        XCTAssertEqual(calledMethods, ["TractandaStore/info"])
    }

    func testPageToolResultBudgetIncludesJSONEscapingAndMCPWrapper() throws {
        let small = try JSONSerialization.data(withJSONObject: ["page": String(repeating: "x", count: 65_536)]
        )
        let smallResult = try MCPAdapter.toolResult(data: small)
        XCTAssertNoThrow(try MCPAdapter.checkedPageToolResult(smallResult))

        let nominalPage = try JSONSerialization.data(
            withJSONObject: ["page": String(repeating: "x", count: 262_144)])
        XCTAssertLessThan(nominalPage.count, NativeGateway.maximumResultSize)
        let wrapped = try MCPAdapter.toolResult(data: nominalPage)
        XCTAssertGreaterThan(
            try JSONEncoder().encode(wrapped).count, MCPAdapter.maximumSerializedPageToolResultBytes)
        XCTAssertThrowsError(try MCPAdapter.checkedPageToolResult(wrapped)) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "responseTooLarge")
        }

        let escaped = try JSONSerialization.data(
            withJSONObject: ["page": String(repeating: "\\", count: 100_000)])
        XCTAssertLessThan(escaped.count, NativeGateway.maximumResultSize)
        let escapedResult = try MCPAdapter.toolResult(data: escaped)
        XCTAssertThrowsError(try MCPAdapter.checkedPageToolResult(escapedResult)) { error in
            XCTAssertEqual((error as? TractandaError)?.code, "responseTooLarge")
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
        let rootID = "44444444-4444-4444-8444-444444444444"
        XCTAssertNoThrow(
            try query.arguments(from: [
                "sort": .array([
                    .object([
                        "categoryRootID": .string(rootID), "isAscending": .bool(true),
                    ])
                ])
            ]))
        XCTAssertThrowsError(
            try query.arguments(from: [
                "sort": .array([
                    .object([
                        "categoryRootID": .string(rootID), "property": .string("subject"),
                    ])
                ])
            ]))
        XCTAssertThrowsError(
            try query.arguments(from: [
                "sort": .array([
                    .object([
                        "categoryRootID": .string("not-an-id")
                    ])
                ])
            ]))
        XCTAssertEqual(
            definitions.first { $0.tool.name == "tractanda_memberships" }?.nativeMethod,
            "TractandaCategory/memberships")
        XCTAssertThrowsError(try query.arguments(from: ["sectionID": .string("id")]))
        XCTAssertThrowsError(try query.arguments(from: ["viewID": .string("id"), "sort": .array([])]))

        let get = try XCTUnwrap(definitions.first { $0.tool.name == "tractanda_get" })
        for name in ["tractanda_get", "tractanda_history", "tractanda_revision"] {
            let tool = try XCTUnwrap(definitions.first { $0.tool.name == name })
            XCTAssertTrue(tool.description.contains("projection and properties are mutually exclusive"))
            var arguments: [String: Value] = [
                "projection": .string("summary"), "properties": .array([.string("subject")]),
            ]
            if name == "tractanda_get" {
                arguments["ids"] = .array([.string(rootID)])
            } else {
                arguments["itemID"] = .string(rootID)
            }
            if name == "tractanda_revision" { arguments["revisionID"] = .string(rootID) }
            XCTAssertThrowsError(try tool.arguments(from: arguments)) { error in
                XCTAssertTrue((error as? TractandaError)?.message.contains("mutually exclusive") == true)
            }
        }
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

    func testExtractedTextToolDescribesAndValidatesItsIndependentLimits() throws {
        let tool = try XCTUnwrap(
            ToolCatalog.definitions().first { $0.tool.name == "tractanda_extracted_text" })
        XCTAssertEqual(tool.nativeMethod, "TractandaItem/extractedText")
        XCTAssertTrue(tool.readOnly)
        XCTAssertFalse(tool.destructive)
        let id = "44444444-4444-4444-8444-444444444444"
        XCTAssertNoThrow(
            try tool.arguments(from: [
                "ids": .array([.string(id)]), "projection": .string("fts"), "maxBytes": .int(8_192),
            ]))
        XCTAssertThrowsError(
            try tool.arguments(from: ["ids": .array([.string(id)]), "projection": .string("content")]))
        XCTAssertThrowsError(try tool.arguments(from: ["ids": .array([.string(id), .string(id)])]))
        XCTAssertThrowsError(
            try tool.arguments(from: ["ids": .array([.string(id)]), "maxBytes": .int(8_191)]))
        XCTAssertThrowsError(
            try tool.arguments(from: ["ids": .array([.string(id)]), "properties": .array([])]))
        XCTAssertTrue(tool.description.contains("oversizedIDs"))
        XCTAssertTrue(tool.description.contains("tractanda.extracted-text.v1"))
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
        let documentJobs = try XCTUnwrap(ResourceCatalog.references.first { $0.key == "document-jobs" })
        XCTAssertTrue(documentJobs.text.contains("tractanda.document-jobs.v1"))
        XCTAssertTrue(documentJobs.text.contains("provisional"))
        XCTAssertTrue(documentJobs.text.contains("tractanda_attachment_document_page"))
        XCTAssertTrue(ResourceCatalog.requiredServerFeatures.contains("tractanda.document-jobs.v1"))
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
