import Foundation
import TractandaClient
import TractandaCore

let tuiFixtureAccountID = "00000001-0000-1000-8000-000000000001"
private let tuiFixtureSessionState = "fixture-session"

func tuiFixtureSession(callID: String) throws -> Data {
    let value: [String: Any] = [
        "profile": TractandaJMAP.localProfile,
        "capabilities": [JMAPKernel.core: [:], TractandaJMAP.capability: [:]],
        "accounts": [
            tuiFixtureAccountID: [
                "name": "Fixture", "isPersonal": true, "isReadOnly": false,
                "accountCapabilities": [TractandaJMAP.capability: [:]],
            ]
        ],
        "primaryAccounts": [TractandaJMAP.capability: tuiFixtureAccountID],
        "username": "fixture", "state": tuiFixtureSessionState,
    ]
    // Validate the actual public Session decoder rather than inventing a fixture parser.
    let session = try JMAPLocalSession(data: JSONSerialization.data(withJSONObject: value))
    return try tuiFixtureReply(
        method: TractandaJMAP.discoveryMethod,
        result: JSONSerialization.jsonObject(with: session.value.encoded()) as! [String: Any], callID: callID)
}

func tuiFixtureReply(method: String, result: [String: Any], callID: String) throws -> Data {
    let canonical = try JMAPValue.decode(JSONSerialization.data(withJSONObject: result))
    let wire = try TractandaJMAPCodec.extensionResultToWire(method: method, result: canonical)
    return try JSONSerialization.data(withJSONObject: [
        "sessionState": tuiFixtureSessionState,
        "methodResponses": [[method, try JSONSerialization.jsonObject(with: wire.encoded()), callID]],
    ])
}

func tuiFixtureItem(_ revision: TractandaCore.Revision) throws -> [String: Any] {
    let record = try JMAPItemRecord(
        id: revision.itemID, revisionID: revision.revisionID, formatVersion: revision.formatVersion,
        fields: revision.fields, resolution: nil)
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
}

func tuiFixtureUnresolved(_ itemID: String, stateToken: String = "fixture-token") throws -> [String: Any] {
    let state = ItemState(
        itemID: itemID, stateToken: stateToken, status: .conflicted, detailsComplete: true)
    let record = try JMAPItemRecord(unresolved: state)
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
}
