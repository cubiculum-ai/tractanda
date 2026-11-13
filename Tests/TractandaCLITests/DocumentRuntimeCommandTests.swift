import Foundation
import XCTest

@testable import TractandaCLI
@testable import TractandaCore

final class DocumentRuntimeCommandTests: XCTestCase {
    func testStatusAndUnloadUseNativeAccountWithoutStartingService() throws {
        let account = "01010101-0101-1101-8101-010101010101"
        var options = ConnectionOptions()
        options.socketPath = "/tmp/document-runtime.sock"
        for operation in ["status", "unload"] {
            for json in [false, true] {
                var result = Data()
                var methods: [String] = []
                let args = ["document-runtime", operation] + (json ? ["--json"] : [])
                XCTAssertTrue(
                    try documentRuntimeCommand(
                        arguments: args, options: options, output: { result = $0 },
                        sendForTesting: { connection, request, _ in
                            XCTAssertNil(connection.managedService)
                            let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
                            let call = (envelope["methodCalls"] as! [[Any]])[0]
                            let method = call[0] as! String
                            if method == "TractandaSession/get" {
                                let capability = ItemService.capability
                                return try JSONSerialization.data(withJSONObject: [
                                    "methodResponses": [
                                        [
                                            method,
                                            [
                                                "profile": "tractanda.local-session.v1", "username": "alice",
                                                "state": "metadata",
                                                "capabilities": [
                                                    "urn:ietf:params:jmap:core": [:], capability: [:],
                                                ],
                                                "accounts": [
                                                    account: ["accountCapabilities": [capability: [:]]]
                                                ],
                                                "primaryAccounts": [capability: account],
                                            ], call[2],
                                        ]
                                    ]
                                ])
                            }
                            methods.append(method)
                            XCTAssertEqual((call[1] as? [String: Any])?["accountId"] as? String, account)
                            return try JSONSerialization.data(withJSONObject: [
                                "methodResponses": [
                                    [
                                        method,
                                        [
                                            "accountId": account, "workerRunning": true,
                                            "documentActive": false, "unloadPending": false,
                                        ], call[2],
                                    ]
                                ]
                            ])
                        }))
                XCTAssertEqual(methods, ["TractandaDocumentRuntime/" + operation])
                if json {
                    let value = try JSON.decode(DocumentWorkerPoolStatus.self, result)
                    XCTAssertTrue(value.workerRunning)
                } else {
                    XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("does not establish"))
                }
            }
        }
        XCTAssertThrowsError(
            try documentRuntimeCommand(arguments: ["document-runtime", "unload", "oops"], options: options))
    }
}
