import Foundation
import Testing

@testable import TractandaClient

private let jmapExtension = "https://example.test/jmap/items"
private func jmapKernel(_ methods: [String: JMAPMethodDefinition] = [:], limits: JMAPKernel.Limits = .init())
    -> JMAPKernel
{
    JMAPKernel(methods: methods, limits: limits, sessionState: { try! JMAPSessionState("session-1") })
}
private func jmapJSON(_ text: String) throws -> JMAPValue { try .decode(Data(text.utf8)) }
private func jmapTranscript(_ kernel: JMAPKernel, _ request: String, _ expected: String) async throws {
    let response = try await kernel.execute(Data(request.utf8))
    let actual = try #require(JSONSerialization.jsonObject(with: response.value.encoded()) as? [String: Any])
    let wanted = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any])
    #expect(NSDictionary(dictionary: actual).isEqual(to: wanted))
}
private func jmapProblem(_ kernel: JMAPKernel, _ request: String, code: String, limit: String? = nil) async {
    do {
        _ = try await kernel.execute(Data(request.utf8))
        Issue.record("Expected request rejection")
    } catch let problem as JMAPProblem {
        #expect(problem.type == "urn:ietf:params:jmap:error:" + code)
        #expect(problem.limit == limit)
    } catch { Issue.record("Unexpected error: \(error)") }
}
private actor JMAPEffectCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test func jmapCoreOnlyEchoTranscript() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"a":[true,null,1.25,1e2]},"e"]]}"##,
        ##"{"methodResponses":[["Core/echo",{"a":[true,null,1.25,1e2]},"e"]],"sessionState":"session-1"}"##)
}
@Test func jmapUnknownCapabilityRejectsBeforeSideEffects() async {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel([
        "Example/write": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in
            await counter.increment()
            return .success([.init("Example/write", .object([]))])
        }
    ])
    await jmapProblem(
        kernel,
        ##"{"using":["https://example.test/jmap/items","unknown"],"methodCalls":[["Example/write",{},"w"]]}"##,
        code: "unknownCapability")
    #expect(await counter.count == 0)
}
@Test func jmapMalformedLaterInvocationRejectsBeforeAnyHandler() async {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel([
        "Example/write": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in
            await counter.increment()
            return .success([.init("Example/write", .object([]))])
        }
    ])
    await jmapProblem(
        kernel,
        ##"{"using":["https://example.test/jmap/items"],"methodCalls":[["Example/write",{},"w"],["Core/echo",null,"e"]]}"##,
        code: "notRequest")
    #expect(await counter.count == 0)
}
@Test func jmapRequestShapeErrorsAndFutureProperty() async throws {
    for request in [
        "[]", ##"{"using":"core","methodCalls":[]}"##, ##"{"using":[],"methodCalls":[["x",{},4]]}"##,
        ##"{"using":[],"methodCalls":[],"createdIds":null}"##,
    ] {
        await jmapProblem(jmapKernel(), request, code: "notRequest")
    }
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":[],"methodCalls":[],"future":{"ignored":true}}"##,
        ##"{"methodResponses":[],"sessionState":"session-1"}"##)
}
@Test func jmapOptInGatesExtensionWithoutExecutingIt() async throws {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel([
        "Example/write": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in
            await counter.increment()
            return .success([.init("Example/write", .object([]))])
        }
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Example/write",{},"w"],["Core/echo",{},"e"]]}"##,
        ##"{"methodResponses":[["error",{"type":"unknownMethod"},"w"],["Core/echo",{},"e"]],"sessionState":"session-1"}"##
    )
    #expect(await counter.count == 0)
}
@Test func jmapEmptyAndRepeatedCallIDsRetainOrder() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"n":1},""],["No/such",{},""],["Core/echo",{"n":3},""]]}"##,
        ##"{"methodResponses":[["Core/echo",{"n":1},""],["error",{"type":"unknownMethod"},""],["Core/echo",{"n":3},""]],"sessionState":"session-1"}"##
    )
}
@Test func jmapCreatedIDsAbsentEmptyAndSeeded() async throws {
    try await jmapTranscript(
        jmapKernel(), ##"{"using":[],"methodCalls":[],"createdIds":{}}"##,
        ##"{"methodResponses":[],"sessionState":"session-1","createdIds":{}}"##)
    try await jmapTranscript(
        jmapKernel(), ##"{"using":[],"methodCalls":[],"createdIds":{"c":"record_1"}}"##,
        ##"{"methodResponses":[],"sessionState":"session-1","createdIds":{"c":"record_1"}}"##)
    for invalid in [##"{"bad/key":"r"}"##, ##"{"c":""}"##, ##"{"c":true}"##] {
        await jmapProblem(
            jmapKernel(), "{\"using\":[],\"methodCalls\":[],\"createdIds\":\(invalid)}", code: "notRequest")
    }
}
@Test func jmapCreationMapUpdatesAndImplicitResponses() async throws {
    let kernel = jmapKernel([
        "Example/create": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session,
            maximumResponseBytes: 512, maximumCreatedIDBytes: 128
        ) { _, context in
            #expect(context.createdIDs["seed"] == "existing")
            return .success(
                [
                    .init("Example/create", .object([.init("id", .string("new"))])),
                    .init("Example/implicit", .object([])),
                ], createdIDs: ["c": "new"])
        },
        "Example/check": .init(
            capability: jmapExtension, effect: .readOnly, scope: .session, maximumResponseBytes: 256
        ) {
            _, context in
            #expect(context.createdIDs["c"] == "new")
            return .success([.init("Example/check", .object([]))])
        },
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["https://example.test/jmap/items"],"createdIds":{"seed":"existing"},"methodCalls":[["Example/create",{},"a"],["Example/check",{},"b"]]}"##,
        ##"{"methodResponses":[["Example/create",{"id":"new"},"a"],["Example/implicit",{},"a"],["Example/check",{},"b"]],"sessionState":"session-1","createdIds":{"seed":"existing","c":"new"}}"##
    )
}
@Test func jmapCreationMapOmittedUnlessRequested() async throws {
    let kernel = jmapKernel([
        "Example/create": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session,
            maximumResponseBytes: 256, maximumCreatedIDBytes: 128
        ) { _, _ in
            .success([.init("Example/create", .object([]))], createdIDs: ["c": "new"])
        }
    ])
    let response = try await kernel.execute(
        Data(
            ##"{"using":["https://example.test/jmap/items"],"methodCalls":[["Example/create",{},"c"]]}"##.utf8
        ))
    #expect(response.createdIDs == nil)
}
@Test func jmapReferencesRootEscapedKeysAndArrayIndex() async throws {
    let root = try jmapJSON(##"{"a/b":{"~key":[{"v":9}]},"":{"x":1}}"##)
    #expect(try JMAPResultReference.pointer("", in: root) == root)
    #expect(try JMAPResultReference.pointer("/a~1b/~0key/0/v", in: root) == jmapJSON("9"))
    #expect(try JMAPResultReference.pointer("//x", in: root) == jmapJSON("1"))
}
@Test func jmapReferenceWildcardFlattensArraysAndEmptyLists() throws {
    let root = try jmapJSON(##"{"list":[{"ids":["a","b"]},{"ids":[]},{"ids":["c"]}],"empty":[],"*":7}"##)
    #expect(try JMAPResultReference.pointer("/list/*/ids", in: root) == jmapJSON(##"["a","b","c"]"##))
    #expect(try JMAPResultReference.pointer("/empty/*/anything", in: root) == jmapJSON("[]"))
    #expect(try JMAPResultReference.pointer("/*", in: root) == jmapJSON("7"))
}
@Test func jmapReferenceInvalidPointers() throws {
    let root = try jmapJSON(##"{"list":[1],"rows":[{"x":1},{}]}"##)
    for path in [
        "list", "/list/01", "/list/-", "/list/1", "/list/-1", "/missing", "/~2", "/rows/*/x", "/list/0/x",
    ] {
        #expect(throws: JMAPMethodError("invalidResultReference")) {
            try JMAPResultReference.pointer(path, in: root)
        }
    }
}
@Test func jmapReferencesUseFirstResponseAndContinueOnFailure() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"v":1},"same"],["Core/echo",{"v":2},"same"],["Core/echo",{"#result":{"resultOf":"same","name":"Core/echo","path":"/v"}},"r"],["Core/echo",{"#bad":{"resultOf":"future","name":"Core/echo","path":""}},"bad"],["Core/echo",{},"last"]]}"##,
        ##"{"methodResponses":[["Core/echo",{"v":1},"same"],["Core/echo",{"v":2},"same"],["Core/echo",{"result":1},"r"],["error",{"type":"invalidResultReference"},"bad"],["Core/echo",{},"last"]],"sessionState":"session-1"}"##
    )
}
@Test func jmapReferenceCollisionIsInvalidArguments() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"x":null,"#x":{"resultOf":"no","name":"Core/echo","path":""}},"r"]]}"##,
        ##"{"methodResponses":[["error",{"type":"invalidArguments"},"r"]],"sessionState":"session-1"}"##)
}
@Test func jmapReferenceWrongNameOrErrorResponseRejected() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["No/such",{},"x"],["Core/echo",{"#x":{"resultOf":"x","name":"Core/echo","path":""}},"r"]]}"##,
        ##"{"methodResponses":[["error",{"type":"unknownMethod"},"x"],["error",{"type":"invalidResultReference"},"r"]],"sessionState":"session-1"}"##
    )
}
@Test func jmapStrictJSONRejectsDuplicateDecodedKeysAndMalformedUnicode() throws {
    for input in [
        ##"{"a":1,"\u0061":2}"##, ##"{"x":{"k":1,"k":2}}"##, ##""\uDEAD""##, ##""\uFDD0""##,
        ##""\uDBFF\uDFFF""##, ##"{"a":1,}"##, "[1,]", "01", "1.", "1e", "+1", "NaN", "true false",
    ] {
        #expect(throws: (any Error).self) { try jmapJSON(input) }
    }
    #expect(throws: JMAPJSONError.invalidUnicode) { try JMAPValue.decode(Data([0x22, 0xff, 0x22])) }
}
@Test func jmapScalarDistinctKeysDoNotNormalizeTogether() throws {
    let value = try jmapJSON(##"{"\u00e9":1,"e\u0301":2}"##)
    #expect(value.members?.count == 2)
    #expect(value["\u{e9}"] == .number(try JMAPNumber("1")))
    #expect(value["e\u{301}"] == .number(try JMAPNumber("2")))
    #expect(try JMAPValue.decode(value.encoded()) == value)
}
@Test func jmapValidSurrogatePairAndEscapedControls() throws {
    let value = try jmapJSON(##"{"emoji":"\uD83D\uDE00","controls":"\b\f\n\r\t\\\"\/"}"##)
    #expect(value["emoji"]?.text == "😀")
    #expect(value["controls"]?.text == "\u{8}\u{c}\n\r\t\\\"/")
    #expect(try JMAPValue.decode(value.encoded()) == value)
}
@Test func jmapNumberTokensAndBooleansAreNotConflated() throws {
    for token in ["0", "-0", "1.25", "1e100", "9007199254740992", "-7E-4", "1.0000000000000000000001"] {
        let value = try jmapJSON(token)
        #expect(String(decoding: try value.encoded(), as: UTF8.self) == token)
    }
    #expect(try jmapJSON("true") != jmapJSON("1"))
    #expect(try jmapJSON("false") != jmapJSON("0"))
}
@Test func jmapArbitraryEchoDoesNotApplyInt53Globally() async throws {
    let raw =
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["Core/echo",{"n":9007199254740992,"fraction":0.125,"large":1e100},"e"]]}"##
    let response = try await jmapKernel().execute(Data(raw.utf8))
    #expect(response.methodResponses[0].arguments["n"] == .number(try JMAPNumber("9007199254740992")))
    #expect(response.methodResponses[0].arguments["large"] == .number(try JMAPNumber("1e100")))
}
@Test func jmapDeclaredProtocolIntegerChecksExactValue() throws {
    #expect(try JMAPNumber("9007199254740991").protocolInt() == 9_007_199_254_740_991)
    #expect(try JMAPNumber("-9007199254740991").protocolInt() == -9_007_199_254_740_991)
    #expect(try JMAPNumber("1.0e2").protocolInt() == 100)
    #expect(try JMAPNumber("0e9999999999999999999999").protocolInt() == 0)
    for token in [
        "9007199254740992", "-9007199254740992", "0.5", "1.00000000000000000000000000000000000000001",
        "1e100", "1e-999999999999999999999",
    ] {
        #expect(throws: JMAPJSONError.invalidProtocolInteger) { try JMAPNumber(token).protocolInt() }
    }
    #expect(throws: JMAPJSONError.invalidProtocolInteger) { try JMAPNumber("-1").protocolInt(unsigned: true) }
}
@Test func jmapRequestLimitsRejectBeforeEffects() async {
    await jmapProblem(
        jmapKernel(limits: .init(maximumRequestBytes: 1)), "{}", code: "limit", limit: "maxSizeRequest")
    await jmapProblem(
        jmapKernel(limits: .init(maximumCalls: 0)),
        ##"{"using":[],"methodCalls":[["x",{},"x"]]}"##, code: "limit", limit: "maxCallsInRequest")
}
@Test func jmapLargeDeclaredBoundsDoNotRejectSmallSequentialMutations() async throws {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel(
        [
            "Example/write": .init(
                capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 2048
            ) { _, _ in
                await counter.increment()
                return .success([.init("Example/write", .object([]))])
            }
        ], limits: .init(maximumResponseBytes: 4096))
    let result = try await kernel.execute(
        Data(
            ##"{"using":["https://example.test/jmap/items"],"methodCalls":[["Example/write",{},"a"],["Example/write",{},"b"]]}"##
                .utf8))
    #expect(await counter.count == 2)
    #expect(result.methodResponses.allSatisfy { $0.name == "Example/write" })
    #expect(try result.value.encoded().count <= 4096)
}
@Test func jmapMutationBudgetBreachIsTruthfulPartialFailureAndContinues() async throws {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel([
        "Example/write": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 128
        ) {
            _, _ in
            await counter.increment()
            return .success([
                .init("Example/write", .object([.init("huge", .string(String(repeating: "x", count: 2048)))]))
            ])
        }
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["urn:ietf:params:jmap:core","https://example.test/jmap/items"],"methodCalls":[["Example/write",{},"w"],["Core/echo",{},"e"]]}"##,
        ##"{"methodResponses":[["error",{"type":"serverPartialFail"},"w"],["Core/echo",{},"e"]],"sessionState":"session-1"}"##
    )
    #expect(await counter.count == 1)
}
@Test func jmapKnownNoEffectsVersusChangedOrUnknownFailures() async throws {
    let kernel = jmapKernel([
        "Example/none": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in .failure(.init("forbidden"), effects: .none)
        },
        "Example/changed": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in .failure(.init("serverFail"), effects: .changed)
        },
        "Example/throws": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 256
        ) {
            _, _ in throw JMAPMethodError("forbidden")
        },
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["https://example.test/jmap/items"],"methodCalls":[["Example/none",{},"n"],["Example/changed",{},"c"],["Example/throws",{},"t"]]}"##,
        ##"{"methodResponses":[["error",{"type":"forbidden"},"n"],["error",{"type":"serverPartialFail"},"c"],["error",{"type":"serverPartialFail"},"t"]],"sessionState":"session-1"}"##
    )
}
@Test func jmapSessionProviderIsSeparateAndBounded() async throws {
    let kernel = JMAPKernel(sessionState: { try! .init("session-catalog-state") })
    let response = try await kernel.execute(Data(##"{"using":[],"methodCalls":[]}"##.utf8))
    #expect(response.sessionState == "session-catalog-state")
    #expect(throws: (any Error).self) { try JMAPSessionState(String(repeating: "x", count: 1024)) }
}
@Test func jmapJSONAndPointerDepthBounds() throws {
    #expect(throws: JMAPJSONError.tooDeep) { try JMAPValue.decode(Data("[[[0]]]".utf8), maximumDepth: 2) }
    #expect(throws: JMAPMethodError("invalidResultReference")) {
        try JMAPResultReference.pointer(String(repeating: "/x", count: 257), in: .object([]))
    }
}

@Test func jmapReferenceDelimitersAreScalarNotGraphemeBased() async throws {
    let root = try jmapJSON(##"{"\u0301":1,"a":{"\u0301":2}}"##)
    #expect(try JMAPResultReference.pointer("/\u{301}", in: root) == jmapJSON("1"))
    #expect(try JMAPResultReference.pointer("/a/\u{301}", in: root) == jmapJSON("2"))
    let arguments = try jmapJSON(##"{"#\u0301":{"resultOf":"r","name":"Core/echo","path":"/\u0301"}}"##)
    let resolved = try JMAPResultReference.resolve(
        arguments: arguments,
        previous: [.init(name: "Core/echo", arguments: root, callID: "r")])
    #expect(resolved["\u{301}"] == .number(try JMAPNumber("1")))
}
@Test func jmapReferencesMaySelectAnExplicitlyNamedErrorResponse() async throws {
    try await jmapTranscript(
        jmapKernel(),
        ##"{"using":["urn:ietf:params:jmap:core"],"methodCalls":[["No/such",{},"x"],["Core/echo",{"#type":{"resultOf":"x","name":"error","path":"/type"}},"r"]]}"##,
        ##"{"methodResponses":[["error",{"type":"unknownMethod"},"x"],["Core/echo",{"type":"unknownMethod"},"r"]],"sessionState":"session-1"}"##
    )
}
@Test func jmapKnownNoEffectsBudgetBreachDoesNotInventMutation() async throws {
    let kernel = jmapKernel([
        "Example/reject": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session, maximumResponseBytes: 128
        ) {
            _, _ in
            .failure(.init("forbidden", description: String(repeating: "x", count: 2048)), effects: .none)
        }
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["https://example.test/jmap/items"],"methodCalls":[["Example/reject",{},"x"]]}"##,
        ##"{"methodResponses":[["error",{"type":"serverFail"},"x"]],"sessionState":"session-1"}"##)
}
@Test func jmapCreationMapBudgetBreachIsPartialFailureAfterMutation() async throws {
    let counter = JMAPEffectCounter()
    let kernel = jmapKernel([
        "Example/create": .init(
            capability: jmapExtension, effect: .mayMutate, scope: .session,
            maximumResponseBytes: 256, maximumCreatedIDBytes: 0
        ) { _, _ in
            await counter.increment()
            return .success([.init("Example/create", .object([]))], createdIDs: ["c": "new"])
        }
    ])
    try await jmapTranscript(
        kernel,
        ##"{"using":["https://example.test/jmap/items"],"createdIds":{},"methodCalls":[["Example/create",{},"c"]]}"##,
        ##"{"methodResponses":[["error",{"type":"serverPartialFail"},"c"]],"sessionState":"session-1","createdIds":{}}"##
    )
    #expect(await counter.count == 1)
}
@Test func jmapResponseBudgetIncludesCreationMapAndSessionState() async throws {
    let kernel = jmapKernel(
        [
            "Example/create": .init(
                capability: jmapExtension, effect: .mayMutate, scope: .session,
                maximumResponseBytes: 256, maximumCreatedIDBytes: 128
            ) { _, _ in
                .success([.init("Example/create", .object([]))], createdIDs: ["new": "record"])
            }
        ], limits: .init(maximumResponseBytes: 2048))
    let response = try await kernel.execute(
        Data(
            ##"{"using":["https://example.test/jmap/items"],"createdIds":{"seed":"existing"},"methodCalls":[["Example/create",{},"x"]]}"##
                .utf8))
    #expect(try response.value.encoded().count <= 2048)
    await jmapProblem(
        jmapKernel(limits: .init(maximumJSONDepth: 1)),
        ##"{"using":[],"methodCalls":[["x",{},"x"]]}"##, code: "limit", limit: "tractanda.maxJSONDepth")
}
