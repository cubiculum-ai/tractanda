import Foundation
import MCP
import XCTest

@testable import TractandaCore
@testable import TractandaMCP

final class MCPHTTPServiceTests: XCTestCase {
    private actor Tokens {
        var revoked = false
        func identity(_ token: String, alice: AccountIdentity, bob: AccountIdentity) throws -> AccountIdentity
        {
            if token == "alice", !revoked { return alice }
            if token == "bob" { return bob }
            throw TractandaError("unauthorized", "bad")
        }
        func revokeAlice() { revoked = true }
    }
    private final class Clock: @unchecked Sendable {
        var value = Date(timeIntervalSince1970: 1_000)
    }
    private actor AuthorizerGate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }
    private let alice = AccountIdentity(uid: 8001, name: "alice", primaryGroupName: "staff", groupIDs: [])
    private let bob = AccountIdentity(uid: 8002, name: "bob", primaryGroupName: "staff", groupIDs: [])

    private func body(_ id: String, _ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
    }
    private func request(_ body: Data, token: String, session: String? = nil) -> HTTPRequest {
        var headers = [
            "Authorization": "Bearer \(token)", "Content-Type": "application/json",
            "Accept": "application/json",
        ]
        if let session { headers["Mcp-Session-Id"] = session }
        return HTTPRequest(method: "POST", headers: headers, body: body)
    }
    private func service() -> MCPHTTPService {
        let alice = alice
        let bob = bob
        return MCPHTTPService(
            authorize: { token in
                if token == "alice" { return alice }
                if token == "bob" { return bob }
                throw TractandaError("unauthorized", "bad")
            },
            dispatch: { data, _ in
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let call = (request["methodCalls"] as! [[Any]])[0]
                return try JSONSerialization.data(withJSONObject: [
                    "methodResponses": [[call[0], ["ok": true], "client"]]
                ])
            })
    }

    func testSessionIsBoundToReauthenticatedBearerAndCanBeDeleted() async throws {
        let service = service()
        let initialize = await service.handle(
            request(
                try body(
                    "1", "initialize",
                    [
                        "protocolVersion": "2025-11-25", "capabilities": [:],
                        "clientInfo": ["name": "test", "version": "1"],
                    ]), token: "alice"))
        XCTAssertEqual(initialize.statusCode, 200)
        let session = initialize.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
        XCTAssertNotNil(session)
        let foreign = await service.handle(
            request(try body("2", "tools/list"), token: "bob", session: session))
        XCTAssertEqual(foreign.statusCode, 404)
        let deletion = await service.handle(
            HTTPRequest(
                method: "DELETE", headers: ["Authorization": "Bearer alice", "Mcp-Session-Id": session!]))
        XCTAssertEqual(deletion.statusCode, 200)
        let gone = await service.handle(
            request(try body("3", "tools/list"), token: "alice", session: session))
        XCTAssertEqual(gone.statusCode, 404)
        await service.close()
    }

    func testInProcessInfoReportsNoSocketOrProfile() async throws {
        let alice = alice
        let service = MCPHTTPService(
            authorize: { token in
                guard token == "alice" else { throw TractandaError("unauthorized", "bad") }
                return alice
            },
            dispatch: { data, _ in
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let call = (request["methodCalls"] as! [[Any]])[0]
                let result: [String: Any] = [
                    "accessScope": "single-user",
                    "server": ["name": "Tractanda", "version": "fixture", "instanceID": "native-instance"],
                ]
                return try JSONSerialization.data(withJSONObject: [
                    "methodResponses": [[call[0], result, call[2]]]
                ])
            }, resultFormat: .structured)
        let initialize = await service.handle(
            request(
                try body(
                    "1", "initialize",
                    [
                        "protocolVersion": "2025-11-25", "capabilities": [:],
                        "clientInfo": ["name": "test", "version": "1"],
                    ]), token: "alice"))
        let session = try XCTUnwrap(
            initialize.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value)
        let response = await service.handle(
            request(
                try body("2", "tools/call", ["name": "tractanda_info", "arguments": [:]]),
                token: "alice", session: session))
        XCTAssertEqual(response.statusCode, 200)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(response.bodyData)) as? [String: Any])
        let result = try XCTUnwrap(payload["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let connection = try XCTUnwrap(structured["connection"] as? [String: Any])
        XCTAssertEqual(connection["transport"] as? String, "inProcess")
        XCTAssertEqual(connection["status"] as? String, "ready")
        XCTAssertNil(connection["socketPath"])
        XCTAssertNil(connection["profile"])
        XCTAssertEqual((structured["server"] as? [String: Any])?["instanceID"] as? String, "native-instance")
        await service.close()
    }

    func testConcurrentInitializeCapsAtEightAndNotificationDoesNotReserve() async throws {
        let service = service()
        let notification = HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer alice", "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "method": "initialize", "params": [:],
            ]))
        let notificationResponse = await service.handle(notification)
        XCTAssertEqual(notificationResponse.statusCode, 400)
        let initialize = try body(
            "1", "initialize",
            [
                "protocolVersion": "2025-11-25", "capabilities": [:],
                "clientInfo": ["name": "test", "version": "1"],
            ])
        let concurrentRequest = HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer alice", "Content-Type": "application/json",
                "Accept": "application/json",
            ], body: initialize)
        let responses = await withTaskGroup(of: HTTPResponse.self, returning: [HTTPResponse].self) { group in
            for _ in 0..<10 {
                group.addTask { await service.handle(concurrentRequest) }
            }
            var values: [HTTPResponse] = []
            for await response in group { values.append(response) }
            return values
        }
        XCTAssertEqual(responses.filter { $0.statusCode == 200 }.count, 8)
        XCTAssertEqual(responses.filter { $0.statusCode == 429 }.count, 2)
        let session = try XCTUnwrap(
            responses.first(where: { $0.statusCode == 200 })?.headers.first {
                $0.key.lowercased() == "mcp-session-id"
            }?.value)
        _ = await service.handle(
            HTTPRequest(
                method: "DELETE", headers: ["Authorization": "Bearer alice", "Mcp-Session-Id": session]))
        let replacement = await service.handle(request(initialize, token: "alice"))
        XCTAssertEqual(replacement.statusCode, 200)
        await service.close()
    }

    func testToolDispatchRevocationCrossUserAndOriginRules() async throws {
        let tokens = Tokens()
        let alice = alice
        let bob = bob
        let service = MCPHTTPService(
            authorize: { try await tokens.identity($0, alice: alice, bob: bob) },
            dispatch: { data, _ in
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let call = (request["methodCalls"] as! [[Any]])[0]
                return try JSONSerialization.data(withJSONObject: [
                    "methodResponses": [[call[0], ["ok": true], "client"]]
                ])
            })
        let initialize = try body(
            "1", "initialize",
            [
                "protocolVersion": "2025-11-25", "capabilities": [:],
                "clientInfo": ["name": "test", "version": "1"],
            ])
        var initRequest = request(initialize, token: "alice")
        initRequest = HTTPRequest(
            method: "POST",
            headers: initRequest.headers.merging(["Origin": "http://127.0.0.1:48728"]) { _, new in new },
            body: initRequest.body)
        let initialized = await service.handle(initRequest)
        XCTAssertEqual(initialized.statusCode, 200)
        let session = try XCTUnwrap(
            initialized.headers.first { $0.key.lowercased() == "mcp-session-id" }?.value)
        let tool = try body("2", "tools/call", ["name": "tractanda_info", "arguments": [:]])
        let toolResponse = await service.handle(request(tool, token: "alice", session: session))
        XCTAssertEqual(toolResponse.statusCode, 200)
        let foreign = await service.handle(request(tool, token: "bob", session: session))
        XCTAssertEqual(foreign.statusCode, 404)
        await tokens.revokeAlice()
        let revoked = await service.handle(request(tool, token: "alice", session: session))
        XCTAssertEqual(revoked.statusCode, 401)
        var evil = request(initialize, token: "bob")
        evil = HTTPRequest(
            method: "POST", headers: evil.headers.merging(["Origin": "https://evil.test"]) { _, new in new },
            body: evil.body)
        let evilResponse = await service.handle(evil)
        XCTAssertEqual(evilResponse.statusCode, 403)
        await service.close()
    }

    func testIdleSessionsExpireAndCapacityIsReclaimed() async throws {
        let clock = Clock()
        let alice = alice
        let bob = bob
        let service = MCPHTTPService(
            authorize: { token in token == "alice" ? alice : bob },
            dispatch: { _, _ in Data() }, now: { clock.value })
        let initialize = try body(
            "1", "initialize",
            [
                "protocolVersion": "2025-11-25", "capabilities": [:],
                "clientInfo": ["name": "test", "version": "1"],
            ])
        for _ in 0..<8 {
            let response = await service.handle(request(initialize, token: "alice"))
            XCTAssertEqual(response.statusCode, 200)
        }
        clock.value.addTimeInterval(3_601)
        let reclaimed = await service.handle(request(initialize, token: "alice"))
        XCTAssertEqual(reclaimed.statusCode, 200)
        await service.close()
    }

    func testCloseDuringAuthorizationDoesNotAllocateSession() async throws {
        let gate = AuthorizerGate()
        let alice = alice
        let service = MCPHTTPService(
            authorize: { _ in
                await gate.wait()
                return alice
            }, dispatch: { _, _ in Data() })
        let initialize = try body(
            "1", "initialize",
            [
                "protocolVersion": "2025-11-25", "capabilities": [:],
                "clientInfo": ["name": "test", "version": "1"],
            ])
        let pendingRequest = HTTPRequest(
            method: "POST",
            headers: [
                "Authorization": "Bearer alice", "Content-Type": "application/json",
                "Accept": "application/json",
            ], body: initialize)
        let pending = Task { await service.handle(pendingRequest) }
        await Task.yield()
        await service.close()
        await gate.release()
        let response = await pending.value
        XCTAssertEqual(response.statusCode, 503)
    }
}
