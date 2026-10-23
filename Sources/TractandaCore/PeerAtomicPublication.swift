import CSQLite
import Foundation

extension PeerIntakeCoordinator {
    /// Explicit store activation only; never raises a floor while an ordinary write is running.
    func atomicCanonicalActivated() throws -> Bool {
        guard let value = try CanonicalReaderRequirement.load(root: root, ownerUID: ownerUID) else {
            return false
        }
        guard value.minimumReaderLevel >= 15 || value.capabilities.contains(AtomicAuthorityFormat.profile)
        else { return false }
        try requireAtomicCanonicalActivation()
        return true
    }

    /// Physical durability only. This receipt is PREPARED publication, not a logical acceptance.
    /// All normal origin/context checks and reserve guards remain on the existing journal path.
    func sealAtomicLocalPackage(
        _ manifest: PeerPackage.Manifest, contextToken: String, localItemPath: String? = nil,
        arrivalMinute: String? = nil
    ) throws {
        try requireAtomicCanonicalActivation()
        let context = try context(peerID: "local")
        guard manifest.storeID == storeID else {
            throw AtomicAuthorityFormat.invalid("Atomic local packet names another store.")
        }
        let stamp = try RevisionTimestamp(Timestamp.now()).formatted()
        let minute =
            arrivalMinute
            ?? String(stamp.prefix(16)).replacingOccurrences(of: "-", with: "/")
            .replacingOccurrences(of: "T", with: "/").replacingOccurrences(of: ":", with: "/")
        var publication = PeerIntakeJournal.Publication(
            packageID: manifest.packageID,
            manifestDigest: AuthorityRecordCodec.sha256(try JSON.encode(manifest)),
            context: context, contextToken: contextToken, arrivalMinute: minute)
        publication.localItemPath = localItemPath
        try journal.prepare(publication)
        try StoreCheckpoint.markDirty(root: root)
        try journal.seal(manifest.packageID)
    }
}

extension PeerIntakeCoordinator {
    /// Streams one frozen local metadata unit into the existing private intake journal. The
    /// caller supplies a fresh exact ordered iterator for each pass, never an all-object array.
    /// This performs no canonical publication, acceptance seal, queue consumption or activation.
    func stageStreamedObjects(
        archive: PeerLocalPackageArchive, context: PeerPackage.Context, packageID: String,
        inputIdentity: String,
        makeObjects: () throws -> (() throws -> (PeerPackage.Object, Data)?)
    ) throws -> PeerPackage.Manifest {
        guard context.peerID == "local", context.storeID == storeID else {
            throw TractandaError(
                "invalidPeerPackage", "Local streamed framing requires its exact Store context.")
        }
        try requireCurrent(context)
        let first = try makeObjects()
        func requireBytes(_ pair: (PeerPackage.Object, Data)) throws {
            try pair.0.validate()
            guard [.item, .authority].contains(pair.0.kind), pair.0.part == nil,
                pair.1.count == pair.0.length, AuthorityRecordCodec.sha256(pair.1) == pair.0.sha256
            else {
                throw TractandaError(
                    "peerObjectCollision", "Local streamed original differs from its frozen descriptor.")
            }
        }
        let manifest = try archive.build(
            storeID: storeID, packageID: packageID,
            inputIdentity: inputIdentity,
            objects: {
                try self.progress?()
                guard let value = try first() else { return nil }
                try requireBytes(value)
                return value.0
            })
        let prior = try journal.files.readIfPresent(
            path: ["authority", "intake", packageID, "begin.json"], maximumBytes: PeerPackage.maximumPageBytes
        ).map { try PeerPackage.decode(PeerIntakeJournal.Begin.self, $0) }
        if let prior {
            guard prior.context == context, prior.manifest == manifest else {
                throw TractandaError(
                    "peerObjectCollision", "Local streamed continuation changed context or manifest.")
            }
        }
        _ = try journal.begin(
            context: context, manifestBytes: JSON.encode(manifest), retainedLocal: prior != nil)
        func append(_ object: PeerPackage.Object, _ data: Data) throws {
            try self.progress?()
            for offset in stride(from: 0, to: data.count, by: object.chunkBytes) {
                _ = try journal.append(
                    context: context, packageID: packageID, object: object,
                    offset: offset,
                    bytes: data.subdata(in: offset..<min(data.count, offset + object.chunkBytes)),
                    retainedLocal: prior != nil)
            }
        }
        // Authenticated generated pages first. Original descriptors below come only from the
        // hash-bound frozen manifest, never a self-authenticating second iterator or page pair.
        try archive.forEachIndexObject(manifest) { object, data in try append(object, data) }
        let second = try makeObjects()
        try journal.walk(packageID) { expected, _ in
            guard let value = try second(), value.0 == expected else {
                throw TractandaError(
                    "peerObjectCollision", "Local streamed input changed between framing and staging.")
            }
            try requireBytes(value)
            try append(expected, value.1)
        }
        if (try second()) != nil {
            throw TractandaError("peerObjectCollision", "Local streamed input extends its frozen manifest.")
        }
        try requireCurrent(context)
        return manifest
    }
}

extension PeerIntakeCoordinator {
    /// Bounded descriptor spool reconciles tree traversal with global UUID lexical order. A
    /// source control's arbitrary number of physical parts never becomes a Swift object array.
    /// The optional item and bounded ordinary evidence/exposure records are one native intent,
    /// not a materialization of all targets, imported history, or effect entries.
    func stageAtomicLocalUnit(
        archive: AtomicAuthorityArchive, handle: AtomicAuthorityArchive.Handle,
        packageArchive: PeerLocalPackageArchive, index: ItemIndex, packageID: String,
        inputIdentity: String, item: (PeerPackage.Object, Data)? = nil,
        authorityRecords: [(PeerPackage.Object, Data)] = []
    ) throws -> PeerPackage.Manifest {
        guard authorityRecords.count <= AuthorityRecord.maximumEntries,
            authorityRecords.allSatisfy({ $0.0.kind == .authority }),
            item?.0.kind == nil || item?.0.kind == .item
        else { throw AtomicAuthorityFormat.invalid("Invalid bounded per-intent local metadata roles.") }
        let context = try self.context(peerID: "local")
        let token = "atomic-publication:" + (try UUID.makeVersion1().uuidString.lowercased())
        return try index.withAtomicPublicationSpool {
            var spoolBytes: UInt64 = 0
            var extras: [String: (PeerPackage.Object, Data)] = [:]
            for pair in authorityRecords + (item.map { [$0] } ?? []) {
                try pair.0.validate()
                guard pair.1.count == pair.0.length, AuthorityRecordCodec.sha256(pair.1) == pair.0.sha256,
                    extras.updateValue(pair, forKey: pair.0.id) == nil,
                    try index.spoolAtomicPublicationDescriptor(pair.0, token: token, storedBytes: &spoolBytes)
                else {
                    throw TractandaError(
                        "peerObjectCollision", "Local intent metadata has conflicting bytes or IDs.")
                }
            }
            try archive.forEachUntrustedLocalObject(handle) { descriptor, _ in
                guard
                    try index.spoolAtomicPublicationDescriptor(
                        descriptor, token: token, storedBytes: &spoolBytes)
                else {
                    throw TractandaError(
                        "peerObjectCollision", "Atomic root/part conflicts with per-intent metadata.")
                }
            }
            return try archive.withUntrustedLocalObjectReader(handle) { reader in
                try stageStreamedObjects(
                    archive: packageArchive, context: context, packageID: packageID,
                    inputIdentity: inputIdentity,
                    makeObjects: {
                        var after: String?
                        var page: [PeerPackage.Object] = []
                        var offset = 0
                        return {
                            if offset == page.count {
                                page = try index.atomicPublicationDescriptorPage(
                                    token: token, afterID: after, limit: 128)
                                offset = 0
                            }
                            guard offset < page.count else { return nil }
                            let expected = page[offset]
                            offset += 1
                            after = expected.id
                            if let value = extras[expected.id] {
                                guard value.0 == expected else {
                                    throw AtomicAuthorityFormat.invalid(
                                        "Publication metadata descriptor changed.")
                                }
                                return value
                            }
                            return (expected, try reader.object(expected: expected))
                        }
                    })
            }
        }
    }
}

extension ItemIndex {
    /// One serialized local build owns this private table. A new scope removes only obsolete
    /// descriptor work, including interrupted earlier builds; no canonical/staged facts are here.
    func withAtomicPublicationSpool<T>(_ body: () throws -> T) throws -> T {
        guard !atomicPublicationSpoolActive else {
            throw TractandaError("storeBusy", "Private publication spool is already borrowed.")
        }
        try installAtomicAuthorityIndexSchema(.publication)
        atomicPublicationSpoolActive = true
        defer {
            try? execute("DELETE FROM authority_atomic_publication_spool")
            atomicPublicationSpoolActive = false
        }
        try execute("DELETE FROM authority_atomic_publication_spool")
        return try body()
    }
    func spoolAtomicPublicationDescriptor(
        _ object: PeerPackage.Object, token: String, storedBytes: inout UInt64
    ) throws -> Bool {
        try object.validate()
        guard [.item, .authority].contains(object.kind), object.part == nil else {
            throw AtomicAuthorityFormat.invalid("Unsupported private publication descriptor.")
        }
        let encoded = String(decoding: try JSON.encode(object), as: UTF8.self)
        let query = try corpusPrepare(
            "SELECT 1 FROM authority_atomic_publication_spool WHERE token=? AND id=?", [token, object.id])
        defer { sqlite3_finalize(query) }
        let status = catalogueStep(query)
        if status == SQLITE_ROW { return false }
        guard status == SQLITE_DONE else { throw graphSQLiteError() }
        let next = storedBytes.addingReportingOverflow(
            UInt64(encoded.utf8.count + token.utf8.count + 512) * 4)
        guard !next.overflow, next.partialValue <= graphMaximumTemporaryBytes else {
            throw TractandaError("resourceLimit", "Private publication spool exceeds its storage allowance.")
        }
        try requireGraphCapacity(additionalBytes: next.partialValue)
        try execute(
            "INSERT INTO authority_atomic_publication_spool VALUES(?,?,?)", [token, object.id, encoded])
        storedBytes = next.partialValue
        return true
    }
    func atomicPublicationDescriptorPage(token: String, afterID: String?, limit: Int) throws -> [PeerPackage
        .Object]
    {
        try LogicalControlSource.page(-1, limit)
        return try withCatalogueScanBudget(reusingActiveBudget: true) {
            let s = try corpusPrepare(
                "SELECT id,descriptor FROM authority_atomic_publication_spool WHERE token=?"
                    + (afterID == nil ? "" : " AND id>?") + " ORDER BY id LIMIT ?",
                [token] + (afterID.map { [$0] } ?? []) + [String(limit)])
            defer { sqlite3_finalize(s) }
            var result: [PeerPackage.Object] = []
            while true {
                try checkCatalogueScanProgress()
                let status = catalogueStep(s)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW, sqlite3_column_type(s, 0) == SQLITE_TEXT,
                    sqlite3_column_bytes(s, 0) == 36, let raw = sqlite3_column_text(s, 0),
                    let id = String(data: Data(bytes: raw, count: 36), encoding: .utf8)
                else {
                    throw AtomicAuthorityFormat.invalid("Malformed private publication ID cursor.")
                }
                _ = try AuthorityRecord.persistentID(.text(id))
                guard sqlite3_column_type(s, 1) == SQLITE_TEXT,
                    let rawDescriptor = sqlite3_column_text(s, 1),
                    sqlite3_column_bytes(s, 1) <= 4096
                else {
                    throw AtomicAuthorityFormat.invalid("Malformed private publication descriptor.")
                }
                let bytes = Data(bytes: rawDescriptor, count: Int(sqlite3_column_bytes(s, 1)))
                let object = try PeerPackage.decode(PeerPackage.Object.self, bytes, maximum: 4096)
                try object.validate()
                guard object.id == id, [.item, .authority].contains(object.kind), object.part == nil else {
                    throw AtomicAuthorityFormat.invalid("Private descriptor cursor identity differs.")
                }
                result.append(object)
            }
        }
    }
}

extension PeerIntakeJournal {
    /// Disposal of an unpublished native proposal, never rollback of an uncertain publication.
    func discardUnsealedAtomicDraft(_ manifest: PeerPackage.Manifest) throws {
        let id = manifest.packageID
        let begin = try beginRecord(id)
        guard begin.manifest == manifest, begin.context.peerID == "local",
            try publication(id) == nil, try preparedPublication(id) == nil
        else {
            throw TractandaError(
                "peerRepairRequired", "A published/uncertain local proposal must be recovered.")
        }
        try files.removeUnsealedAtomicDraft(id)
        invalidateStageAccounting(packageID: id)
    }
}
