import Foundation
import Synchronization
import TractandaClient
import TractandaCore
import XCTest

@testable import TractandaTUI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@MainActor
final class ItemSearchTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: ItemStore
        let client: TractandaCore.ItemClient
        init() throws {
            let parent = FileManager.default.temporaryDirectory
            var capacity = statvfs()
            guard statvfs(parent.path, &capacity) == 0,
                UInt64(capacity.f_bavail) * UInt64(capacity.f_frsize) >= 10 * 1_024 * 1_024 * 1_024
            else { throw XCTSkip("Tiny fixture requires genuine 10 GiB free reserve.") }
            root = parent.appendingPathComponent(Identifier.make())
            store = try ItemStore(root: root.appendingPathComponent("store"))
            let service = ItemService(store: store)
            let uid = store.ownerUID
            client = TractandaCore.ItemClient(transport: { data in
                return service.handle(data, peerUID: uid)
            })
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func item(_ subject: String, extra: [String: TractandaCore.ItemValue] = [:]) throws
            -> TractandaCore.Revision
        {
            var fields = extra
            fields["subject"] = .text(subject)
            return try client.commitFixture(
                CommitRequest(classID: "Item", changes: fields, operationID: Identifier.make())
            ).revision
        }
        func app(itemsOnly: Bool = false, loader: ItemSearchLoader? = nil, viewID: String? = nil) throws
            -> TerminalApplication
        {
            try TerminalApplication(
                client: client,
                journal: RecoveryJournal(
                    url: root.appendingPathComponent(Identifier.make() + ".json"), socket: "/fixture"),
                viewID: viewID, itemsOnly: itemsOnly, itemSearchLoader: loader)
        }
    }

    private actor Transport: ItemTransport {
        let items: [TractandaCore.Revision]
        let hits: [ItemSearchHit]
        let behavior: String
        var requests: [Data] = []
        var polls = 0
        var getCount = 0
        var gate: CheckedContinuation<Void, Never>?
        var gateReleased = false
        var currentItems: [TractandaCore.Revision]?
        func release(items: [TractandaCore.Revision]? = nil) {
            currentItems = items
            gateReleased = true
            gate?.resume()
            gate = nil
        }
        func searchCount() throws -> Int {
            try requests.filter {
                let decoded = try JSONSerialization.jsonObject(with: $0) as! [String: Any]
                return (decoded["methodCalls"] as! [[Any]])[0][0] as? String == "TractandaSemantic/search"
            }.count
        }
        init(items: [TractandaCore.Revision] = [], hits: [ItemSearchHit] = [], behavior: String = "ready") {
            self.items = items
            self.hits = hits
            self.behavior = behavior
        }
        func send(_ request: Data) async throws -> Data {
            requests.append(request)
            let decoded = try JSONSerialization.jsonObject(with: request) as! [String: Any]
            let call = (decoded["methodCalls"] as! [[Any]])[0]
            let method = call[0] as! String
            let args = call[1] as! [String: Any]
            let callID = call[2] as! String
            if method == TractandaJMAP.discoveryMethod { return try tuiFixtureSession(callID: callID) }
            var result: [String: Any]
            var returned = method
            if method == "TractandaItem/get" || method == "TractandaItem/getBounded" {
                getCount += 1
                if behavior == "gatedValidation", getCount > 1, !gateReleased {
                    await withCheckedContinuation { gate = $0 }
                }
                let available = currentItems ?? items
                let ids = args["ids"] as! [String]
                let selected =
                    behavior == "continuation" && ids.count > 1
                    ? Array(available.prefix(1)) : available.filter { ids.contains($0.itemID) }
                let unresolvedID = behavior == "unresolved" ? ids.first : nil
                let blockedIDs = behavior == "unhydrated" || behavior == "oversized" ? ids : []
                let readable = selected.filter {
                    $0.itemID != unresolvedID && !blockedIDs.contains($0.itemID)
                }
                result = [
                    "accountId": tuiFixtureAccountID, "state": "stable",
                    "notFound": ids.filter { id in !available.contains { $0.itemID == id } },
                    "remainingIDs": behavior == "continuation" && ids.count > 1
                        ? Array(ids.dropFirst()) : behavior == "unhydrated" ? blockedIDs : [],
                    "oversizedIDs": behavior == "oversized" ? blockedIDs : [],
                    "list": try readable.map { try tuiFixtureItem($0) }
                        + (try unresolvedID.map { [try tuiFixtureUnresolved($0, stateToken: "token")] } ?? [])
                        ,
                ]
            } else if behavior == "unavailable" {
                returned = "error"
                result = ["type": "semanticDisabled", "description": "Disabled for test"]
            } else {
                let queryID = args["queryID"] as? String ?? args["text"] as? String ?? "query"
                if queryID == "old" { try? await Task.sleep(nanoseconds: 200_000_000) }
                if method == "TractandaSemantic/results" { polls += 1 }
                let state =
                    method == "TractandaSemantic/search" || behavior == "pending"
                        || (behavior == "pendingThenReady" && polls == 1)
                    ? "pending" : behavior == "failed" ? "failed" : "ready"
                result = [
                    "queryID": queryID, "state": state,
                    "expiresAt": Timestamp.format(Date().addingTimeInterval(behavior == "expired" ? -1 : 10)),
                    "retryAfterMilliseconds": 100, "partialCoverage": behavior == "partial",
                    "results": hits.map {
                        [
                            "itemID": $0.itemID, "revisionID": $0.revisionID,
                            "passage": $0.passage, "similarity": $0.similarity,
                        ]
                    },
                ]
            }
            return try tuiFixtureReply(method: returned, result: result, callID: callID)
        }
    }

    private func screen(_ app: TerminalApplication) -> String {
        app.render(columns: 120, rows: 32).map(\.text).joined(separator: "\n")
    }
    private func semantic(_ app: TerminalApplication, query: String) {
        app.handle(.text("f"))
        app.handle(.paste(query))
        app.handle(.tab)
        app.handle(.right)
        app.handle(.enter)
    }
    private func ready(_ loader: ItemSearchLoader) async throws -> ItemSearchLoader.Delivery {
        for _ in 0..<100 {
            if let delivery = loader.take() {
                if case .pending = delivery.outcome {} else { return delivery }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TractandaCore.TractandaError("timeout", "Test delivery timeout")
    }

    func testSearchInvokesFromViewsAndCategoriesAndRetainsTypingBindings() async throws {
        let fixture = try Fixture()
        let app = try fixture.app()
        XCTAssertTrue(screen(app).contains("[Views]"))
        app.handle(.modified(.text("f"), .control))
        XCTAssertTrue(screen(app).contains("Search items"))
        app.handle(.paste("abc"))
        app.handle(.control(1))
        app.handle(.modified(.text("f"), .control))
        app.handle(.text("Z"))
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("Text: aZbc"), screen(app))
        app.handle(.escape)
        app.handle(.function(9))
        XCTAssertTrue(screen(app).contains("[Categories]"))
        app.handle(.text("f"))
        XCTAssertTrue(screen(app).contains("Search items"))
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("[Categories]"))
        XCTAssertEqual(
            Keymap.standard.command(for: .modified(.text("f"), .command), in: .categories), .filter)
        XCTAssertNotEqual(Keymap.standard.command(for: .modified(.text("f"), .control), in: .text), .filter)
    }

    func testTextSearchIsGlobalWithoutSavingViewAndEscapeRestoresSelection() async throws {
        let fixture = try Fixture()
        _ = try fixture.item("needle outside", extra: ["scope": .text("outside")])
        _ = try fixture.item("inside", extra: ["scope": .text("inside")])
        let view = try fixture.item(
            "Inside view",
            extra: [
                "viewDefinition": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("scope == 'inside'"),
                ])
            ])
        let app = try fixture.app(itemsOnly: true, viewID: view.itemID)
        let before = screen(app)
        app.handle(.text("f"))
        app.handle(.paste("needle"))
        app.handle(.enter)
        let results = screen(app)
        XCTAssertTrue(results.contains("Search results"))
        XCTAssertTrue(results.contains("needle outside"))
        XCTAssertTrue(results.contains("All readable items"))
        XCTAssertEqual(try fixture.client.revision(for: view.itemID), view)
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("inside"))
        XCTAssertFalse(screen(app).contains("needle outside"))
        XCTAssertTrue(before.contains("inside"))
    }

    func testClearRemovesSearchAndOptionalExpressionWorks() async throws {
        let fixture = try Fixture()
        _ = try fixture.item("needle")
        let app = try fixture.app(itemsOnly: true)
        app.handle(.text("f"))
        app.handle(.paste("needle"))
        app.handle(.tab)
        app.handle(.tab)
        app.handle(.paste("subject == 'missing'"))
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("No search results"))
        app.handle(.text("a"))
        XCTAssertFalse(screen(app).contains("Search results"))
        XCTAssertTrue(screen(app).contains("needle"))
        let category = try fixture.item(
            "Root",
            extra: [
                "selection": .object([
                    "language": .text(SpotlightQuery.profile), "expression": .text("itemID == *"),
                ])
            ])
        app.handle(.function(9))
        app.handle(.paste("Root"))
        app.handle(.function(2))
        app.handle(.paste(" unsaved"))
        XCTAssertTrue(screen(app).contains("Root unsaved"))
        app.handle(.function(10))
        app.handle(.right)
        app.handle(.right)
        app.handle(.down)
        app.handle(.enter)
        XCTAssertTrue(screen(app).contains("Search items"))
        app.handle(.paste("needle"))
        app.handle(.enter)
        app.handle(.text("a"))
        app.handle(.function(9))
        XCTAssertTrue(screen(app).contains("Root unsaved"))
        XCTAssertEqual(try fixture.client.revision(for: category.itemID), category)
    }

    func testSemanticRankingDeduplicationAndCurrentRevisionAuthorization() async throws {
        let fixture = try Fixture()
        let first = try fixture.item("First")
        let second = try fixture.item("Second")
        let old = ItemSearchHit(
            itemID: first.itemID, revisionID: Identifier.make(), passage: "stale", similarity: 0.99)
        let hits = [
            ItemSearchHit(
                itemID: second.itemID, revisionID: second.revisionID, passage: "second passage",
                similarity: 0.9),
            ItemSearchHit(
                itemID: second.itemID, revisionID: second.revisionID, passage: "duplicate", similarity: 0.8),
            old,
            ItemSearchHit(itemID: "denied", revisionID: "missing", passage: "private", similarity: 0.7),
        ]
        let response = ItemSearchResponse(
            queryID: "q", state: "ready", expiresAt: Timestamp.now(), retryAfterMilliseconds: nil,
            partialCoverage: true, results: hits)
        let page = ItemSearchPage(response: response, current: [first, second])
        XCTAssertEqual(page.items.map(\.itemID), [second.itemID])
        XCTAssertEqual(page.hits[second.itemID]?.passage, "second passage")
        XCTAssertEqual(page.omitted, 2)
        XCTAssertTrue(page.partialCoverage)
    }

    func testPendingReadyRequestsUseGlobalScopeAndBoundedLimit() async throws {
        let transport = Transport(behavior: "pendingThenReady")
        let loader = ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport))
        loader.start(text: "meaning", expression: "subject == *")
        if case .pending = try XCTUnwrap(loader.take()).outcome {} else { XCTFail("No pending state") }
        if case .ready = try await ready(loader).outcome {} else { XCTFail("No ready state") }
        let requests = await transport.requests
        var firstSearch: [String: Any]?
        for bytes in requests {
            let envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let calls = envelope["methodCalls"] as! [[Any]]
            if calls.first?.first as? String == "TractandaSemantic/search" {
                firstSearch = envelope
                break
            }
        }
        let first = try XCTUnwrap(firstSearch)
        let args = (first["methodCalls"] as! [[Any]])[0][1] as! [String: Any]
        XCTAssertEqual(args["limit"] as? Int, 64)
        XCTAssertEqual(args["text"] as? String, "meaning")
        XCTAssertNil(args["viewID"])
        XCTAssertNil(args["categoryPath"])
        XCTAssertNil(args["excludedCategoryIDs"])
        XCTAssertEqual(args["timeZone"] as? String, TimeZone.current.identifier)
    }

    func testSemanticGetContinuationPreservesRank() async throws {
        let fixture = try Fixture()
        let first = try fixture.item("First")
        let second = try fixture.item("Second")
        let hits = [first, second].enumerated().map { index, item in
            ItemSearchHit(
                itemID: item.itemID, revisionID: item.revisionID,
                passage: "passage", similarity: 0.9 - Double(index) / 10)
        }
        let transport = Transport(items: [first, second], hits: hits, behavior: "continuation")
        let loader = ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport))
        loader.start(text: "meaning", expression: "")
        if case .ready(let page) = try await ready(loader).outcome {
            XCTAssertEqual(page.items.map(\.itemID), [first.itemID, second.itemID])
            XCTAssertEqual(page.omitted, 0)
        } else {
            XCTFail("Expected ready continuation")
        }
        let requests = await transport.requests
        let domainRequests = try requests.filter { bytes in
            let envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return (envelope["methodCalls"] as! [[Any]])[0][0] as? String != TractandaJMAP.discoveryMethod
        }
        XCTAssertEqual(domainRequests.count, 4)
        XCTAssertEqual(requests.count - domainRequests.count, 1, "One current Session discovery is expected")
    }

    func testSemanticMixedReadableAndUnresolvedResultsRetainReadableHits() async throws {
        let first = try Revision(fields: [
            "itemID": .text("10000000-0000-1000-8000-010000000001"),
            "revisionID": .text("10000000-0000-1000-8001-010000000001"),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "subject": .text("Readable"), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        ])
        let second = try Revision(fields: [
            "itemID": .text("20000000-0000-1000-8000-010000000001"),
            "revisionID": .text("20000000-0000-1000-8001-010000000001"),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "subject": .text("Unresolved"), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        ])
        let hits = [first, second].map {
            ItemSearchHit(itemID: $0.itemID, revisionID: $0.revisionID, passage: "hit", similarity: 0.9)
        }
        let loader = ItemSearchLoader(
            client: TractandaClient.ItemClient(
                transport: Transport(items: [first, second], hits: hits, behavior: "unresolved")))
        loader.start(text: "meaning", expression: "")
        guard case .ready(let page) = try await ready(loader).outcome else {
            return XCTFail("Expected readable partial result")
        }
        XCTAssertEqual(page.items.map(\.itemID), [second.itemID])
        XCTAssertEqual(page.unresolved.map(\.itemID), [first.itemID])
        XCTAssertFalse(page.items.isEmpty)
    }

    func testSemanticUnhydratedAndOversizedResultsStayExplicit() async throws {
        let item = try Revision(fields: [
            "itemID": .text("30000000-0000-1000-8000-010000000001"),
            "revisionID": .text("30000000-0000-1000-8001-010000000001"),
            "classID": .text("Item"), "schemaVersion": .integer(1),
            "subject": .text("Partial"), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
        ])
        let hit = ItemSearchHit(
            itemID: item.itemID, revisionID: item.revisionID, passage: "hit", similarity: 0.9)
        for behavior in ["unhydrated", "oversized"] {
            let loader = ItemSearchLoader(
                client: TractandaClient.ItemClient(
                    transport: Transport(items: [item], hits: [hit], behavior: behavior)))
            loader.start(text: "meaning", expression: "")
            guard case .ready(let page) = try await ready(loader).outcome else {
                return XCTFail("Expected a partial semantic result")
            }
            XCTAssertTrue(page.items.isEmpty)
            XCTAssertEqual(page.unhydratedIDs, [item.itemID])
        }
    }

    func testReplacementAndCancelRejectLateReplies() async throws {
        let transport = Transport()
        let loader = ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport))
        let old = loader.start(text: "old", expression: "")
        try await Task.sleep(nanoseconds: 20_000_000)
        let new = loader.start(text: "new", expression: "")
        XCTAssertGreaterThan(new, old)
        let delivery = try await ready(loader)
        XCTAssertEqual(delivery.generation, new)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(loader.take())
        loader.start(text: "old", expression: "")
        loader.cancel()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(loader.take())
    }

    func testFailureExpiryUnavailableAndPartialCoverage() async throws {
        for behavior in ["failed", "expired", "unavailable", "partial"] {
            let loader = ItemSearchLoader(
                client: TractandaClient.ItemClient(transport: Transport(behavior: behavior)))
            loader.start(text: "meaning", expression: "")
            switch try await ready(loader).outcome {
            case .failed: XCTAssertEqual(behavior, "failed")
            case .expired: XCTAssertEqual(behavior, "expired")
            case .unavailable: XCTAssertEqual(behavior, "unavailable")
            case .ready(let page):
                XCTAssertEqual(behavior, "partial")
                XCTAssertTrue(page.partialCoverage)
            case .pending, .checking: XCTFail("Pending should finish")
            }
        }
    }

    private func waitScreen(_ app: TerminalApplication, contains text: String) async throws {
        for _ in 0..<100 {
            if screen(app).contains(text) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("No screen containing \(text): \(screen(app))")
    }

    func testClockAndCanceledPopupPreservePendingSemanticJob() async throws {
        let fixture = try Fixture()
        let transport = Transport(behavior: "pending")
        let loader = ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport))
        let app = try fixture.app(itemsOnly: true, loader: loader)
        semantic(app, query: "original")
        XCTAssertTrue(screen(app).contains("Semantic pending"))
        app.handle(.text("f"))
        app.handle(.paste(" draft"))
        app.handle(.tab)
        app.handle(.left)
        app.handle(.escape)
        XCTAssertTrue(screen(app).contains("Semantic pending"))
        XCTAssertTrue(screen(app).contains("Semantic: original"))
        XCTAssertFalse(app.refreshClock(at: Date().addingTimeInterval(31)))
        try await Task.sleep(nanoseconds: 150_000_000)
        let count = try await transport.searchCount()
        XCTAssertEqual(count, 1)
        app.handle(.escape)
    }

    func testAsyncValidationAllowsRapidNavigationAndWithholdsOldPreview() async throws {
        let fixture = try Fixture()
        let items = try ["First", "Second", "Third"].map {
            try fixture.item($0, extra: ["body": .text("private preview " + $0)])
        }
        let hits = items.enumerated().map { index, item in
            ItemSearchHit(
                itemID: item.itemID, revisionID: item.revisionID,
                passage: "passage " + item.fields["subject"]!.string!, similarity: 0.9 - Double(index) / 10)
        }
        let transport = Transport(items: items, hits: hits, behavior: "gatedValidation")
        let app = try fixture.app(
            itemsOnly: true,
            loader: ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport)))
        semantic(app, query: "meaning")
        try await waitScreen(app, contains: "Semantic ready")
        XCTAssertTrue(screen(app).contains("0.900 First · passage First"))
        let started = Date()
        app.handle(.down)
        app.handle(.down)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        let checking = screen(app)
        XCTAssertTrue(checking.contains("refreshing snapshot"))
        XCTAssertTrue(
            checking.components(separatedBy: "\n").contains { $0.hasPrefix("> ") && $0.contains("Third") })
        XCTAssertFalse(checking.contains("private preview Third"))
        XCTAssertFalse(checking.contains("passage Third"))
        _ = app.render(columns: 90, rows: 25)
        await transport.release()
        try await waitScreen(app, contains: "Semantic ready")
        XCTAssertTrue(
            screen(app).components(separatedBy: "\n").contains { $0.hasPrefix("> ") && $0.contains("Third") })
        XCTAssertTrue(screen(app).contains("private preview Third"))
        let count = try await transport.searchCount()
        XCTAssertEqual(count, 1)
        app.handle(.escape)
    }

    func testClockValidationRemovesDeniedAndRevisionMismatchedTitlesAndPassages() async throws {
        let fixture = try Fixture()
        let first = try fixture.item("Readable")
        let denied = try fixture.item("Denied title")
        let stale = try fixture.item("Stale title")
        let items = [first, denied, stale]
        let hits = items.map {
            ItemSearchHit(
                itemID: $0.itemID, revisionID: $0.revisionID,
                passage: "passage " + $0.fields["subject"]!.string!, similarity: 0.9)
        }
        let transport = Transport(items: items, hits: hits, behavior: "gatedValidation")
        let app = try fixture.app(
            itemsOnly: true,
            loader: ItemSearchLoader(client: TractandaClient.ItemClient(transport: transport)))
        semantic(app, query: "meaning")
        try await waitScreen(app, contains: "Semantic ready")
        XCTAssertTrue(app.refreshClock(at: Date().addingTimeInterval(31)))
        let changed = try fixture.client.commitFixture(
            CommitRequest(
                action: .revise, itemID: stale.itemID,
                expectedRevisionID: stale.revisionID, changes: ["subject": .text("Changed")],
                operationID: Identifier.make())
        ).revision
        await transport.release(items: [first, changed])
        try await waitScreen(app, contains: "Semantic ready")
        let rendered = screen(app)
        XCTAssertFalse(rendered.contains("Denied title"))
        XCTAssertFalse(rendered.contains("Stale title"))
        XCTAssertFalse(rendered.contains("Changed"))
        XCTAssertTrue(rendered.contains("2 stale/unavailable passages omitted"))
        let count = try await transport.searchCount()
        XCTAssertEqual(count, 1)
        app.handle(.escape)
    }

    func testPendingEscapeAndUnavailableRetainQueryWithoutSilentTextFallback() async throws {
        let fixture = try Fixture()
        _ = try fixture.item("needle")
        let loader = ItemSearchLoader(
            client: TractandaClient.ItemClient(transport: Transport(behavior: "pending")))
        let app = try fixture.app(itemsOnly: true, loader: loader)
        semantic(app, query: "needle")
        XCTAssertTrue(screen(app).contains("Semantic pending"))
        app.handle(.escape)
        XCTAssertFalse(screen(app).contains("Search results"))
        XCTAssertTrue(screen(app).contains("needle"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(screen(app).contains("Semantic pending"))
        semantic(app, query: "another")
        app.handle(.text("f"))
        XCTAssertTrue(screen(app).contains("another"))
        XCTAssertTrue(screen(app).contains("Semantic"))
        app.handle(.escape)
        app.handle(.escape)
        let unavailable = try fixture.app(itemsOnly: true)
        semantic(unavailable, query: "needle")
        XCTAssertTrue(screen(unavailable).contains("Semantic unavailable"))
        XCTAssertTrue(screen(unavailable).contains("No search results"))
        unavailable.handle(.text("f"))
        XCTAssertTrue(screen(unavailable).contains("needle"))
        unavailable.handle(.tab)
        unavailable.handle(.left)
        unavailable.handle(.enter)
        XCTAssertTrue(screen(unavailable).contains("Text search ready"))
        XCTAssertTrue(screen(unavailable).contains("needle"))
    }
}
