import CSQLite
import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Read-only admission of the current personal/workgroup derived index. Canonical files
/// remain authoritative; this never repairs rows or refreshes dates during ordinary opening.
enum PersonalIndexCheckpoint {
    static let key = "personalCheckpointBindingV1"

    static func binding(profile: PersonalWorkgroupProfile.Record) throws -> String {
        return try ItemIndex.graphValueDigest(
            .object([
                "profile": .text(profile.profile), "merge": .text(RevisionMerge.personalProfile),
                "store": .text(profile.storeID), "replica": .text(profile.replicaID),
            ]))
    }

    /// Ordinary projections cover raw catalogue items. The historical authority checkpoint
    /// instead uses recovery_roots and retirement barriers, which this profile never maintains.
    static func hasCompleteProjection(_ index: ItemIndex) throws -> Bool {
        for sql in [
            "SELECT 1 FROM current_projection WHERE dirty=1 LIMIT 1",
            "SELECT 1 FROM revision_catalog r LEFT JOIN current_projection c ON c.item=r.item WHERE c.item IS NULL LIMIT 1",
            "SELECT 1 FROM current_projection c WHERE NOT EXISTS(SELECT 1 FROM revision_catalog r WHERE r.item=c.item) LIMIT 1",
            "SELECT 1 FROM current_projection c LEFT JOIN items i ON i.id=c.item WHERE c.status='ready' AND (i.id IS NULL OR c.policies_complete=0) LIMIT 1",
            "SELECT 1 FROM items i LEFT JOIN current_projection c ON c.item=i.id WHERE c.item IS NULL OR c.status!='ready' LIMIT 1",
            "SELECT 1 FROM head_summaries h LEFT JOIN current_projection c ON c.item=h.item_id WHERE c.item IS NULL OR c.status!='ready' LIMIT 1",
            "SELECT 1 FROM current_projection c WHERE (SELECT COUNT(*) FROM current_policy p WHERE p.item=c.item)!=1 LIMIT 1",
            "SELECT 1 FROM current_policy p LEFT JOIN revision_catalog r ON r.item=p.item AND r.revision=p.revision WHERE r.revision IS NULL LIMIT 1",
            "SELECT 1 FROM current_policy p LEFT JOIN projection_acl a ON a.item=p.item AND a.revision=p.revision WHERE p.permissions!='' AND a.item IS NULL LIMIT 1",
        ] {
            let statement = try index.corpusPrepare(sql)
            defer { sqlite3_finalize(statement) }
            let status = index.catalogueStep(statement)
            try index.checkCatalogueScanProgress()
            guard status == SQLITE_DONE else {
                let primary = status & 0xff
                if [SQLITE_NOMEM, SQLITE_FULL, SQLITE_TOOBIG].contains(primary) {
                    throw TractandaError(
                        "indexResource", "Personal checkpoint completeness exceeded resources.")
                }
                if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(primary) {
                    throw TractandaError(
                        "indexTransient", "Personal checkpoint completeness was interrupted.")
                }
                return false
            }
        }
        var cursor: String?
        while true {
            let items = try index.personalItemIDs(after: cursor, limit: 128)
            if items.isEmpty { break }
            for id in items {
                try Task.checkCancellation()
                guard let projection = try index.currentProjection(itemID: id), projection.state.itemID == id
                else { return false }
                let shape = try index.corpusPrepare(
                    "SELECT c.status,i.revision,h.revision,EXISTS(SELECT 1 FROM acl_core a WHERE a.item_id=c.item),EXISTS(SELECT 1 FROM current_policy p JOIN projection_acl a ON a.item=p.item AND a.revision=p.revision WHERE p.item=c.item) FROM current_projection c LEFT JOIN items i ON i.id=c.item LEFT JOIN head_summaries h ON h.item_id=c.item WHERE c.item=?",
                    [id])
                defer { sqlite3_finalize(shape) }
                let shapeStatus = index.catalogueStep(shape)
                try index.checkCatalogueScanProgress()
                if [SQLITE_NOMEM, SQLITE_FULL, SQLITE_TOOBIG].contains(shapeStatus & 0xff) {
                    throw TractandaError("indexResource", "Personal checkpoint row exceeded resources.")
                }
                if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(shapeStatus & 0xff) {
                    throw TractandaError("indexTransient", "Personal checkpoint row was interrupted.")
                }
                guard shapeStatus == SQLITE_ROW,
                    let rawStatus = sqlite3_column_text(shape, 0),
                    String(cString: rawStatus) == projection.state.status.rawValue
                else { return false }
                if projection.state.status == .ready {
                    guard let representative = projection.state.representativeRevisionID,
                        let head = try index.currentHeadSummary(id), head.revisionID == representative,
                        let itemRevision = sqlite3_column_text(shape, 1),
                        String(cString: itemRevision) == representative,
                        let headRevision = sqlite3_column_text(shape, 2),
                        String(cString: headRevision) == representative,
                        head.fields["permissions"] == nil
                            || (sqlite3_column_int(shape, 3) == 1 && sqlite3_column_int(shape, 4) == 1),
                        let row = try index.revision(itemID: id, revisionID: representative),
                        projection.representativeDigest
                            == row.digest.map({ String(format: "%02x", $0) }).joined()
                    else { return false }
                }
                cursor = id
            }
        }
        return true
    }

    static func validate(
        index: ItemIndex, root: URL, ownerUID: UInt32, binding: String,
        validateReferences: (Revision) throws -> Void
    ) throws -> Bool {
        func scalar(_ sql: String, _ bindings: [String] = []) throws -> String? {
            let statement = try index.corpusPrepare(sql, bindings)
            defer { sqlite3_finalize(statement) }
            func step() throws -> Int32 {
                let status = index.catalogueStep(statement)
                try index.checkCatalogueScanProgress()
                let primary = status & 0xff
                if [SQLITE_NOMEM, SQLITE_FULL, SQLITE_TOOBIG].contains(primary) {
                    throw TractandaError(
                        "indexResource", "Checkpoint verification exceeded SQLite resources.")
                }
                if [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(primary) {
                    throw TractandaError("indexTransient", "Checkpoint verification was interrupted.")
                }
                return status
            }
            guard try step() == SQLITE_ROW,
                sqlite3_column_bytes(statement, 0) <= 1024,
                let bytes = sqlite3_column_text(statement, 0)
            else { return nil }
            let result = String(cString: bytes)
            guard try step() == SQLITE_DONE else { return nil }
            return result
        }
        guard try scalar("SELECT value FROM checkpoint_meta WHERE key=?", [key]) == binding,
            try scalar("PRAGMA quick_check") == "ok",
            let countText = try scalar("SELECT COUNT(*) FROM revision_catalog"),
            let expectedCount = UInt64(countText)
        else { return false }

        struct Directory {
            let url: URL
            let handle: UnsafeMutableRawPointer
        }
        let items = root.appendingPathComponent("items")
        guard let handle = tractanda_directory_open(items.path) else {
            throw FileMetadataError.posix(errno)
        }
        var directories = [Directory(url: items, handle: handle)]
        defer { for directory in directories.reversed() { _ = tractanda_directory_close(directory.handle) } }
        var records: UInt64 = 0
        while let directory = directories.last {
            try Task.checkCancellation()
            var buffer = [CChar](repeating: 0, count: 1024)
            let status = buffer.withUnsafeMutableBufferPointer {
                tractanda_directory_next(directory.handle, $0.baseAddress, $0.count)
            }
            if status == 0 {
                let closed = tractanda_directory_close(directory.handle)
                directories.removeLast()
                guard closed == 0 else { throw FileMetadataError.posix(errno) }
                continue
            }
            guard status == 1 else { throw FileMetadataError.posix(errno) }
            guard
                let name = String(
                    bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else { return false }
            let child = directory.url.appendingPathComponent(name)
            let metadata = try FileMetadata.read(at: child)
            let archived = tractanda_path_read_only(child.path) == 1
            guard archived || (metadata.uid == ownerUID && metadata.mode & 0o077 == 0) else { return false }
            if metadata.type == .directory {
                guard directories.count < 128, let next = tractanda_directory_open(child.path) else {
                    return false
                }
                directories.append(Directory(url: child, handle: next))
                continue
            }
            guard metadata.type == .regular else { return false }
            if CanonicalVerifier.isLegalStagingName(name) { continue }
            let relative = String(child.path.dropFirst(root.path.count + 1))
            guard let ids = CanonicalRecordPath.identities(relative),
                let row = try index.revision(itemID: ids.itemID, revisionID: ids.revisionID),
                row.path == relative
            else { return false }
            records += 1
            guard records <= expectedCount else { return false }
            // Read one bounded immutable record at a time. Historical payload references are
            // not yet projected in the ordinary index, so their presence is checked from bytes.
            let record = try PooledCanonicalRecord.read(row: row, root: root, ownerUID: ownerUID)
            try validateReferences(record.revision)
        }
        return records == expectedCount
    }
}
