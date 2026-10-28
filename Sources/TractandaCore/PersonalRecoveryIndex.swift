import CTractandaPlatform
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Disposable native index construction over one administrator-selected offline content tree.
/// Selection abandons the old trust context; it is not an assertion of prior peer admission.
enum PersonalRecoveryIndex {
    struct Completed {
        let root: URL
        let directory: URL
        let ownerUID: UInt32
        /// Derived snapshot binding only; never a recovered logical-store or peer identity.
        let rebuildContextID: String
        fileprivate init(root: URL, directory: URL, ownerUID: UInt32, rebuildContextID: String) {
            self.root = root
            self.directory = directory
            self.ownerUID = ownerUID
            self.rebuildContextID = rebuildContextID
        }
    }
    struct Incomplete: Error {
        let diagnostics: [PersonalRecoveryInventory.Diagnostic]
    }
    struct Limits {
        var inventory = PersonalRecoveryInventory.Limits()
        // A bounded fork-analysis window, not a maximum ordinary history length. Linear histories
        // are streamed; exceeding this window leaves only that fork explicitly unmaterializable.
        var graph = RevisionGraph.Limits(
            maximumNodes: 4096, maximumEdges: 16384,
            maximumEncodedBytes: 32 * 1024 * 1024, maximumWork: 16_000_000)
        var maximumDerivedBytes: UInt64 = 8 * 1024 * 1024 * 1024
        var minimumAvailableBytes: UInt64 = 10 * 1024 * 1024 * 1024
    }

    /// Publishes a new derived directory only after all selected items have unambiguous heads.
    /// The caller supplies a new destination; an existing index can simply be discarded offline.
    static func rebuild(
        source: PersonalRecoveryInventory.Source, destination: URL,
        accounts: any AccountDirectory, configuration: AccessConfiguration, limits: Limits = .init(),
        rebuildContextID requestedContextID: String? = nil
    ) throws -> Completed {
        // Compare physical ancestry as well as checking the selected source with no-follow I/O.
        // A private symlinked ancestor must not redirect generated output into canonical content.
        func physical(_ url: URL) throws -> URL {
            // Foundation may normalize /private/var back to the symlink /var on macOS.
            // Retain the actual physical pathname for SQLite's all-component NOFOLLOW check.
            guard let path = realpath(url.path, nil) else { throw FileMetadataError.posix(errno) }
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        let root = try physical(source.root)
        let parent = try physical(destination.deletingLastPathComponent())
        let output = parent.appendingPathComponent(destination.lastPathComponent)
        guard source.ownerUID == tractanda_uid(), limits.maximumDerivedBytes > 0,
            output.path != root.path,
            !output.path.hasPrefix(root.path + "/"),
            !root.path.hasPrefix(output.path + "/"),
            (try? FileMetadata.read(at: output)) == nil
        else {
            throw TractandaError(
                "invalidRecoveryScope", "Choose a new derived destination outside the selected content tree.")
        }
        try PrivateConfiguration.validate(parent, directory: true)
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw FileMetadataError.posix(errno) }
        defer { _ = close(parentDescriptor) }
        // No source lock file, store identity, pairing credentials or placement journal is created.
        // The administrator must keep the selected tree offline throughout construction and use.
        let temporary = parent.appendingPathComponent(".personal-index-" + Identifier.make())
        guard mkdir(temporary.path, 0o700) == 0 else { throw FileMetadataError.posix(errno) }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: temporary) } }
        func capacity() throws {
            try Task.checkCancellation()
            var stat = statvfs()
            guard statvfs(temporary.path, &stat) == 0, stat.f_frsize > 0 else {
                throw TractandaError("resourceLimit", "Cannot determine recovery index capacity.")
            }
            let free = UInt64(stat.f_bavail).multipliedReportingOverflow(by: UInt64(stat.f_frsize))
            guard !free.overflow, free.partialValue >= limits.minimumAvailableBytes else {
                throw TractandaError("resourceLimit", "Recovery index free-space reserve crossed.")
            }
            var bytes: UInt64 = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: temporary.path) {
                let metadata = try FileMetadata.read(at: temporary.appendingPathComponent(name))
                guard metadata.type == .regular,
                    metadata.size <= limits.maximumDerivedBytes - bytes
                else { throw TractandaError("resourceLimit", "Recovery derived-index byte limit crossed.") }
                bytes += metadata.size
            }
        }
        try capacity()
        let path = temporary.appendingPathComponent("items.sqlite")
        let index = try ItemIndex(path: path.path, create: true, noFollow: true, journalMode: .delete)
        defer { index.close() }
        index.graphMaximumTemporaryBytes = limits.maximumDerivedBytes
        index.graphReserveBytes = limits.minimumAvailableBytes
        index.maintenanceCapacityCheck = capacity
        try index.execute("BEGIN IMMEDIATE")
        let contextID = try populate(
            source: source, index: index, accounts: accounts, configuration: configuration,
            limits: limits, rebuildContextID: requestedContextID, boundary: capacity)
        try index.execute("COMMIT")
        try capacity()
        try index.closeChecked()
        guard chmod(path.path, 0o600) == 0 else { throw FileMetadataError.posix(errno) }
        try StoreCheckpoint.syncDirectory(temporary)
        guard
            tractanda_publish_directory_at(
                parentDescriptor, temporary.lastPathComponent, parentDescriptor, output.lastPathComponent)
                == 0
        else { throw FileMetadataError.posix(errno) }
        published = true
        try StoreCheckpoint.syncDirectory(parent)
        return Completed(
            root: root, directory: output, ownerUID: source.ownerUID, rebuildContextID: contextID)
    }
    /// Shared ordinary content reconstruction. Caller owns an empty staged native index and
    /// transaction; this method neither copies originals nor loads operational trust configuration.
    static func populate(
        source: PersonalRecoveryInventory.Source, index: ItemIndex,
        accounts: any AccountDirectory, configuration: AccessConfiguration,
        limits: Limits = .init(), rebuildContextID requestedContextID: String? = nil,
        boundary: () throws -> Void, inventoryCheck: @escaping @Sendable () throws -> Void = {},
        inventoryActivity: @escaping @Sendable () throws -> Void = {},
        originalVerified: @escaping @Sendable (Int64) throws -> Void = { _ in },
        pageVerified: @escaping @Sendable () throws -> Void = {},
        recordVerified: () throws -> Void = {}, itemProjected: () throws -> Void = {},
        projectCurrentItems: Bool = true,
        materialize: ((RevisionGraph, [String: Revision]) throws -> (ItemIndex.CatalogueRow, Revision))? =
            nil,
        personalMergeObserved: () throws -> Void = {}, documentReadFailureForTesting: Int32? = nil
    ) throws -> String {
        index.personalContentProjectionMode = true
        let inventory = try PersonalRecoveryInventory.inspect(
            [source], limits: limits.inventory,
            check: inventoryCheck, activity: inventoryActivity, originalVerified: originalVerified,
            pageVerified: pageVerified, documentReadFailureForTesting: documentReadFailureForTesting)
        guard inventory.isStructurallyComplete else { throw Incomplete(diagnostics: inventory.diagnostics) }
        // PageCorpusInput needs an operation snapshot binding. This UUID is confined to the
        // new derived index and establishes no old logical-store identity, trust or admission.
        let contextID = try requestedContextID ?? UUID.makeVersion1().uuidString.lowercased()
        guard UUID(uuidString: contextID)?.version1Components != nil else {
            throw TractandaError("invalidRecoveryScope", "Use a fresh UUIDv1 reconstruction context.")
        }
        let rootDescriptor = open(source.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw FileMetadataError.posix(errno) }
        defer { _ = close(rootDescriptor) }
        let rootMetadata = try PooledCanonicalRecord.inventoryMetadata(for: rootDescriptor)
        guard rootMetadata.uid == source.ownerUID, rootMetadata.mode & 0o077 == 0 else {
            throw TractandaError("invalidRecoveryScope", "Selected recovery root custody changed.")
        }
        let readBudget = RecoveryReadBudget(inventory: inventory, limits: limits.inventory)
        let provider = SelectedRecoveryPageProvider(
            root: source.root, rootDescriptor: rootDescriptor, ownerUID: source.ownerUID,
            locations: inventory.validatedDocumentLocations, budget: readBudget,
            check: inventoryCheck, activity: inventoryActivity)
        let resolver = PrincipalResolver(directory: accounts, configuration: configuration)
        try configuration.validate(using: resolver)
        let statements = try index.makeRebuildStatements()
        defer { statements.close() }
        var personalAutomaticHeads: Set<String> = []
        for identifier in inventory.records.keys.sorted() {
            try boundary()
            let record = inventory.records[identifier]!
            guard let location = record.locations.first else {
                throw TractandaError("recoveryError", "Selected revision has no original locator.")
            }
            let (row, revision) = try PooledCanonicalRecord.selectedRecoveryRow(
                record, path: location.path, root: source.root, ownerUID: source.ownerUID,
                readBudget: {
                    try inventoryCheck()
                    try readBudget.record($0)
                }, activity: inventoryActivity)
            // Ordinary DAG metadata is retained without old admission/reconciliation/retirement replay.
            try index.insertGraphCatalogueRow(row, graphFields: revision.fields)
            try recordVerified()
            guard projectCurrentItems else { continue }
            if try revision.provenance?.mergeProfile == RevisionMerge.personalProfile {
                // Raw ancestry, including a merge below an ordinary child, carries its semantics
                // across fresh identity/index creation. Old local configuration is unnecessary.
                try personalMergeObserved()
                if inventory.items[record.itemID]?.heads == [identifier] {
                    personalAutomaticHeads.insert(record.itemID)
                }
            }
            guard inventory.items[record.itemID]?.heads == [identifier],
                !personalAutomaticHeads.contains(record.itemID)
            else { continue }
            if let permissions = revision.fields["permissions"] {
                try ItemPermissions(permissions).validate(using: resolver)
            } else if revision.classID != AccessConfiguration.classID {
                throw TractandaError(
                    "unresolvedPrincipal", "Current revision \(identifier) has no recoverable ACL.")
            }
            let corpus = try PageCorpusInput(storeID: contextID, revision: revision)
            try index.putForRebuild(
                revision, using: statements, corpusInput: corpus, pageProvider: provider,
                corpusBoundary: boundary)
            try index.replacePersonalProjection(
                itemID: revision.itemID, analysis: nil, representative: revision,
                permissions: revision.fields["permissions"], physicalHeads: [identifier])
            try itemProjected()
        }
        let recordsByItem = Dictionary(grouping: inventory.records.values, by: \.itemID)
        for item in inventory.items.values.sorted(by: { $0.itemID < $1.itemID })
        where projectCurrentItems && (item.heads.count > 1 || personalAutomaticHeads.contains(item.itemID)) {
            try boundary()
            var revisions: [String: Revision] = [:]
            var analysis: RevisionMerge.Analysis?
            var representative: Revision?
            var permissions: ItemValue?
            var physicalHeads = item.heads
            var resourceCode: String?
            do {
                let records = recordsByItem[item.itemID]!
                guard records.count <= limits.graph.maximumNodes else {
                    throw TractandaError("resourceLimit", "Personal fork exceeds the analysis window.")
                }
                var bytes = 0
                for record in records {
                    guard record.byteCount <= UInt64(limits.graph.maximumEncodedBytes - bytes) else {
                        throw TractandaError("resourceLimit", "Personal fork exceeds the byte window.")
                    }
                    bytes += Int(record.byteCount)
                    let row = try index.revision(record.revisionID)!
                    try inventoryCheck()
                    try readBudget.record(Int(row.size))
                    revisions[record.revisionID] = try PooledCanonicalRecord.read(
                        row: row, root: source.root, ownerUID: source.ownerUID
                    ).revision
                }
                func graph() throws -> RevisionGraph {
                    try RevisionGraph(
                        nodes: revisions.values.map { revision in
                            try RevisionMerge.node(
                                revision, parent: revision.supersedes.flatMap { revisions[$0] })
                        }, profile: RevisionMerge.personalProfile, limits: limits.graph)
                }
                var current = try graph()
                permissions = try current.personalPermissionPlan?.validatedPOSIXValue(using: resolver)
                analysis = try current.analyze()
                if analysis!.needsMaterialization, let materialize {
                    let (row, revision) = try materialize(current, revisions)
                    revisions[revision.revisionID] = revision
                    current = try graph()
                    analysis = try current.analyze()
                    permissions = try current.personalPermissionPlan?.validatedPOSIXValue(using: resolver)
                    try index.insertGraphCatalogueRow(row, graphFields: revision.fields)
                    physicalHeads = [revision.revisionID]
                }
                representative = analysis!.representativeRevisionID.flatMap { revisions[$0] }
            } catch let error as TractandaError where error.code == "resourceLimit" {
                resourceCode = "personalGraphWindowExceeded"
            }
            if let representative {
                let corpus = try PageCorpusInput(storeID: contextID, revision: representative)
                try index.putForRebuild(
                    representative, using: statements, corpusInput: corpus, pageProvider: provider,
                    corpusBoundary: boundary)
            }
            try index.replacePersonalProjection(
                itemID: item.itemID, analysis: analysis, representative: representative,
                permissions: permissions, physicalHeads: physicalHeads, resourceCode: resourceCode)
            try itemProjected()
        }
        try index.finalizeSavedViewMaterializations()
        // This is derived content metadata, not an old authority admission certificate.
        try index.execute(
            "INSERT OR REPLACE INTO checkpoint_meta VALUES ('personalRecoveryContent','1')")
        try index.execute(
            "INSERT OR REPLACE INTO checkpoint_meta VALUES ('personalRecoveryContext',?)", [contextID])
        return contextID
    }

}
