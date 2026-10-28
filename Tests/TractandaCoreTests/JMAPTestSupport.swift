import CTractandaPlatform
import Foundation
import TractandaClient

@testable import TractandaCore

/// Fixture adaptation uses the production Request decoder/state machine, never an old envelope parser.
func nativeFixtureInvocation(_ data: Data) throws -> NativeMethodInvocation {
    let request = try JMAPRequest.decode(data)
    var definitions = NativeMethodCatalog.definitions { _, _ in .failure(.init("serverFail"), effects: .none)
    }
    for call in request.methodCalls where definitions[call.name] == nil && call.name != "Core/echo" {
        definitions[call.name] = .init(
            capability: ItemService.capability, effect: .readOnly, maximumResponseBytes: 524_288
        ) { _, _ in
            .failure(.init("serverFail"), effects: .none)
        }
    }
    var execution = try JMAPKernel(methods: definitions, sessionState: { try! .init("fixture") }).begin(
        request)
    guard let call = try execution.next() else {
        throw TractandaError("invalidArguments", "Fixture needs one yielded invocation.")
    }
    return NativeMethodInvocation(call.invocation, context: call.context)
}

/// Build positive domain fixtures with the current JMAP account, filter and wire-value contracts.
/// Protocol-rejection tests intentionally keep their own raw envelopes.
func nativeFixtureEnvelope(calls: [[Any]], accountID: String) throws -> Data {
    let prepared: [[Any]] = try calls.map { call in
        guard call.count == 3, let method = call[0] as? String,
            var arguments = call[1] as? [String: Any], let callID = call[2] as? String
        else {
            throw TractandaError("testFixture", "Malformed positive fixture invocation.")
        }
        if method == "TractandaItem/query" {
            let filterKeys: Set<String> = [
                "expression", "text", "categoryPath", "excludedCategoryIDs", "viewID", "sectionID", "at",
                "timeZone",
            ]
            var filter: [String: Any] = [:]
            for key in filterKeys {
                if let value = arguments.removeValue(forKey: key) { filter[key] = value }
            }
            if !filter.isEmpty {
                guard arguments["filter"] == nil else {
                    throw TractandaError("testFixture", "Use one explicit query filter in a fixture.")
                }
                arguments["filter"] = filter
            }
            if arguments["calculateTotal"] == nil { arguments["calculateTotal"] = true }
            if let sort = arguments["sort"] as? [[String: Any]],
                sort.contains(where: { $0["categoryRootID"] != nil })
            {
                let domain = try JSONDecoder().decode(
                    [ItemSort].self, from: JSONSerialization.data(withJSONObject: sort))
                arguments["sort"] = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(domain.map(JMAPReadComparator.init)))
            }
        }
        let canonical = try JMAPValue.decode(JSONSerialization.data(withJSONObject: arguments))
        let selected = try TractandaJMAP.prepareArguments(
            method: method, arguments: canonical, accountID: accountID)
        let wire = try TractandaJMAPCodec.argumentsToWire(method: method, arguments: selected)
        return [method, try JSONSerialization.jsonObject(with: wire.encoded()), callID]
    }
    return try NativeClientContext.envelope(calls: prepared)
}

func nativeFixtureRequest(
    method: String, arguments: [String: Any], accountID: String, callID: String = "test"
) throws -> Data {
    try nativeFixtureEnvelope(calls: [[method, arguments, callID]], accountID: accountID)
}

/// A coordinator owns its store's writer lease; read its public identity through canonical metadata.
func nativeFixtureAccountID(_ root: URL) throws -> String {
    try PersonalWorkgroupProfile.load(root, ownerUID: tractanda_uid())?.storeID
        ?? CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
}
