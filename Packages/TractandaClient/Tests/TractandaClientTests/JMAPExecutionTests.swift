import Foundation
import Testing

@testable import TractandaClient

private let executionCapability = "https://example.test/jmap/execution"
private func executionOutcome(_ call: JMAPInvocation, _ context: JMAPMethodContext) -> JMAPMethodOutcome {
    switch call.name {
    case "Example/create":
        return .success(
            [.init(call.name, .object([.init("id", .string("record-1"))]))], createdIDs: ["c": "record-1"])
    case "Example/context":
        return .success([
            .init(
                call.name,
                .object([
                    .init("created", .string(context.createdIDs["c"] ?? "missing")),
                    .init("callID", .string(context.callID)),
                    .init("callCount", .number(try! JMAPNumber(String(context.callCount)))),
                    .init("args", call.arguments),
                ]))
        ])
    default: return .failure(.init("forbidden"), effects: .none)
    }
}
private func executionKernel(limits: JMAPKernel.Limits = .init()) -> JMAPKernel {
    var methods: [String: JMAPMethodDefinition] = [:]
    for name in ["Example/create", "Example/context", "Example/fail"] {
        methods[name] = .init(
            capability: executionCapability, effect: name == "Example/create" ? .mayMutate : .readOnly,
            scope: .session,
            maximumResponseBytes: 512, maximumCreatedIDBytes: name == "Example/create" ? 128 : 0
        ) { args, context in
            executionOutcome(.init(name: name, arguments: args, callID: context.callID), context)
        }
    }
    return .init(methods: methods, limits: limits, sessionState: { try! .init("metadata-state") })
}

@Test func jmapSyncAndAsyncDriversShareOrderedReferenceAndCreationTransitions() async throws {
    let bytes = Data(
        ##"{"using":["urn:ietf:params:jmap:core","https://example.test/jmap/execution"],"createdIds":{},"future":true,"methodCalls":[["Example/create",{},""],["Example/context",{"#new":{"resultOf":"","name":"Example/create","path":"/id"}},""],["Example/fail",{},"e"],["Core/echo",{"ok":true},"e"]]}"##
            .utf8)
    let kernel = executionKernel()
    let asyncResult = try await kernel.execute(bytes)
    let syncResult = try kernel.executeSynchronously(
        bytes, sessionState: { try! .init("metadata-state") }, handle: executionOutcome)
    #expect(syncResult.value == asyncResult.value)
    let expected = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                ##"{"methodResponses":[["Example/create",{"id":"record-1"},""],["Example/context",{"created":"record-1","callID":"","callCount":4,"args":{"new":"record-1"}},""],["error",{"type":"forbidden"},"e"],["Core/echo",{"ok":true},"e"]],"createdIds":{"c":"record-1"},"sessionState":"metadata-state"}"##
                    .utf8)) as? [String: Any])
    let actual = try #require(
        JSONSerialization.jsonObject(with: syncResult.value.encoded()) as? [String: Any])
    #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
}
@Test func jmapAlreadyDecodedRequestHasIdenticalSyncAsyncDrivers() async throws {
    let request = try JMAPRequest.decode(
        Data(##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"n":1e100},""]]}"##.utf8))
    let kernel = executionKernel()
    let asyncResult = try await kernel.execute(request)
    let syncResult = try kernel.executeSynchronously(
        request, sessionState: { try! .init("metadata-state") },
        handle: {
            _, _ in
            Issue.record("Core/echo must not yield to the domain executor")
            return .failure(.init("serverFail"), effects: .none)
        })
    #expect(syncResult.value == asyncResult.value)
    #expect(syncResult.methodResponses[0].arguments["n"] == .number(try JMAPNumber("1e100")))
}
@Test func jmapStateMachineEnforcesOnePendingOutcome() throws {
    var execution = try executionKernel().begin(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"]]}"##
                .utf8))
    let pending = try execution.next()
    let first = try #require(pending)
    #expect(first.invocation.name == "Example/create")
    #expect(throws: JMAPKernel.ExecutionError.awaitingOutcome) { try execution.next() }
    #expect(throws: JMAPKernel.ExecutionError.incomplete) { try execution.finish(sessionState: .init("s")) }
    try execution.accept(executionOutcome(first.invocation, first.context))
    #expect(throws: JMAPKernel.ExecutionError.noPendingCall) {
        try execution.accept(.failure(.init("serverFail"), effects: .none))
    }
    #expect(try execution.next() == nil)
    #expect(try execution.finish(sessionState: .init("s")).methodResponses.count == 1)
}
@Test func jmapSyncDriverRejectsUnknownCapabilitiesBeforeAnyHandler() throws {
    var effects = 0
    #expect(throws: JMAPProblem("unknownCapability")) {
        try executionKernel().executeSynchronously(
            Data(
                ##"{"using":["https://example.test/jmap/execution","unknown"],"methodCalls":[["Example/create",{},"c"]]}"##
                    .utf8), sessionState: { try! .init("s") },
            handle: { _, _ in
                effects += 1
                return .success([.init("Example/create", .object([]))])
            })
    }
    #expect(effects == 0)
}
@Test func jmapSyncDriverRejectsUnfundedMutationBeforeTheHandler() throws {
    var effects = 0
    let result = try executionKernel(limits: .init(maximumResponseBytes: 1536)).executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"]]}"##
                .utf8), sessionState: { try! .init("s") },
        handle: { _, _ in
            effects += 1
            return .success([.init("Example/create", .object([]))])
        })
    #expect(result.methodResponses[0].arguments["type"]?.text == "responseTooLarge")
    #expect(effects == 0)
}
@Test func jmapSyncThrownMutationRemainsPartialAndLaterCallsRun() throws {
    var effects = 0
    let response = try executionKernel().executeSynchronously(
        Data(
            ##"{"using":["urn:ietf:params:jmap:core","https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"],["Core/echo",{},"e"]]}"##
                .utf8), sessionState: { try! .init("new-metadata-state") },
        handle: { _, _ in
            effects += 1
            throw JMAPMethodError("serverFail")
        })
    #expect(effects == 1)
    #expect(response.methodResponses[0].arguments["type"]?.text == "serverPartialFail")
    #expect(response.methodResponses[1].name == "Core/echo")
    #expect(response.sessionState == "new-metadata-state")
}
@Test func jmapStateMachineKeepsUnoptedMethodsOutOfEitherDriver() throws {
    var execution = try executionKernel().begin(
        Data(
            ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Example/create",{},"c"],["Core/echo",{},"e"]]}"##
                .utf8))
    #expect(try execution.next() == nil)
    let result = try execution.finish(sessionState: .init("s"))
    #expect(result.methodResponses[0].arguments["type"]?.text == "unknownMethod")
    #expect(result.methodResponses[1].name == "Core/echo")
}
@Test func jmapStateMachineResolvesProtocolFailuresWithoutInvokingDomain() throws {
    var calls = 0
    let result = try executionKernel().executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{"#x":{"resultOf":"future","name":"Example/create","path":""}},"c"],["Example/context",{},"next"]]}"##
                .utf8), sessionState: { try! .init("s") },
        handle: { call, context in
            calls += 1
            return executionOutcome(call, context)
        })
    #expect(calls == 1)
    #expect(result.methodResponses[0].arguments["type"]?.text == "invalidResultReference")
    #expect(result.methodResponses[1].name == "Example/context")
}

@Test func jmapPredecodedRequestsStillObeyTheSelectedBindingLimits() throws {
    let bytes = Data(
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"x":[1]},"e"]],"future":[[[1]]]}"##
            .utf8)
    let request = try JMAPRequest.decode(bytes)
    #expect(request.sourceByteCount == bytes.count)
    #expect(throws: JMAPProblem("limit", limit: "maxSizeRequest")) {
        try executionKernel(limits: .init(maximumRequestBytes: 1)).begin(request)
    }
    #expect(throws: JMAPProblem("limit", limit: "maxCallsInRequest")) {
        try executionKernel(limits: .init(maximumCalls: 0)).begin(request)
    }
    #expect(throws: JMAPProblem("limit", limit: "tractanda.maxJSONDepth")) {
        try executionKernel(limits: .init(maximumJSONDepth: 2)).begin(request)
    }
}
@Test func jmapSyncSessionStateIsAnAlreadyValidatedNonthrowingFinalizationInput() throws {
    let state = try JMAPSessionState("catalog-state")
    var effects = 0
    let response = try executionKernel().executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"]]}"##
                .utf8), sessionState: { state },
        handle: { call, context in
            effects += 1
            return executionOutcome(call, context)
        })
    #expect(effects == 1)
    #expect(response.sessionState == "catalog-state")
    #expect(response.methodResponses[0].name == "Example/create")
}

@Test func jmapMinimumResponseSlotsRejectTheRequestBeforeHandlers() throws {
    var effects = 0
    #expect(throws: JMAPProblem("limit", limit: "tractanda.maxResponseBytes")) {
        try executionKernel(limits: .init(maximumResponseBytes: 1024)).executeSynchronously(
            Data(
                ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"]]}"##
                    .utf8), sessionState: { try! .init("s") },
            handle: { _, _ in
                effects += 1
                return .failure(.init("serverFail"), effects: .none)
            })
    }
    #expect(effects == 0)
}
@Test func jmapMixedQueryGetMutationAndReadExhaustionRemainIndependent() throws {
    var methods: [String: JMAPMethodDefinition] = [:]
    for name in ["Example/query", "Example/get", "Example/write", "Example/largeRead"] {
        methods[name] = .init(
            capability: executionCapability, effect: name == "Example/write" ? .mayMutate : .readOnly,
            scope: .session,
            maximumResponseBytes: 8 * 1024 * 1024, requiresMutationAdmission: name == "Example/write"
        ) { _, _ in
            .failure(.init("serverFail"), effects: .none)
        }
    }
    let kernel = JMAPKernel(
        methods: methods, limits: .init(maximumResponseBytes: 4096), sessionState: { try! .init("metadata") })
    var published = 0
    let result = try kernel.executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/query",{},"q"],["Example/get",{"#ids":{"resultOf":"q","name":"Example/query","path":"/ids"}},"g"],["Example/write",{},"w"],["Example/largeRead",{},"big"]]}"##
                .utf8), sessionState: { try! .init("metadata") },
        handle: { call, context in
            switch call.name {
            case "Example/query":
                return .success([.init(call.name, .object([.init("ids", .array([.string("a")]))]))])
            case "Example/get":
                #expect(call.arguments["ids"]?.elements == [.string("a")])
                return .success([
                    .init(call.name, .object([.init("list", .array([.object([.init("id", .string("a"))])]))]))
                ])
            case "Example/write":
                try context.replyBudget.reserveMutationResponse(maximumResponseBytes: 256)
                published += 1
                return .success([.init(call.name, .object([.init("revisionId", .string("r"))]))])
            default:
                return .success([
                    .init(call.name, .object([.init("large", .string(String(repeating: "x", count: 4096)))]))
                ])
            }
        })
    #expect(published == 1)
    #expect(result.methodResponses.map(\.name) == ["Example/query", "Example/get", "Example/write", "error"])
    #expect(result.methodResponses[3].arguments["type"]?.text == "serverFail")
    #expect(try result.value.encoded().count <= 4096)
}
@Test func jmapDynamicMutationAdmissionPrecedesPublication() throws {
    let kernel = JMAPKernel(
        methods: [
            "Example/write": .init(
                capability: executionCapability,
                effect: .mayMutate, scope: .session, maximumResponseBytes: 0, requiresMutationAdmission: true
            ) { _, _ in
                .failure(.init("serverFail"), effects: .none)
            }
        ], limits: .init(maximumResponseBytes: 2048), sessionState: { try! .init("s") })
    var published = 0
    let result = try kernel.executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/write",{},"w"]]}"##
                .utf8), sessionState: { try! .init("s") },
        handle: { call, context in
            do { try context.replyBudget.reserveMutationResponse(maximumResponseBytes: 4096) } catch let error
                as JMAPMethodError
            { return .failure(error, effects: .none) }
            published += 1
            return .success([.init(call.name, .object([]))])
        })
    #expect(published == 0)
    #expect(result.methodResponses[0].arguments["type"]?.text == "responseTooLarge")
}
@Test func jmapMissingMutationAdmissionIsOnlyPartialFailureContainment() throws {
    let kernel = JMAPKernel(
        methods: [
            "Example/write": .init(
                capability: executionCapability,
                effect: .mayMutate, scope: .session, maximumResponseBytes: 0, requiresMutationAdmission: true
            ) { _, _ in
                .failure(.init("serverFail"), effects: .none)
            }
        ], sessionState: { try! .init("s") })
    var published = 0
    let result = try kernel.executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/write",{},"w"]]}"##
                .utf8), sessionState: { try! .init("s") },
        handle: { call, _ in
            published += 1
            return .success([.init(call.name, .object([]))])
        })
    #expect(published == 1)
    #expect(result.methodResponses[0].arguments["type"]?.text == "serverPartialFail")
}

@Test func jmapSessionMetadataIsCapturedBeforeAnyMutationEffects() throws {
    var published = 0
    var metadataReads = 0
    let result = try executionKernel().executeSynchronously(
        Data(
            ##"{"using":["https://example.test/jmap/execution"],"methodCalls":[["Example/create",{},"c"]]}"##
                .utf8),
        sessionState: {
            metadataReads += 1
            #expect(published == 0)
            return try! .init("before-publication")
        },
        handle: { call, context in
            published += 1
            return executionOutcome(call, context)
        })
    #expect(published == 1)
    #expect(metadataReads == 1)
    #expect(result.sessionState == "before-publication")
}
@Test func jmapReservedCoreEchoCannotBeReplacedByVendorRegistryEntry() async throws {
    let kernel = JMAPKernel(
        methods: [
            "Core/echo": .init(
                capability: executionCapability, effect: .mayMutate, scope: .session, maximumResponseBytes: 0
            ) {
                _, _ in
                Issue.record("Reserved Core method must not invoke a vendor replacement")
                return .failure(.init("forbidden"), effects: .none)
            }
        ], sessionState: { try! .init("s") })
    let result = try await kernel.execute(
        Data(##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"ok":true},"e"]]}"##.utf8)
    )
    #expect(result.methodResponses[0].name == "Core/echo")
    #expect(result.methodResponses[0].arguments["ok"] == .bool(true))
}
