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

extension TractandaCore.ItemClient {
    /// Storage fixture setup only: production save acknowledgement never depends on hydration.
    func commitFixture(_ request: CommitRequest) throws -> CommitResult {
        let receipt = try commit(request)
        let revision = try self.revision(itemID: receipt.itemID, revisionID: receipt.revisionID)
        return CommitResult(
            revision: revision, wasReplayed: receipt.wasReplayed,
            isIndexReady: receipt.isIndexReady, warnings: receipt.diagnostics.map(\.rawValue))
    }
}

/// Build positive domain fixtures with the current JMAP account, filter and wire-value contracts.
/// Protocol-rejection tests intentionally keep their own raw envelopes.
func nativeFixtureEnvelope(calls: [[Any]], accountID: String) throws -> Data {
    var prepared: [[Any]] = []
    for call in calls {
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
                let data = try JSONSerialization.data(withJSONObject: sort)
                let domain = try JSONDecoder().decode([TractandaClient.ItemSort].self, from: data)
                let comparators = try domain.map { try TractandaClient.JMAPReadComparator($0) }
                let encoded = try JSONEncoder().encode(comparators)
                arguments["sort"] = try JSONSerialization.jsonObject(with: encoded)
            }
        }
        let canonical = try JMAPValue.decode(JSONSerialization.data(withJSONObject: arguments))
        let selected = try TractandaJMAP.prepareArguments(
            method: method, arguments: canonical, accountID: accountID)
        let wire = try TractandaJMAPCodec.argumentsToWire(method: method, arguments: selected)
        let encoded = try wire.encoded()
        let object = try JSONSerialization.jsonObject(with: encoded)
        prepared.append([method, object, callID])
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

/// Positive in-process fixtures use production discovery, account selection and typed wire values.
func nativeFixtureResponse(
    _ service: ServiceCoordinator, forUID uid: UInt32, method: String,
    arguments: Data = Data("{}".utf8), callID: String = "fixture"
) async throws -> Data {
    let context = NativeAsyncClientContext { request in
        try await service.handle(request, forUID: uid)
    }
    return try await context.send(method: method, arguments: arguments, callID: callID)
}
