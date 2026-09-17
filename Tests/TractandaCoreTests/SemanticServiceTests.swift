import Foundation
import XCTest

@testable import TractandaCore

final class SemanticServiceTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 50001
        let bob: UInt32 = 50002
        private let users: [UInt32: AccountIdentity]

        init() {
            users = Dictionary(
                uniqueKeysWithValues: [
                    (getuid(), "admin"), (alice, "alice"), (bob, "bob"),
                ].map { uid, name in
                    (uid, AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [70001]))
                })
        }

        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let user = users[uid] else { throw TractandaError("unresolvedPrincipal", "Unknown user") }
            return user
        }

        func user(named name: String) throws -> AccountIdentity {
            guard let user = users.values.first(where: { $0.name == name }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return user
        }

        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else { throw TractandaError("unresolvedPrincipal", "Unknown group") }
            return 70001
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class QueryLifetimeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Date) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private func fixture(_ body: (ItemStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "semantic-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        try body(try ItemStore(root: root), root)
    }

    private func accessFixture(_ body: (ItemStore, Accounts) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "semantic-access-\(Identifier.make())")
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try ItemStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "access")
        try body(store, accounts)
    }

    private func permissions(owner: String, mode: Int64) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile),
            "owner": .text(owner),
            "group": .text("staff"),
            "mode": .integer(mode),
            "acl": .object([:]),
        ])
    }

    private func note(_ store: ItemStore, subject: String, body: String, operation: String) throws -> Revision
    {
        try store.commit(
            CommitRequest(
                classID: "Item",
                changes: ["subject": .text(subject), "body": .text(body)],
                operationID: operation)
        ).revision
    }

    private func configuration(operationID: String = "semantic-config") -> SemanticConfiguration {
        SemanticConfiguration(
            operationID: operationID,
            endpoint: "http://127.0.0.1:11434/v1/embeddings",
            model: "test-model",
            modelRevision: "test-revision",
            dimensions: 2,
            documentPrefix: "document: ",
            queryPrefix: "query: ")
    }

    private func drain(_ service: SemanticService) {
        for _ in 0..<50 {
            service.maintain()
            usleep(10_000)
        }
    }

    private final class FailingDiagnosticStorage: SemanticVectorStorage {
        func identity(itemID: String, profileID: String) throws -> SemanticIndexedIdentity? {
            throw TractandaError("semanticIndex", "/private/sensitive-index diagnostic secret")
        }
        func hasCurrent(itemID: String, profileID: String, contentHash: String) throws -> Bool { false }
        func rebind(_ snapshot: SemanticSnapshot) throws {}
        func replace(_ snapshot: SemanticSnapshot, chunks: [SemanticChunk], vectors: [[Double]]) throws {}
        func prune(profileID: String, keeping itemIDs: Set<String>) throws {}
        func search(vector: [Double], profileID: String, current: [SemanticSnapshot], limit: Int) throws
            -> [SemanticIndexedPassage]
        { [] }
        func reset() throws {}
    }

    func testTextDiagnosticsPendingAndFailuresStayLocalAndNonDisclosing() throws {
        try fixture { store, root in
            let calls = Counter()
            let service = SemanticService(store: store, storage: FailingDiagnosticStorage()) { _, _, _ in
                calls.increment()
                return []
            }
            let config = configuration(operationID: "diagnostic-failure")
            try service.configure(config, expectedConfigurationID: nil)
            // Establish the backend with an empty canonical store: no documents to embed.
            service.maintain()
            let item = try note(store, subject: "Visible", body: "Text", operation: "diagnostic-failure-item")
            let corpus = ItemTextContent.corpus(for: item)
            let pendingService = SemanticService(store: store, storage: SemanticMemoryStorage()) { _, _, _ in
                calls.increment()
                return []
            }
            XCTAssertEqual(
                pendingService.textDiagnostics(for: item, corpus: corpus)["status"] as? String, "pending")
            let result = service.textDiagnostics(for: item, corpus: corpus)
            XCTAssertEqual(result["status"] as? String, "unavailable")
            XCTAssertEqual(result["enabled"] as? Bool, true)
            XCTAssertEqual(result["configurationID"] as? String, config.configurationID)
            XCTAssertFalse(
                String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains(
                    "sensitive-index"))
            try Data("invalid configuration".utf8).write(to: root.appendingPathComponent("semantic.json"))
            let unknown = service.textDiagnostics(for: item, corpus: corpus)
            XCTAssertEqual(unknown["status"] as? String, "unavailable")
            XCTAssertTrue(unknown["enabled"] is NSNull)
            XCTAssertEqual(calls.read(), 0)
        }
    }

    func testTextDiagnosticsDisabledAndNotIndexableDoNotEmbed() throws {
        try fixture { store, _ in
            let calls = Counter()
            let service = SemanticService(store: store) { _, _, _ in
                calls.increment()
                return []
            }
            let empty = try note(store, subject: "", body: "", operation: "diagnostic-empty")
            let emptyCorpus = ItemTextContent.corpus(for: empty)
            XCTAssertEqual(
                service.textDiagnostics(for: empty, corpus: emptyCorpus)["status"] as? String, "disabled")
            XCTAssertEqual(calls.read(), 0)
            try service.configure(configuration(), expectedConfigurationID: nil)
            XCTAssertEqual(
                service.textDiagnostics(for: empty, corpus: emptyCorpus)["status"] as? String, "notIndexable")
            let deleted = try store.commit(
                CommitRequest(
                    action: .revise, itemID: empty.itemID, expectedRevisionID: empty.revisionID,
                    changes: ["isDeleted": .boolean(true)], operationID: "diagnostic-delete")
            ).revision
            XCTAssertEqual(
                service.textDiagnostics(for: deleted, corpus: ItemTextContent.corpus(for: deleted))["status"]
                    as? String, "notIndexable")
            XCTAssertEqual(calls.read(), 0)
        }
    }

    func testTextDiagnosticsIdentityLifecycleDoesNotEmbed() throws {
        try fixture { store, _ in
            let calls = Counter()
            let storage = SemanticMemoryStorage()
            let service = SemanticService(store: store, storage: storage) { _, _, _ in
                calls.increment()
                return [[1, 0]]
            }
            let configuration = configuration(operationID: "diagnostic-lifecycle")
            try service.configure(configuration, expectedConfigurationID: nil)
            service.maintain()
            let item = try note(store, subject: "Alpha", body: "Body", operation: "diagnostic-item")
            let corpus = ItemTextContent.corpus(for: item)
            XCTAssertEqual(service.textDiagnostics(for: item, corpus: corpus)["status"] as? String, "missing")
            let profile = try SemanticSource.profileID(configuration)
            let hash = try SemanticSource.contentHash(sourceText: corpus.sourceText)
            XCTAssertEqual(service.textDiagnostics(for: item, corpus: corpus)["status"] as? String, "missing")
            let chunk = try XCTUnwrap(
                SemanticChunker.chunks(
                    corpus.sourceText, chunkBytes: configuration.chunkBytes,
                    overlapBytes: configuration.overlapBytes
                ).first)
            let snapshot = SemanticSnapshot(
                itemID: item.itemID, revisionID: item.revisionID, subject: corpus.subject, body: corpus.body,
                sourceText: corpus.sourceText, profileID: profile, contentHash: hash)
            try storage.replace(snapshot, chunks: [chunk], vectors: [[1, 0]])
            XCTAssertEqual(service.textDiagnostics(for: item, corpus: corpus)["status"] as? String, "current")
            let revised = try store.commit(
                CommitRequest(
                    action: .revise, itemID: item.itemID, expectedRevisionID: item.revisionID,
                    changes: ["dueAt": .date("2030-01-01T00:00:00Z")], operationID: "diagnostic-revision")
            ).revision
            XCTAssertEqual(
                service.textDiagnostics(for: revised, corpus: ItemTextContent.corpus(for: revised))["status"]
                    as? String, "stale")
            try storage.rebind(
                SemanticSnapshot(
                    itemID: revised.itemID, revisionID: revised.revisionID, subject: corpus.subject,
                    body: corpus.body, sourceText: corpus.sourceText, profileID: profile, contentHash: hash))
            XCTAssertEqual(
                service.textDiagnostics(for: revised, corpus: ItemTextContent.corpus(for: revised))["status"]
                    as? String, "current")
            XCTAssertEqual(calls.read(), 0)
        }
    }

    private func assertQueryTiming(
        _ response: [String: Any], createdAt: Date, expiresAt: Date, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(response["createdAt"] as? String, Timestamp.format(createdAt), file: file, line: line)
        XCTAssertEqual(response["expiresAt"] as? String, Timestamp.format(expiresAt), file: file, line: line)
    }

    func testBackgroundEmbeddingDoesNotBlockCommitAndMetadataRevisionReusesVectors() throws {
        try fixture { store, _ in
            let counter = Counter()
            let service = SemanticService(store: store) { _, inputs, query in
                counter.increment()
                if !query { try await Task.sleep(for: .milliseconds(100)) }
                return inputs.map { _ in query ? [0.9, 0.1] : [1, 0] }
            }
            let original = try note(store, subject: "Alpha", body: "Body", operation: "note")
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            service.maintain()
            let started = Date()
            let changed = try store.commit(
                CommitRequest(
                    action: .revise,
                    itemID: original.itemID,
                    expectedRevisionID: original.revisionID,
                    changes: ["priority": .integer(1)],
                    operationID: "metadata-only")
            ).revision
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
            drain(service)
            let callsAfterIndex = counter.read()
            service.maintain()
            drain(service)
            XCTAssertEqual(counter.read(), callsAfterIndex)
            let status = try store.withAccess(forUID: store.ownerUID) { try service.status() }
            XCTAssertEqual(status["indexedItems"] as? Int, 1)
            XCTAssertEqual(try store.get(changed.itemID).revisionID, changed.revisionID)
        }
    }

    func testExternalIndexDirectoryHoldsVec1Files() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "semantic-root-\(Identifier.make())")
        let index = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("semantic-index-\(Identifier.make())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: index)
        }
        let store = try ItemStore(root: root, indexDirectory: index)
        let service = SemanticService(store: store) { _, inputs, query in
            inputs.map { _ in query ? [0.8, 0.2] : [1, 0] }
        }
        _ = try note(store, subject: "external vectors", body: "derived only", operation: "note")
        try store.withAccess(forUID: store.ownerUID) {
            _ = try service.configure(configuration(), expectedConfigurationID: nil)
        }
        drain(service)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: index.appendingPathComponent("semantic.sqlite").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("index/semantic.sqlite").path))
    }

    func testSearchFreezesPastEvaluationClockAndTimeZoneWithoutExpiringTheQuery() throws {
        try fixture { store, _ in
            let service = SemanticService(store: store) { _, inputs, query in
                inputs.map { _ in query ? [0.8, 0.2] : [1, 0] }
            }
            let expression = "dueAt >= $time.today && dueAt < $time.today(1)"
            let view = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "viewDefinition": .object([
                            "language": .text(SpotlightQuery.profile), "expression": .text(expression),
                            "sort": .list([]),
                        ])
                    ], operationID: "day-view")
            ).revision
            let utc = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("UTC day"), "body": .text("calendar evidence"),
                        "dueAt": .date("2026-01-01T12:00:00Z"),
                    ], operationID: "utc-day")
            ).revision
            let newYork = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "subject": .text("New York day"), "body": .text("calendar evidence"),
                        "dueAt": .date("2025-12-31T12:00:00Z"),
                    ], operationID: "new-york-day")
            ).revision
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            drain(service)
            let evaluatedAt = Timestamp.parse("2000-01-01T00:30:00Z")!
            let boundary = Timestamp.parse("2026-01-01T00:30:00Z")!
            func search(expression: String? = nil, viewID: String? = nil, timeZone: String) throws
                -> [String]
            {
                let queryID = try store.withAccess(forUID: store.ownerUID) {
                    try service.search(
                        text: "calendar", expression: expression, categoryPath: [],
                        excludedCategoryIDs: [], viewID: viewID, limit: 10, evaluatedAt: boundary,
                        timeZone: timeZone)["queryID"] as! String
                }
                drain(service)
                let result = try store.withAccess(forUID: store.ownerUID) {
                    try service.results(queryID: queryID)
                }
                XCTAssertEqual(result["timeZone"] as? String, timeZone)
                XCTAssertEqual(result["evaluatedAt"] as? String, Timestamp.format(boundary))
                return (result["results"] as? [[String: Any]])?.compactMap { $0["itemID"] as? String } ?? []
            }
            XCTAssertEqual(try search(expression: expression, timeZone: "UTC"), [utc.itemID])
            XCTAssertEqual(
                try search(expression: expression, timeZone: "America/New_York"), [newYork.itemID])
            XCTAssertEqual(try search(viewID: view.itemID, timeZone: "UTC"), [utc.itemID])
            XCTAssertEqual(try search(viewID: view.itemID, timeZone: "America/New_York"), [newYork.itemID])
            let pastQueryID = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: "calendar", expression: nil, categoryPath: [], excludedCategoryIDs: [], viewID: nil,
                    limit: 10, evaluatedAt: evaluatedAt, timeZone: "America/New_York")["queryID"] as! String
            }
            XCTAssertNoThrow(
                try store.withAccess(forUID: store.ownerUID) { try service.results(queryID: pastQueryID) })
        }
    }

    func testQueryDiagnosticsAreStableForPendingPartialAndFailedResults() throws {
        try fixture { store, _ in
            let createdAt = Timestamp.parse("2026-09-16T10:00:00Z")!
            let clock = QueryLifetimeClock(createdAt)
            let service = SemanticService(store: store, queryLifetimeClock: { clock.now() }) {
                _, inputs, query in
                if !query { throw TractandaError("semanticProvider", "injected") }
                return inputs.map { _ in [1, 0] }
            }
            _ = try note(store, subject: "partial", body: "coverage", operation: "partial-coverage")
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            let search = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: "diagnostics", expression: nil, categoryPath: [], excludedCategoryIDs: [],
                    viewID: nil, limit: 10, evaluatedAt: Timestamp.parse("2000-01-01T00:00:00Z")!)
            }
            let queryID = search["queryID"] as! String
            let expiresAt = createdAt.addingTimeInterval(120)
            assertQueryTiming(search, createdAt: createdAt, expiresAt: expiresAt)
            XCTAssertEqual(search["state"] as? String, "pending")
            XCTAssertEqual(search["retryAfterMilliseconds"] as? Int, 500)

            let pending = try store.withAccess(forUID: store.ownerUID) {
                try service.results(queryID: queryID)
            }
            assertQueryTiming(pending, createdAt: createdAt, expiresAt: expiresAt)
            XCTAssertEqual(pending["state"] as? String, "pending")
            XCTAssertEqual(pending["retryAfterMilliseconds"] as? Int, 500)

            drain(service)
            let partial = try store.withAccess(forUID: store.ownerUID) {
                try service.results(queryID: queryID)
            }
            assertQueryTiming(partial, createdAt: createdAt, expiresAt: expiresAt)
            XCTAssertEqual(partial["state"] as? String, "ready")
            XCTAssertEqual(partial["partialCoverage"] as? Bool, true)
            XCTAssertNil(partial["retryAfterMilliseconds"])

            let failedService = SemanticService(store: store, queryLifetimeClock: { clock.now() }) {
                _, _, query in
                if query { throw TractandaError("semanticProvider", "injected") }
                return []
            }
            let previous = try store.withAccess(forUID: store.ownerUID) { try service.status() }
            var failedConfiguration = configuration(operationID: "failed-query")
            failedConfiguration.model = "failed-model"
            try store.withAccess(forUID: store.ownerUID) {
                _ = try failedService.configure(
                    failedConfiguration, expectedConfigurationID: previous["configurationID"] as? String)
            }
            let failedSearch = try store.withAccess(forUID: store.ownerUID) {
                try failedService.search(
                    text: "diagnostics", expression: nil, categoryPath: [], excludedCategoryIDs: [],
                    viewID: nil, limit: 10)
            }
            let failedID = failedSearch["queryID"] as! String
            drain(failedService)
            let failed = try store.withAccess(forUID: store.ownerUID) {
                try failedService.results(queryID: failedID)
            }
            assertQueryTiming(failed, createdAt: createdAt, expiresAt: expiresAt)
            XCTAssertEqual(failed["state"] as? String, "failed")
            XCTAssertNil(failed["retryAfterMilliseconds"])
        }
    }

    func testQueryLifetimeUsesCreationClockAndPollingDoesNotExtendIt() throws {
        try fixture { store, _ in
            let createdAt = Timestamp.parse("2026-09-16T10:00:00Z")!
            let clock = QueryLifetimeClock(createdAt)
            let service = SemanticService(store: store, queryLifetimeClock: { clock.now() })
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            let response = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: "lifetime", expression: nil, categoryPath: [], excludedCategoryIDs: [], viewID: nil,
                    limit: 10, evaluatedAt: Timestamp.parse("2000-01-01T00:00:00Z")!)
            }
            let queryID = response["queryID"] as! String
            let expiresAt = createdAt.addingTimeInterval(120)
            assertQueryTiming(response, createdAt: createdAt, expiresAt: expiresAt)

            clock.set(createdAt.addingTimeInterval(119))
            let polled = try store.withAccess(forUID: store.ownerUID) {
                try service.results(queryID: queryID)
            }
            assertQueryTiming(polled, createdAt: createdAt, expiresAt: expiresAt)

            clock.set(expiresAt)
            var expiredError: TractandaError?
            XCTAssertThrowsError(
                try store.withAccess(forUID: store.ownerUID) {
                    try service.results(queryID: queryID)
                }
            ) { error in
                let error = error as? TractandaError
                expiredError = error
                XCTAssertEqual(error?.code, "notFound")
                XCTAssertEqual(
                    error?.message,
                    "This semantic query may have expired or been invalidated; start a new search.")
            }
            XCTAssertThrowsError(
                try store.withAccess(forUID: store.ownerUID) {
                    try service.results(queryID: Identifier.make())
                }
            ) { error in
                XCTAssertEqual((error as? TractandaError)?.code, expiredError?.code)
                XCTAssertEqual((error as? TractandaError)?.message, expiredError?.message)
            }
        }
    }

    func testCurrentPassageUsesOneSourceRepresentation() throws {
        try fixture { store, _ in
            let service = SemanticService(store: store) { _, inputs, query in
                inputs.map { _ in query ? [1, 0] : [1, 0] }
            }
            _ = try note(store, subject: "Café", body: "", operation: "empty-body")
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            drain(service)
            let queryID = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: "cafe", expression: nil, categoryPath: [], excludedCategoryIDs: [], viewID: nil,
                    limit: 10)["queryID"] as! String
            }
            drain(service)
            let result = try store.withAccess(forUID: store.ownerUID) {
                try service.results(queryID: queryID)
            }
            let rows = result["results"] as! [[String: Any]]
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["passage"] as? String, "subject:\nCafé")
            XCTAssertEqual(rows[0]["byteEnd"] as? Int, Array("subject:\nCafé".utf8).count)
            XCTAssertEqual(result["partialCoverage"] as? Bool, false)
        }
    }

    func testConfigurationRejectsAmbiguousEndpointAndOversizedDimensions() throws {
        var badEndpoint = configuration()
        badEndpoint.endpoint = "http://127.0.0.1:11434"
        XCTAssertThrowsError(try badEndpoint.validate())
        var badDimensions = configuration()
        badDimensions.dimensions = 4097
        XCTAssertThrowsError(try badDimensions.validate())

        var differentPooling = configuration()
        differentPooling.pooling = .mean
        XCTAssertNotEqual(
            try SemanticSource.profileID(configuration()),
            try SemanticSource.profileID(differentPooling))
    }

    func testExtractionUpgradeInvalidatesThePreviousProfile() throws {
        // Golden hash from the previous expanded-text profile, before extraction-rule versioning.
        XCTAssertNotEqual(
            try SemanticSource.profileID(configuration()),
            "52cd37c79b4604214217d229c5ceb0585fc5480b4a6eb407b500c7ff6a7ec725")
    }

    func testBlankExpandedItemIsNotQueuedForEmbedding() throws {
        try fixture { store, _ in
            let counter = Counter()
            let service = SemanticService(store: store) { _, inputs, _ in
                counter.increment()
                return inputs.map { _ in [1, 0] }
            }
            _ = try note(store, subject: " \n", body: "\t", operation: "blank-expanded")
            var expanded = configuration()
            expanded.inputEncoding = .itemTextUTF8V2
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(expanded, expectedConfigurationID: nil)
            }
            drain(service)
            XCTAssertEqual(counter.read(), 0)
            let status = try store.withAccess(forUID: store.ownerUID) { try service.status() }
            XCTAssertEqual(status["indexableItems"] as? Int, 0)
        }
    }

    func testOwnedTextDrivesHashPassagesAndMetadataRebinding() throws {
        try fixture { store, _ in
            let counter = Counter()
            let service = SemanticService(store: store) { _, inputs, query in
                counter.increment()
                return inputs.map { _ in query ? [1, 0] : [1, 0] }
            }
            let original = try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: [
                        "workingNotes": .text("metadata passage é needle"),
                        "developmentUUIDMigration": .object(["note": .text("original issuer unknown")]),
                        "templateKey": .text("internal-template-marker"),
                        "assignee": .text(" \n\t"),
                    ], operationID: "v2-note")
            )
            .revision
            let expanded = configuration()
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(expanded, expectedConfigurationID: nil)
            }
            drain(service)
            let beforeRebind = counter.read()
            let current = try store.get(original.itemID)
            let permissions: ItemValue = .object([
                "profile": .text(ItemPermissions.profile), "owner": .text("owner"),
                "group": .text("group"), "mode": .integer(0o600), "acl": .object([:]),
            ])
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: current.itemID, expectedRevisionID: current.revisionID,
                    changes: ["permissions": permissions], operationID: "v2-permissions"))
            drain(service)
            XCTAssertEqual(counter.read(), beforeRebind, "excluded permission edits must only rebind")
            let changed = try store.get(original.itemID)
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: changed.itemID, expectedRevisionID: changed.revisionID,
                    changes: ["workingNotes": .text("metadata passage é changed")], operationID: "v2-content")
            )
            drain(service)
            XCTAssertGreaterThan(counter.read(), beforeRebind, "v2-owned text edits must re-embed")
            let queryID = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: "needle", expression: nil, categoryPath: [], excludedCategoryIDs: [], viewID: nil,
                    limit: 10)["queryID"] as! String
            }
            drain(service)
            let rows = try store.withAccess(forUID: store.ownerUID) {
                try service.results(queryID: queryID)["results"] as! [[String: Any]]
            }
            let passages = rows.compactMap { $0["passage"] as? String }.joined(separator: "\n")
            XCTAssertFalse(passages.contains("original issuer unknown"))
            XCTAssertFalse(passages.contains("internal-template-marker"))
            XCTAssertFalse(passages.contains("field[\"assignee\"]"))
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue((rows[0]["passage"] as? String ?? "").contains("metadata passage é changed"))
            XCTAssertEqual(
                rows[0]["byteEnd"] as? Int,
                (rows[0]["passage"] as! String).utf8.count)
        }
    }

    func testChunkerPreservesUTF8AtZeroOverlap() throws {
        let source = "subject:\né\n\nbody:\n日本語"
        let chunks = try SemanticChunker.chunks(source, chunkBytes: 32, overlapBytes: 0)
        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertEqual(chunks.first?.byteRange, 0..<Array(source.utf8).count)
    }

    func testScopedSearchAndStatusNeverExposePrivateCandidatesAndRevocationRechecksResults() throws {
        try accessFixture { store, accounts in
            let service = SemanticService(store: store) { _, inputs, query in
                inputs.map { text in
                    if query { return [1, 0] }
                    return text.contains("private") ? [1, 0] : [0, 1]
                }
            }
            let visible = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "subject": .text("public"), "body": .text("visible"),
                            "permissions": permissions(owner: "alice", mode: 0o640),
                        ], operationID: "visible")
                ).revision
            }
            _ = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    CommitRequest(
                        classID: "Item",
                        changes: [
                            "subject": .text("private"), "body": .text("hidden"),
                            "permissions": permissions(owner: "alice", mode: 0o600),
                        ], operationID: "private")
                ).revision
            }
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(configuration(), expectedConfigurationID: nil)
            }
            drain(service)
            let bobStatus = try store.withAccess(forUID: accounts.bob) { try service.status() }
            XCTAssertEqual(bobStatus["indexableItems"] as? Int, 1)
            XCTAssertEqual(bobStatus["indexedItems"] as? Int, 1)
            let queryID = try store.withAccess(forUID: accounts.bob) {
                try service.search(
                    text: "private", expression: nil, categoryPath: [], excludedCategoryIDs: [], viewID: nil,
                    limit: 10)["queryID"] as! String
            }
            drain(service)
            XCTAssertThrowsError(
                try store.withAccess(forUID: accounts.alice) { try service.results(queryID: queryID) })
            let initial = try store.withAccess(forUID: accounts.bob) { try service.results(queryID: queryID) }
            XCTAssertEqual(
                (initial["results"] as? [[String: Any]])?.map { $0["itemID"] as? String }, [visible.itemID])
            _ = try store.withAccess(forUID: accounts.alice) {
                try store.commit(
                    CommitRequest(
                        action: .revise,
                        itemID: visible.itemID,
                        expectedRevisionID: visible.revisionID,
                        changes: ["permissions": permissions(owner: "alice", mode: 0o600)],
                        operationID: "revoke"))
            }
            let revoked = try store.withAccess(forUID: accounts.bob) { try service.results(queryID: queryID) }
            XCTAssertTrue((revoked["results"] as? [[String: Any]] ?? []).isEmpty)
            let afterStatus = try store.withAccess(forUID: accounts.bob) { try service.status() }
            XCTAssertEqual(afterStatus["indexableItems"] as? Int, 0)
        }
    }

    func testConfigurationChangeCancelsOldGatedWorkAndFailuresBackOff() throws {
        try fixture { store, _ in
            let calls = Counter()
            let cancelled = Counter()
            let service = SemanticService(store: store) { configuration, inputs, _ in
                calls.increment()
                if configuration.model == "test-model" {
                    do { try await Task.sleep(for: .seconds(1)) } catch {
                        cancelled.increment()
                        throw error
                    }
                }
                if configuration.model == "failing" { throw TractandaError("semanticProvider", "injected") }
                return inputs.map { _ in [1, 0] }
            }
            _ = try note(store, subject: "Gated", body: "work", operation: "gated")
            let old = configuration()
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(old, expectedConfigurationID: nil)
            }
            service.maintain()
            for _ in 0..<50 where calls.read() == 0 { usleep(10_000) }
            XCTAssertEqual(calls.read(), 1, "the old provider work must be active before cancellation")
            var replacement = configuration(operationID: "replacement")
            replacement.model = "replacement"
            try store.withAccess(forUID: store.ownerUID) {
                _ = try service.configure(replacement, expectedConfigurationID: old.configurationID)
            }
            usleep(50_000)
            XCTAssertEqual(cancelled.read(), 1)
            drain(service)
            let status = try store.withAccess(forUID: store.ownerUID) { try service.status() }
            XCTAssertEqual(status["model"] as? String, "replacement")

            let failedService = SemanticService(store: store) { _, _, _ in
                calls.increment()
                throw TractandaError("semanticProvider", "injected")
            }
            var failureConfiguration = configuration(operationID: "failure")
            failureConfiguration.model = "failing"
            try store.withAccess(forUID: store.ownerUID) {
                _ = try failedService.configure(
                    failureConfiguration, expectedConfigurationID: replacement.configurationID)
            }
            failedService.maintain()
            usleep(20_000)
            failedService.maintain()
            let afterFailure = calls.read()
            for _ in 0..<5 { failedService.maintain() }
            XCTAssertEqual(calls.read(), afterFailure, "failed documents must observe retry backoff")
        }
    }

    func testMaintenanceReceiptsRetainOlderReplayAndOnlyRecordSuccessfulActions() throws {
        try fixture { _, root in
            let receipts = SemanticConfigurationStore(storeRoot: root)
            var performed: [String] = []
            XCTAssertTrue(
                try receipts.performMaintenance(
                    configurationID: "profile-a", operationID: "A", action: "reset"
                ) { performed.append("A") })
            XCTAssertTrue(
                try receipts.performMaintenance(
                    configurationID: "profile-b", operationID: "B", action: "rebuild"
                ) { performed.append("B") })
            XCTAssertFalse(
                try receipts.performMaintenance(
                    configurationID: "profile-a", operationID: "A", action: "reset"
                ) { performed.append("duplicate-A") })
            XCTAssertEqual(performed, ["A", "B"])
            XCTAssertThrowsError(
                try receipts.performMaintenance(
                    configurationID: "profile-c", operationID: "C", action: "reset"
                ) { throw TractandaError("injected", "discard failed") })
            XCTAssertTrue(
                try receipts.performMaintenance(
                    configurationID: "profile-c", operationID: "C", action: "reset"
                ) { performed.append("C") })
            XCTAssertEqual(performed, ["A", "B", "C"])
        }
    }
}
