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
