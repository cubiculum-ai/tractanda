import Foundation
import Testing

@testable import TractandaClient

private let accountURI = "https://example.test/jmap/account"
private let accountID = "00000000-0000-1000-8000-000000000001"
private func accountState() -> JMAPSessionState { try! .init("metadata") }

@Test func accountAdmissionPrecedesMutationAndCarriesOnlyValidatedDatasetID() async throws {
    let definition = JMAPMethodDefinition(
        capability: accountURI, effect: .mayMutate,
        scope: .account, requiresWritableAccount: true, maximumResponseBytes: 256
    ) { _, context in
        #expect(context.accountID == accountID)
        return .success([.init("Example/write", .object([]))])
    }
    let kernel = JMAPKernel(
        methods: ["Example/write": definition],
        accounts: [try .init(accountID: accountID, capabilities: [accountURI], isReadOnly: false)],
        sessionState: accountState)
    for (args, expected) in [
        ("{}", "invalidArguments"), ("{\"accountId\":true}", "invalidArguments"),
        ("{\"accountId\":\"foreign\"}", "accountNotFound"),
    ] {
        let result = try await kernel.execute(
            Data("{\"using\":[\"\(accountURI)\"],\"methodCalls\":[[\"Example/write\",\(args),\"w\"]]}".utf8))
        #expect(result.methodResponses[0].arguments["type"]?.text == expected)
    }
    let result = try await kernel.execute(
        Data(
            "{\"using\":[\"\(accountURI)\"],\"methodCalls\":[[\"Example/write\",{\"accountId\":\"\(accountID)\"},\"w\"]]}"
                .utf8))
    #expect(result.methodResponses[0].name == "Example/write")
}
@Test func readonlyAccountSeparatesItemWritesFromAuthorizedRecoveryEffects() async throws {
    let methods: [String: JMAPMethodDefinition] = [
        "Example/write": .init(
            capability: accountURI, effect: .mayMutate, requiresWritableAccount: true,
            maximumResponseBytes: 256
        ) { _, _ in
            Issue.record("Read-only item writer must not run")
            return .success([.init("Example/write", .object([]))])
        },
        "Example/rebuild": .init(
            capability: accountURI, effect: .mayMutate, requiresWritableAccount: false,
            maximumResponseBytes: 256
        ) { _, context in
            #expect(context.accountID == accountID)
            return .success([.init("Example/rebuild", .object([.init("recovered", .bool(true))]))])
        },
    ]
    let kernel = JMAPKernel(
        methods: methods,
        accounts: [try .init(accountID: accountID, capabilities: [accountURI], isReadOnly: true)],
        sessionState: accountState)
    let result = try await kernel.execute(
        Data(
            "{\"using\":[\"\(accountURI)\"],\"methodCalls\":[[\"Example/write\",{\"accountId\":\"\(accountID)\"},\"w\"],[\"Example/rebuild\",{\"accountId\":\"\(accountID)\"},\"r\"]]}"
                .utf8))
    #expect(result.methodResponses[0].arguments["type"]?.text == "accountReadOnly")
    #expect(result.methodResponses[1].arguments["recovered"] == .bool(true))
}
@Test func accountReferencesResolveBeforeGateAndUnsupportedCapabilityIsDistinct() async throws {
    let method = JMAPMethodDefinition(capability: accountURI, effect: .readOnly, maximumResponseBytes: 256) {
        _, _ in .success([.init("Example/get", .object([]))])
    }
    let kernel = JMAPKernel(
        methods: ["Example/get": method],
        accounts: [try .init(accountID: accountID, capabilities: [], isReadOnly: false)],
        sessionState: accountState)
    let result = try await kernel.execute(
        Data(
            "{\"using\":[\"\(JMAPKernel.core)\",\"\(accountURI)\"],\"methodCalls\":[[\"Core/echo\",{\"id\":\"\(accountID)\"},\"s\"],[\"Example/get\",{\"#accountId\":{\"resultOf\":\"s\",\"name\":\"Core/echo\",\"path\":\"/id\"}},\"g\"]]}"
                .utf8))
    #expect(result.methodResponses[1].arguments["type"]?.text == "accountNotSupportedByMethod")
}
@Test func localDiscoveryCacheAndScopePreserveExplicitSelectionWithoutIntegerRewriting() throws {
    let limits = try JMAPSessionLimits(
        maxSizeUpload: 0, maxConcurrentUpload: 1, maxSizeRequest: 8_388_608,
        maxConcurrentRequests: 64, maxCallsInRequest: 32, maxObjectsInGet: 64, maxObjectsInSet: 0,
        collationAlgorithms: [])
    let metadata = try JMAPSessionMetadata(
        storeID: accountID, accountName: "Store", username: "caller", isReadOnly: false,
        limits: limits, capabilities: [TractandaJMAP.capability: .object([])],
        accountCapabilities: [TractandaJMAP.capability: .object([])])
    let document = try JMAPLocalSession(
        metadata: metadata, authorizationBasis: Data("auth".utf8), stateFactory: { _ in accountState() })
    let decoded = try JMAPLocalSession(data: document.value.encoded())
    #expect(decoded.accountID == accountID)
    #expect(decoded.value["apiUrl"] == nil)
    var cache = JMAPDiscoveryCache()
    cache.accept(decoded)
    cache.observe(sessionState: "metadata")
    #expect(cache.session != nil)
    cache.observe(sessionState: "changed")
    #expect(cache.session == nil)
    let explicit = JMAPValue.object([.init("accountId", .string("foreign"))])
    #expect(
        try TractandaJMAP.prepareArguments(
            method: "TractandaItem/get", arguments: explicit, accountID: accountID) == explicit)
    let arbitrary = try JMAPValue.decode(
        Data(##"{"x":{"type":"integer","value":9223372036854775807}}"##.utf8))
    #expect(
        try TractandaJMAP.prepareArguments(method: "Core/echo", arguments: arbitrary, accountID: nil)
            == arbitrary)
    #expect(
        try TractandaJMAP.prepareArguments(
            method: "TractandaItem/commit", arguments: arbitrary, accountID: accountID)["x"] == arbitrary["x"]
    )
}
