import CSQLite
import Foundation

/// A request-scoped, already-resolved snapshot of authorization principals.
/// The pool deliberately performs no account or NSS lookups.
struct ReadPrincipalContext: Sendable, Equatable {
    let actorUID: UInt32
    let users: [String: UInt32]
    let groups: [String: (gid: UInt32, member: Bool)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.actorUID == rhs.actorUID && lhs.users == rhs.users && lhs.groups.count == rhs.groups.count
            && lhs.groups.allSatisfy { key, value in
                guard let other = rhs.groups[key] else { return false }
                return value.gid == other.gid && value.member == other.member
            }
    }
}

enum SQLiteReadPoolError: Error, Equatable {
    case stopped
    case busy
    case cancelled
    case timeout
    case staleLease
    case invalidPrincipal
    case resultLimit
    case invalidText
    case sqlite(String)
}

/// Values accepted by the bounded read API. SQL values are always passed through SQLite
/// bindings; callers cannot interpolate request data into statement text.
enum SQLiteReadValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

struct SQLiteReadLimits: Sendable, Equatable {
    let maximumRows: Int
    let maximumBytes: Int

    init(maximumRows: Int = 10_000, maximumBytes: Int = 8 * 1024 * 1024) {
        self.maximumRows = maximumRows
        self.maximumBytes = maximumBytes
    }
}

private final class SQLiteProgressContext {
    let cancellation: SQLiteReadCancellation
    init(_ cancellation: SQLiteReadCancellation) { self.cancellation = cancellation }
}

private let sqliteReadProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { pointer in
    guard let pointer else { return 0 }
    return Unmanaged<SQLiteProgressContext>.fromOpaque(pointer).takeUnretainedValue().cancellation.isCancelled
        ? 1 : 0
}

/// Cancellation is explicit so callers can remove a queued admission without racing a
/// continuation. It can also abandon a waiter from another task/thread.
final class SQLiteReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    init() {}
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Bounded read-only SQLite connections with writable connection-local TEMP authorization state.
/// Rebuild/shutdown owners must close admission and drain before swapping or closing the writer.
final class SQLiteReadPool: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        let connection: Connection
        fileprivate let leaseGeneration: UInt64
        fileprivate let pool: SQLiteReadPool
        private let finishLock = NSLock()
        private var finished = false
        fileprivate init(connection: Connection, generation: UInt64, pool: SQLiteReadPool) {
            self.connection = connection
            self.leaseGeneration = generation
            self.pool = pool
        }
        var connectionID: Int { connection.id }
        var generation: UInt64 { leaseGeneration }
        func executeRead(_ sql: String) throws -> Int64 { try pool.execute(sql, on: self) }
        func scalarInt64(_ sql: String) throws -> Int64 { try pool.scalar(sql, on: self) }
        func query(
            _ sql: String, bindings: [SQLiteReadValue] = [], limits: SQLiteReadLimits = SQLiteReadLimits(),
            cancellation: SQLiteReadCancellation = SQLiteReadCancellation()
        ) throws -> [[SQLiteReadValue]] {
            try pool.query(sql, bindings: bindings, limits: limits, cancellation: cancellation, on: self)
        }
        /// Copies and delivers one row at a time. The pool retains no result rows after each callback.
        @discardableResult
        func stream(
            _ sql: String, bindings: [SQLiteReadValue] = [], maximumRows: Int = 10_000,
            maximumRowBytes: Int = 9 * 1024 * 1024,
            cancellation: SQLiteReadCancellation = SQLiteReadCancellation(),
            onRow: ([SQLiteReadValue]) throws -> Void
        ) throws -> Int {
            try pool.stream(
                sql, bindings: bindings, maximumRows: maximumRows,
                maximumRowBytes: maximumRowBytes, cancellation: cancellation, on: self, onRow: onRow)
        }
        func withReadTransaction<T>(_ body: () throws -> T) throws -> T {
            try pool.transaction(on: self, body)
        }
        func finish() {
            finishLock.lock()
            defer { finishLock.unlock() }
            guard !finished else { return }
            finished = true
            pool.releaseLease(self)
        }
        deinit { finish() }
    }

    final class Connection {
        let id: Int
        var db: OpaquePointer?
        var generation: UInt64 = 0
        var retiring = false
        init(id: Int, db: OpaquePointer) {
            self.id = id
            self.db = db
        }
        func closeChecked() throws {
            guard let db else { return }
            retiring = true
            let result = sqlite3_close(db)
            guard result == SQLITE_OK else { throw SQLiteReadPoolError.sqlite("close code \(result)") }
            self.db = nil
        }
        deinit { if let db { sqlite3_close_v2(db) } }
    }

    private struct Waiter {
        let id: UInt64
        let cancellation: SQLiteReadCancellation
    }
    private let condition = NSCondition()
    private var path: String
    private let maximumConnections: Int
    private let maximumWaiters: Int
    private var connections: [Connection] = []
    private var waiters: [Waiter] = []
    private var leased = Set<Int>()
    private var nextWaiter: UInt64 = 0
    private var nextConnectionID = 0
    private var epoch: UInt64 = 1
    private var accepting = true
    private var exclusiveWaiting = false

    init(databaseURL: URL, maximumConnections: Int = 3, maximumWaiters: Int = 64) throws {
        guard (2...4).contains(maximumConnections), maximumWaiters > 0 else {
            throw SQLiteReadPoolError.busy
        }
        path = databaseURL.path
        self.maximumConnections = maximumConnections
        self.maximumWaiters = maximumWaiters
    }

    var generation: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return epoch
    }
    var activeLeaseCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return leased.count
    }
    var queuedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiters.count
    }
    var isExclusiveWaiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return exclusiveWaiting
    }

    func lease(
        principal: ReadPrincipalContext, timeout: TimeInterval = 2,
        cancellation: SQLiteReadCancellation = SQLiteReadCancellation()
    ) throws -> Lease {
        try validate(principal)
        condition.lock()
        guard accepting else {
            condition.unlock()
            throw SQLiteReadPoolError.stopped
        }
        guard waiters.count < maximumWaiters else {
            condition.unlock()
            throw SQLiteReadPoolError.busy
        }
        nextWaiter &+= 1
        let waiter = Waiter(id: nextWaiter, cancellation: cancellation)
        waiters.append(waiter)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if cancellation.isCancelled {
                waiters.removeAll { $0.id == waiter.id }
                condition.broadcast()
                condition.unlock()
                throw SQLiteReadPoolError.cancelled
            }
            guard accepting else {
                waiters.removeAll { $0.id == waiter.id }
                condition.broadcast()
                condition.unlock()
                throw SQLiteReadPoolError.stopped
            }
            let first = waiters.first?.id == waiter.id
            let hasReusable = connections.contains { !leased.contains($0.id) && $0.db != nil && !$0.retiring }
            let canOpen = connections.count < maximumConnections
            let canTake =
                first && !exclusiveWaiting && leased.count < maximumConnections
                && (hasReusable || canOpen)
            if canTake {
                let connection: Connection
                if let idle = connections.first(where: {
                    !leased.contains($0.id) && $0.db != nil && !$0.retiring
                }) {
                    connection = idle
                } else {
                    do {
                        nextConnectionID += 1
                        connection = try openConnection(id: nextConnectionID)
                        connections.append(connection)
                    } catch {
                        waiters.removeAll { $0.id == waiter.id }
                        condition.unlock()
                        throw error
                    }
                }
                waiters.removeFirst()
                leased.insert(connection.id)
                connection.generation = epoch
                condition.unlock()
                do { try replacePrincipal(principal, on: connection) } catch {
                    release(connection, generation: epoch, reusable: false)
                    throw error
                }
                return Lease(connection: connection, generation: epoch, pool: self)
            }
            if Date() >= deadline {
                waiters.removeAll { $0.id == waiter.id }
                condition.broadcast()
                condition.unlock()
                throw SQLiteReadPoolError.timeout
            }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    /// Stops admission and waits until every accepted lease has returned. Timeout preserves
    /// the old connections and generation so a caller can safely retry the barrier.
    func stopAdmissionAndDrain(timeout: TimeInterval = 5) throws {
        condition.lock()
        accepting = false
        condition.broadcast()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !leased.isEmpty {
            guard condition.wait(until: deadline) else {
                condition.unlock()
                throw SQLiteReadPoolError.timeout
            }
        }
        epoch &+= 1
        condition.unlock()
    }

    /// Nonblocking coordinator-facing drain. Blocking condition waits run away from the
    /// cooperative actor executor so accepted readers can return their leases.
    func stopAdmissionAndDrainAsync(timeout: TimeInterval = 5) async throws {
        try await Task.detached(priority: .userInitiated) { try self.stopAdmissionAndDrain(timeout: timeout) }
            .value
    }

    /// Marks an exclusive writer/rebuild as waiting so later readers cannot overtake it,
    /// then waits for all currently admitted readers to leave.
    func beginExclusiveAndDrain(timeout: TimeInterval = 5) throws {
        condition.lock()
        exclusiveWaiting = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !leased.isEmpty {
            guard condition.wait(until: deadline) else {
                exclusiveWaiting = false
                condition.broadcast()
                condition.unlock()
                throw SQLiteReadPoolError.timeout
            }
        }
        do {
            for connection in connections { try connection.closeChecked() }
        } catch {
            connections.removeAll { $0.db == nil }
            // A statement still owns an old-generation handle. Keep pooled reads
            // closed until a later checked drain can retire it; no swap may proceed.
            accepting = false
            condition.broadcast()
            condition.unlock()
            throw SQLiteReadPoolError.busy
        }
        connections.removeAll()
        epoch &+= 1
        condition.broadcast()
        condition.unlock()
    }

    func beginExclusiveAndDrainAsync(timeout: TimeInterval = 5) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.beginExclusiveAndDrain(timeout: timeout)
        }.value
    }

    /// Call once the exclusive owner has completed its write/rebuild operation.
    func endExclusive() {
        condition.lock()
        guard connections.isEmpty else {
            condition.unlock()
            return
        }
        exclusiveWaiting = false
        condition.broadcast()
        condition.unlock()
    }

    /// Reopens admission after the owner has completed a rebuild/swap and validated the new DB.
    func resumeAfterRebuild(databaseURL: URL? = nil) throws {
        condition.lock()
        defer { condition.unlock() }
        guard leased.isEmpty else { throw SQLiteReadPoolError.busy }
        do { for connection in connections { try connection.closeChecked() } } catch {
            connections.removeAll { $0.db == nil }
            throw SQLiteReadPoolError.busy
        }
        connections.removeAll()
        if let databaseURL { path = databaseURL.path }
        epoch &+= 1
        accepting = true
        condition.broadcast()
    }

    func shutdown(timeout: TimeInterval = 5) throws {
        try stopAdmissionAndDrain(timeout: timeout)
        condition.lock()
        defer { condition.unlock() }
        do { for connection in connections { try connection.closeChecked() } } catch {
            connections.removeAll { $0.db == nil }
            throw SQLiteReadPoolError.busy
        }
        connections.removeAll()
    }

    func shutdownAsync(timeout: TimeInterval = 5) async throws {
        try await Task.detached(priority: .userInitiated) { try self.shutdown(timeout: timeout) }.value
    }

    private func release(_ connection: Connection, generation: UInt64, reusable: Bool) {
        condition.lock()
        defer { condition.unlock() }
        guard leased.remove(connection.id) != nil else { return }
        if !reusable || generation != epoch || connection.generation != generation {
            closeForDiscard(connection)
        } else {
            do { try clearPrincipal(on: connection) } catch {
                closeForDiscard(connection)
            }
        }
        condition.broadcast()
    }

    private func closeForDiscard(_ connection: Connection) {
        do {
            try connection.closeChecked()
            connections.removeAll { $0.id == connection.id }
        } catch {
            connection.retiring = true
        }
    }

    private func execute(_ sql: String, on lease: Lease) throws -> Int64 {
        condition.lock()
        let valid =
            leased.contains(lease.connection.id) && lease.leaseGeneration == epoch
            && lease.connection.generation == lease.leaseGeneration
        condition.unlock()
        guard valid, let db = lease.connection.db else { throw SQLiteReadPoolError.staleLease }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_changes64(db)
    }

    private func scalar(_ sql: String, on lease: Lease) throws -> Int64 {
        condition.lock()
        let valid =
            leased.contains(lease.connection.id) && lease.leaseGeneration == epoch
            && lease.connection.generation == lease.leaseGeneration
        condition.unlock()
        guard valid, let db = lease.connection.db else { throw SQLiteReadPoolError.staleLease }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private func query(
        _ sql: String, bindings: [SQLiteReadValue], limits: SQLiteReadLimits,
        cancellation: SQLiteReadCancellation, on lease: Lease
    ) throws -> [[SQLiteReadValue]] {
        condition.lock()
        let valid =
            leased.contains(lease.connection.id) && lease.leaseGeneration == epoch
            && lease.connection.generation == lease.leaseGeneration
        condition.unlock()
        guard valid, let db = lease.connection.db else { throw SQLiteReadPoolError.staleLease }
        guard limits.maximumRows >= 0, limits.maximumBytes >= 0 else { throw SQLiteReadPoolError.resultLimit }
        guard !cancellation.isCancelled else { throw SQLiteReadPoolError.cancelled }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw SQLiteReadPoolError.sqlite("read API requires a read-only statement")
        }
        guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
            throw SQLiteReadPoolError.sqlite("binding count mismatch")
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                guard string.utf8.count <= Int(Int32.max) else { throw SQLiteReadPoolError.resultLimit }
                result = string.withCString {
                    sqlite3_bind_text(
                        statement, index, $0, Int32(string.utf8.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .blob(let data):
                guard data.count <= Int(Int32.max) else { throw SQLiteReadPoolError.resultLimit }
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement, index, bytes.baseAddress, Int32(data.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
            }
            guard result == SQLITE_OK else { throw sqliteError(db) }
        }

        let progress = SQLiteProgressContext(cancellation)
        sqlite3_progress_handler(
            db, 1000, sqliteReadProgressCallback,
            Unmanaged.passUnretained(progress).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }

        var rows: [[SQLiteReadValue]] = []
        var bytes = 0
        while true {
            if cancellation.isCancelled { sqlite3_interrupt(db) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            if result != SQLITE_ROW {
                if cancellation.isCancelled || result == SQLITE_INTERRUPT {
                    throw SQLiteReadPoolError.cancelled
                }
                throw sqliteError(db)
            }
            guard rows.count < limits.maximumRows else { throw SQLiteReadPoolError.resultLimit }
            var row: [SQLiteReadValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                bytes += MemoryLayout<SQLiteReadValue>.size
                guard bytes <= limits.maximumBytes else { throw SQLiteReadPoolError.resultLimit }
                let value: SQLiteReadValue
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: value = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let pointer = sqlite3_column_text(statement, column) else {
                        value = .text("")
                        break
                    }
                    value = .text(
                        String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
                    bytes += count
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let pointer = sqlite3_column_blob(statement, column)
                    value = .blob(pointer.map { Data(bytes: $0, count: count) } ?? Data())
                    bytes += count
                default: value = .null
                }
                row.append(value)
                guard bytes <= limits.maximumBytes else { throw SQLiteReadPoolError.resultLimit }
            }
            rows.append(row)
        }
        return rows
    }

    private func stream(
        _ sql: String, bindings: [SQLiteReadValue], maximumRows: Int, maximumRowBytes: Int,
        cancellation: SQLiteReadCancellation, on lease: Lease,
        onRow: ([SQLiteReadValue]) throws -> Void
    ) throws -> Int {
        condition.lock()
        let valid =
            leased.contains(lease.connection.id) && lease.leaseGeneration == epoch
            && lease.connection.generation == lease.leaseGeneration
        condition.unlock()
        guard valid, let db = lease.connection.db else { throw SQLiteReadPoolError.staleLease }
        guard maximumRows >= 0, maximumRowBytes >= 0 else { throw SQLiteReadPoolError.resultLimit }
        guard !cancellation.isCancelled else { throw SQLiteReadPoolError.cancelled }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw SQLiteReadPoolError.sqlite("read API requires a read-only statement")
        }
        try bind(bindings, to: statement, db: db)

        let progress = SQLiteProgressContext(cancellation)
        sqlite3_progress_handler(
            db, 1000, sqliteReadProgressCallback,
            Unmanaged.passUnretained(progress).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil) }

        var rowCount = 0
        while true {
            if cancellation.isCancelled { sqlite3_interrupt(db) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            if result != SQLITE_ROW {
                if cancellation.isCancelled || result == SQLITE_INTERRUPT {
                    throw SQLiteReadPoolError.cancelled
                }
                throw sqliteError(db)
            }
            guard rowCount < maximumRows else { throw SQLiteReadPoolError.resultLimit }
            let row = try copyRow(statement, maximumBytes: maximumRowBytes)
            try onRow(row)
            rowCount += 1
            if cancellation.isCancelled { throw SQLiteReadPoolError.cancelled }
        }
        return rowCount
    }

    private func bind(_ bindings: [SQLiteReadValue], to statement: OpaquePointer, db: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else {
            throw SQLiteReadPoolError.sqlite("binding count mismatch")
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                guard string.utf8.count <= Int(Int32.max) else { throw SQLiteReadPoolError.resultLimit }
                result = string.withCString {
                    sqlite3_bind_text(
                        statement, index, $0, Int32(string.utf8.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .blob(let data):
                guard data.count <= Int(Int32.max) else { throw SQLiteReadPoolError.resultLimit }
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement, index, bytes.baseAddress, Int32(data.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
            }
            guard result == SQLITE_OK else { throw sqliteError(db) }
        }
    }

    private func copyRow(_ statement: OpaquePointer, maximumBytes: Int) throws -> [SQLiteReadValue] {
        var row: [SQLiteReadValue] = []
        var bytes = 0
        for column in 0..<sqlite3_column_count(statement) {
            bytes += MemoryLayout<SQLiteReadValue>.size
            guard bytes <= maximumBytes else { throw SQLiteReadPoolError.resultLimit }
            let value: SQLiteReadValue
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT: value = .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT:
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count <= maximumBytes - bytes else { throw SQLiteReadPoolError.resultLimit }
                guard let pointer = sqlite3_column_text(statement, column) else {
                    value = .text("")
                    break
                }
                guard
                    let text = String(
                        bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
                else {
                    throw SQLiteReadPoolError.invalidText
                }
                value = .text(text)
                bytes += count
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count <= maximumBytes - bytes else { throw SQLiteReadPoolError.resultLimit }
                let pointer = sqlite3_column_blob(statement, column)
                value = .blob(pointer.map { Data(bytes: $0, count: count) } ?? Data())
                bytes += count
            default: value = .null
            }
            row.append(value)
        }
        return row
    }

    private func transaction<T>(on lease: Lease, _ body: () throws -> T) throws -> T {
        try execute("BEGIN", on: lease)
        do {
            let result = try body()
            _ = try execute("COMMIT", on: lease)
            return result
        } catch {
            _ = try? execute("ROLLBACK", on: lease)
            throw error
        }
    }

    private func openConnection(id: Int) throws -> Connection {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteReadPoolError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 1500)
        let connection = Connection(id: id, db: db)
        do {
            try run(
                "CREATE TEMP TABLE request_users (name TEXT PRIMARY KEY, uid INTEGER NOT NULL) WITHOUT ROWID",
                db)
            try run(
                "CREATE TEMP TABLE request_groups (name TEXT PRIMARY KEY, gid INTEGER NOT NULL, member INTEGER NOT NULL) WITHOUT ROWID",
                db)
            try run("CREATE TEMP TABLE request_actor (uid INTEGER NOT NULL)", db)
        } catch {
            do { try connection.closeChecked() } catch { connection.retiring = true }
            throw error
        }
        return connection
    }

    private func replacePrincipal(_ context: ReadPrincipalContext, on connection: Connection) throws {
        guard let db = connection.db else { throw SQLiteReadPoolError.staleLease }
        try run("SAVEPOINT read_principal_replace", db)
        do {
            try run("DELETE FROM request_users; DELETE FROM request_groups; DELETE FROM request_actor", db)
            for (name, uid) in context.users.sorted(by: { $0.key < $1.key }) {
                try insertUser(name: name, uid: uid, db: db)
            }
            for (name, group) in context.groups.sorted(by: { $0.key < $1.key }) {
                try insertGroup(name: name, gid: group.gid, member: group.member, db: db)
            }
            try insertActor(uid: context.actorUID, db: db)
            try run("RELEASE read_principal_replace", db)
        } catch {
            try? run("ROLLBACK TO read_principal_replace; RELEASE read_principal_replace", db)
            throw error
        }
    }

    private func clearPrincipal(on connection: Connection) throws {
        guard let db = connection.db else { throw SQLiteReadPoolError.staleLease }
        try run("SAVEPOINT read_principal_clear", db)
        do {
            try run("DELETE FROM request_users; DELETE FROM request_groups; DELETE FROM request_actor", db)
            try run("RELEASE read_principal_clear", db)
        } catch {
            try? run("ROLLBACK TO read_principal_clear; RELEASE read_principal_clear", db)
            throw error
        }
    }

    private func validate(_ context: ReadPrincipalContext) throws {
        guard context.users.count + context.groups.count <= 1024 else {
            throw SQLiteReadPoolError.invalidPrincipal
        }
        for name in Array(context.users.keys) + Array(context.groups.keys) {
            guard !name.isEmpty, name.utf8.count <= 1024, !name.utf8.contains(0) else {
                throw SQLiteReadPoolError.invalidPrincipal
            }
        }
    }

    private func insertUser(name: String, uid: UInt32, db: OpaquePointer) throws {
        try insertPrincipalRow(
            sql: "INSERT INTO request_users VALUES (?, ?)", name: name,
            firstValue: Int64(uid), secondValue: nil, db: db)
    }

    private func insertGroup(name: String, gid: UInt32, member: Bool, db: OpaquePointer) throws {
        try insertPrincipalRow(
            sql: "INSERT INTO request_groups VALUES (?, ?, ?)", name: name,
            firstValue: Int64(gid), secondValue: member ? 1 : 0, db: db)
    }

    private func insertActor(uid: UInt32, db: OpaquePointer) throws {
        try insertPrincipalRow(
            sql: "INSERT INTO request_actor VALUES (?)", name: nil,
            firstValue: Int64(uid), secondValue: nil, db: db)
    }

    private func insertPrincipalRow(
        sql: String, name: String?, firstValue: Int64, secondValue: Int64?, db: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let name {
            let result = name.withCString {
                sqlite3_bind_text(
                    statement, index, $0, Int32(name.utf8.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw sqliteError(db) }
            index += 1
        }
        guard sqlite3_bind_int64(statement, index, firstValue) == SQLITE_OK else { throw sqliteError(db) }
        index += 1
        if let secondValue {
            guard sqlite3_bind_int64(statement, index, secondValue) == SQLITE_OK else {
                throw sqliteError(db)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }
    private func run(_ sql: String, _ db: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw SQLiteReadPoolError.sqlite(detail)
        }
    }
    private func sqliteError(_ db: OpaquePointer) -> SQLiteReadPoolError {
        SQLiteReadPoolError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

extension SQLiteReadPool {
    fileprivate func releaseLease(_ lease: Lease) {
        release(lease.connection, generation: lease.leaseGeneration, reusable: true)
    }
}
