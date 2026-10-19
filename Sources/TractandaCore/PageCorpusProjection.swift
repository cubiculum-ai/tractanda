import CSQLite
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct PageCorpusSpoolPolicy: Sendable {
    let maximumBytes: Int64
    let minimumFreeBytes: Int64
    let availableBytes: (@Sendable () throws -> UInt64)?
    let stagingBoundary: (@Sendable (URL, Int64) throws -> Void)?
    init(
        maximumBytes: Int64, minimumFreeBytes: Int64,
        availableBytes: (@Sendable () throws -> UInt64)? = nil,
        stagingBoundary: (@Sendable (URL, Int64) throws -> Void)? = nil
    ) throws {
        guard maximumBytes >= 128 * 1024, minimumFreeBytes >= 0 else {
            throw TractandaError("resourceLimit", "Invalid corpus spool capacity policy.")
        }
        self.maximumBytes = maximumBytes
        self.minimumFreeBytes = minimumFreeBytes
        self.availableBytes = availableBytes
        self.stagingBoundary = stagingBoundary
    }
    func reservation(additionalBytes: Int64, allocationUnit: Int64) throws -> Int64 {
        guard additionalBytes >= 0, additionalBytes <= maximumBytes else {
            throw TractandaError("resourceLimit", "Corpus spool exceeds its operator byte budget.")
        }
        return try PageCorpusAllocation.rounded(additionalBytes, allocationUnit: allocationUnit)
    }
    func checkAvailable(_ available: UInt64, reservedGrowth: Int64) throws {
        guard reservedGrowth >= 0 else {
            throw TractandaError("resourceLimit", "Invalid corpus spool reservation.")
        }
        let needed = UInt64(minimumFreeBytes).addingReportingOverflow(UInt64(reservedGrowth))
        guard !needed.overflow, available >= needed.partialValue else {
            throw TractandaError("resourceLimit", "Corpus spool would cross its genuine-free reserve.")
        }
    }
    func check(at directory: URL, additionalBytes: Int64) throws {
        let growth = try reservation(
            additionalBytes: additionalBytes,
            allocationUnit: PageCorpusAllocation.allocationUnit(at: directory))
        // Preserve the conservative reservation for shared staging and genuine free space.
        // This is not an exact pre-write physical allocation guarantee on variable filesystems.
        try stagingBoundary?(directory, growth)
        let available: UInt64
        if let availableBytes {
            do { available = try availableBytes() } catch {
                throw TractandaError("resourceLimit", "Cannot inspect corpus spool capacity.")
            }
        } else {
            var capacity = statvfs()
            guard statvfs(directory.path, &capacity) == 0, capacity.f_frsize > 0 else {
                throw TractandaError("resourceLimit", "Cannot inspect corpus spool filesystem capacity.")
            }
            let product = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
            guard !product.overflow else {
                throw TractandaError("resourceLimit", "Corpus spool filesystem capacity overflowed.")
            }
            available = product.partialValue
        }
        try checkAvailable(available, reservedGrowth: growth)
    }
}

struct PageCorpusFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int32
    init(_ metadata: FileMetadata) {
        device = metadata.device
        inode = metadata.inode
        size = metadata.size
        modifiedSeconds = metadata.modificationSeconds
        modifiedNanoseconds = metadata.modificationNanoseconds
    }
}

struct PageCorpusReceipt: Codable, Equatable, Sendable {
    let schema: String
    let source: PageCorpusBinding
    let summary: PageCorpusSummary
    let fileSHA256: String
    let file: PageCorpusFileIdentity
    let maximumSpoolBytes: Int64
}

struct PreparedPageCorpus: Sendable {
    let directory: URL  // Internal private recovery path; never a client argument.
    let receipt: PageCorpusReceipt
    var databaseURL: URL { directory.appendingPathComponent("projection.sqlite") }
}

struct PageCorpusUnitWindow: Sendable {
    let source: PageCorpusBinding
    let ordinal: Int64
    let origin: PageCorpusOrigin
    let byteCount: Int64
    let offset: Int64
    let nextOffset: Int64
    let data: Data
}

/// One private projection. Main supplies current source/ACL/CAS authority and installs its
/// assigned publication revision later. This helper grants no authority and mutates no Store.
enum PageCorpusProjection {
    static func prepare(
        input: PageCorpusInput, provider: any PageCorpusPageProvider,
        root: URL, policy: PageCorpusSpoolPolicy, boundary: () throws -> Void = {}
    ) throws -> PreparedPageCorpus {
        try privateDirectory(root)
        try policy.check(at: root, additionalBytes: 128 * 1024)
        try boundary()
        let directory = root.appendingPathComponent(
            "page-corpus-" + (try UUID.makeVersion1().uuidString.lowercased()))
        guard mkdir(directory.path, 0o700) == 0 else {
            throw integrity("Cannot create private corpus stage.")
        }
        do {
            try synchronize(root)
            let database = directory.appendingPathComponent("projection.sqlite")
            let created = open(database.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard created >= 0 else { throw integrity("Cannot create corpus spool file.") }
            _ = close(created)
            let connection = try PageCorpusSQLite(path: database.path, readOnly: false)
            do {
                try connection.execute("PRAGMA page_size=4096")
                // Reserve half the operator cap for rollback journal/receipt overhead.
                let pages = min(Int64(UInt32.max - 2), policy.maximumBytes / 8192)
                try connection.execute("PRAGMA max_page_count=\(pages)")
                try connection.execute("PRAGMA journal_mode=DELETE")
                try connection.execute("PRAGMA synchronous=FULL")
                try connection.execute("PRAGMA temp_store=MEMORY")
                try connection.execute("PRAGMA mmap_size=0")
                try connection.execute("PRAGMA cache_size=-1024")
                try connection.execute(
                    "CREATE TABLE corpus_head (item_id TEXT PRIMARY KEY, source TEXT NOT NULL, summary TEXT NOT NULL)"
                )
                try connection.execute(
                    "CREATE TABLE corpus_unit (id INTEGER PRIMARY KEY, item_id TEXT NOT NULL, ordinal INTEGER NOT NULL UNIQUE, byte_start INTEGER NOT NULL, byte_count INTEGER NOT NULL, origin TEXT NOT NULL)"
                )
                try connection.execute("CREATE INDEX corpus_unit_item ON corpus_unit(item_id, ordinal)")
                try connection.execute(
                    "CREATE TABLE corpus_span (unit_id INTEGER NOT NULL, block_index INTEGER NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL, box TEXT, PRIMARY KEY(unit_id, block_index))"
                )
                try connection.execute(
                    "CREATE VIRTUAL TABLE text_index USING fts5(text, tokenize='unicode61', detail=full)")
                try connection.execute("BEGIN IMMEDIATE")
                let summary = try PageCorpusEmitter.emit(input, provider: provider, boundary: boundary) {
                    unit in
                    let origin = try JSON.encode(unit.origin)
                    let spans = try JSON.encode(unit.spans)
                    let size = try PageCorpusEmitter.add(
                        Int64(unit.text.utf8.count), Int64(origin.count + spans.count))
                    let growth = size.multipliedReportingOverflow(by: 4)
                    guard !growth.overflow else { throw integrity("Corpus unit growth estimate overflowed.") }
                    try budget(
                        directory, policy: policy,
                        additional: try PageCorpusEmitter.add(growth.partialValue, 65_536))
                    let id = try PageCorpusEmitter.add(unit.ordinal, 1)
                    try connection.execute(
                        "INSERT INTO corpus_unit VALUES (?, ?, ?, ?, ?, ?)",
                        [
                            .integer(id), .text(input.binding.itemID), .integer(unit.ordinal),
                            .integer(unit.byteStart),
                            .integer(Int64(unit.text.utf8.count)),
                            .text(String(decoding: origin, as: UTF8.self)),
                        ])
                    try connection.execute(
                        "INSERT INTO text_index(rowid, text) VALUES (?, ?)", [.integer(id), .text(unit.text)])
                    for span in unit.spans {
                        try boundary()
                        let box = try span.box.map { String(decoding: try JSON.encode($0), as: UTF8.self) }
                        try connection.execute(
                            "INSERT INTO corpus_span VALUES (?, ?, ?, ?, ?)",
                            [
                                .integer(id), .integer(span.blockIndex), .integer(span.unitByteStart),
                                .integer(span.unitByteEnd),
                                box.map(PageCorpusSQLite.Value.text) ?? .null,
                            ])
                    }
                    try budget(directory, policy: policy, additional: 0)
                }
                try connection.execute(
                    "INSERT INTO corpus_head VALUES (?, ?, ?)",
                    [
                        .text(input.binding.itemID),
                        .text(String(decoding: try JSON.encode(input.binding), as: UTF8.self)),
                        .text(String(decoding: try JSON.encode(summary), as: UTF8.self)),
                    ])
                try boundary()
                try budget(directory, policy: policy, additional: 16 * 1024)
                try connection.execute("COMMIT")
                try connection.close()
                try seal(database)
                let metadata = try sealedFile(database, maximumBytes: UInt64(policy.maximumBytes))
                let receipt = PageCorpusReceipt(
                    schema: "tractanda.page-corpus-spool.v2", source: input.binding, summary: summary,
                    fileSHA256: try hashFile(database, expected: metadata, boundary: boundary),
                    file: PageCorpusFileIdentity(metadata), maximumSpoolBytes: policy.maximumBytes)
                let bytes = try JSON.encode(receipt)
                guard bytes.count <= 16 * 1024 else { throw integrity("Corpus receipt exceeds its window.") }
                try budget(directory, policy: policy, additional: Int64(bytes.count))
                let receiptURL = directory.appendingPathComponent("receipt.json")
                let fd = open(receiptURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw integrity("Cannot create corpus receipt.") }
                do {
                    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
                    guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else {
                        throw integrity("Cannot seal corpus receipt.")
                    }
                } catch {
                    _ = close(fd)
                    throw error
                }
                _ = close(fd)
                try synchronize(directory)
                try synchronize(root)
                try budget(directory, policy: policy, additional: 0)
                return PreparedPageCorpus(directory: directory, receipt: receipt)
            } catch {
                try? connection.close()
                throw error
            }
        } catch {
            // Disposable derived work only, in the exact newly owned stage; source is untouched.
            try? FileManager.default.removeItem(at: directory)
            try? synchronize(root)
            throw error
        }
    }

    /// Cold recovery/transfer validation is explicitly streamed and belongs off the Store queue.
    static func verify(
        _ prepared: PreparedPageCorpus, expected: PageCorpusBinding, boundary: () throws -> Void = {}
    ) throws {
        guard prepared.receipt.schema == "tractanda.page-corpus-spool.v2",
            prepared.receipt.source == expected,
            prepared.receipt.maximumSpoolBytes >= 128 * 1024
        else {
            throw integrity("Corpus spool belongs to a different store/source revision.")
        }
        try privateDirectory(prepared.directory)
        _ = try PageCorpusAllocation.check(
            PageCorpusAllocation.usage(at: prepared.directory),
            maximumBytes: prepared.receipt.maximumSpoolBytes,
            additionalBytes: 0, allocationUnit: PageCorpusAllocation.allocationUnit(at: prepared.directory))
        let metadata = try sealedFile(prepared.databaseURL, maximumBytes: prepared.receipt.file.size)
        guard PageCorpusFileIdentity(metadata) == prepared.receipt.file,
            try hashFile(prepared.databaseURL, expected: metadata, boundary: boundary)
                == prepared.receipt.fileSHA256
        else { throw integrity("Corpus spool checksum or file identity changed.") }
    }

    static func load(
        root: URL, artifactName: String, expected: PageCorpusBinding,
        boundary: () throws -> Void = {}
    ) throws -> PreparedPageCorpus {
        guard artifactName.hasPrefix("page-corpus-"),
            UUID(uuidString: String(artifactName.dropFirst("page-corpus-".count))) != nil,
            !artifactName.contains("/"), !artifactName.contains("\0")
        else { throw integrity("Invalid private corpus artifact name.") }
        try privateDirectory(root)
        let directory = root.appendingPathComponent(artifactName)
        try privateDirectory(directory)
        let url = directory.appendingPathComponent("receipt.json")
        let metadata = try sealedFile(url, maximumBytes: 16 * 1024)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw integrity("Cannot open corpus receipt.") }
        defer { _ = close(fd) }
        let data =
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16 * 1024 + 1) ?? Data()
        guard data.count == metadata.size, try FileMetadata.read(at: url) == metadata else {
            throw integrity("Corpus receipt changed while reading.")
        }
        let receipt = try DocumentValue.strictDecode(PageCorpusReceipt.self, data: data)
        let prepared = PreparedPageCorpus(directory: directory, receipt: receipt)
        try verify(prepared, expected: expected, boundary: boundary)
        return prepared
    }

    /// Compiler primitive only: caller installs its current revision/binding and ACL predicates.
    static func literalMembershipSQL() -> String {
        "EXISTS (SELECT 1 FROM text_index JOIN corpus_unit u ON u.id=text_index.rowid WHERE u.item_id=corpus_head.item_id AND text_index MATCH ?)"
    }
    static func literalArgument(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Bounded, deduplicated fixture/spool access. Final integration must supply fresh authority.
    static func forEachMatchingItem(
        _ prepared: PreparedPageCorpus, expected: PageCorpusBinding, literalText: String,
        isCurrentAndReadable: (PageCorpusBinding) throws -> Bool,
        boundary: () throws -> Void = {}, visit: (String) throws -> Void
    ) throws {
        guard try isCurrentAndReadable(expected) else { return }
        try verify(prepared, expected: expected, boundary: boundary)
        let connection = try PageCorpusSQLite(path: prepared.databaseURL.path, readOnly: true)
        defer { try? connection.close() }
        try validateHead(connection, receipt: prepared.receipt)
        try connection.rows(
            "SELECT item_id, source, summary FROM corpus_head WHERE " + literalMembershipSQL(),
            [.text(literalArgument(literalText))]
        ) { statement in
            try boundary()
            let source = try JSON.decode(
                PageCorpusBinding.self, Data(connection.text(statement, column: 1).utf8))
            let summary = try JSON.decode(
                PageCorpusSummary.self, Data(connection.text(statement, column: 2).utf8))
            guard source == expected, summary == prepared.receipt.summary,
                connection.text(statement, column: 0) == expected.itemID
            else { throw integrity("Corpus spool current binding changed.") }
            if try isCurrentAndReadable(source) { try visit(source.itemID) }
        }
    }

    static func readUnit(
        _ prepared: PreparedPageCorpus, expected: PageCorpusBinding, ordinal: Int64,
        offset: Int64 = 0, limit: Int = 262_144,
        isCurrentAndReadable: (PageCorpusBinding) throws -> Bool,
        boundary: () throws -> Void = {}
    ) throws -> PageCorpusUnitWindow {
        guard ordinal >= 0, offset >= 0, offset < Int64.max, (1...262_144).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded corpus unit byte window.")
        }
        guard try isCurrentAndReadable(expected) else {
            throw TractandaError("notFound", "Corpus unit is unavailable.")
        }
        try verify(prepared, expected: expected, boundary: boundary)
        let connection = try PageCorpusSQLite(path: prepared.databaseURL.path, readOnly: true)
        defer { try? connection.close() }
        try validateHead(connection, receipt: prepared.receipt)
        var window: PageCorpusUnitWindow?
        try connection.rows(
            "SELECT u.byte_count, u.origin, substr(CAST(text_index.text AS BLOB), ?, ?) FROM corpus_unit u JOIN text_index ON text_index.rowid=u.id WHERE u.ordinal=? AND u.item_id=?",
            [.integer(offset + 1), .integer(Int64(limit)), .integer(ordinal), .text(expected.itemID)]
        ) { statement in
            try boundary()
            let byteCount = sqlite3_column_int64(statement, 0)
            guard byteCount >= 0, offset <= byteCount, byteCount <= 8 * 1024 * 1024 else {
                throw integrity("Corpus unit byte range changed.")
            }
            let origin = try JSON.decode(
                PageCorpusOrigin.self, Data(connection.text(statement, column: 1).utf8))
            let data = connection.data(statement, column: 2)
            guard data.count == min(Int64(limit), byteCount - offset) else {
                throw integrity("Corpus unit window changed.")
            }
            window = PageCorpusUnitWindow(
                source: expected, ordinal: ordinal, origin: origin, byteCount: byteCount,
                offset: offset, nextOffset: offset + Int64(data.count), data: data)
        }
        guard try isCurrentAndReadable(expected), let window else {
            throw TractandaError("notFound", "Corpus unit is unavailable.")
        }
        return window
    }

    private static func validateHead(_ connection: PageCorpusSQLite, receipt: PageCorpusReceipt) throws {
        var count = 0
        try connection.rows("SELECT item_id, source, summary FROM corpus_head", []) { statement in
            count += 1
            let source = try JSON.decode(
                PageCorpusBinding.self, Data(connection.text(statement, column: 1).utf8))
            let summary = try JSON.decode(
                PageCorpusSummary.self, Data(connection.text(statement, column: 2).utf8))
            guard count == 1, source == receipt.source, summary == receipt.summary,
                connection.text(statement, column: 0) == receipt.source.itemID
            else { throw integrity("Corpus spool head differs from its source receipt.") }
        }
        guard count == 1 else { throw integrity("Corpus spool has no source head.") }
    }

    private static func budget(_ directory: URL, policy: PageCorpusSpoolPolicy, additional: Int64) throws {
        _ = try PageCorpusAllocation.check(
            PageCorpusAllocation.usage(at: directory), maximumBytes: policy.maximumBytes,
            additionalBytes: additional, allocationUnit: PageCorpusAllocation.allocationUnit(at: directory))
        try policy.check(at: directory, additionalBytes: additional)
    }
    private static func privateDirectory(_ url: URL) throws {
        let metadata = try FileMetadata.read(at: url)
        guard metadata.type == .directory, metadata.uid == getuid(), metadata.mode & 0o077 == 0 else {
            throw integrity("Corpus spool directory must be private and service-owned.")
        }
    }
    private static func sealedFile(_ url: URL, maximumBytes: UInt64) throws -> FileMetadata {
        let metadata = try FileMetadata.read(at: url)
        guard metadata.type == .regular, metadata.uid == getuid(), metadata.mode & 0o777 == 0o400,
            metadata.size > 0, metadata.size <= maximumBytes
        else { throw integrity("Unsafe or oversized sealed corpus file.") }
        return metadata
    }
    private static func seal(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw integrity("Cannot open corpus spool for sealing.") }
        defer { _ = close(fd) }
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else { throw integrity("Cannot seal corpus spool.") }
    }
    private static func synchronize(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw integrity("Cannot open corpus directory for synchronization.") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw integrity("Cannot synchronize corpus directory.") }
    }
    private static func hashFile(_ url: URL, expected: FileMetadata, boundary: () throws -> Void) throws
        -> String
    {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw integrity("Cannot open corpus spool for hashing.") }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_size >= 0,
            UInt64(truncatingIfNeeded: metadata.st_dev) == expected.device,
            UInt64(metadata.st_ino) == expected.inode, UInt64(metadata.st_size) == expected.size
        else { throw integrity("Corpus spool changed before hashing.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try boundary()
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 65_536) ?? Data()
            if data.isEmpty { break }
            count = try PageCorpusEmitter.add(count, Int64(data.count))
            guard UInt64(count) <= expected.size else { throw integrity("Corpus spool grew while hashing.") }
            hash.update(data: data)
        }
        guard UInt64(count) == expected.size, try FileMetadata.read(at: url) == expected else {
            throw integrity("Corpus spool changed while hashing.")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func integrity(_ message: String) -> TractandaError {
        TractandaError("documentIntegrity", message)
    }
}

/// Thread-confined prepared statements; no connection crosses a Store or provider boundary.
private final class PageCorpusSQLite {
    enum Value {
        case text(String)
        case integer(Int64)
        case null
    }
    private var database: OpaquePointer?
    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &database, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw TractandaError("indexError", "Cannot open private corpus projection.")
        }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 16 * 1024 * 1024)
    }
    deinit { if let database { sqlite3_close(database) } }
    func close() throws {
        guard let database else { return }
        guard sqlite3_close(database) == SQLITE_OK else { throw failure() }
        self.database = nil
    }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        try rows(sql, values) { _ in }
    }
    func rows(_ sql: String, _ values: [Value], visit: (OpaquePointer) throws -> Void) throws {
        guard let database else { throw TractandaError("indexError", "Corpus projection is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .text(let text):
                guard let bytes = Int32(exactly: text.utf8.count) else { throw failure() }
                result = text.withCString {
                    sqlite3_bind_text(statement, Int32(offset + 1), $0, bytes, transient)
                }
            case .integer(let value): result = sqlite3_bind_int64(statement, Int32(offset + 1), value)
            case .null: result = sqlite3_bind_null(statement, Int32(offset + 1))
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw failure() }
            try visit(statement)
        }
    }
    func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: text)
    }
    func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    private func failure() -> TractandaError {
        let code = sqlite3_errcode(database)
        return TractandaError(
            code == SQLITE_FULL || code == SQLITE_TOOBIG ? "resourceLimit" : "indexError",
            "Corpus projection SQLite operation failed."
        )
    }
}
