import Foundation
import Testing

@testable import TractandaClient

private let sessionStore = "e0ca4be4-cfed-11f1-b1b1-842f575e6ac5"
private let sessionCapability = "https://example.test/jmap/items"
private let sessionResources = JMAPSessionResources(
    api: true, upload: true, download: true, eventSource: true)
private func sessionLimits(_ request: Int64 = 8_388_608) throws -> JMAPSessionLimits {
    try .init(
        maxSizeUpload: 262_144, maxConcurrentUpload: 1, maxSizeRequest: request,
        maxConcurrentRequests: 2, maxCallsInRequest: 32, maxObjectsInGet: 128,
        maxObjectsInSet: 16, collationAlgorithms: ["i;unicode-casemap"])
}
private func sessionMetadata(
    username: String = "alice", readOnly: Bool = false, request: Int64 = 8_388_608,
    capabilities: [String: JMAPValue] = [sessionCapability: .object([])],
    accountCapabilities: [String: JMAPValue] = [sessionCapability: .object([])]
) throws -> JMAPSessionMetadata {
    try .init(
        storeID: sessionStore, accountName: "Family", username: username,
        isReadOnly: readOnly, limits: sessionLimits(request), capabilities: capabilities,
        accountCapabilities: accountCapabilities,
        primaryCapabilities: Array(accountCapabilities.keys).sorted())
}

@Test func jmapSessionHasExactFieldsAndRequiredTemplates() throws {
    let exposure = try JMAPHTTPSExposure(
        baseURL: "https://example.test/tractanda/", resources: sessionResources)
    let document = try sessionMetadata().session(authorizationBasis: Data("auth".utf8), exposure: exposure) {
        _ in
        try JMAPSessionState("opaque-metadata-state")
    }
    let value = try JMAPValue.decode(document.encoded())
    #expect(
        Set(value.members!.map(\.name))
            == Set([
                "capabilities", "accounts", "primaryAccounts", "username", "apiUrl", "downloadUrl",
                "uploadUrl", "eventSourceUrl", "state",
            ]))
    #expect(value["state"]?.text == document.state.value)
    #expect(value["username"]?.text == "alice")
    let accounts = try #require(value["accounts"])
    #expect(accounts.members?.map(\.name) == [sessionStore])
    #expect(accounts[sessionStore]?["isPersonal"] == .bool(false))
    #expect(accounts[sessionStore]?["isReadOnly"] == .bool(false))
    #expect(value["primaryAccounts"]?[sessionCapability]?.text == sessionStore)
    #expect(value["primaryAccounts"]?[JMAPKernel.core] == nil)
    #expect(value["apiUrl"]?.text == "https://example.test/tractanda/jmap/api")
    #expect(value["uploadUrl"]?.text == "https://example.test/tractanda/jmap/upload/{accountId}")
    #expect(
        value["downloadUrl"]?.text
            == "https://example.test/tractanda/jmap/download/{accountId}/{blobId}/{name}?type={type}")
    #expect(
        value["eventSourceUrl"]?.text
            == "https://example.test/tractanda/jmap/events?types={types}&closeafter={closeafter}&ping={ping}")
    #expect(try value["capabilities"]?[JMAPKernel.core] == sessionLimits().value)
}

@Test func jmapSessionStateMaterialIncludesOnlyExplicitMetadataAndAuthorization() throws {
    let metadata = try sessionMetadata()
    let auth = Data("current-auth".utf8)
    let local = try metadata.stateMaterial(authorizationBasis: auth)
    #expect(try local == metadata.stateMaterial(authorizationBasis: auth))
    #expect(try local != metadata.stateMaterial(authorizationBasis: Data("new-rights".utf8)))
    #expect(try local != sessionMetadata(username: "bob").stateMaterial(authorizationBasis: auth))
    #expect(try local != sessionMetadata(readOnly: true).stateMaterial(authorizationBasis: auth))
    #expect(try local != sessionMetadata(request: 1024).stateMaterial(authorizationBasis: auth))
    let exposure = try JMAPHTTPSExposure(baseURL: "https://example.test", resources: sessionResources)
    let remote = try metadata.stateMaterial(authorizationBasis: auth, exposure: exposure)
    #expect(try local != remote)
    let other = try JMAPHTTPSExposure(baseURL: "https://other.example.test", resources: sessionResources)
    #expect(try remote != metadata.stateMaterial(authorizationBasis: auth, exposure: other))
    let localValue = try JMAPValue.decode(local)
    #expect(localValue["metadata"]?["apiUrl"] == nil)
    #expect(localValue["binding"]?.text == "local")
    #expect(localValue["metadata"]?["state"] == nil)
}

@Test func jmapSessionStateMaterialCanonicalizesNestedCapabilityObjects() throws {
    let a: JMAPValue = .object([
        .init("b", .bool(true)), .init("a", .object([.init("z", .null), .init("x", .null)])),
    ])
    let b: JMAPValue = .object([
        .init("a", .object([.init("x", .null), .init("z", .null)])), .init("b", .bool(true)),
    ])
    let one = try sessionMetadata(capabilities: [sessionCapability: a])
    let two = try sessionMetadata(capabilities: [sessionCapability: b])
    #expect(
        try one.stateMaterial(authorizationBasis: Data()) == two.stateMaterial(authorizationBasis: Data()))
}

@Test func jmapSessionRefusesUnavailableResourcePlaceholders() throws {
    for missing in 0..<4 {
        let exposure = try JMAPHTTPSExposure(
            baseURL: "https://example.test",
            resources: .init(
                api: missing != 0, upload: missing != 1, download: missing != 2, eventSource: missing != 3))
        var invoked = false
        #expect(throws: JMAPSessionError.unavailableResources) {
            try sessionMetadata().session(authorizationBasis: Data(), exposure: exposure) { _ in
                invoked = true
                return try JMAPSessionState("should-not-run")
            }
        }
        #expect(!invoked)
    }
}

@Test func jmapSessionExposureRejectsUntrustedOrAmbiguousBases() {
    for invalid in [
        "http://example.test", "//example.test", "https://user:secret@example.test",
        "https://example.test?next=evil", "https://example.test#frag", "https://example.test/{host}",
        "https://example.test/a/../b", "https://example.test/%2e%2e", "https://example.test/a//b",
        "https://example.test\\evil", "https://example.test:0", "https://example.test:65536",
        "https://example.test/ spaced", "https://example.test/\n",
    ] {
        #expect(throws: JMAPSessionError.invalidExposure) {
            try JMAPHTTPSExposure(baseURL: invalid, resources: sessionResources)
        }
    }
}

@Test func jmapSessionCapabilitiesCannotEscalateOrOverrideCore() throws {
    #expect(throws: JMAPSessionError.invalidCapability) {
        try sessionMetadata(capabilities: [:])
    }
    #expect(throws: JMAPSessionError.invalidCapability) {
        try sessionMetadata(capabilities: [sessionCapability: .object([]), JMAPKernel.core: .object([])])
    }
    #expect(throws: JMAPSessionError.invalidCapability) {
        try sessionMetadata(capabilities: [sessionCapability: .bool(true)])
    }
    #expect(throws: JMAPSessionError.invalidCapability) {
        try sessionMetadata(capabilities: ["peer-admin": .object([])], accountCapabilities: [:])
    }
    let ordinary = try sessionMetadata(capabilities: [:], accountCapabilities: [:])
    let exposure = try JMAPHTTPSExposure(baseURL: "https://example.test", resources: sessionResources)
    let session = try ordinary.session(authorizationBasis: Data(), exposure: exposure) { _ in
        try .init("state")
    }
    #expect(session.value["accounts"]?[sessionStore]?["accountCapabilities"] == .object([]))
    #expect(session.value["capabilities"]?.members?.count == 1)
}

@Test func jmapSessionRejectsInvalidLimitsAndNonStoreAccounts() throws {
    for invalid in [-1, 9_007_199_254_740_992] as [Int64] {
        #expect(throws: JMAPSessionError.invalidLimit) { try sessionLimits(invalid) }
    }
    for invalid in ["alice", "/private/store", "E0CA4BE4-CFED-11F1-B1B1-842F575E6AC5"] {
        #expect(throws: JMAPSessionError.invalidAccount) {
            try JMAPSessionMetadata(
                storeID: invalid, accountName: "Family", username: "alice", isReadOnly: false,
                limits: sessionLimits(), capabilities: [:], accountCapabilities: [:])
        }
    }
}

@Test func jmapSessionStateFactoryFailurePropagatesBeforeDocument() throws {
    let exposure = try JMAPHTTPSExposure(baseURL: "https://example.test", resources: sessionResources)
    #expect(throws: JMAPMethodError("serverFail")) {
        try sessionMetadata().session(authorizationBasis: Data(), exposure: exposure) { _ in
            try JMAPSessionState(String(repeating: "s", count: 1025))
        }
    }
}

@Test func jmapSessionDocumentAndResponseStateUseTheSameMaterial() throws {
    let metadata = try sessionMetadata()
    let exposure = try JMAPHTTPSExposure(baseURL: "https://example.test", resources: sessionResources)
    let authorization = Data("current-caller-basis".utf8)
    let expected = try metadata.stateMaterial(authorizationBasis: authorization, exposure: exposure)
    var seen: [Data] = []
    let factory: (Data) throws -> JMAPSessionState = { bytes in
        seen.append(bytes)
        return try .init("one-metadata-token")
    }
    let session = try metadata.session(
        authorizationBasis: authorization, exposure: exposure, stateFactory: factory)
    let responseState = try metadata.state(
        authorizationBasis: authorization, exposure: exposure, stateFactory: factory)
    #expect(seen == [expected, expected])
    #expect(session.state.value == responseState.value)
    #expect(session.value["state"]?.text == responseState.value)
    let changed = try sessionMetadata(capabilities: [
        sessionCapability: .object([.init("version", .string("2"))])
    ])
    #expect(try changed.stateMaterial(authorizationBasis: authorization, exposure: exposure) != expected)
}

@Test func jmapSessionUnavailableExposureCannotSupplyResponseState() throws {
    let exposure = try JMAPHTTPSExposure(
        baseURL: "https://example.test",
        resources: .init(api: true, upload: true, download: false, eventSource: true))
    #expect(throws: JMAPSessionError.unavailableResources) {
        try sessionMetadata().stateMaterial(authorizationBasis: Data(), exposure: exposure)
    }
}
