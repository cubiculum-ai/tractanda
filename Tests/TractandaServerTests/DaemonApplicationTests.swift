import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaServer

final class DaemonApplicationTests: XCTestCase {
    private struct Authenticator: PasswordAuthenticating {
        let uid: UInt32
        func authenticate(username: String, password: String) throws -> UInt32 { uid }
    }

    private func fixture(_ body: (DaemonApplication, ServiceCoordinator, UInt32) async throws -> Void)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "daemon-app-\(UUID().uuidString)")
        let coordinator = try await ServiceCoordinator(opening: root)
        let uid = try await coordinator.accountIdentity(forUID: tractanda_uid()).uid
        let sessions = SessionAuthority(coordinator: coordinator, authenticator: Authenticator(uid: uid))
        let app = DaemonApplication(
            coordinator: coordinator, sessions: sessions, page: Data("page".utf8),
            manual: Data("manual".utf8), nonce: "test")
        do { try await body(app, coordinator, uid) } catch {
            await app.close()
            await coordinator.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await app.close()
        await coordinator.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func request(
        _ method: String, _ uri: String, headers: [String: [String]] = [:], body: Data = Data()
    ) -> DaemonHTTPRequest {
        let final = headers["host"] == nil ? headers.merging(["host": ["127.0.0.1:48730"]]) { $1 } : headers
        return DaemonHTTPRequest(method: method, uri: uri, headers: final, body: body, localPort: 48730)
    }
    private func native(_ method: String, _ args: [String: Any] = [:], id: String = "x") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [[method, args, id]],
        ])
    }

    func testNativeSessionIssuesOnlyForPeerAndHTTPUsesIt() async throws {
        try await fixture { app, _, uid in
            let issued = try await app.native(try native("TractandaAuth/createSession"), forUID: uid)
            let value = try JSONSerialization.jsonObject(with: issued) as! [String: Any]
            let token = ((value["methodResponses"] as! [[Any]])[0][1] as! [String: Any])["token"] as! String
            let profile = try await app.http(
                request("GET", "/auth/session", headers: ["authorization": ["Bearer \(token)"]]))
            XCTAssertEqual(profile.status, 200)
            let api = try await app.http(
                request(
                    "POST", "/api",
                    headers: ["authorization": ["Bearer \(token)"], "content-type": ["application/json"]],
                    body: try native("TractandaStore/info")))
            XCTAssertEqual(api.status, 200)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: api.body) as? [String: Any])
            let forged = try await app.native(
                try native("TractandaAuth/createSession", ["uid": uid &+ 1]), forUID: uid)
            XCTAssertFalse(String(data: forged, encoding: .utf8)!.contains("token"))
            let mixed = try JSONSerialization.data(withJSONObject: [
                "using": [ItemService.capability],
                "methodCalls": [
                    ["TractandaAuth/createSession", [:], "a"], ["TractandaAuth/createSession", [:], "b"],
                ],
            ])
            let mixedResponse = try await app.native(mixed, forUID: uid)
            XCTAssertFalse(String(data: mixedResponse, encoding: .utf8)!.contains("token"))

            let throughHTTP = try await app.http(
                request(
                    "POST", "/api",
                    headers: [
                        "authorization": ["Bearer \(token)"], "content-type": ["application/json"],
                    ], body: try native("TractandaAuth/createSession")))
            XCTAssertEqual(throughHTTP.status, 200)
            XCTAssertFalse(String(decoding: throughHTTP.body, as: UTF8.self).contains("token"))

            let mixedHTTP = try await app.http(
                request(
                    "POST", "/api",
                    headers: [
                        "authorization": ["Bearer \(token)"], "content-type": ["application/json"],
                    ], body: mixed))
            XCTAssertEqual(mixedHTTP.status, 200)
            XCTAssertFalse(String(decoding: mixedHTTP.body, as: UTF8.self).contains("token"))
        }
    }

    func testLogoutRevokesHTTPWhileNativeAndAssetsRemainUsable() async throws {
        try await fixture { app, _, uid in
            let issued = try await app.native(try native("TractandaAuth/createSession"), forUID: uid)
            let token =
                (((try JSONSerialization.jsonObject(with: issued) as! [String: Any])["methodResponses"]
                as! [[Any]])[0][1] as! [String: Any])["token"] as! String
            let logout = try await app.http(
                request("POST", "/auth/logout", headers: ["authorization": ["Bearer \(token)"]]))
            XCTAssertEqual(logout.status, 200)
            let revoked = try await app.http(
                request(
                    "POST", "/api",
                    headers: [
                        "authorization": ["Bearer \(token)"], "content-type": ["application/json"],
                    ], body: try native("TractandaStore/info"))
            )
            XCTAssertEqual(revoked.status, 401)
            let nativeResponse = try await app.native(try native("TractandaStore/info"), forUID: uid)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: nativeResponse) as? [String: Any])
            let page = try await app.http(request("GET", "/"))
            XCTAssertEqual(page.status, 200)
            XCTAssertTrue(page.headers["Content-Security-Policy"]!.contains("connect-src 'self'"))
            let wrongMethod = try await app.http(request("GET", "/api"))
            let wrongHost = try await app.http(
                request("GET", "/auth/session", headers: ["host": ["evil:48730"]]))
            let wrongOrigin = try await app.http(
                request("POST", "/api", headers: ["origin": ["http://evil"]]))
            XCTAssertEqual(wrongMethod.status, 405)
            XCTAssertEqual(wrongHost.status, 403)
            XCTAssertEqual(wrongOrigin.status, 403)

            let duplicateBearer = try await app.http(
                request(
                    "POST", "/api",
                    headers: [
                        "authorization": ["Bearer \(token)", "Bearer \(token)"],
                        "content-type": ["application/json"],
                    ], body: try native("TractandaStore/info")))
            XCTAssertEqual(duplicateBearer.status, 401)
            let malformedMedia = try await app.http(
                request("POST", "/api", headers: ["authorization": ["Bearer \(token)"]]))
            XCTAssertEqual(malformedMedia.status, 415)
            let malformedPath = try await app.http(request("POST", "/api?ignored"))
            XCTAssertEqual(malformedPath.status, 404)
        }
    }
}
