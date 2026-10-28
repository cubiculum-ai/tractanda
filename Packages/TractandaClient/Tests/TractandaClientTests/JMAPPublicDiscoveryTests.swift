import Foundation
import Testing

@testable import TractandaClient

@Test func publicDiscoveryUsesCommonCacheWithoutPretendingToBeLocal() throws {
    let account = "11111111-1111-4111-8111-111111111111"
    let limits = try JMAPSessionLimits(
        maxSizeUpload: 1_000_000, maxConcurrentUpload: 8, maxSizeRequest: 8_388_608,
        maxConcurrentRequests: 64, maxCallsInRequest: 32, maxObjectsInGet: 64, maxObjectsInSet: 64,
        collationAlgorithms: [])
    let metadata = try JMAPSessionMetadata(
        storeID: account, accountName: "Store", username: "alice", isReadOnly: false, limits: limits,
        capabilities: [TractandaJMAP.capability: .object([])],
        accountCapabilities: [TractandaJMAP.capability: .object([])],
        primaryCapabilities: [TractandaJMAP.capability])
    let document = try metadata.session(
        authorizationBasis: Data(),
        exposure: .init(
            baseURL: "https://localhost:9443",
            resources: .init(api: true, upload: true, download: true, eventSource: true)),
        stateFactory: { _ in try .init("public-state") })
    let session = try JMAPDiscoverySession(value: document.value)
    #expect(session.accountID == account)
    #expect(session.state.value == document.state.value)
    #expect(session.value["profile"] == nil)
    #expect(throws: (any Error).self) { try JMAPLocalSession(value: document.value) }
    var cache = JMAPDiscoveryCache()
    cache.accept(session)
    cache.observe(sessionState: document.state.value)
    #expect(cache.session?.accountID == account)
    cache.observe(sessionState: "different")
    #expect(cache.session == nil)
}
@Test func comparatorNonnullableFieldsDistinguishOmissionFromNull() throws {
    let omitted = try JSON.decode(JMAPReadComparator.self, Data(#"{"property":"subject"}"#.utf8))
    #expect(omitted.isAscending)
    for fixture in [
        #"{"property":"subject","isAscending":null}"#, #"{"property":"subject","collation":null}"#,
        #"{"property":"subject","isAscending":0}"#,
    ] {
        #expect(throws: (any Error).self) { try JSON.decode(JMAPReadComparator.self, Data(fixture.utf8)) }
    }
}
@Test func accountScopedCoreMethodNeedsKnownAccountButNoInventedAccountCoreCapability() async throws {
    let account = "11111111-1111-4111-8111-111111111111"
    let kernel = JMAPKernel(
        methods: [
            "Blob/copy": .init(
                capability: JMAPKernel.core, effect: .readOnly, scope: .account, maximumResponseBytes: 4096
            ) { args, _ in .success([.init("Blob/copy", args)]) }
        ], accounts: [try .init(accountID: account, capabilities: [], isReadOnly: false)],
        sessionState: { try! .init("metadata") })
    let data = try JSONSerialization.data(withJSONObject: [
        "using": [JMAPKernel.core], "methodCalls": [["Blob/copy", ["accountId": account], "c"]],
    ])
    let response = try await kernel.execute(data)
    #expect(response.methodResponses.first?.name == "Blob/copy")
}
