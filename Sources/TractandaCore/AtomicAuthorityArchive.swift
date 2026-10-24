import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Private structural archive only: no accepted-control, publication, permission or queue integration.
/// Callers supply a frozen ordered draft; a structural proof is never an authorization decision.
final class AtomicAuthorityArchive {
    typealias Format = AtomicAuthorityFormat
    typealias Section = Format.Section
    struct Limits {
        let maximumStoredBytes: UInt64
        let maximumParts: Int64
        var minimumFreeBytes: Int64 = 10 * 1024 * 1024 * 1024
    }
    /// Only a retained-original loader may report an unreceived declared part. Missing files for
    /// an already retained descriptor remain custody errors, not healthy network incompleteness.
    struct PartUnavailable: Error {
        let binding: AuthorityBinding
    }
    struct Window {
        var maximumParts = 16
        var maximumBytes = 1024 * 1024
    }
    struct Context: Equatable {
        let rootID: String
        let storeID: String
        let origin: String
        let actor: String
        let createdAt: String
        let inputIdentity: String
        let previous: AuthorityBinding?
        let bootstrap: AuthorityBinding?
        init(
            rootID: String, storeID: String, origin: String, actor: String, createdAt: String,
            inputIdentity: String, previous: AuthorityBinding? = nil, bootstrap: AuthorityBinding? = nil
        ) throws {
            self.rootID = try AuthorityRecord.persistentID(.text(rootID))
            try Identifier.validate(storeID)
            self.storeID = storeID
            self.origin = try AuthorityRecord.persistentID(.text(origin))
            self.actor = try AuthorityRecord.text(.text(actor))
            guard createdAt.utf8.count <= 36, Timestamp.parse(createdAt) != nil else {
                throw Format.invalid("Invalid reserved creation time.")
            }
            _ = try RevisionTimestamp(createdAt)
            self.createdAt = createdAt
            self.inputIdentity = try AuthorityRecord.digest(.text(inputIdentity))
            self.previous = previous
            self.bootstrap = bootstrap
        }
        func record(_ kind: Format.Kind, id: String, payload: [String: ItemValue]) throws -> Format.Record {
            try .init(
                value: .object([
                    "profile": .text(Format.profile), "kind": .text(kind.rawValue), "recordID": .text(id),
                    "controlID": .text(rootID), "storeID": .text(storeID), "originReplicaID": .text(origin),
                    "actorPrincipal": .text(actor), "createdAt": .date(createdAt),
                    "payload": .object(payload),
                ]))
        }
        func reservation(chunkBytes: Int) -> ItemValue {
            .object([
                "profile": .text("tractanda.atomic-archive-reservation.v1"), "rootID": .text(rootID),
                "storeID": .text(storeID), "origin": .text(origin), "actor": .text(actor),
                "createdAt": .date(createdAt), "inputIdentity": .text(inputIdentity),
                "previous": .list(previous.map { [$0.itemValue] } ?? []),
                "bootstrap": .list(bootstrap.map { [$0.itemValue] } ?? []),
                "chunkBytes": .integer(Int64(chunkBytes)),
            ])
        }
    }
    struct Handle: Equatable {
        let binding: AuthorityBinding
        let encodedBytes: Int
    }
    struct Structure: Equatable {
        let handle: Handle
        let parts: Int64
        let encodedPartBytes: Int64
        let parentEntries: Int64
        let supportFacts: Int64
        let targets: Int64
    }
    /// A parsed prefix fact, not a proof: only isolated private staging may consume it.
    struct UntrustedStagingFact {
        let section: Section
        let value: ItemValue
    }

    /// Optional private filesystem scope; never a logical-authority/acceptance capability.
    enum StorageMutation: String { case immutableWrite, lease, removeFile, removeDirectory }
    struct StorageHooks {
        let begin: (StorageMutation, [String], UInt64) throws -> String
        let finish: (String, Bool) throws -> Void
    }
    private let io: Files
    private let chunkBytes: Int
    private let progress: (() throws -> Void)?
    private let canonicalPartLoader: ((AuthorityBinding, Int64) throws -> Data)?
    private let canonicalRootLoader: (() throws -> Data)?
    init(
        root: URL, limits: Limits, chunkBytes: Int = Format.maximumChunkBytes,
        availableBytes: (@Sendable () throws -> UInt64)? = nil, progress: (() throws -> Void)? = nil,
        canonicalPartLoader: ((AuthorityBinding, Int64) throws -> Data)? = nil,
        canonicalRootLoader: (() throws -> Data)? = nil, storageHooks: StorageHooks? = nil
    ) throws {
        guard (1...Format.maximumChunkBytes).contains(chunkBytes), limits.maximumParts > 0,
            (canonicalPartLoader == nil) == (canonicalRootLoader == nil)
        else {
            throw Format.invalid("Invalid private archive limits.")
        }
        self.chunkBytes = chunkBytes
        self.progress = progress
        self.canonicalPartLoader = canonicalPartLoader
        self.canonicalRootLoader = canonicalRootLoader
        io = try Files(root: root, limits: limits, availableBytes: availableBytes, storageHooks: storageHooks)
    }
    private func check() throws {
        try Task.checkCancellation()
        try io.checkLease()
        try progress?()
        try io.checkLease()
    }
    private func referencePath(_ section: Section, _ level: Int64, _ ordinal: Int64) -> [String] {
        ["references", section.rawValue, String(level), String(ordinal)]
    }
    private func reference(_ section: Section, _ level: Int64, _ ordinal: Int64) throws -> Format.Reference {
        try .init(value: Format.decodeValue(io.read(referencePath(section, level, ordinal))))
    }
    private func allocation(_ context: Context, section: Section, level: Int64, ordinal: Int64) throws
        -> String
    {
        let path = ["allocations", section.rawValue, String(level), String(ordinal)]
        if let old = try io.optional(path) {
            let p = try AuthorityRecord.object(Format.decodeValue(old), keys: ["controlID", "recordID"])
            guard p["controlID"]?.string == context.rootID else {
                throw Format.invalid("Allocation root changed.")
            }
            return try AuthorityRecord.persistentID(p["recordID"])
        }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        try io.put(
            try JSON.encode(
                ItemValue.object([
                    "controlID": .text(context.rootID), "recordID": .text(id),
                ])), at: path)
        return id
    }
    /// Replays exact frozen inputs against durable addressed allocations, never restamping root/PRE/time.
    func build(
        context: Context, parents: () throws -> ItemValue?, effects: () throws -> ItemValue?
    ) throws -> Handle {
        guard canonicalPartLoader == nil else {
            throw Format.invalid("A canonical closure reader cannot construct or replace parts.")
        }
        let lock = try io.lock()
        defer { io.unlock(lock) }
        try check()
        try io.put(try JSON.encode(context.reservation(chunkBytes: chunkBytes)), at: ["reservation"])
        let old = try io.optional(["root"]).map { try Format.Codec.decode($0) }
        if let old {
            guard old.recordID == context.rootID else { throw Format.invalid("Root identity changed.") }
        }
        var partCount: Int64 = 0
        var partBytes: Int64 = 0
        func save(_ record: Format.Record, section: Section, level: Int64, ordinal: Int64) throws
            -> Format.Reference
        {
            try check()
            let data = try Format.Codec.encode(record)
            partCount = try Format.sum(partCount, 1)
            partBytes = try Format.sum(partBytes, Int64(data.count))
            guard partCount <= io.limits.maximumParts else {
                throw resource("Private archive part allowance exhausted.")
            }
            try io.put(data, at: ["parts", record.recordID])
            let ref = try record.reference()
            try io.put(try JSON.encode(ref.itemValue), at: referencePath(section, level, ordinal))
            return ref
        }
        func stream(_ section: Section, next: () throws -> ItemValue?) throws -> Format.Stream {
            var bytes: Int64 = 0
            var entries: Int64 = 0
            var targets: Int64 = 0
            var leaves: Int64 = 0
            var buffer = Data()
            var lastKey: String?
            var lastTarget: String?
            var previousFound = context.previous == nil
            let expected = try old.map {
                try Format.Stream(value: $0.payload[section.rawValue]!, section: section)
            }
            func flush() throws {
                guard !buffer.isEmpty else { return }
                let id = try allocation(context, section: section, level: 0, ordinal: leaves)
                _ = try save(
                    context.record(
                        .atomicControlPart, id: id,
                        payload: [
                            "section": .text(section.rawValue), "ordinal": .integer(leaves),
                            "byteOffset": .integer(bytes - Int64(buffer.count)), "bytes": .bytes(buffer),
                        ]), section: section, level: 0, ordinal: leaves)
                leaves = try Format.sum(leaves, 1)
                buffer.removeAll(keepingCapacity: true)
            }
            while let value = try next() {
                try check()
                let frame = try AtomicAuthorityEntryStream.frame(value, section: section)
                let target =
                    try section == .parents
                    ? AuthorityBinding(value: value).recordID
                    : AuthorityStore.DispositionDelta(value: value).target.revisionID
                let key =
                    section == .parents
                    ? target : target + ":" + AuthorityRecordCodec.sha256(Data(frame.dropFirst(8)))
                guard lastKey == nil || lastKey! < key else {
                    throw Format.invalid("Draft entries are not strictly ordered.")
                }
                lastKey = key
                if section == .parents {
                    let parent = try AuthorityBinding(value: value)
                    guard parent.recordID != context.rootID else {
                        throw Format.invalid("Root cannot be its own logical PRE parent.")
                    }
                    if parent.recordID == context.previous?.recordID {
                        guard parent == context.previous else {
                            throw Format.invalid("Previous root digest differs from input.")
                        }
                        previousFound = true
                    }
                }
                if section == .effects && lastTarget != target { targets = try Format.sum(targets, 1) }
                lastTarget = target
                entries = try Format.sum(entries, 1)
                if let expected {
                    guard entries <= expected.entryCount, Int64(frame.count) <= expected.byteCount - bytes
                    else {
                        throw Format.invalid("Exact retry extends the completed input stream.")
                    }
                }
                var offset = 0
                while offset < frame.count {
                    let amount = min(chunkBytes - buffer.count, frame.count - offset)
                    buffer.append(frame.subdata(in: offset..<(offset + amount)))
                    bytes = try Format.sum(bytes, Int64(amount))
                    offset += amount
                    if buffer.count == chunkBytes { try flush() }
                }
            }
            try flush()
            guard section != .parents || previousFound else {
                throw Format.invalid("Previous root is omitted from input.")
            }
            if let expected {
                guard expected.entryCount == entries, expected.targetCount == targets,
                    expected.byteCount == bytes
                else {
                    throw Format.invalid("Exact retry input counts changed.")
                }
            }
            var level: Int64 = 0
            var count = leaves
            while count > 1 {
                var first: Int64 = 0
                var parentOrdinal: Int64 = 0
                while first < count {
                    try check()
                    var children: [Format.Reference] = []
                    for ordinal in first..<min(first + Format.fanout, count) {
                        children.append(try reference(section, level, ordinal))
                    }
                    let id = try allocation(
                        context, section: section, level: level + 1, ordinal: parentOrdinal)
                    _ = try save(
                        context.record(
                            .atomicControlIndex, id: id,
                            payload: [
                                "section": .text(section.rawValue), "level": .integer(level + 1),
                                "totalLeaves": .integer(leaves), "children": .list(children.map(\.itemValue)),
                            ]), section: section, level: level + 1, ordinal: parentOrdinal)
                    parentOrdinal += 1
                    first += Int64(children.count)
                }
                count = parentOrdinal
                level += 1
            }
            return try Format.Stream(
                value: .object([
                    "root": .list(leaves == 0 ? [] : [reference(section, level, 0).itemValue]),
                    "byteCount": .integer(bytes), "entryCount": .integer(entries),
                    "targetCount": .integer(targets), "leafCount": .integer(leaves),
                ]), section: section)
        }
        let parentStream = try stream(.parents, next: parents)
        let effectStream = try stream(.effects, next: effects)
        let root = try context.record(
            .atomicControl, id: context.rootID,
            payload: [
                "previous": .list(context.previous.map { [$0.itemValue] } ?? []),
                "bootstrap": .list(context.bootstrap.map { [$0.itemValue] } ?? []),
                "parents": parentStream.itemValue, "effects": effectStream.itemValue,
                "partCount": .integer(partCount), "partBytes": .integer(partBytes),
            ])
        let data = try Format.Codec.encode(root)
        // Only after every addressed immutable part/reference is durable. Still no runtime authority.
        try check()
        try io.put(data, at: ["root"])
        return Handle(
            binding: try .init(recordID: root.recordID, sha256: AuthorityRecordCodec.sha256(data)),
            encodedBytes: data.count)
    }

    func beginValidation(_ handle: Handle) throws -> Reader { try Reader(archive: self, handle: handle) }
    /// Captures one bounded exact root in owned private work; canonical parts remain in their
    /// original custody and are freshly loaded/rechecked on every reopen by the supplied boundary.
    func bindCanonicalRoot(_ bytes: Data) throws -> Handle {
        guard canonicalPartLoader != nil else {
            throw Format.invalid("Canonical root binding requires a retained-original loader.")
        }
        let record = try Format.Codec.decode(bytes)
        guard record.kind == .atomicControl else { throw Format.invalid("Expected a logical root.") }
        let lock = try io.lock()
        defer { io.unlock(lock) }
        try check()
        guard try canonicalRootLoader?() == bytes else {
            throw Format.invalid("Canonical root changed before private reader binding.")
        }
        try io.put(bytes, at: ["root"])
        return .init(
            binding: try .init(recordID: record.recordID, sha256: AuthorityRecordCodec.sha256(bytes)),
            encodedBytes: bytes.count)
    }
    private func partBytes(_ reference: Format.Reference) throws -> Data {
        if let canonicalPartLoader {
            return try canonicalPartLoader(reference.binding, reference.encodedBytes)
        }
        return try io.read(["parts", reference.binding.recordID])
    }
    private func currentRootBytes() throws -> Data {
        let bytes = try io.read(["root"])
        if let canonicalRootLoader {
            guard try canonicalRootLoader() == bytes else {
                throw Format.invalid("Canonical root changed after private reader binding.")
            }
        }
        return bytes
    }
    /// Exact physical root bytes only; this does not assert closure or semantic acceptance.
    func rootBytes(_ handle: Handle) throws -> Data {
        let lock = try io.lock()
        defer { io.unlock(lock) }
        try check()
        let bytes = try currentRootBytes()
        let record = try Format.Codec.decode(bytes)
        guard bytes.count == handle.encodedBytes, record.kind == .atomicControl,
            record.recordID == handle.binding.recordID,
            AuthorityRecordCodec.sha256(bytes) == handle.binding.sha256
        else { throw Format.invalid("Private root differs from its exact handle.") }
        return bytes
    }
    /// Source-publication spool input only. A complete structural walk precedes enumeration,
    /// then every object is freshly reopened under the private lease. The consumer may stage
    /// descriptors/bytes but may not accept authority from this callback. Final Store validation
    /// still binds the canonical root/parts after physical publication, before ACCEPTED sealing.
    func forEachUntrustedLocalObject(
        _ handle: Handle, body: (PeerPackage.Object, Data) throws -> Void
    ) throws {
        guard canonicalPartLoader == nil else {
            throw Format.invalid("Only an owned local construction archive supplies publication bytes.")
        }
        let structure = try validate(handle)
        let held = try io.lock()
        defer { io.unlock(held) }
        let rootBytes = try currentRootBytes()
        guard rootBytes.count == handle.encodedBytes,
            AuthorityRecordCodec.sha256(rootBytes) == handle.binding.sha256
        else {
            throw Format.invalid("Local publication root changed after its closure check.")
        }
        let root = try Format.Codec.decode(rootBytes)
        var parts: Int64 = 0
        do {
            try io.forEachPartName { id in
                try self.check()
                let bytes = try self.io.read(["parts", id])
                _ = try self.requireLocalPart(bytes, id: id, root: root)
                parts = try Format.sum(parts, 1)
                guard parts <= structure.parts else {
                    throw Format.invalid("Local archive contains unreferenced part files.")
                }
                try body(
                    .init(
                        kind: .authority, id: id, length: bytes.count,
                        sha256: AuthorityRecordCodec.sha256(bytes)), bytes)
            }
        } catch FileMetadataError.posix(let code) where code == ENOENT && structure.parts == 0 {
            // An empty physical closure need not create a parts directory.
        }
        guard parts == structure.parts, try currentRootBytes() == rootBytes else {
            throw Format.invalid("Local publication closure changed during enumeration.")
        }
        try body(
            .init(
                kind: .authority, id: handle.binding.recordID, length: rootBytes.count,
                sha256: handle.binding.sha256), rootBytes)
        try check()
        guard try currentRootBytes() == rootBytes else {
            throw Format.invalid("Local publication root changed during callback.")
        }
    }

    /// Read-only publication input under one exclusive archive lease. The initial and final
    /// inventories are constant per successful scope; individual objects never recount the tree.
    /// Expected descriptors remain untrusted input, not proof of root membership or authority.
    func withUntrustedLocalObjectReader<T>(
        _ handle: Handle, body: (UntrustedLocalObjectReader) throws -> T
    ) throws -> T {
        guard canonicalPartLoader == nil else {
            throw Format.invalid("Canonical reader cannot author local publication input.")
        }
        let held = try io.lock()
        var reader: UntrustedLocalObjectReader?
        defer {
            reader?.invalidate()
            io.unlock(held)
        }
        try io.requireReadCapacity()
        let current = try UntrustedLocalObjectReader(archive: self, handle: handle)
        reader = current
        // A throwing body already fails the scope. Preserve that primary error unchanged;
        // cleanup only releases the lease and cannot replace it with a secondary census error.
        let result = try body(current)
        try current.finish()
        return result
    }

    /// No accepting or membership API: every returned object is a freshly verified byte value.
    /// The enclosing scope invalidates escaped references, including when its callback throws.
    final class UntrustedLocalObjectReader {
        private let archive: AtomicAuthorityArchive
        private let handle: Handle
        private let rootBytes: Data
        private let root: Format.Record
        private var active = true
        private var failed = false
        private var busy = false
        fileprivate init(archive: AtomicAuthorityArchive, handle: Handle) throws {
            self.archive = archive
            self.handle = handle
            try archive.check()
            let bytes = try archive.currentRootBytes()
            let root = try Format.Codec.decode(bytes)
            guard bytes.count == handle.encodedBytes, root.kind == .atomicControl,
                root.recordID == handle.binding.recordID,
                AuthorityRecordCodec.sha256(bytes) == handle.binding.sha256
            else { throw Format.invalid("Scoped local publication changed its exact root.") }
            rootBytes = bytes
            self.root = root
            try requireCurrentRoot()
        }
        fileprivate func invalidate() { active = false }
        private func requireOpen() throws {
            guard active, !failed else {
                throw Format.invalid("Untrusted local object reader is closed or failed.")
            }
        }
        private func requireRootWithoutCallback() throws {
            try archive.io.checkLease()
            guard try archive.currentRootBytes() == rootBytes else {
                throw Format.invalid("Scoped local publication root changed during callback.")
            }
            try archive.io.checkLease()
        }
        private func requireCurrentRoot() throws {
            try requireOpen()
            try requireRootWithoutCallback()
            try archive.check()
            try requireOpen()
            try requireRootWithoutCallback()
        }
        func object(expected: PeerPackage.Object) throws -> Data {
            try requireOpen()
            guard !busy else {
                failed = true
                throw Format.invalid("Untrusted local object reader cannot reenter.")
            }
            busy = true
            var succeeded = false
            defer {
                busy = false
                if !succeeded { failed = true }
            }
            try expected.validate()
            guard expected.kind == .authority, expected.part == nil else {
                throw Format.invalid("Local publication reader requires an exact authority descriptor.")
            }
            try requireCurrentRoot()
            let bytes: Data
            if expected.id == handle.binding.recordID {
                bytes = try archive.currentRootBytes()
            } else {
                bytes = try archive.io.read(["parts", expected.id])
                _ = try archive.requireLocalPart(bytes, id: expected.id, root: root)
            }
            guard bytes.count == expected.length, AuthorityRecordCodec.sha256(bytes) == expected.sha256 else {
                throw Format.invalid("Local publication original differs from its expected descriptor.")
            }
            try requireCurrentRoot()
            succeeded = true
            return bytes
        }
        fileprivate func finish() throws {
            try requireOpen()
            guard !busy else { throw Format.invalid("Untrusted local reader is still in use.") }
            busy = true
            defer { busy = false }
            try requireCurrentRoot()
            try archive.io.recountForReadCompletion()
            // No progress callback runs after the final inventory. A callback cannot append
            // unaccounted unknown files after the successful scope's last census.
            try requireRootWithoutCallback()
        }
    }
    /// Read-only per-instance work evidence; no validation/capacity bypass or global hook.
    var inventoryRecountsForTesting: Int { io.inventoryRecounts }

    private func requireLocalPart(_ bytes: Data, id: String, root: Format.Record) throws -> Format.Record {
        let record = try Format.Codec.decode(bytes)
        guard record.kind != .atomicControl, record.recordID == id, record.controlID == root.recordID,
            record.storeID == root.storeID, record.originReplicaID == root.originReplicaID,
            record.itemValue.map?["actorPrincipal"] == root.itemValue.map?["actorPrincipal"],
            record.itemValue.map?["createdAt"] == root.itemValue.map?["createdAt"]
        else {
            throw Format.invalid("Local publication part differs from its reserved root context.")
        }
        return record
    }

    func validate(_ handle: Handle, window: Window = .init()) throws -> Structure {
        let reader = try beginValidation(handle)
        do {
            while true {
                if let result = try reader.step(window: window) {
                    try reader.close()
                    return result
                }
            }
        } catch {
            try? reader.close()
            throw error
        }
    }

    /// Full structure/count validation precedes callbacks. Facts remain untrusted for authority;
    /// future Store integration must stage semantic effects until its own complete atomic activation.
    func forEachEntry(_ handle: Handle, section: Section, _ body: (ItemValue) throws -> Void) throws {
        _ = try validate(handle)
        let reader = try Reader(archive: self, handle: handle)
        do {
            while try reader.replay(window: .init(), section: section, onEntry: body) == nil {}
            try reader.close()
        } catch {
            try? reader.close()
            throw error
        }
    }

    /// One structural pass. Prefix callbacks must not affect accepted/current/head/queue state.
    /// The result exists only after every part, entry, range and aggregate count is checked.
    func forEachUntrustedStagingFact(
        _ handle: Handle, _ body: (UntrustedStagingFact) throws -> Void
    ) throws -> Structure {
        let reader = try beginValidation(handle)
        do {
            while true {
                if let result = try reader.stageWindow(window: .init(), onUntrustedFact: body) {
                    try reader.close()
                    return result
                }
            }
        } catch {
            try? reader.close()
            throw error
        }
    }

    private func resource(_ text: String) -> TractandaError { .init("resourceLimit", text) }

    final class Reader {
        private let archive: AtomicAuthorityArchive
        private let handle: Handle
        private let root: Format.Record
        private let parentStream: Format.Stream
        private let effectStream: Format.Stream
        private let workID: String
        private var stack: [(Section, Format.Reference)] = []
        private var parentDecoder: AtomicAuthorityEntryStream.Decoder
        private var effectDecoder: AtomicAuthorityEntryStream.Decoder
        private var previousFound = false
        private var partCount: Int64 = 0
        private var partBytes: Int64 = 0
        private var lock: Int32?
        private var complete: Structure?
        private var failed = false
        private(set) var steps = 0
        private(set) var waitingForPart: AuthorityBinding?
        fileprivate init(archive: AtomicAuthorityArchive, handle: Handle) throws {
            self.archive = archive
            self.handle = handle
            lock = try archive.io.lock()
            do {
                let data = try archive.currentRootBytes()
                guard data.count == handle.encodedBytes,
                    AuthorityRecordCodec.sha256(data) == handle.binding.sha256
                else {
                    throw Format.invalid("Private archive root differs from its exact handle.")
                }
                let root = try Format.Codec.decode(data)
                guard root.kind == .atomicControl, root.recordID == handle.binding.recordID else {
                    throw Format.invalid("Expected logical root.")
                }
                self.root = root
                parentStream = try Format.Stream(value: root.payload["parents"]!, section: .parents)
                effectStream = try Format.Stream(value: root.payload["effects"]!, section: .effects)
                parentDecoder = try .init(
                    section: .parents, expectedBytes: UInt64(parentStream.byteCount),
                    expectedEntries: UInt64(parentStream.entryCount), expectedTargets: 0)
                effectDecoder = try .init(
                    section: .effects, expectedBytes: UInt64(effectStream.byteCount),
                    expectedEntries: UInt64(effectStream.entryCount),
                    expectedTargets: UInt64(effectStream.targetCount))
                workID = try UUID.makeVersion1().uuidString.lowercased()
                if let ref = effectStream.root { stack.append((.effects, ref)) }
                if let ref = parentStream.root { stack.append((.parents, ref)) }
                previousFound = try Format.bindings(root.payload["previous"]).isEmpty
            } catch {
                if let lock { archive.io.unlock(lock) }
                throw error
            }
        }
        /// Fresh root/custody check under this reader's already-held exclusive archive lease.
        /// Opening another archive lease while a Reader lives would correctly report busy.
        func recheckRoot() throws -> Data {
            guard lock != nil, !failed else { throw Format.invalid("Closed/failed atomic reader.") }
            try archive.check()
            let bytes = try archive.currentRootBytes()
            guard bytes.count == handle.encodedBytes,
                AuthorityRecordCodec.sha256(bytes) == handle.binding.sha256
            else { throw Format.invalid("Atomic root changed between work windows.") }
            return bytes
        }
        deinit { try? close() }
        /// Explicit windows limit work, not logical size or wall-clock lifetime. Partial results grant nothing.
        func step(window: Window) throws -> Structure? {
            try scan(window: window, section: nil, onEntry: { _ in })
        }
        /// May emit a valid prefix before a later invalid part/cancel. No completion or authority
        /// may be exposed until a nonnil Structure is returned and caller final checks succeed.
        func stageWindow(window: Window, onUntrustedFact: (UntrustedStagingFact) throws -> Void) throws
            -> Structure?
        {
            try scan(window: window, section: nil, onEntry: { _ in }, onUntrustedFact: onUntrustedFact)
        }
        /// Private intake only: retain the exact parser/stack prefix when the loader reports a
        /// declared object that has not arrived. No callback completion/authority is produced.
        func stageAvailableWindow(
            window: Window, onUntrustedFact: (UntrustedStagingFact) throws -> Void
        ) throws -> Structure? {
            try scan(
                window: window, section: nil, onEntry: { _ in },
                onUntrustedFact: onUntrustedFact, permitUnavailable: true)
        }
        fileprivate func replay(window: Window, section: Section, onEntry: (ItemValue) throws -> Void) throws
            -> Structure?
        {
            try scan(window: window, section: section, onEntry: onEntry)
        }
        private func scan(
            window: Window, section selected: Section?, onEntry: (ItemValue) throws -> Void,
            onUntrustedFact: (UntrustedStagingFact) throws -> Void = { _ in },
            permitUnavailable: Bool = false
        )
            throws -> Structure?
        {
            guard lock != nil, !failed, window.maximumParts > 0,
                window.maximumBytes >= Format.maximumEnvelopeBytes
            else { throw Format.invalid("Invalid or failed structural reader window.") }
            try archive.check()
            if let complete { return complete }
            var succeeded = false
            defer { if !succeeded { failed = true } }
            var count = 0
            var bytes = 0
            waitingForPart = nil
            while let (section, expected) = stack.last {
                try archive.check()
                if count == window.maximumParts || expected.encodedBytes > Int64(window.maximumBytes - bytes)
                {
                    break
                }
                let seen = ["read-work", workID, expected.binding.recordID]
                guard try archive.io.optional(seen) == nil else {
                    throw Format.invalid("Duplicated/cyclic atomic part.")
                }
                let data: Data
                do {
                    data = try archive.partBytes(expected)
                } catch let missing as PartUnavailable where permitUnavailable {
                    guard archive.canonicalPartLoader != nil, missing.binding == expected.binding else {
                        throw Format.invalid("Unavailable part does not match its exact declared reference.")
                    }
                    // No popped stack, seen marker, decoder input or totals change on this path.
                    waitingForPart = missing.binding
                    succeeded = true
                    return nil
                }
                stack.removeLast()
                try archive.io.put(Data([1]), at: seen)
                guard data.count == expected.encodedBytes,
                    AuthorityRecordCodec.sha256(data) == expected.binding.sha256
                else { throw Format.invalid("Atomic part bytes/digest differ.") }
                let record = try Format.Codec.decode(data)
                guard try record.reference() == expected, record.controlID == root.recordID,
                    record.storeID == root.storeID, record.originReplicaID == root.originReplicaID,
                    record.itemValue.map?["actorPrincipal"] == root.itemValue.map?["actorPrincipal"],
                    record.itemValue.map?["createdAt"] == root.itemValue.map?["createdAt"],
                    record.section == section
                else { throw Format.invalid("Atomic part root/issuer/section/range binding differs.") }
                partCount = try Format.sum(partCount, 1)
                partBytes = try Format.sum(partBytes, Int64(data.count))
                guard partCount <= archive.io.limits.maximumParts else {
                    throw archive.resource("Archive read part allowance exhausted.")
                }
                if record.kind == .atomicControlIndex {
                    let stream = section == .parents ? parentStream : effectStream
                    guard record.payload["totalLeaves"]?.integerValue == stream.leafCount else {
                        throw Format.invalid("Index uses another stream leaf count.")
                    }
                    for child in try AuthorityRecord.list(record.payload["children"]).reversed() {
                        stack.append((section, try .init(value: child)))
                    }
                } else {
                    guard record.kind == .atomicControlPart, case .bytes(let chunk)? = record.payload["bytes"]
                    else { throw Format.invalid("Expected leaf bytes.") }
                    if section == .parents {
                        guard expected.byteOffset == Int64(parentDecoder.receivedBytes) else {
                            throw Format.invalid("Parent byte coverage differs.")
                        }
                        let previous = try Format.bindings(root.payload["previous"]).first
                        var found = previousFound
                        try parentDecoder.append(chunk) { value in
                            let binding = try AuthorityBinding(value: value)
                            guard binding.recordID != root.recordID else {
                                throw Format.invalid("Logical control is its own PRE parent.")
                            }
                            if binding.recordID == previous?.recordID {
                                guard binding == previous else {
                                    throw Format.invalid("Previous local root digest differs.")
                                }
                                found = true
                            }
                            if selected == section { try onEntry(value) }
                            try onUntrustedFact(.init(section: section, value: value))
                        }
                        previousFound = found
                    } else {
                        guard expected.byteOffset == Int64(effectDecoder.receivedBytes) else {
                            throw Format.invalid("Effect byte coverage differs.")
                        }
                        try effectDecoder.append(chunk) { value in
                            if selected == section { try onEntry(value) }
                            try onUntrustedFact(.init(section: section, value: value))
                        }
                    }
                }
                count += 1
                bytes += data.count
            }
            steps += 1
            if stack.isEmpty {
                try parentDecoder.finish()
                try effectDecoder.finish()
                let current = try archive.currentRootBytes()
                guard current.count == handle.encodedBytes,
                    AuthorityRecordCodec.sha256(current) == handle.binding.sha256,
                    previousFound, root.payload["partCount"]?.integerValue == partCount,
                    root.payload["partBytes"]?.integerValue == partBytes
                else { throw Format.invalid("Atomic closure totals/previous/root changed.") }
                complete = Structure(
                    handle: handle, parts: partCount, encodedPartBytes: partBytes,
                    parentEntries: parentStream.entryCount, supportFacts: effectStream.entryCount,
                    targets: effectStream.targetCount)
            }
            succeeded = true
            return complete
        }
        func close() throws {
            guard let held = lock else { return }
            defer {
                archive.io.unlock(held)
                lock = nil
            }
            try archive.io.removeReadWork(workID)
        }

    }

    /// Existing caller-private artifact primitives enforce no-follow, ACL, owner, nlink, stamps and fsync.
    private final class Files {
        let root: URL
        let limits: Limits
        let helpers: DocumentContentFiles
        private let storageHooks: StorageHooks?
        private var footprint: UInt64 = 0
        private(set) var inventoryRecounts = 0
        private var heldLocks = Set<Int32>()
        private let identity: (UInt64, UInt64)
        init(
            root: URL, limits: Limits, availableBytes: (@Sendable () throws -> UInt64)?,
            storageHooks: StorageHooks?
        ) throws {
            self.storageHooks = storageHooks
            self.root = root
            self.limits = limits
            let fd = root.path.withCString { tractanda_open_private_directory($0) }
            guard fd >= 0 else {
                throw Format.invalid("Archive root is not caller-private/no-follow (POSIX \(errno)).")
            }
            defer { close(fd) }
            var s = stat()
            guard fstat(fd, &s) == 0 else { throw Format.invalid("Cannot inspect archive root.") }
            identity = (UInt64(truncatingIfNeeded: s.st_dev), UInt64(s.st_ino))
            helpers = DocumentContentFiles(
                root: root, ownerUID: tractanda_uid(), minimumFreeBytes: limits.minimumFreeBytes,
                availableBytes: availableBytes)
            try helpers.requireCapacity(0, at: root)
            try recount()
        }
        private func rootDescriptor() throws -> Int32 {
            let fd = root.path.withCString { tractanda_open_private_directory($0) }
            var s = stat()
            guard fd >= 0 else { throw Format.invalid("Archive root custody changed.") }
            guard fstat(fd, &s) == 0, UInt64(truncatingIfNeeded: s.st_dev) == identity.0,
                UInt64(s.st_ino) == identity.1
            else {
                close(fd)
                throw Format.invalid("Archive root was replaced.")
            }
            for lock in heldLocks {
                var held = stat()
                var named = stat()
                guard fstat(lock, &held) == 0,
                    fstatat(fd, ".archive.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                    held.st_dev == named.st_dev, held.st_ino == named.st_ino,
                    held.st_nlink == 1, named.st_nlink == 1,
                    held.st_uid == tractanda_uid(), named.st_uid == tractanda_uid(),
                    held.st_mode & 0o777 == 0o600, named.st_mode == held.st_mode
                else {
                    close(fd)
                    throw Format.invalid("Private archive lease path was replaced.")
                }
            }
            return fd
        }
        func checkLease() throws {
            let fd = try rootDescriptor()
            close(fd)
        }
        private func parent<T>(_ path: [String], _ body: (Int32, String) throws -> T) throws -> T {
            guard !path.isEmpty, path.count <= 12,
                path.allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
                })
            else { throw Format.invalid("Unsafe private archive path.") }
            let rootFD = try rootDescriptor()
            defer { close(rootFD) }
            let url = path.dropLast().reduce(root) { $0.appendingPathComponent($1) }
            // Validate every private descendant, not only the final parent.
            var current = root
            for name in path.dropLast() {
                current.appendPathComponent(name)
                let fd = current.path.withCString { tractanda_open_private_directory($0) }
                guard fd >= 0 else { throw FileMetadataError.posix(errno) }
                close(fd)
            }
            let held = url.path.withCString { tractanda_open_private_directory($0) }
            guard held >= 0 else { throw FileMetadataError.posix(errno) }
            defer { close(held) }
            let result = try body(held, path.last!)
            let named = url.path.withCString { tractanda_open_private_directory($0) }
            guard named >= 0 else { throw Format.invalid("Archive parent changed.") }
            defer { close(named) }
            var a = stat()
            var b = stat()
            guard fstat(held, &a) == 0, fstat(named, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino
            else { throw Format.invalid("Archive parent was replaced.") }
            let check = try rootDescriptor()
            close(check)
            return result
        }
        func forEachPartName(_ body: (String) throws -> Void) throws {
            try parent(["parts", ".enumerate"]) { fd, _ in
                try POSIXDirectory.withEntries(descriptor: fd) { name in
                    _ = try AuthorityRecord.persistentID(.text(name))
                    try body(name)
                    return true
                }
            }
        }
        func optional(_ path: [String]) throws -> Data? {
            try Task.checkCancellation()
            do {
                return try parent(path) { fd, name in
                    var pointer: UnsafeMutableRawPointer?
                    var count: UInt32 = 0
                    let result = name.withCString {
                        tractanda_capture_private_artifact_at(
                            fd, $0, &pointer, &count, UInt32(Format.maximumEnvelopeBytes))
                    }
                    if result == 1 { return nil }
                    guard result == 0, let pointer else {
                        throw Format.invalid("Archive artifact custody changed.")
                    }
                    defer { tractanda_private_free(pointer, count) }
                    var s = stat()
                    guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_mode & 0o777 == 0o400 else {
                        throw Format.invalid("Archive artifact must be sealed0400.")
                    }
                    return Data(bytes: pointer, count: Int(count))
                }
            } catch FileMetadataError.posix(let code) where code == ENOENT { return nil }
        }
        func read(_ path: [String]) throws -> Data {
            guard let data = try optional(path) else {
                throw TractandaError("missingDependencies", "Private atomic part is missing.")
            }
            return data
        }
        private func storageMutation<T>(
            _ operation: StorageMutation, path: [String],
            additional: UInt64, body: () throws -> T
        ) throws -> T {
            guard let storageHooks else { return try body() }
            let url = path.reduce(root) { $0.appendingPathComponent($1) }
            func stamp() throws -> FileMetadata? {
                do { return try FileMetadata.read(at: url) } catch FileMetadataError.posix(ENOENT) {
                    return nil
                }
            }
            let before = try stamp()
            let ticket = try storageHooks.begin(operation, path, additional)
            do {
                try checkLease()
                guard try stamp() == before else {
                    throw Format.invalid("Private mutation target changed after scope check.")
                }
                let result = try body()
                try storageHooks.finish(ticket, false)
                return result
            } catch {
                try? storageHooks.finish(ticket, true)
                throw error
            }
        }
        func put(_ data: Data, at path: [String]) throws {
            try Task.checkCancellation()
            if let old = try optional(path) {
                guard old == data else { throw Format.invalid("Immutable archive retry bytes differ.") }
                try helpers.synchronizeDirectory(Array(path.dropLast()))
                return
            }
            let cost = UInt64(data.count + 4096 * (path.count + 1))
            guard cost <= limits.maximumStoredBytes - min(footprint, limits.maximumStoredBytes) else {
                throw TractandaError("resourceLimit", "Private archive storage allowance exhausted.")
            }
            try storageMutation(.immutableWrite, path: path, additional: cost) {
                try helpers.requireCapacity(cost, at: root)
                footprint += cost
                try helpers.ensurePrivateDirectory(Array(path.dropLast()))
                try parent(path) { _, _ in
                    try PeerEnrollmentFiles.writeExact(
                        data, path: path.reduce(root) { $0.appendingPathComponent($1) }.path,
                        maximum: Format.maximumEnvelopeBytes)
                }
            }
        }
        func lock() throws -> Int32 {
            let old = try optionalLockMetadata()
            var acquired: Int32?
            do {
                return try storageMutation(.lease, path: [".archive.lock"], additional: old == nil ? 4096 : 0)
                {
                    let value = try acquireLock()
                    acquired = value
                    return value
                }
            } catch {
                if let acquired { unlock(acquired) }
                throw error
            }
        }
        private func optionalLockMetadata() throws -> FileMetadata? {
            do {
                return try FileMetadata.read(at: root.appendingPathComponent(".archive.lock"))
            } catch FileMetadataError.posix(ENOENT) { return nil }
        }
        private func acquireLock() throws -> Int32 {
            let fd = try rootDescriptor()
            defer { close(fd) }
            var prior = stat()
            if fstatat(fd, ".archive.lock", &prior, AT_SYMLINK_NOFOLLOW) < 0 {
                guard errno == ENOENT else { throw Format.invalid("Cannot inspect private archive lock.") }
                guard 4096 <= limits.maximumStoredBytes - min(footprint, limits.maximumStoredBytes) else {
                    throw TractandaError("resourceLimit", "Archive lock exceeds storage allowance.")
                }
                try helpers.requireCapacity(4096, at: root)
                footprint += 4096
            }
            let lock = openat(fd, ".archive.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw Format.invalid("Cannot open private archive lock.") }
            var s = stat()
            guard fstat(lock, &s) == 0, s.st_uid == tractanda_uid(), s.st_nlink == 1,
                s.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0
            else {
                close(lock)
                throw Format.invalid("Private archive is busy or unsafe.")
            }
            var pointer: UnsafeMutableRawPointer?
            var count: UInt32 = 0
            let checked = tractanda_capture_private_artifact_at(fd, ".archive.lock", &pointer, &count, 1)
            defer { if let pointer { tractanda_private_free(pointer, count) } }
            var held = stat()
            var named = stat()
            guard checked == 0, pointer != nil, count == 0, fstat(lock, &held) == 0,
                fstatat(fd, ".archive.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                held.st_dev == named.st_dev, held.st_ino == named.st_ino
            else {
                _ = flock(lock, LOCK_UN)
                close(lock)
                throw Format.invalid("Archive lock ACL/custody changed.")
            }
            heldLocks.insert(lock)
            do {
                // Reader validation also writes markers: all I/O uses one exclusive lease.
                // Never trust an instance's census from before another holder used the archive.
                try discardAbandonedReadWork()
                try recount()
                return lock
            } catch {
                unlock(lock)
                throw error
            }
        }
        func unlock(_ fd: Int32) {
            heldLocks.remove(fd)
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        func requireReadCapacity() throws {
            try checkLease()
            try helpers.requireCapacity(0, at: root)
            try checkLease()
        }
        func recountForReadCompletion() throws {
            try recount()
            try requireReadCapacity()
        }
        private func recount() throws {
            inventoryRecounts += 1
            let fd = try rootDescriptor()
            defer { close(fd) }
            var total: UInt64 = 4096
            func visit(_ fd: Int32, depth: Int) throws {
                guard depth <= 12 else { throw Format.invalid("Private archive depth exceeded.") }
                try POSIXDirectory.withEntries(descriptor: fd) { name in
                    try Task.checkCancellation()
                    var s = stat()
                    guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_uid == tractanda_uid(),
                        s.st_mode & 0o077 == 0
                    else { throw Format.invalid("Unsafe archive inventory.") }
                    let cost = UInt64(max(0, s.st_size)) + 4096
                    guard cost <= limits.maximumStoredBytes - min(total, limits.maximumStoredBytes) else {
                        throw TractandaError("resourceLimit", "Existing archive exceeds storage allowance.")
                    }
                    total += cost
                    if s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw Format.invalid("Unsafe archive directory.") }
                        defer { close(child) }
                        try visit(child, depth: depth + 1)
                    } else {
                        guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1 else {
                            throw Format.invalid("Linked/special archive inventory entry.")
                        }
                    }
                    return true
                }
            }
            try visit(fd, depth: 0)
            footprint = total
        }
        private var cleanupBudget: Int64 {
            let value = limits.maximumParts.multipliedReportingOverflow(by: 2)
            return value.overflow ? Int64.max : value.partialValue
        }
        private func discardAbandonedReadWork() throws {
            var remaining = cleanupBudget
            do {
                try parent(["read-work", "scan"]) { fd, _ in
                    try POSIXDirectory.withEntries(descriptor: fd) { id in
                        _ = try AuthorityRecord.persistentID(.text(id))
                        try removeReadWork(id, remaining: &remaining, refresh: false)
                        return true
                    }
                }
            } catch FileMetadataError.posix(let code) where code == ENOENT { return }
        }
        func removeReadWork(_ id: String) throws {
            var remaining = cleanupBudget
            try removeReadWork(id, remaining: &remaining, refresh: true)
        }
        private func removeReadWork(_ id: String, remaining: inout Int64, refresh: Bool) throws {
            _ = try AuthorityRecord.persistentID(.text(id))
            do {
                try parent(["read-work", id]) { fd, name in
                    var s = stat()
                    if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT { return }
                    guard s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), s.st_uid == tractanda_uid(),
                        s.st_mode & 0o077 == 0
                    else { throw Format.invalid("Unsafe abandoned reader directory.") }
                    guard remaining > 0 else {
                        throw TractandaError("resourceLimit", "Bounded reader cleanup remains incomplete.")
                    }
                    remaining -= 1
                    let path = root.appendingPathComponent("read-work").appendingPathComponent(id).path
                    let child = path.withCString { tractanda_open_private_directory($0) }
                    guard child >= 0 else { throw Format.invalid("Cannot open private reader work.") }
                    defer { close(child) }
                    var held = stat()
                    guard fstat(child, &held) == 0, held.st_dev == s.st_dev, held.st_ino == s.st_ino else {
                        throw Format.invalid("Reader scratch directory was replaced.")
                    }
                    try POSIXDirectory.withEntries(descriptor: child) { marker in
                        guard remaining > 0 else {
                            throw TractandaError(
                                "resourceLimit", "Bounded reader cleanup remains incomplete.")
                        }
                        remaining -= 1
                        let temporary = marker.hasPrefix(".peer-artifact-") && marker.hasSuffix(".tmp")
                        if temporary {
                            let text = String(marker.dropFirst(".peer-artifact-".count).dropLast(4))
                            guard UUID(uuidString: text)?.uuidString == text else {
                                throw Format.invalid("Unknown reader scratch file.")
                            }
                        } else {
                            _ = try AuthorityRecord.persistentID(.text(marker))
                        }
                        var pointer: UnsafeMutableRawPointer?
                        var count: UInt32 = 0
                        let result = marker.withCString {
                            tractanda_capture_private_artifact_at(child, $0, &pointer, &count, 1)
                        }
                        defer { if let pointer { tractanda_private_free(pointer, count) } }
                        guard result == 0, let pointer,
                            count == 1 ? pointer.load(as: UInt8.self) == 1 : (temporary && count == 0)
                        else { throw Format.invalid("Unknown reader marker bytes/custody.") }
                        try storageMutation(.removeFile, path: ["read-work", id, marker], additional: 0) {
                            guard unlinkat(child, marker, 0) == 0 else {
                                throw Format.invalid("Cannot remove private reader marker.")
                            }
                        }
                        return true
                    }
                    try storageMutation(.removeDirectory, path: ["read-work", id], additional: 0) {
                        guard fsync(child) == 0, unlinkat(fd, name, AT_REMOVEDIR) == 0, fsync(fd) == 0 else {
                            throw Format.invalid("Cannot synchronize reader-work cleanup.")
                        }
                    }
                }
                if refresh { try recount() }
            } catch FileMetadataError.posix(let code) where code == ENOENT { return }
        }
    }
}
