import CSQLite
import Foundation
import XCTest

@testable import TractandaCore

final class SQLiteReadPoolTests: XCTestCase {
    private var fixtureDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in fixtureDirectories { try? FileManager.default.removeItem(at: directory) }
        fixtureDirectories.removeAll()
        try super.tearDownWithError()
    }

    private func fixture() throws -> (URL, SQLiteReadPool) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixtureDirectories.append(folder)
        let database = folder.appendingPathComponent("items.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle, "CREATE TABLE durable (value INTEGER); INSERT INTO durable VALUES (7)", nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        return (database, try SQLiteReadPool(databaseURL: database, maximumConnections: 2, maximumWaiters: 2))
    }

    private var emptyContext: ReadPrincipalContext {
        ReadPrincipalContext(actorUID: 42, users: [:], groups: [:])
    }

    func testDistinctReadOnlyConnectionsOverlapBehindGate() throws {
        let (_, pool) = try fixture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let ids = NSLockBox<[Int]>([])
        let context = emptyContext
        for _ in 0..<2 {
            DispatchQueue.global().async {
                defer { done.signal() }
                guard let lease = try? pool.lease(principal: context) else { return }
                ids.withLock { $0.append(lease.connectionID) }
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                lease.finish()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(pool.activeLeaseCount, 2)
        XCTAssertEqual(Set(ids.value).count, 2)
        release.signal()
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        try pool.shutdown()
    }

    func testReadOnlyMainAndWritableTempAuthorizationTables() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(
            principal: ReadPrincipalContext(
                actorUID: 42, users: ["alice": 42], groups: ["staff": (gid: 9, member: true)]))
        XCTAssertEqual(try lease.scalarInt64("SELECT uid FROM request_users WHERE name='alice'"), 42)
        XCTAssertEqual(try lease.scalarInt64("SELECT gid FROM request_groups WHERE name='staff'"), 9)
        XCTAssertEqual(try lease.scalarInt64("SELECT uid FROM request_actor"), 42)
        XCTAssertThrowsError(try lease.executeRead("INSERT INTO durable VALUES (8)"))
        XCTAssertEqual(try lease.executeRead("CREATE TEMP TABLE scratch (value INTEGER)"), 0)
        XCTAssertEqual(try lease.executeRead("INSERT INTO scratch VALUES (3)"), 1)
        lease.finish()
        try pool.shutdown()
    }

    func testBoundQueryCopiesTypedValuesAndEnforcesRowAndByteCaps() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        let rows = try lease.query(
            "SELECT ?, ?, ?, ?, ?",
            bindings: [.text("alice"), .integer(9), .real(1.5), .blob(Data([0, 1, 255])), .null])
        XCTAssertEqual(rows, [[.text("alice"), .integer(9), .real(1.5), .blob(Data([0, 1, 255])), .null]])
        XCTAssertThrowsError(
            try lease.query(
                "SELECT value FROM durable UNION ALL SELECT value FROM durable",
                limits: SQLiteReadLimits(maximumRows: 1, maximumBytes: 100))
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .resultLimit)
        }
        XCTAssertThrowsError(
            try lease.query(
                "SELECT 'large payload'", limits: SQLiteReadLimits(maximumRows: 1, maximumBytes: 2))
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .resultLimit)
        }
        XCTAssertThrowsError(try lease.query("INSERT INTO durable VALUES (8)"))
        lease.finish()
        try pool.shutdown()
    }

    func testBoundQueryInterruptionAndFailedQueryLeaveConnectionReusable() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        let cancellation = SQLiteReadCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { cancellation.cancel() }
        XCTAssertThrowsError(
            try lease.query(
                "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 100000000) SELECT sum(x) FROM n",
                cancellation: cancellation)
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .cancelled)
        }
        XCTAssertThrowsError(try lease.query("SELECT missing_column FROM durable"))
        XCTAssertEqual(try lease.query("SELECT value FROM durable"), [[.integer(7)]])
        lease.finish()
        try pool.shutdown()
    }

    func testStreamDeliversManyRowsWithoutCollectingThemAndUsesBindings() throws {
        let (database, pool) = try fixture()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE stream_rows (value INTEGER); "
                    + "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<240) "
                    + "INSERT INTO stream_rows SELECT x FROM n",
                nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)

        let lease = try pool.lease(principal: emptyContext)
        var callbacks = 0
        var firstRow: [SQLiteReadValue]?
        let streamed = try lease.stream(
            "SELECT value FROM stream_rows WHERE value > ? ORDER BY value", bindings: [.integer(0)]
        ) { row in
            callbacks += 1
            if firstRow == nil { firstRow = row }
        }
        XCTAssertEqual(streamed, 240)
        XCTAssertEqual(callbacks, streamed)
        XCTAssertEqual(firstRow, [.integer(1)])
        lease.finish()
        try pool.shutdown()
    }

    func testStreamEnforcesRowByteLimitAndRejectsInvalidUTF8ThenReusesLease() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        var callbacks = 0
        XCTAssertThrowsError(
            try lease.stream("SELECT 'payload'", maximumRowBytes: 20) { _ in callbacks += 1 }
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .resultLimit)
        }
        XCTAssertEqual(callbacks, 0)
        XCTAssertThrowsError(try lease.stream("SELECT CAST(x'80' AS TEXT)") { _ in callbacks += 1 }) {
            XCTAssertEqual($0 as? SQLiteReadPoolError, .invalidText)
        }
        XCTAssertEqual(try lease.scalarInt64("SELECT value FROM durable"), 7)
        lease.finish()
        try pool.shutdown()
    }

    func testStreamCallbackThrowAndCancellationFinalizeStatementsForReuse() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        XCTAssertThrowsError(
            try lease.stream(
                "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<50) SELECT x FROM n"
            ) { _ in throw SQLiteReadPoolError.busy }
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .busy)
        }

        let cancellation = SQLiteReadCancellation()
        var callbacks = 0
        XCTAssertThrowsError(
            try lease.stream(
                "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<50) SELECT x FROM n",
                cancellation: cancellation
            ) { _ in
                callbacks += 1
                cancellation.cancel()
            }
        ) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .cancelled)
        }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try lease.query("SELECT value FROM durable"), [[.integer(7)]])
        lease.finish()
        try pool.shutdown()
    }

    func testSeparateLeasesStreamOnDistinctConnections() throws {
        let (_, pool) = try fixture()
        let first = try pool.lease(principal: emptyContext)
        let second = try pool.lease(principal: emptyContext)
        XCTAssertNotEqual(first.connectionID, second.connectionID)
        var firstRows = 0
        var secondRows = 0
        XCTAssertEqual(try first.stream("SELECT value FROM durable") { _ in firstRows += 1 }, 1)
        XCTAssertEqual(try second.stream("SELECT value FROM durable") { _ in secondRows += 1 }, 1)
        XCTAssertEqual(firstRows, 1)
        XCTAssertEqual(secondRows, 1)
        first.finish()
        second.finish()
        try pool.shutdown()
    }

    func testPrincipalNamesAreBoundedAndNULIsRejected() throws {
        let (_, pool) = try fixture()
        XCTAssertThrowsError(
            try pool.lease(principal: ReadPrincipalContext(actorUID: 1, users: ["bad\0name": 1], groups: [:]))
        )
        XCTAssertThrowsError(
            try pool.lease(
                principal: ReadPrincipalContext(
                    actorUID: 1, users: [String(repeating: "x", count: 1025): 1], groups: [:])))
        XCTAssertThrowsError(
            try pool.lease(
                principal: ReadPrincipalContext(
                    actorUID: 1, users: [:],
                    groups: Dictionary(
                        uniqueKeysWithValues: (0..<1025).map { ("g\($0)", (gid: UInt32($0), member: true)) }))
            ))
        try pool.shutdown()
    }

    func testPrincipalReplacementAndNestedTransactionFailureCleanup() throws {
        let (_, pool) = try fixture()
        let first = try pool.lease(
            principal: ReadPrincipalContext(actorUID: 10, users: ["old": 10], groups: [:]))
        let id = first.connectionID
        XCTAssertThrowsError(
            try first.withReadTransaction {
                _ = try first.executeRead("INSERT INTO request_users VALUES ('nested', 11)")
                throw SQLiteReadPoolError.busy
            })
        first.finish()
        let second = try pool.lease(
            principal: ReadPrincipalContext(actorUID: 20, users: ["new": 20], groups: [:]))
        XCTAssertEqual(second.connectionID, id)
        XCTAssertEqual(try second.scalarInt64("SELECT count(*) FROM request_users"), 1)
        XCTAssertEqual(try second.scalarInt64("SELECT uid FROM request_users"), 20)
        XCTAssertEqual(try second.scalarInt64("SELECT count(*) FROM request_actor"), 1)
        second.finish()
        try pool.shutdown()
    }

    func testExclusiveAdmissionIsFairAndCancellationRemovesWaiter() throws {
        let (_, pool) = try fixture()
        let first = try pool.lease(principal: emptyContext)
        let second = try pool.lease(principal: emptyContext)
        let cancelled = SQLiteReadCancellation()
        let cancelledDone = DispatchSemaphore(value: 0)
        let context = emptyContext
        DispatchQueue.global().async {
            defer { cancelledDone.signal() }
            _ = try? pool.lease(principal: context, timeout: 2, cancellation: cancelled)
        }
        let queueDeadline = Date().addingTimeInterval(1)
        while pool.queuedCount == 0 && Date() < queueDeadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertEqual(pool.queuedCount, 1)
        cancelled.cancel()
        XCTAssertEqual(cancelledDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(pool.queuedCount, 0)

        let exclusiveDone = DispatchSemaphore(value: 0)
        let exclusiveSucceeded = NSLockBox(false)
        DispatchQueue.global().async {
            do {
                try pool.beginExclusiveAndDrain(timeout: 2)
                exclusiveSucceeded.withLock { $0 = true }
            } catch {}
            exclusiveDone.signal()
        }
        let exclusiveDeadline = Date().addingTimeInterval(1)
        while !pool.isExclusiveWaiting && Date() < exclusiveDeadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(pool.isExclusiveWaiting)
        let queued = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { queued.signal() }
            guard let lease = try? pool.lease(principal: context, timeout: 2) else { return }
            lease.finish()
        }
        first.finish()
        second.finish()
        XCTAssertEqual(exclusiveDone.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(exclusiveSucceeded.value)
        XCTAssertEqual(queued.wait(timeout: .now() + 0.05), .timedOut)
        pool.endExclusive()
        XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
        try pool.shutdown()
    }

    func testBusyCloseKeepsRetiredHandleAndBlocksSwapUntilRetry() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        let oldID = lease.connectionID
        guard let db = lease.connection.db else { return XCTFail("missing test database handle") }
        lease.finish()

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT value FROM durable", -1, &statement, nil), SQLITE_OK)
        XCTAssertThrowsError(try pool.beginExclusiveAndDrain(timeout: 0.2)) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .busy)
        }
        XCTAssertTrue(pool.isExclusiveWaiting)
        XCTAssertThrowsError(try pool.lease(principal: emptyContext, timeout: 0.05))
        XCTAssertThrowsError(try pool.shutdown(timeout: 0.2)) { error in
            XCTAssertEqual(error as? SQLiteReadPoolError, .busy)
        }
        sqlite3_finalize(statement)

        try pool.beginExclusiveAndDrain(timeout: 1)
        XCTAssertGreaterThan(pool.generation, lease.generation)
        try pool.resumeAfterRebuild()
        pool.endExclusive()
        let replacement = try pool.lease(principal: emptyContext)
        XCTAssertNotEqual(replacement.connectionID, oldID)
        replacement.finish()
        try pool.shutdown()
    }

    func testDrainKeepsAcceptedLeaseUsableThenInvalidatesItAndShutdownCloses() throws {
        let (_, pool) = try fixture()
        let lease = try pool.lease(principal: emptyContext)
        let oldGeneration = lease.generation
        let drainDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? pool.stopAdmissionAndDrain(timeout: 2)
            drainDone.signal()
        }
        let deadline = Date().addingTimeInterval(1)
        while pool.queuedCount == 0 && pool.activeLeaseCount != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try lease.scalarInt64("SELECT value FROM durable"), 7)
        lease.finish()
        XCTAssertEqual(drainDone.wait(timeout: .now() + 1), .success)
        XCTAssertGreaterThan(pool.generation, oldGeneration)
        XCTAssertThrowsError(try lease.scalarInt64("SELECT value FROM durable"))
        XCTAssertThrowsError(try pool.lease(principal: emptyContext))
        try pool.shutdown()
    }
}

private final class NSLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func withLock(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
