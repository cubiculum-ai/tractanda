import CSQLite
import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Native window driver for physical preparation only. Completion accepts no control or target.
/// The caller owns writer custody, current rights and subsequent whole-root semantic validation.
final class PeerAtomicIntakePreparation {
    private enum Phase: Equatable {
        case preflight, closure, verifyOriginals, verifyDocuments, seal
        case publishOriginals, publishDocuments, retain, complete
    }
    private let coordinator: PeerIntakeCoordinator
    private let index: ItemIndex
    private let scratch: ItemIndex
    private let storage: Storage
    private let context: PeerPackage.Context
    private let packageID: String
    private let contextToken: String
    private let retainedRecovery: Bool
    private let beforeSeal: () throws -> Void
    private let begin: PeerIntakeJournal.Begin
    private let owner: String
    private let token: String
    private var publication: PeerIntakeJournal.Publication?
    private var phase = Phase.preflight
    private var metadataCursor: PeerPackage.ResumeCursor?
    private var retentionCursor: PeerPackage.ResumeCursor?
    private var originalAfter = ""
    private var documentAfter = ""
    private var unsupportedLocalHold = false
    private var closed = false

    init(
        coordinator: PeerIntakeCoordinator, index: ItemIndex, privateRoot: URL,
        context: PeerPackage.Context, packageID: String, contextToken: String,
        retainedRecovery: Bool = false, beforeSeal: @escaping () throws -> Void
    ) throws {
        _ = try AuthorityRecord.persistentID(.text(packageID))
        _ = try AuthorityRecord.text(.text(contextToken))
        let scratchLimit = min(
            index.graphMaximumTemporaryBytes, coordinator.journal.limits.maximumStagedBytes)
        // The database cap leaves two database sizes plus headers for rollback journaling.
        // This is an implementation allocation bound, not a package count limit.
        guard scratchLimit >= 4 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Private preparation storage allowance is too small.")
        }
        guard context.storeID == coordinator.storeID, coordinator.journal.limits.reserveBytes >= 0 else {
            throw TractandaError("invalidPeerPackage", "Preparation store or storage reserve differs.")
        }
        let captured = try coordinator.withOperation {
            if !retainedRecovery { try coordinator.requireIntakeCurrent(context, packageID: packageID) }
            let begin = try coordinator.journal.beginRecord(
                packageID, readBudget: coordinator.admissionReadBudget())
            let sealed = try coordinator.journal.publication(
                packageID, readBudget: coordinator.admissionReadBudget())
            let manifestDigest = AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
            guard begin.context == context, begin.manifest.storeID == coordinator.storeID,
                sealed.map({
                    $0.context == context && $0.packageID == packageID
                        && $0.manifestDigest == manifestDigest
                }) ?? !retainedRecovery
            else {
                throw TractandaError(
                    "invalidPeerPackage", "Preparation changed its exact journal/context/seal binding.")
            }
            if !retainedRecovery { try coordinator.journal.requireCurrentProfile(packageID) }
            return (begin, sealed)
        }
        let owner = try UUID.makeVersion1().uuidString.lowercased() + ":intake"
        let token = "atomic-preparation:" + (try UUID.makeVersion1().uuidString.lowercased())
        let storage = try Storage(
            root: privateRoot, reserveBytes: coordinator.journal.limits.reserveBytes,
            maximumBytes: scratchLimit)
        let scratch: ItemIndex
        do {
            scratch = try ItemIndex(
                path: privateRoot.appendingPathComponent("preparation.sqlite").path, create: true,
                noFollow: true, journalMode: .delete)
            do {
                try storage.check()
                scratch.graphReserveBytes = max(
                    index.graphReserveBytes, UInt64(coordinator.journal.limits.reserveBytes))
                scratch.graphMaximumTemporaryBytes = index.graphMaximumTemporaryBytes
                scratch.graphMaximumVMInstructions = index.graphMaximumVMInstructions
                // All descriptor rows live in MAIN. Indexed bounded queries need no TEMP
                // relation or automatic-index builder; no SQLite workfile can escape the root.
                try scratch.execute("PRAGMA temp_store=MEMORY")
                try scratch.execute("PRAGMA automatic_index=OFF")
                try scratch.execute("PRAGMA cache_size=-256")
                try scratch.execute("PRAGMA journal_mode=DELETE")
                try scratch.execute("PRAGMA synchronous=FULL")
                try scratch.execute("PRAGMA journal_size_limit=0")
                guard try Self.pragmaText(scratch, "journal_mode") == "delete",
                    try Self.pragmaText(scratch, "temp_store") == "2",
                    try Self.pragmaText(scratch, "automatic_index") == "0",
                    let pageSize = UInt64(try Self.pragmaText(scratch, "page_size")),
                    (512...65536).contains(pageSize)
                else { throw TractandaError("resourceLimit", "Private SQLite backing could not be bounded.") }
                let pageLimit = storage.databaseLimit / pageSize
                try scratch.execute("PRAGMA main.max_page_count=\(pageLimit)")
                guard let actualLimit = UInt64(try Self.pragmaText(scratch, "max_page_count")),
                    actualLimit <= pageLimit
                else { throw TractandaError("resourceLimit", "Private database exceeds its allocation cap.") }
                try storage.requireDeleteJournal()
                try index.withCatalogueScanBudget(reusingActiveBudget: true) {
                    try scratch.withBorrowedAtomicPreparationBudget(from: index) {
                        try scratch.initializeAuthoritySchema()
                        try scratch.peerOriginalBegin(storage: .privateDatabase)
                        try scratch.authorityBeginWalk(token: token)
                    }
                }
                try storage.check()
            } catch {
                scratch.close()
                throw error
            }
        } catch {
            try? storage.removeOwnedFiles()
            throw error
        }
        self.coordinator = coordinator
        self.index = index
        self.scratch = scratch
        self.storage = storage
        self.context = context
        self.packageID = packageID
        self.contextToken = contextToken
        self.retainedRecovery = retainedRecovery
        self.beforeSeal = beforeSeal
        begin = captured.0
        publication = captured.1
        self.owner = owner
        self.token = token
    }
    deinit { try? close() }

    private static func pragmaText(_ database: ItemIndex, _ name: String) throws -> String {
        let statement = try database.corpusPrepare("PRAGMA " + name, [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let bytes = sqlite3_column_text(statement, 0)
        else { throw TractandaError("resourceLimit", "Cannot verify private SQLite configuration.") }
        return String(cString: bytes)
    }
    private func check() throws {
        try Task.checkCancellation()
        try storage.check()
        try coordinator.progress?()
        if !retainedRecovery { try coordinator.requireIntakeCurrent(context, packageID: packageID) }
        guard
            try coordinator.journal.beginRecord(packageID, readBudget: coordinator.admissionReadBudget())
                == begin
        else {
            throw TractandaError("peerObjectCollision", "Preparation immutable begin changed.")
        }
        if let publication {
            guard
                try coordinator.journal.publication(packageID, readBudget: coordinator.admissionReadBudget())
                    == publication
            else {
                throw TractandaError("peerRepairRequired", "Preparation lost its exact physical publication.")
            }
        }
    }
    private func privateWork<T>(_ body: () throws -> T) throws -> T {
        try scratch.withBorrowedAtomicPreparationBudget(from: index) {
            try storage.check()
            guard try Self.pragmaText(scratch, "journal_mode") == "delete" else {
                throw TractandaError("storeBusy", "Private SQLite journal mode changed.")
            }
            return try body()
        }
    }
    /// Cursor publication follows SQL release; fixed cleanup bypasses a failed scan callback.
    private func window<T>(on database: ItemIndex, _ body: () throws -> T) throws -> T {
        let saved = database.captureAuthorityPeerGraphState()
        try database.execute("SAVEPOINT peer_inventory_retain")
        do {
            let result = try body()
            try database.execute("RELEASE peer_inventory_retain")
            return result
        } catch {
            let original = error
            do {
                try database.rollbackPeerInventoryRetain()
                database.restoreAuthorityPeerGraphState(saved)
            } catch {
                throw TractandaError(
                    "recoveryRequired", "Preparation SQL rollback failed; retain recovery state.")
            }
            throw original
        }
    }
    private func objectBytes(_ object: PeerPackage.Object) throws -> Data {
        let data =
            try coordinator.journal.object(
                object, packageID: packageID, readBudget: coordinator.admissionReadBudget())
            ?? index.retainedAuthorityObject(id: object.id).map { try coordinator.bytes($0) }
        guard let data else {
            throw TractandaError("missingDependencies", "Preparation original transfer is incomplete.")
        }
        guard data.count == object.length, AuthorityRecordCodec.sha256(data) == object.sha256 else {
            throw TractandaError(
                "peerObjectCollision", "Preparation original differs from its exact descriptor.")
        }
        return data
    }
    private func visit(_ object: PeerPackage.Object) throws {
        try coordinator.requireStorageIdentity(object, index: index)
        guard try scratch.authorityVisitOnce(token: token, id: object.id) else {
            throw TractandaError("invalidPeerPackage", "Repeated all-kind identity in package preparation.")
        }
    }
    private func preflight(_ object: PeerPackage.Object) throws {
        try visit(object)
        switch object.kind {
        case .index: throw TractandaError("invalidPeerPackage", "Index object cannot be a metadata leaf.")
        case .attachment: try scratch.peerOriginalPresent(object)
        case .document:
            try scratch.peerDocumentPresent(object)
            try coordinator.journal.admitDocumentAnchor(packageID: packageID, object: object)
        case .item, .authority:
            let data = try objectBytes(object)
            if let known = try index.retainedAuthorityObject(id: object.id) {
                guard known.descriptor == object, try coordinator.bytes(known) == data else {
                    throw TractandaError(
                        "peerObjectCollision", "Preparation collides with a retained original.")
                }
                try coordinator.requireRetainedReceipt(known, original: data, index: index)
            } else if object.kind == .item, let known = try index.revision(object.id) {
                try coordinator.admissionReadBudget()(object.length)
                _ = try PooledCanonicalRecord.read(
                    row: known, root: coordinator.root, ownerUID: coordinator.ownerUID)
                guard known.digest == Data(SHA256.hash(data: data)) else {
                    throw TractandaError("peerObjectCollision", "Preparation collides with accepted history.")
                }
            }
            if object.kind == .item {
                let node = try AuthorityRevision(originalBytes: data)
                guard node.revision.revisionID == object.id else {
                    throw TractandaError("invalidPeerPackage", "Preparation item identity differs.")
                }
                try ItemSemantics.validate(node.revision)
                try scratch.peerOriginalRegister(node.revision)
            } else {
                let original = try CanonicalAuthorityOriginal(data)
                guard original.recordID == object.id, original.storeID == context.storeID else {
                    throw TractandaError("invalidAuthority", "Preparation authority identity/store differs.")
                }
                if case .atomic = original.payload { try coordinator.requireAtomicCanonicalActivation() }
            }
        }
    }
    private func metadataStep() throws {
        let page = try privateWork {
            try window(on: scratch) {
                let page = try coordinator.journal.atomicMetadataPage(
                    context: context, packageID: packageID, cursor: metadataCursor, limit: 1,
                    readBudget: coordinator.admissionReadBudget(), visitIndex: visit)
                for object in page.objects { try preflight(object) }
                return page
            }
        }
        metadataCursor = page.next
        if page.next == nil { phase = .closure }
    }
    private func originalStep(publish: Bool) throws -> Bool {
        guard
            let row = try privateWork({ try scratch.peerOriginalPage(after: originalAfter, limit: 1).first })
        else {
            originalAfter = ""
            phase = publish ? .publishDocuments : .verifyDocuments
            return true
        }
        guard let originals = coordinator.journal.originals else {
            throw TractandaError(
                "missingDependencies", "Preparation original streaming bridge is unavailable.")
        }
        try coordinator.withAtomicPreparationReadBudget { budget in
            try originals.requireComplete(
                packageID: packageID, object: row.object, descriptor: row.descriptor,
                progress: coordinator.progress, budget: budget)
            if publish {
                try originals.publish(
                    packageID: packageID, object: row.object, descriptor: row.descriptor, budget: budget)
            }
        }
        originalAfter = row.object.id
        return true
    }
    private func documentStep(publish: Bool, maximumUnits: Int) throws -> Bool {
        guard
            let row = try privateWork({ try scratch.peerDocumentPage(after: documentAfter, limit: 1).first })
        else {
            documentAfter = ""
            phase = publish ? .retain : .seal
            return true
        }
        if row.document.content != nil {
            guard let transfer = coordinator.journal.documents,
                let verification = coordinator.documentVerification
            else {
                throw TractandaError(
                    "missingDependencies", "Preparation document verification is unavailable.")
            }
            let complete = try coordinator.withAtomicPreparationReadBudget { budget in
                // Persistent verification/corpus owners belong to MAIN for GC/custody continuity.
                try verification.step(
                    scope: "intake:" + packageID, document: row.document,
                    source: .incoming(packageID: packageID, transfer: transfer), index: index,
                    budget: budget, maximumUnits: maximumUnits, publish: publish,
                    beforePublication: {
                        if !self.retainedRecovery {
                            try self.coordinator.requireIntakeCurrent(self.context, packageID: self.packageID)
                        }
                    })
            }
            guard complete else { return false }
        }
        documentAfter = row.document.representationID
        return true
    }
    private func seal() throws {
        try beforeSeal()
        try check()
        if publication == nil {
            let prepared =
                try coordinator.journal.preparedPublication(packageID)
                ?? .init(
                    packageID: packageID,
                    manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest)),
                    context: context, contextToken: contextToken,
                    arrivalMinute: PeerIntakeJournal.currentArrivalMinute())
            guard prepared.context == context, prepared.packageID == packageID,
                prepared.manifestDigest == AuthorityRecordCodec.sha256(try JSON.encode(begin.manifest))
            else {
                throw TractandaError("peerObjectCollision", "Preparation frozen publication differs.")
            }
            try coordinator.journal.prepare(prepared)
            try coordinator.journal.seal(packageID)
            guard try coordinator.journal.publication(packageID) == prepared else {
                throw TractandaError("peerRepairRequired", "Preparation physical seal could not be reopened.")
            }
            publication = prepared
        }
        phase = .publishOriginals
    }
    private func retainStep() throws {
        guard let publication else {
            throw TractandaError("invalidPeerPackage", "Preparation raw retention lacks a physical seal.")
        }
        var unsupported = false
        let page = try window(on: index) {
            let page = try coordinator.journal.atomicMetadataPage(
                context: context, packageID: packageID,
                cursor: retentionCursor, limit: 1, readBudget: coordinator.admissionReadBudget())
            for object in page.objects where object.kind == .item || object.kind == .authority {
                unsupported =
                    try coordinator.retainSealedOriginal(
                        object, data: objectBytes(object), publication: publication,
                        index: index, applyAssessment: false, allowReviewClosure: true,
                        recovering: retainedRecovery) || unsupported
            }
            return page
        }
        retentionCursor = page.next
        unsupportedLocalHold = unsupportedLocalHold || unsupported
        if page.next == nil {
            guard !unsupportedLocalHold else {
                throw TractandaError(
                    "unsupportedAuthorityReviewHold",
                    "Raw local hold originals require historical source validation.")
            }
            phase = .complete
        }
    }
    func step(maximumObjects: Int = 16) throws -> Bool {
        guard !closed, (1...128).contains(maximumObjects) else {
            throw TractandaError("invalidArguments", "Closed preparation or invalid work window.")
        }
        defer { coordinator.journal.invalidateStageAccounting(packageID: packageID) }
        return try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try coordinator.withOperation(recovery: retainedRecovery) {
                let body = {
                    try self.check()
                    for _ in 0..<maximumObjects {
                        guard try self.index.atomicPrivateWindowHasRoom(minimumVMInstructions: 4096) else {
                            return false
                        }
                        do {
                            try self.check()
                            switch self.phase {
                            case .preflight: try self.metadataStep()
                            case .closure:
                                try self.privateWork { try self.scratch.peerOriginalValidateClosure() }
                                self.phase = .verifyOriginals
                            case .verifyOriginals: if try !self.originalStep(publish: false) { return false }
                            case .verifyDocuments:
                                if try !self.documentStep(publish: false, maximumUnits: maximumObjects) {
                                    return false
                                }
                            case .seal: try self.seal()
                            case .publishOriginals: if try !self.originalStep(publish: true) { return false }
                            case .publishDocuments:
                                if try !self.documentStep(publish: true, maximumUnits: maximumObjects) {
                                    return false
                                }
                            case .retain: try self.retainStep()
                            case .complete:
                                try self.check()
                                return true
                            }
                        } catch let error as TractandaError
                            where ["peerPayloadVerifying", "peerVerificationBusy"].contains(error.code)
                        {
                            return false
                        }
                        try self.storage.check()
                    }
                    if self.phase == .complete { try self.check() }
                    return self.phase == .complete
                }
                if let originals = self.coordinator.journal.originals {
                    return try originals.withLogicalVerificationOwner(self.owner, body)
                }
                return try body()
            }
        }
    }
    func close() throws {
        guard !closed else { return }
        try scratch.closeChecked()
        coordinator.journal.originals?.releaseLogicalVerification(owner)
        coordinator.documentVerification?.releaseLogicalVerification(owner)
        try storage.removeOwnedFiles()
        closed = true
    }

    /// Fresh private roots only. Orphan restart roots are a caller recovery/cleanup decision.
    private final class Storage {
        let root: URL
        let directory: Int32
        let file: Int32
        private let rootIdentity: (dev_t, ino_t)
        private let fileIdentity: (dev_t, ino_t)
        let databaseLimit: UInt64
        private let maximumBytes: UInt64
        private let reserveBytes: Int64
        private var deleteJournal = false
        private var sidecars: [String: (dev_t, ino_t)] = [:]
        private static let names = [
            "preparation.sqlite-journal", "preparation.sqlite-wal", "preparation.sqlite-shm",
        ]
        init(root: URL, reserveBytes: Int64, maximumBytes: UInt64) throws {
            self.root = root
            self.reserveBytes = reserveBytes
            self.maximumBytes = maximumBytes
            databaseLimit = (maximumBytes - 64 * 1024) / 3
            directory = root.path.withCString { tractanda_open_private_directory($0) }
            guard directory >= 0 else {
                throw TractandaError("storeBusy", "Preparation root is not caller-private/no-follow.")
            }
            var rootStat = stat()
            guard fstat(directory, &rootStat) == 0 else {
                tractanda_close(directory)
                throw FileMetadataError.posix(errno)
            }
            rootIdentity = (rootStat.st_dev, rootStat.st_ino)
            do {
                try DocumentContentFiles(
                    root: root, ownerUID: tractanda_uid(), minimumFreeBytes: reserveBytes
                ).requireCapacity(4 * 1024 * 1024, at: root)
                for name in ["preparation.sqlite"] + Self.names {
                    var s = stat()
                    guard fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else {
                        throw TractandaError(
                            "storeBusy",
                            "Use a fresh preparation root; existing private files were preserved.")
                    }
                }
            } catch {
                tractanda_close(directory)
                throw error
            }
            file = openat(
                directory, "preparation.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else {
                tractanda_close(directory)
                throw FileMetadataError.posix(errno)
            }
            var s = stat()
            guard fstat(file, &s) == 0 else {
                tractanda_close(file)
                tractanda_close(directory)
                throw FileMetadataError.posix(errno)
            }
            fileIdentity = (s.st_dev, s.st_ino)
        }
        deinit {
            tractanda_close(file)
            tractanda_close(directory)
        }
        func requireDeleteJournal() throws {
            deleteJournal = true
            try check()
        }
        private func allocated(_ value: stat) throws -> UInt64 {
            guard value.st_size >= 0, value.st_blocks >= 0 else {
                throw TractandaError("resourceLimit", "Cannot measure private SQLite allocation.")
            }
            let blocks = UInt64(value.st_blocks).multipliedReportingOverflow(by: 512)
            guard !blocks.overflow else {
                throw TractandaError("resourceLimit", "Private allocation overflow.")
            }
            return max(UInt64(value.st_size), blocks.partialValue)
        }
        func check(recordNewSidecars: Bool = true, enforceCapacity: Bool = true) throws {
            let named = root.path.withCString { tractanda_open_private_directory($0) }
            guard named >= 0 else { throw TractandaError("storeBusy", "Preparation root custody changed.") }
            defer { tractanda_close(named) }
            var r = stat()
            var f = stat()
            var held = stat()
            guard fstat(named, &r) == 0, r.st_dev == rootIdentity.0, r.st_ino == rootIdentity.1,
                fstat(file, &held) == 0,
                fstatat(directory, "preparation.sqlite", &f, AT_SYMLINK_NOFOLLOW) == 0,
                held.st_dev == fileIdentity.0, held.st_ino == fileIdentity.1,
                f.st_dev == held.st_dev, f.st_ino == held.st_ino,
                f.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), f.st_mode & 0o7777 == 0o600,
                f.st_uid == tractanda_uid(), f.st_nlink == 1,
                tractanda_peer_configuration_no_mutation_acl(file) == 0
            else { throw TractandaError("storeBusy", "Preparation scratch database custody changed.") }
            var total = try allocated(f)
            if enforceCapacity, deleteJournal, UInt64(f.st_size) > databaseLimit {
                throw TractandaError("resourceLimit", "Private database exceeded its page allocation cap.")
            }
            for name in Self.names {
                var s = stat()
                if fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT {
                    sidecars.removeValue(forKey: name)
                    continue
                }
                guard !deleteJournal || name == "preparation.sqlite-journal" else {
                    throw TractandaError("storeBusy", "Unexpected private SQLite WAL files were preserved.")
                }
                let bytes = try allocated(s)
                guard !enforceCapacity || bytes <= maximumBytes - min(total, maximumBytes) else {
                    throw TractandaError(
                        "resourceLimit", "Combined private SQLite allocation exceeded its cap.")
                }
                let combined = total.addingReportingOverflow(bytes)
                guard !combined.overflow else {
                    throw TractandaError("resourceLimit", "Combined private allocation overflow.")
                }
                total = combined.partialValue
                guard recordNewSidecars || sidecars[name] != nil else {
                    throw TractandaError("storeBusy", "Unobserved preparation sidecar was preserved.")
                }
                let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw TractandaError("storeBusy", "Preparation sidecar is unsafe.") }
                defer { tractanda_close(fd) }
                var held = stat()
                guard fstat(fd, &held) == 0, held.st_dev == s.st_dev, held.st_ino == s.st_ino,
                    s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_mode & 0o7777 == 0o600,
                    s.st_uid == tractanda_uid(), s.st_nlink == 1,
                    tractanda_peer_configuration_no_mutation_acl(fd) == 0,
                    sidecars[name].map({ $0.0 == s.st_dev && $0.1 == s.st_ino }) ?? true
                else { throw TractandaError("storeBusy", "Preparation sidecar custody changed.") }
                sidecars[name] = (s.st_dev, s.st_ino)
            }
            if enforceCapacity {
                guard total <= maximumBytes else {
                    throw TractandaError("resourceLimit", "Private SQLite allocation exceeded its cap.")
                }
                // A rollback can journal every capped database page. Leave one extra whole
                // page per page plus fixed header room, even before a write begins.
                try DocumentContentFiles(
                    root: root, ownerUID: tractanda_uid(), minimumFreeBytes: reserveBytes
                ).requireCapacity(databaseLimit * 2 + 64 * 1024, at: root)
            }
        }
        func removeOwnedFiles() throws {
            try check(recordNewSidecars: false, enforceCapacity: false)
            for name in Self.names {
                var s = stat()
                if fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT { continue }
                guard let original = sidecars[name], original.0 == s.st_dev, original.1 == s.st_ino,
                    unlinkat(directory, name, 0) == 0
                else { throw TractandaError("storeBusy", "Preparation sidecar replacement was preserved.") }
            }
            guard unlinkat(directory, "preparation.sqlite", 0) == 0, fsync(directory) == 0 else {
                throw TractandaError("writeFailed", "Cannot synchronize owned preparation cleanup.")
            }
        }
    }
}
