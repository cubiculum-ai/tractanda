import Foundation
import NIOCore
import Synchronization
import TractandaClient
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

final class PersonalPeerJMAPTests: XCTestCase {
    private func binding() throws -> PeerExchangeBinding {
        try .init(
            peerID: "remote-dial", storeID: UUID.makeVersion1().uuidString.lowercased(),
            localReplicaID: UUID.makeVersion1().uuidString.lowercased(),
            remoteReplicaID: UUID.makeVersion1().uuidString.lowercased(),
            pairingID: UUID.makeVersion1().uuidString.lowercased(), localIsInitiator: true,
            configurationDigest: String(repeating: "a", count: 64))
    }
    private func wire(
        _ method: String, account: String, capabilities: [String] = [PersonalPeerJMAP.capability],
        callID: String = "peer", fields: JMAPValue = .object([])
    ) throws -> Data {
        var arguments = fields.members ?? []
        if arguments.isEmpty {
            if method == "TractandaPeer/inventory" {
                arguments = [.init("offset", .string("0")), .init("limit", .number(try JMAPNumber("128")))]
            } else if method == "TractandaPeer/read" {
                let descriptor = try PersonalObjectDescriptor(
                    kind: .revision, id: UUID.makeVersion1().uuidString.lowercased(), byteCount: 1,
                    sha256: String(repeating: "a", count: 64),
                    itemID: UUID.makeVersion1().uuidString.lowercased())
                arguments = try PersonalPeerJMAP.arguments(
                    .init(
                        "personal.read",
                        [
                            "descriptor": .bytes(JSON.encode(descriptor)), "offset": .integer(0),
                            "limit": .integer(262144),
                        ]), accountID: account
                ).members!.filter { $0.name != "accountId" }
            }
        }
        return try JMAPValue.object([
            .init("using", .array(capabilities.map(JMAPValue.string))),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: method, arguments: .object([.init("accountId", .string(account))] + arguments),
                        callID: callID
                    ).value
                ])),
        ]).encoded()
    }

    private func response(_ result: PersonalPeerJMAP.Reply) throws -> JMAPValue {
        guard case .response(let data) = result else {
            throw TractandaError("testFailure", "Expected method response")
        }
        return try JMAPValue.decode(data)
    }
    private func errorType(_ value: JMAPValue) -> String? {
        value["methodResponses"]?.elements?.first?.elements?[1]["type"]?.text
    }

    func testExactOuterFrameBudgetCoversWorstBase64AndCorrelation() throws {
        // Fixed bounded frame bodies; no filesystem fixture or persistent data.
        let maximum = try PeerExchangeCodec.maximumPersonalBodyBytes()
        for kind: PeerExchangeCodec.Kind in [.request, .response, .failure, .acknowledgement] {
            let frame = PeerExchangeCodec.Frame(
                version: PersonalPeerJMAP.wireVersion, requestID: UInt64.max, kind: kind,
                body: Data(repeating: 255, count: maximum))
            let encoded = try PeerExchangeCodec.encode(frame, allocator: ByteBufferAllocator())
            XCTAssertLessThanOrEqual(encoded.readableBytes, PeerExchangeCodec.maximumFrameBytes + 4)
        }
        XCTAssertThrowsError(
            try PeerExchangeCodec.encode(
                .init(
                    version: PersonalPeerJMAP.wireVersion, requestID: UInt64.max, kind: .acknowledgement,
                    body: Data(repeating: 255, count: maximum + 3)), allocator: ByteBufferAllocator()))
        XCTAssertLessThan(maximum, PeerExchangeCodec.maximumFrameBytes)
    }

    func testMalformedAndUnknownCapabilityRequestsAreTypedProblemsBeforeDomain() async throws {
        let bound = try binding()
        let called = Mutex(0)
        for data in [
            Data("{".utf8),
            try wire(
                "TractandaPeer/read", account: bound.storeID, capabilities: ["https://example.test/unknown"]),
        ] {
            let result = try await PersonalPeerJMAP.execute(
                data, binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
                validate: { _ in },
                perform: { _, _ in
                    called.withLock { $0 += 1 }
                    return Data()
                })
            guard case .problem(let problem) = result else { return XCTFail("Expected request problem") }
            XCTAssertNotNil(JMAPProblem.decode(problem))
            XCTAssertTrue(try PersonalPeerJMAP.problem(problem) is JMAPProblem)
        }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testForeignAccountUserMethodsAndPushIntakeNeverEnterGateway() async throws {
        let bound = try binding()
        let called = Mutex(0)
        for (method, account, expected) in [
            ("TractandaPeer/read", "foreign", "accountNotFound"),
            ("TractandaItem/commit", bound.storeID, "unknownMethod"),
            ("TractandaPeer/prepare", bound.storeID, "unknownMethod"),
            ("TractandaPeer/apply", bound.storeID, "unknownMethod"),
        ] {
            let result = try await PersonalPeerJMAP.execute(
                wire(method, account: account), binding: bound,
                maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(), validate: { _ in },
                perform: { _, _ in
                    called.withLock { $0 += 1 }
                    return Data()
                })
            XCTAssertEqual(errorType(try response(result)), expected)
        }
        XCTAssertThrowsError(
            try PersonalPeerJMAP.request(
                .init("personal.prepare"), binding: bound,
                maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes()))
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testBoundedByteReplyAndCapturedNodeMetadataRoundTrip() async throws {
        let bound = try binding()
        let descriptor = try PersonalObjectDescriptor(
            kind: .revision, id: UUID.makeVersion1().uuidString.lowercased(), byteCount: 1,
            sha256: String(repeating: "a", count: 64), itemID: UUID.makeVersion1().uuidString.lowercased())
        let request = PeerExchangeRequest(
            "personal.read",
            [
                "descriptor": .bytes(try JSON.encode(descriptor)), "offset": .integer(0),
                "limit": .integer(262144),
            ])
        let bytes = Data(repeating: 255, count: 256 * 1024)
        let result = try await PersonalPeerJMAP.execute(
            PersonalPeerJMAP.request(
                request, binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes()),
            binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in },
            perform: { received, operation in
                XCTAssertEqual(received, bound)
                XCTAssertEqual(operation.operation, "personal.read")
                return bytes
            })
        guard case .response(let data) = result else { return XCTFail("Expected response") }
        XCTAssertEqual(try PersonalPeerJMAP.response(data, request: request), bytes)
        XCTAssertNotNil(try JMAPValue.decode(data)["sessionState"]?.text)
        XCTAssertLessThan(data.count, try PeerExchangeCodec.maximumPersonalBodyBytes())
    }

    func testSnapshotFailureAndMalformedMetadataArePartial() async throws {
        let bound = try binding()
        for oversized in [false, true] {
            let result = try await PersonalPeerJMAP.execute(
                wire("TractandaPeer/inventory", account: bound.storeID), binding: bound,
                maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(), validate: { _ in },
                perform: { _, _ in
                    if oversized {
                        return Data(repeating: 0, count: PersonalPeerJMAP.maximumChunkBytes + 1)
                    }
                    throw TractandaError("diskFull", "Simulated after snapshot effect")
                })
            XCTAssertEqual(errorType(try response(result)), "serverPartialFail")
        }
    }

    func testLongCorrelationRejectsSnapshotBeforeGatewayEffects() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let result = try await PersonalPeerJMAP.execute(
            wire(
                "TractandaPeer/inventory", account: bound.storeID,
                callID: String(repeating: "x", count: 96 * 1024)),
            binding: bound, maximumBodyBytes: 200 * 1024, validate: { _ in },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return Data()
            })
        XCTAssertEqual(errorType(try response(result)), "responseTooLarge")
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testReadonlyOverrunAndRevokedBindingRemainDistinctMethodErrors() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let oversized = try await PersonalPeerJMAP.execute(
            wire("TractandaPeer/read", account: bound.storeID), binding: bound,
            maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(), validate: { _ in },
            perform: { _, _ in Data(repeating: 0, count: PersonalPeerJMAP.maximumChunkBytes + 1) })
        XCTAssertEqual(errorType(try response(oversized)), "responseTooLarge")
        do {
            _ = try await PersonalPeerJMAP.execute(
                wire("TractandaPeer/inventory", account: bound.storeID), binding: bound,
                maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
                validate: { _ in throw TractandaError("untrustedPeer", "Removed member") },
                perform: { _, _ in
                    called.withLock { $0 += 1 }
                    return Data()
                })
            XCTFail("A removed peer entered the request engine")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testCoreOnlyEchoRequiresCurrentBindingAndCannotOptIntoPeerReads() async throws {
        let bound = try binding()
        let validations = Mutex(0)
        let called = Mutex(0)
        let echo = try await PersonalPeerJMAP.execute(
            wire("Core/echo", account: bound.storeID, capabilities: [JMAPKernel.core]),
            binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in validations.withLock { $0 += 1 } },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return Data()
            })
        let value = try response(echo)
        XCTAssertEqual(value["methodResponses"]?.elements?.first?.elements?[0].text, "Core/echo")
        XCTAssertEqual(validations.withLock { $0 }, 1)
        let unopted = try await PersonalPeerJMAP.execute(
            wire("TractandaPeer/read", account: bound.storeID, capabilities: [JMAPKernel.core]),
            binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return Data()
            })
        XCTAssertEqual(errorType(try response(unopted)), "unknownMethod")
        do {
            _ = try await PersonalPeerJMAP.execute(
                wire("Core/echo", account: bound.storeID, capabilities: [JMAPKernel.core]),
                binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
                validate: { _ in throw TractandaError("untrustedPeer", "Removed member") },
                perform: { _, _ in
                    called.withLock { $0 += 1 }
                    return Data()
                })
            XCTFail("A removed peer dispatched echo")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "untrustedPeer") }
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testStructuredDescriptorsAndInt64OffsetsRoundTripWithoutDoubleRounding() throws {
        let bound = try binding()
        let attachment = try AttachmentDescriptor(
            attachmentID: UUID.makeVersion1().uuidString.lowercased(), filename: "Original.pdf",
            mediaType: "application/pdf", byteCount: Int64.max, sha256: String(repeating: "a", count: 64))
        let descriptor = try PersonalObjectDescriptor(
            kind: .original, id: attachment.attachmentID, byteCount: attachment.byteCount,
            sha256: attachment.sha256, attachment: attachment)
        let request = PeerExchangeRequest(
            "personal.read",
            [
                "descriptor": .bytes(try JSON.encode(descriptor)), "offset": .integer(Int64.max - 1),
                "limit": .integer(1),
            ])
        let arguments = try PersonalPeerJMAP.arguments(request, accountID: bound.storeID)
        XCTAssertNil(arguments["fields"])
        XCTAssertEqual(arguments["descriptor"]?["byteCount"]?.text, String(Int64.max))
        XCTAssertEqual(arguments["descriptor"]?["attachment"]?["byteCount"]?.text, String(Int64.max))
        XCTAssertEqual(arguments["offset"]?.text, String(Int64.max - 1))
        let decoded = try PersonalPeerJMAP.internalRequest(
            arguments, operation: "personal.read", binding: bound)
        XCTAssertEqual(decoded.fields, request.fields)
        let document = try PersonalObjectDescriptor(
            kind: .document, id: UUID.makeVersion1().uuidString.lowercased(), byteCount: 1,
            sha256: String(repeating: "a", count: 64), part: .init(role: .page, ordinal: Int64.max))
        let documentRequest = PeerExchangeRequest(
            "personal.dependencies",
            ["descriptor": .bytes(try JSON.encode(document)), "offset": .integer(0), "limit": .integer(1)])
        let documentArguments = try PersonalPeerJMAP.arguments(documentRequest, accountID: bound.storeID)
        XCTAssertEqual(documentArguments["descriptor"]?["part"]?["ordinal"]?.text, String(Int64.max))
        XCTAssertEqual(
            try PersonalPeerJMAP.internalRequest(
                documentArguments, operation: documentRequest.operation, binding: bound
            ).fields, documentRequest.fields)
        let page = try PersonalInventoryPage(
            snapshotID: UUID.makeVersion1().uuidString.lowercased(), generationID: "generation",
            cutRowID: Int64.max, entries: [], nextOffset: Int.max, complete: false)
        let structured = try PersonalPeerJMAP.result(JSON.encode(page), operation: "personal.inventory")
        XCTAssertNil(structured["data"])
        XCTAssertEqual(structured["cutRowID"]?.text, String(Int64.max))
        let dependencies = PersonalDependencyPage(entries: [descriptor], nextOffset: nil, complete: true)
        let dependencyJSON = try PersonalPeerJMAP.result(
            JSON.encode(dependencies), operation: "personal.dependencies")
        XCTAssertEqual(dependencyJSON["entries"]?.elements?.first?["id"]?.text, attachment.attachmentID)
        XCTAssertEqual(
            try JSON.decode(
                PersonalDependencyPage.self,
                PersonalPeerJMAP.internalResult(dependencyJSON, operation: "personal.dependencies")),
            dependencies)
        let restored = try JSON.decode(
            PersonalInventoryPage.self,
            PersonalPeerJMAP.internalResult(structured, operation: "personal.inventory"))
        XCTAssertEqual(restored, page)
    }

    func testStructuredMembershipPreparationAndReadinessRoundTrip() throws {
        let bound = try binding()
        let configuration = try PersonalMembershipConfiguration(
            storeID: bound.storeID, configurationID: UUID.makeVersion1().uuidString.lowercased(),
            members: [
                try .init(replicaID: bound.localReplicaID, hostname: "local.example"),
                try .init(replicaID: bound.remoteReplicaID, hostname: "remote.example"),
            ])
        let preparation = try PersonalMembershipPreparation(
            configuration: configuration, expectedDigest: nil,
            nonce: UUID.makeVersion1().uuidString.lowercased(), administrator: "alice",
            requiredOnlineReplicaIDs: [bound.localReplicaID, bound.remoteReplicaID], readmission: false)
        let request = PeerExchangeRequest(
            "personal.membership.ready", ["preparation": .bytes(try JSON.encode(preparation))])
        let arguments = try PersonalPeerJMAP.arguments(request, accountID: bound.storeID)
        XCTAssertNotNil(arguments["preparation"]?["configuration"]?["members"]?.elements)
        XCTAssertEqual(
            try PersonalPeerJMAP.internalRequest(arguments, operation: request.operation, binding: bound)
                .fields, request.fields)
        let ready = PersonalMembershipReady(
            configurationDigest: try configuration.digest, nonce: preparation.nonce,
            replicaID: bound.remoteReplicaID, administrator: "alice")
        let result = try PersonalPeerJMAP.result(JSON.encode(ready), operation: request.operation)
        XCTAssertEqual(result["administrator"]?.text, "alice")
        XCTAssertEqual(
            try JSON.decode(
                PersonalMembershipReady.self,
                PersonalPeerJMAP.internalResult(result, operation: request.operation)), ready)
    }

    func testStructuredInventoryReferenceClosesSnapshotInSameBatch() async throws {
        let bound = try binding()
        let snapshot = try UUID.makeVersion1().uuidString.lowercased()
        let calls = Mutex<[String]>([])
        let request = try JMAPValue.object([
            .init("using", .array([.string(PersonalPeerJMAP.capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(
                        name: "TractandaPeer/inventory",
                        arguments: .object([
                            .init("accountId", .string(bound.storeID)), .init("offset", .string("0")),
                            .init("limit", .number(try JMAPNumber("1"))),
                        ]), callID: "i"
                    ).value,
                    JMAPInvocation(
                        name: "TractandaPeer/inventory.close",
                        arguments: .object([
                            .init("accountId", .string(bound.storeID)),
                            .init(
                                "#snapshotID",
                                .object([
                                    .init("resultOf", .string("i")),
                                    .init("name", .string("TractandaPeer/inventory")),
                                    .init("path", .string("/snapshotID")),
                                ])),
                        ]), callID: "c"
                    ).value,
                ])),
        ]).encoded()
        let result = try await PersonalPeerJMAP.execute(
            request, binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in },
            perform: { _, call in
                calls.withLock { $0.append(call.operation) }
                if call.operation == "personal.inventory" {
                    return try JSON.encode(
                        PersonalInventoryPage(
                            snapshotID: snapshot, generationID: "generation", cutRowID: 0, entries: [],
                            nextOffset: nil, complete: true))
                }
                XCTAssertEqual(call.fields["snapshotID"], .text(snapshot))
                return try JSON.encode(["closed": true])
            })
        let replies = try XCTUnwrap(try response(result)["methodResponses"]?.elements)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0].elements?[1]["snapshotID"]?.text, snapshot)
        XCTAssertEqual(replies[1].elements?[1]["closed"], .bool(true))
        XCTAssertEqual(calls.withLock { $0 }, ["personal.inventory", "personal.inventory.close"])
    }

    func testMixedBatchFailuresContinueWithoutCallingRejectedDomainMethods() async throws {
        let bound = try binding()
        let called = Mutex(0)
        let arguments = JMAPValue.object([.init("accountId", .string(bound.storeID))])
        let request = try JMAPValue.object([
            .init("using", .array([.string(PersonalPeerJMAP.capability)])),
            .init(
                "methodCalls",
                .array([
                    JMAPInvocation(name: "TractandaItem/commit", arguments: arguments, callID: "unknown")
                        .value,
                    JMAPInvocation(name: "TractandaPeer/sync.ready", arguments: arguments, callID: "first")
                        .value,
                    JMAPInvocation(
                        name: "TractandaPeer/inventory.close", arguments: arguments, callID: "invalid"
                    ).value,
                    JMAPInvocation(name: "TractandaPeer/sync.ready", arguments: arguments, callID: "last")
                        .value,
                ])),
        ]).encoded()
        let result = try await PersonalPeerJMAP.execute(
            request, binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return try JSON.encode(["ready": true])
            })
        let replies = try XCTUnwrap(try response(result)["methodResponses"]?.elements)
        XCTAssertEqual(replies[0].elements?[1]["type"]?.text, "unknownMethod")
        XCTAssertEqual(replies[1].elements?[1]["ready"], .bool(true))
        XCTAssertEqual(replies[2].elements?[1]["type"]?.text, "invalidArguments")
        XCTAssertEqual(replies[3].elements?[1]["ready"], .bool(true))
        XCTAssertEqual(called.withLock { $0 }, 2)
    }

    func testAggregateReplyBudgetAndCallLimitRejectBeforeAnyDomainEffect() async throws {
        let bound = try binding()
        let called = Mutex(0)
        func request(_ count: Int) throws -> Data {
            try JMAPValue.object([
                .init("using", .array([.string(PersonalPeerJMAP.capability)])),
                .init(
                    "methodCalls",
                    .array(
                        (0..<count).map {
                            JMAPInvocation(
                                name: "TractandaPeer/inventory", arguments: .object([]),
                                callID: String(repeating: "x", count: 256) + String($0)
                            ).value
                        })),
            ]).encoded()
        }
        let sixteen = try request(16)
        let aggregate = try await PersonalPeerJMAP.execute(
            sixteen, binding: bound, maximumBodyBytes: sixteen.count + 1, validate: { _ in },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return Data()
            })
        guard case .problem(let aggregateBytes) = aggregate else {
            return XCTFail("Expected aggregate budget problem")
        }
        XCTAssertEqual(try JMAPValue.decode(aggregateBytes)["limit"]?.text, "tractanda.maxResponseBytes")
        let overflow = try await PersonalPeerJMAP.execute(
            request(17), binding: bound, maximumBodyBytes: PeerExchangeCodec.maximumPersonalBodyBytes(),
            validate: { _ in },
            perform: { _, _ in
                called.withLock { $0 += 1 }
                return Data()
            })
        guard case .problem(let overflowBytes) = overflow else {
            return XCTFail("Expected call-count problem")
        }
        XCTAssertEqual(try JMAPValue.decode(overflowBytes)["limit"]?.text, "maxCallsInRequest")
        XCTAssertEqual(called.withLock { $0 }, 0)
    }

    func testPeerResponseRejectsWrongCorrelationAndNoncanonicalByteEncoding() throws {
        let bad = try JMAPValue.object([
            .init("sessionState", .string("metadata")),
            .init(
                "methodResponses",
                .array([
                    JMAPInvocation(
                        name: "TractandaPeer/read", arguments: .object([.init("bytes", .string("/w=="))]),
                        callID: "wrong"
                    ).value
                ])),
        ]).encoded()
        XCTAssertThrowsError(try PersonalPeerJMAP.response(bad, request: .init("personal.read")))
        let noncanonical = try JMAPValue.object([
            .init("sessionState", .string("metadata")),
            .init(
                "methodResponses",
                .array([
                    JMAPInvocation(
                        name: "TractandaPeer/read", arguments: .object([.init("bytes", .string("/x=="))]),
                        callID: "peer"
                    ).value
                ])),
        ]).encoded()
        XCTAssertThrowsError(try PersonalPeerJMAP.response(noncanonical, request: .init("personal.read")))
        let methodError = try JMAPValue.object([
            .init("sessionState", .string("metadata")),
            .init(
                "methodResponses",
                .array([
                    JMAPInvocation(
                        name: "error", arguments: .object([.init("type", .string("serverPartialFail"))]),
                        callID: "peer"
                    ).value
                ])),
        ]).encoded()
        XCTAssertThrowsError(try PersonalPeerJMAP.response(methodError, request: .init("personal.inventory")))
        { error in
            XCTAssertEqual((error as? TractandaError)?.code, "serverPartialFail")
        }
    }
}
