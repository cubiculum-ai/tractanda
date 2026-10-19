import CSQLite
import Foundation

extension ItemIndex {
    /// Disposable inventory identity; canonical membership remains the sealed journal.
    /// Initialization/reset runs only on the owning writer, never from an inventory read.
    func initializePeerInventorySchema() throws {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try peerInventoryCapacity(32 * 1024)
            try execute(
                "CREATE TABLE IF NOT EXISTS peer_inventory_state(slot INTEGER PRIMARY KEY CHECK(slot=1),epoch TEXT NOT NULL)"
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS peer_inventory_receipt(sequence INTEGER PRIMARY KEY AUTOINCREMENT,package TEXT NOT NULL,object TEXT NOT NULL,UNIQUE(package,object))"
            )
            let s = try corpusPrepare("SELECT epoch FROM peer_inventory_state WHERE slot=1")
            let status = catalogueStep(s)
            sqlite3_finalize(s)
            if status == SQLITE_DONE {
                // Old derived caches must rebuild at schema17; do not invent a partial
                // initial inventory over already retained, unsequenced memberships.
                guard try peerInventoryNumber("SELECT EXISTS(SELECT 1 FROM authority_packages LIMIT 1)") == 0
                else {
                    throw TractandaError(
                        "peerInventoryChanged", "Retained receipt inventory requires a derived rebuild.")
                }
                try execute("INSERT INTO peer_inventory_state VALUES(1,?)", [Identifier.make()])
            } else if status != SQLITE_ROW {
                throw graphSQLiteError()
            }
        }
    }
    /// The caller's retained-original savepoint owns this assignment and membership.
    /// Existing receipts are immutable and never receive a new sequence on retry.
    func assignPeerInventoryReceipt(packageID: String, objectID: String) throws {
        try checkCatalogueScanProgress()
        let s = try corpusPrepare(
            "SELECT sequence FROM peer_inventory_receipt WHERE package=? AND object=?", [packageID, objectID])
        let status = catalogueStep(s)
        if status == SQLITE_ROW {
            let valid = sqlite3_column_type(s, 0) == SQLITE_INTEGER && sqlite3_column_int64(s, 0) > 0
            sqlite3_finalize(s)
            guard valid else {
                throw TractandaError("peerInventoryChanged", "Invalid receipt sequence requires rebuild.")
            }
            return
        }
        sqlite3_finalize(s)
        guard status == SQLITE_DONE else { throw graphSQLiteError() }
        guard
            try peerInventoryNumber(
                "SELECT EXISTS(SELECT 1 FROM authority_packages WHERE package=? AND object=?)",
                [packageID, objectID]) == 1
        else {
            throw TractandaError("peerInventoryChanged", "Inventory cannot invent a retained receipt.")
        }
        guard
            try peerInventoryNumber(
                "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='peer_inventory_receipt'),0)")
                < Int64.max
        else {
            throw TractandaError("resourceLimit", "Receipt inventory sequence is exhausted.")
        }
        try peerInventoryCapacity(64 * 1024)
        try execute("INSERT INTO peer_inventory_receipt(package,object) VALUES(?,?)", [packageID, objectID])
    }
    func resetPeerInventoryIfPresent() throws {
        guard
            try peerInventoryNumber(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='peer_inventory_state')"
            ) == 1
        else { return }
        try peerInventoryCapacity(16 * 1024)
        try execute("DELETE FROM peer_inventory_receipt")
        // Keep SQLite's AUTOINCREMENT high-water mark as well as changing epoch.
        try execute("UPDATE peer_inventory_state SET epoch=? WHERE slot=1", [Identifier.make()])
    }
    func capturePeerInventory() throws -> (epoch: String, maximumSequence: Int64) {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            try checkCatalogueScanProgress()
            guard
                try peerInventoryNumber(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='peer_inventory_state')"
                ) == 1
            else {
                throw TractandaError("peerInventoryChanged", "Receipt inventory has not been rebuilt.")
            }
            let s = try corpusPrepare("SELECT epoch FROM peer_inventory_state WHERE slot=1")
            defer { sqlite3_finalize(s) }
            guard catalogueStep(s) == SQLITE_ROW, sqlite3_column_bytes(s, 0) <= 128,
                let p = sqlite3_column_text(s, 0), sqlite3_column_bytes(s, 0) > 0
            else { throw TractandaError("peerInventoryChanged", "Receipt inventory epoch is unavailable.") }
            guard
                let epoch = String(
                    bytes: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(s, 0))),
                    encoding: .utf8), !epoch.contains("\0")
            else {
                throw TractandaError("peerInventoryChanged", "Receipt inventory epoch is malformed.")
            }
            let maximum = try peerInventoryNumber(
                "SELECT COALESCE(MAX(sequence),0) FROM peer_inventory_receipt")
            guard maximum >= 0 else {
                throw TractandaError("peerInventoryChanged", "Receipt sequence boundary is invalid.")
            }
            return (epoch, maximum)
        }
    }
    /// Raw receipt enumeration, deliberately independent of query eligibility. Main
    /// validates current context/origin/bytes and retains last SCANNED on empty filtering.
    struct OriginReplayReceipt {
        let sequence: Int64
        let retained: AuthorityStore.RetainedObject
        /// Empty is the existing legacy/non-origin sentinel, never an invented identity.
        let origin: String?
    }
    func peerInventoryReceiptPage(
        epoch: String, afterSequence: Int64, throughSequence: Int64, limit: Int = 128
    ) throws -> [PeerInventory.Receipt] {
        try peerReceiptProjection(
            epoch: epoch, afterSequence: afterSequence,
            throughSequence: throughSequence, limit: limit, includingVerifiedOrigin: false
        )
        .map { .init(sequence: $0.sequence, retained: $0.retained) }
    }
    /// Only receipt replay consumes this typed projection of origin derived during canonical
    /// retention/reconstruction. It is not public inventory output or membership authority.
    func peerOriginReplayReceiptPage(
        epoch: String, afterSequence: Int64, throughSequence: Int64, limit: Int = 128
    ) throws -> [OriginReplayReceipt] {
        try peerReceiptProjection(
            epoch: epoch, afterSequence: afterSequence,
            throughSequence: throughSequence, limit: limit, includingVerifiedOrigin: true)
    }
    private func peerReceiptProjection(
        epoch: String, afterSequence: Int64, throughSequence: Int64, limit: Int,
        includingVerifiedOrigin: Bool
    ) throws -> [OriginReplayReceipt] {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            guard afterSequence >= 0, throughSequence >= afterSequence, (1...1024).contains(limit),
                epoch.utf8.count <= 128
            else {
                throw TractandaError("invalidPeerCursor", "Invalid receipt inventory cursor bounds.")
            }
            let current = try capturePeerInventory()
            guard current.epoch == epoch else {
                throw TractandaError(
                    "peerInventoryChanged", "Receipt inventory was rebuilt; capture a new boundary.")
            }
            guard throughSequence <= current.maximumSequence else {
                throw TractandaError(
                    "invalidPeerCursor", "Receipt inventory cursor exceeds its captured range.")
            }
            if afterSequence == throughSequence { return [] }
            let s = try corpusPrepare(
                "SELECT o.id,o.kind,o.length,o.sha256,o.path,p.package,p.peer,p.configuration,p.permitted,i.sequence,o.origin FROM peer_inventory_receipt i LEFT JOIN authority_packages p ON p.package=i.package AND p.object=i.object LEFT JOIN authority_objects o ON o.id=i.object WHERE i.sequence>? AND i.sequence<=? ORDER BY i.sequence LIMIT ?",
                [String(afterSequence), String(throughSequence), String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [OriginReplayReceipt] = []
            var bytes = 0
            var last = afterSequence
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw graphSQLiteError() }
                var size = 512
                for column in 0..<sqlite3_column_count(s) {
                    let count = Int(sqlite3_column_bytes(s, column))
                    guard count <= Self.authorityMetadataRowBytes - min(size, Self.authorityMetadataRowBytes)
                    else {
                        throw TractandaError(
                            "resourceLimit", "Inventory receipt metadata exceeds its row window.")
                    }
                    size += count
                }
                guard size <= graphMaximumPageBytes - min(bytes, graphMaximumPageBytes) else {
                    if !result.isEmpty { return result }
                    throw TractandaError("resourceLimit", "Inventory page cannot fit one complete receipt.")
                }
                bytes += size
                guard sqlite3_column_type(s, 9) == SQLITE_INTEGER else {
                    throw TractandaError("peerInventoryChanged", "Invalid immutable receipt sequence.")
                }
                let sequence = sqlite3_column_int64(s, 9)
                guard sequence > last, sequence <= throughSequence else {
                    throw TractandaError("peerInventoryChanged", "Receipt sequence ordering changed.")
                }
                let retained = try authorityRetainedRow(s)
                let origin: String?
                if includingVerifiedOrigin {
                    guard sqlite3_column_type(s, 10) == SQLITE_TEXT,
                        sqlite3_column_bytes(s, 10) <= 36,
                        let value = sqlite3_column_text(s, 10),
                        let text = String(
                            bytes: UnsafeBufferPointer(
                                start: value,
                                count: Int(sqlite3_column_bytes(s, 10))), encoding: .utf8),
                        !text.contains("\0")
                    else {
                        throw TractandaError(
                            "peerInventoryChanged",
                            "Verified receipt origin metadata is missing or malformed.")
                    }
                    if text.isEmpty {
                        guard retained.descriptor.kind != .authority else {
                            throw TractandaError(
                                "peerInventoryChanged", "Canonical control lost its verified origin.")
                        }
                        origin = nil
                    } else {
                        origin = try AuthorityRecord.persistentID(.text(text))
                    }
                } else {
                    origin = nil
                }
                result.append(.init(sequence: sequence, retained: retained, origin: origin))
                last = sequence
            }
        }
    }
    /// Exact explicitly administered initial baseline, never an inferred legacy origin.
    func peerInventoryLegacyPin(revisionID: String, sha256: String) throws -> AuthorityBinding? {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            _ = try AuthorityRecord.persistentID(.text(revisionID))
            _ = try AuthorityRecord.digest(.text(sha256))
            guard
                try peerInventoryNumber(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='authority_local_bootstrap')"
                ) == 1
            else { return nil }
            let s = try corpusPrepare(
                "SELECT d.target,d.sha256 FROM authority_dependencies d JOIN authority_objects o ON o.id=d.source AND o.kind='item' AND o.sha256=? JOIN authority_local_bootstrap b ON b.pin=d.target AND b.sha256=d.sha256 JOIN authority_objects pin ON pin.id=b.pin AND pin.sha256=b.sha256 AND pin.control_kind='bootstrap' WHERE d.source=? AND d.kind='bootstrap' AND d.package='' ORDER BY d.target LIMIT 2",
                [sha256, revisionID])
            defer { sqlite3_finalize(s) }
            let status = catalogueStep(s)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, sqlite3_column_bytes(s, 0) <= 64, sqlite3_column_bytes(s, 1) == 64,
                let id = sqlite3_column_text(s, 0), let digest = sqlite3_column_text(s, 1)
            else { throw TractandaError("peerInventoryChanged", "Malformed typed baseline binding.") }
            let binding = try AuthorityBinding(recordID: String(cString: id), sha256: String(cString: digest))
            guard catalogueStep(s) == SQLITE_DONE else {
                throw TractandaError("peerInventoryChanged", "Baseline inventory has competing initial pins.")
            }
            return binding
        }
    }
    /// Untrusted locators for the current initializer's root -> optional index -> page layout.
    /// Every returned reference and member must be checked against canonical bytes by the caller.
    func peerInventoryBootstrapPath(revisionID: String, sha256: String, pin: AuthorityBinding) throws
        -> [AuthorityBinding]?
    {
        try withCatalogueScanBudget(reusingActiveBudget: true) {
            let sql =
                "SELECT '', '', page.id, page.sha256 FROM authority_dependencies member JOIN authority_objects page ON page.id=member.source AND page.control_kind='bootstrapPage' JOIN authority_dependencies root ON root.source=? AND root.kind='pages' AND root.target=page.id AND root.sha256=page.sha256 WHERE member.kind='bootstrapMember' AND member.target=? AND member.sha256=? UNION ALL SELECT idx.id,idx.sha256,page.id,page.sha256 FROM authority_dependencies member JOIN authority_objects page ON page.id=member.source AND page.control_kind='bootstrapPage' JOIN authority_dependencies child ON child.target=page.id AND child.sha256=page.sha256 AND child.kind='children' JOIN authority_objects idx ON idx.id=child.source AND idx.control_kind='bootstrapIndex' JOIN authority_dependencies root ON root.source=? AND root.kind='pages' AND root.target=idx.id AND root.sha256=idx.sha256 WHERE member.kind='bootstrapMember' AND member.target=? AND member.sha256=? LIMIT 2"
            let statement = try corpusPrepare(
                sql, [pin.recordID, revisionID, sha256, pin.recordID, revisionID, sha256])
            defer { sqlite3_finalize(statement) }
            let status = catalogueStep(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else { throw graphSQLiteError() }
            func text(_ column: Int32) throws -> String {
                guard sqlite3_column_bytes(statement, column) <= 64,
                    let value = sqlite3_column_text(statement, column)
                else {
                    throw TractandaError("peerInventoryChanged", "Malformed bootstrap path locator.")
                }
                return String(cString: value)
            }
            var path: [AuthorityBinding] = []
            if try !text(0).isEmpty { path.append(try .init(recordID: text(0), sha256: text(1))) }
            path.append(try .init(recordID: text(2), sha256: text(3)))
            guard catalogueStep(statement) == SQLITE_DONE else {
                throw TractandaError(
                    "peerInventoryChanged", "Initial membership has competing locator paths.")
            }
            return path
        }
    }
    private func peerInventoryNumber(_ sql: String, _ args: [String] = []) throws -> Int64 {
        let s = try corpusPrepare(sql, args)
        defer { sqlite3_finalize(s) }
        guard catalogueStep(s) == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_INTEGER else {
            throw graphSQLiteError()
        }
        return sqlite3_column_int64(s, 0)
    }
    private func peerInventoryCapacity(_ bytes: UInt64) throws {
        try checkCatalogueScanProgress()
        guard bytes <= graphMaximumTemporaryBytes else {
            throw TractandaError("resourceLimit", "Inventory staging exceeds its allowance.")
        }
        try requireGraphCapacity(additionalBytes: bytes)
    }
}
