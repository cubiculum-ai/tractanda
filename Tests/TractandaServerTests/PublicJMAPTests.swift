import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore
@testable import TractandaServer

final class PublicJMAPTests: XCTestCase {
    private func fixture(_ body: (PublicHTTPFixture) async throws -> Void) async throws {
        let value = try await PublicHTTPFixture.open()
        do {
            try await body(value)
            await value.close()
        } catch {
            await value.close()
            throw error
        }
    }
    private static func payload(_ response: PublicHTTPWireResponse, index: Int = 0) throws -> (
        String, [String: Any]
    ) {
        let envelope = try response.json()
        let calls = try XCTUnwrap(envelope["methodResponses"] as? [[Any]])
        return (try XCTUnwrap(calls[index][0] as? String), try XCTUnwrap(calls[index][1] as? [String: Any]))
    }
    private static func account(_ response: PublicHTTPWireResponse) throws -> String {
        let object = try response.json()
        return try XCTUnwrap((object["accounts"] as? [String: Any])?.keys.first)
    }
    func testIndependentTLSClientSessionAndAPIUseOneBindingSnapshot() async throws {
        try await fixture { f in
            let token = try await f.login()
            let response = try await f.session(token)
            XCTAssertEqual(response.status, 200)
            let session = try response.json()
            XCTAssertEqual(session["apiUrl"] as? String, f.baseURL + "/jmap/api")
            XCTAssertEqual(session["uploadUrl"] as? String, f.baseURL + "/jmap/upload/{accountId}")
            XCTAssertTrue((session["eventSourceUrl"] as? String)?.contains("/jmap/events?") == true)
            XCTAssertNil(session["profile"])
            let decoded = try JMAPDiscoverySession(data: XCTUnwrap(response.body))
            XCTAssertEqual(decoded.accountID, try Self.account(response))
            let api = try await f.api(
                token,
                calls: [
                    [TractandaJMAP.discoveryMethod, [:], "s"], ["Core/echo", ["literal": "#unchanged"], "e"],
                ])
            XCTAssertEqual(api.status, 200)
            let envelope = try api.json()
            XCTAssertEqual(envelope["sessionState"] as? String, session["state"] as? String)
            let discovery = try Self.payload(api).1
            XCTAssertEqual(discovery["state"] as? String, envelope["sessionState"] as? String)
            XCTAssertEqual(discovery["apiUrl"] as? String, session["apiUrl"] as? String)
            XCTAssertEqual(try Self.payload(api, index: 1).1["literal"] as? String, "#unchanged")
            let wellKnown = try await f.call([
                .init(
                    method: "GET", path: "/.well-known/jmap", headers: [["Authorization", "Bearer " + token]])
            ])[0]
            XCTAssertEqual(try wellKnown.json()["state"] as? String, session["state"] as? String)
            let wrongTLSName = try await f.call(
                [.init(method: "GET", path: "/jmap/session")], serverName: "not-localhost.fixture")[0]
            XCTAssertEqual(wrongTLSName.status, 0)
            XCTAssertNotNil(wrongTLSName.error)
        }
    }
    func testHostOriginForwardingFramingAndRemoteIssuanceCannotChooseActor() async throws {
        try await fixture { f in
            let token = try await f.login()
            let session = try await f.session(token)
            let account = try Self.account(session)
            let common = [["Authorization", "Bearer " + token], ["Content-Type", "application/json"]]
            let body = try JSONSerialization.data(withJSONObject: [
                "using": TractandaJMAP.using, "methodCalls": [["Core/echo", [:], "e"]],
            ])
            let badHost = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api", headers: common + [["Host", "attacker.fixture"]],
                    body: body)
            ])[0]
            XCTAssertEqual(badHost.status, 403)
            let badOrigin = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: common + [["Origin", "https://attacker.fixture"]], body: body)
            ])[0]
            XCTAssertEqual(badOrigin.status, 403)
            let duplicateAuth = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: common + [["Authorization", "Bearer " + token]], body: body)
            ])[0]
            XCTAssertTrue([0, 400].contains(duplicateAuth.status))
            let ambiguous = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: common + [["Content-Length", "0"], ["Transfer-Encoding", "chunked"]],
                    chunked: true)
            ])[0]
            XCTAssertTrue([0, 400].contains(ambiguous.status))
            let bypass = try await f.api(token, calls: [["TractandaAuth/createSession", [:], "renew"]])
            XCTAssertEqual(try Self.payload(bypass).1["type"] as? String, "unknownMethod")
            let input = CommitRequest(
                classID: "Item", changes: ["subject": .text("actual authenticated actor")],
                operationID: Identifier.make())
            var arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(input)) as? [String: Any])
            arguments["accountId"] = account
            let request = try JSONSerialization.data(withJSONObject: [
                "using": TractandaJMAP.using, "methodCalls": [["TractandaItem/commit", arguments, "save"]],
            ])
            let saved = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: common + [
                        ["Forwarded", "for=127.0.0.1;proto=http;host=attacker.fixture"],
                        ["X-Forwarded-User", "root"], ["X-Authenticated-Uid", "0"],
                    ], body: request)
            ])[0]
            let receipt = try Self.payload(saved).1
            let revisionID = try XCTUnwrap(receipt["revisionId"] as? String)
            let read = try await f.api(
                token,
                calls: [["TractandaRevision/get", ["accountId": account, "ids": [revisionID]], "read"]])
            let records = try XCTUnwrap(try Self.payload(read).1["list"] as? [[String: Any]])
            let fields = try XCTUnwrap(records.first?["fields"] as? [String: [String: Any]])
            XCTAssertEqual(fields["actor"]?["value"] as? String, "user:fixture")
            XCTAssertEqual(
                try saved.json()["sessionState"] as? String, try session.json()["state"] as? String)
            f.clock.advance(43_201)
            let expired = try await f.session(token)
            XCTAssertEqual(expired.status, 401)
        }
    }
    func testFragmentedChunkedRawUploadAttachAndStreamedDownload() async throws {
        try await fixture { f in
            let token = try await f.login()
            let account = try Self.account(try await f.session(token))
            let bytes = Data((0..<420_000).map { UInt8($0 % 251) })
            let uploaded = try await f.call([
                .init(
                    method: "POST", path: "/jmap/upload/" + account,
                    headers: [
                        ["Authorization", "Bearer " + token], ["Content-Type", "application/octet-stream"],
                    ], body: bytes, fragmentBytes: 997, chunked: true)
            ])[0]
            XCTAssertEqual(uploaded.status, 200)
            let blob = try uploaded.json()
            XCTAssertEqual(blob["accountId"] as? String, account)
            XCTAssertEqual(blob["size"] as? Int, bytes.count)
            let blobID = try XCTUnwrap(blob["blobId"] as? String)
            XCTAssertEqual(blobID, PageCorpusInput.digest(bytes))
            let downloaded = try await f.call([
                .init(
                    method: "GET",
                    path: "/jmap/download/\(account)/\(blobID)/file.bin?type=application%2Foctet-stream",
                    headers: [["Authorization", "Bearer " + token]], slowReadMilliseconds: 2)
            ])[0]
            XCTAssertEqual(downloaded.status, 200)
            XCTAssertEqual(downloaded.size, bytes.count)
            XCTAssertEqual(downloaded.sha256, blobID)
            XCTAssertEqual(downloaded.incomplete, false)
            XCTAssertEqual(downloaded.headers["content-type"], "application/octet-stream")
            let create = CommitRequest(
                classID: "Item", changes: ["subject": .text("attachment owner")],
                operationID: Identifier.make())
            var arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(create)) as? [String: Any])
            arguments["accountId"] = account
            let saved = try await f.api(token, calls: [["TractandaItem/commit", arguments, "create"]])
            let receipt = try Self.payload(saved).1
            let itemID = try XCTUnwrap(receipt["itemId"] as? String)
            let revisionID = try XCTUnwrap(receipt["revisionId"] as? String)
            let operation = Identifier.make()
            let attach: [String: Any] = [
                "accountId": account, "itemID": itemID, "expectedRevisionID": revisionID, "blobId": blobID,
                "filename": "file.bin", "mediaType": "application/octet-stream", "operationID": operation,
            ]
            let attached = try await f.api(
                token, calls: [["TractandaAttachment/attachBlob", attach, "attach"]])
            XCTAssertEqual(try Self.payload(attached).0, "TractandaAttachment/attachBlob")
            let replay = try await f.api(
                token, calls: [["TractandaAttachment/attachBlob", attach, "attach"]])
            let attachedRevision = try XCTUnwrap(try Self.payload(attached).1["revisionID"] as? String)
            XCTAssertEqual(try Self.payload(replay).1["revisionID"] as? String, attachedRevision)
            XCTAssertEqual(try Self.payload(replay).1["replayed"] as? Bool, true)
            let owned = try await f.call([
                .init(
                    method: "GET",
                    path: "/jmap/download/\(account)/\(blobID)/again.bin?type=application%2Foctet-stream",
                    headers: [["Authorization", "Bearer " + token]])
            ])[0]
            XCTAssertEqual(owned.sha256, blobID)
            XCTAssertEqual(owned.size, bytes.count)
        }
    }
    func testSSERealChunkedResponseCloseAfterAndCredentialScope() async throws {
        try await fixture { f in
            let token = try await f.login()
            let event = try await f.call([
                .init(
                    method: "GET", path: "/jmap/events?types=TractandaItem&closeafter=state&ping=0",
                    headers: [["Authorization", "Bearer " + token]])
            ])[0]
            XCTAssertEqual(event.status, 200)
            XCTAssertEqual(event.headers["transfer-encoding"], "chunked")
            let frame = String(decoding: try XCTUnwrap(event.body), as: UTF8.self)
            XCTAssertTrue(frame.hasPrefix("event: state\n"))
            XCTAssertTrue(frame.contains("\"TractandaItem\""))
            XCTAssertFalse(frame.contains("\"TractandaRevision\""))
            let persistent = try await f.call([
                .init(
                    method: "GET", path: "/jmap/events?types=%2A&closeafter=no&ping=0",
                    headers: [["Authorization", "Bearer " + token], ["Last-Event-ID", "different-state"]],
                    readEvents: 1)
            ])[0]
            XCTAssertEqual(persistent.status, 200)
            XCTAssertTrue(
                String(decoding: try XCTUnwrap(persistent.body), as: UTF8.self).contains(
                    "\"TractandaRevision\""))
            let created = try await f.api(
                token,
                calls: [
                    [
                        "PushSubscription/set",
                        [
                            "create": [
                                "new": [
                                    "deviceClientId": "fixture-device",
                                    "url": "https://callback.fixture/push", "types": ["TractandaItem"],
                                ]
                            ]
                        ], "p",
                    ]
                ], using: [JMAPKernel.core])
            XCTAssertEqual(try Self.payload(created).0, "PushSubscription/set")
            let another = try await f.login()
            let privateList = try await f.api(
                another, calls: [["PushSubscription/get", ["ids": NSNull()], "get"]], using: [JMAPKernel.core]
            )
            XCTAssertEqual((try Self.payload(privateList).1["list"] as? [Any])?.count, 0)
        }
    }
    func testKeepAlivePipeliningAndProtocolValidationStayDistinct() async throws {
        try await fixture { f in
            let token = try await f.login()
            let account = try Self.account(try await f.session(token))
            let authorization = [["Authorization", "Bearer " + token]]
            let wrongMethodCases: [(String, String, String)] = [
                ("GET", "/jmap/api", "POST"), ("GET", "/auth/login", "POST"),
                ("GET", "/auth/logout", "POST"), ("GET", "/jmap/upload/" + account, "POST"),
                ("POST", "/jmap/session", "GET"), ("POST", "/.well-known/jmap", "GET"),
                ("POST", "/auth/session", "GET"), ("POST", "/jmap/events", "GET"),
                ("POST", "/jmap/download/" + account + "/blob/name", "GET"),
            ]
            for (method, path, allow) in wrongMethodCases {
                let response = try await f.call([
                    .init(method: method, path: path, headers: authorization)
                ])[0]
                XCTAssertEqual(response.status, 405, "\(method) \(path)")
                XCTAssertEqual(response.headers["allow"], allow, "\(method) \(path)")
            }
            let unknownPath = try await f.call([
                .init(method: "GET", path: "/unknown/resource", headers: authorization)
            ])[0]
            XCTAssertEqual(unknownPath.status, 404)
            XCTAssertNil(unknownPath.headers["allow"])
            let replies = try await f.call(
                [
                    .init(
                        method: "GET", path: "/jmap/session",
                        headers: [["Authorization", "Bearer " + token], ["Connection", "keep-alive"]]),
                    .init(
                        method: "GET", path: "/jmap/session",
                        headers: [["Authorization", "Bearer " + token], ["Connection", "close"]]),
                ], pipeline: true)
            XCTAssertEqual(replies.map(\.status), [200, 200])
            XCTAssertEqual(
                try replies[0].json()["state"] as? String, try replies[1].json()["state"] as? String)
            let unknown = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: [["Authorization", "Bearer " + token], ["Content-Type", "application/json"]],
                    body: Data(
                        "{\"using\":[\"urn:ietf:params:jmap:core\",\"unknown:capability\"],\"methodCalls\":[]}"
                            .utf8))
            ])[0]
            XCTAssertEqual(unknown.status, 400)
            XCTAssertTrue(unknown.headers["content-type"]?.hasPrefix("application/problem+json") == true)
            let valid = try await f.api(
                token,
                calls: [["TractandaItem/changes", ["accountId": account, "sinceState": "unknown"], "c"]])
            XCTAssertEqual(valid.status, 200)
            XCTAssertEqual(try Self.payload(valid).1["type"] as? String, "cannotCalculateChanges")
            for bad: [String: Any] in [
                ["accountId": account], ["accountId": account, "sinceState": 12],
                ["accountId": account, "sinceState": "x", "maxChanges": 0],
                ["accountId": account, "sinceState": "x", "maxChanges": true],
            ] {
                let response = try await f.api(token, calls: [["TractandaItem/changes", bad, "c"]])
                XCTAssertEqual(try Self.payload(response).1["type"] as? String, "invalidArguments")
            }
            for bad: [String: Any] in [
                ["position": NSNull()], ["calculateTotal": NSNull()],
                ["sort": [["property": "subject", "isAscending": NSNull()]]],
                ["sort": [["property": "subject", "collation": NSNull()]]],
            ] {
                var args = bad
                args["accountId"] = account
                let response = try await f.api(token, calls: [["TractandaItem/query", args, "q"]])
                XCTAssertEqual(try Self.payload(response).1["type"] as? String, "invalidArguments")
            }
            for malformed in ["", "/"] {
                let response = try await f.api(
                    token,
                    calls: [
                        [
                            "Blob/copy", ["accountId": account, "fromAccountId": malformed, "blobIds": []],
                            "b",
                        ]
                    ], using: [JMAPKernel.core])
                XCTAssertEqual(try Self.payload(response).1["type"] as? String, "invalidArguments")
            }
            let source = try await f.api(
                token,
                calls: [
                    [
                        "Blob/copy", ["accountId": account, "fromAccountId": "valid_unknown", "blobIds": []],
                        "b",
                    ]
                ], using: [JMAPKernel.core])
            XCTAssertEqual(try Self.payload(source).1["type"] as? String, "fromAccountNotFound")
        }
    }
    func testUploadLimitAndFilenameHeaderInjectionAreRejectedBeforeUse() async throws {
        try await fixture { f in
            let token = try await f.login()
            let account = try Self.account(try await f.session(token))
            let tooLarge = try await f.call([
                .init(
                    method: "POST", path: "/jmap/upload/" + account,
                    headers: [
                        ["Authorization", "Bearer " + token], ["Content-Length", "3000000"],
                        ["Content-Type", "application/octet-stream"],
                    ])
            ])[0]
            XCTAssertEqual(tooLarge.status, 413)
            let apiTooLarge = try await f.call([
                .init(
                    method: "POST", path: "/jmap/api",
                    headers: [
                        ["Authorization", "Bearer " + token], ["Content-Type", "application/json"],
                        ["Content-Length", "8388609"],
                    ])
            ])[0]
            XCTAssertEqual(apiTooLarge.status, 413)
            XCTAssertEqual(try apiTooLarge.json()["type"] as? String, "urn:ietf:params:jmap:error:limit")
            XCTAssertEqual(try apiTooLarge.json()["limit"] as? String, "maxSizeRequest")
            let zero = try await f.call([
                .init(
                    method: "POST", path: "/jmap/upload/" + account,
                    headers: [
                        ["Authorization", "Bearer " + token], ["Content-Type", "application/octet-stream"],
                    ])
            ])[0]
            XCTAssertEqual(zero.status, 200)
            let id = try XCTUnwrap(try zero.json()["blobId"] as? String)
            let injected = try await f.call([
                .init(
                    method: "GET",
                    path:
                        "/jmap/download/\(account)/\(id)/name%0D%0AX-Forged%3Ayes?type=application%2Foctet-stream",
                    headers: [["Authorization", "Bearer " + token]])
            ])[0]
            XCTAssertEqual(injected.status, 400)
            XCTAssertNil(injected.headers["x-forged"])
        }
    }
}

extension PublicJMAPTests {
    func testProtectedProxyRejectsRenameableAncestorsAndSymlinkTraversal() throws {
        #if os(macOS)
            let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #else
            let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #endif
        try PeerFixtureCapacity.requireFree(at: temporary)
        let root = temporary.appendingPathComponent("jhp-" + String(Identifier.make().prefix(8)))
        let shared = root.appendingPathComponent("shared")
        let owned = shared.appendingPathComponent("private")
        try FileManager.default.createDirectory(
            at: owned, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        let path = owned.appendingPathComponent("backend.sock").path
        let config = PublicJMAPConfiguration(
            baseURL: "https://localhost", transport: .trustedProxyUnix(path: path))
        XCTAssertThrowsError(try config.validateProtectedProxyParents())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: shared.path)
        XCTAssertNoThrow(try config.validateProtectedProxyParents())
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: owned)
        let aliased = PublicJMAPConfiguration(
            baseURL: "https://localhost",
            transport: .trustedProxyUnix(path: link.appendingPathComponent("backend.sock").path))
        XCTAssertThrowsError(try aliased.validateProtectedProxyParents())
    }
}
