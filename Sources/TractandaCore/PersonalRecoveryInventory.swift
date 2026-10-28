import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Structural discovery of administrator-selected canonical files. This does not open a store,
/// confer item access, admit peer intake, choose a conflict winner or publish a recovered index.
/// Old-format placement does not establish historical admission; selection is an offline boundary.
enum PersonalRecoveryInventory {
    struct Source: Sendable {
        let root: URL
        let ownerUID: UInt32
    }
    struct Limits: Sendable {
        var maximumSources = 64
        var maximumEntries = 2_000_000
        var maximumRevisions = 250_000
        var maximumEdges = 2_000_000
        var maximumMetadataBytes = 256 * 1024 * 1024
        var maximumTotalRecordBytes: UInt64 = 8 * 1024 * 1024 * 1024
        var maximumTotalPayloadBytes: UInt64 = 64 * 1024 * 1024 * 1024
        var maximumDocumentPages: Int64 = 1_000_000
        var maximumDiagnostics = 10_000
    }
    struct Location: Equatable, Sendable {
        let source: Int
        let path: String
    }
    struct Record: Equatable, Sendable {
        let itemID: String
        let revisionID: String
        let parents: [String]
        let isDeleted: Bool
        let sha256: Data
        let byteCount: UInt64
        var locations: [Location]
    }
    struct Diagnostic: Equatable, Sendable {
        enum Kind: String, Sendable {
            case invalidEntry, conflictingRevision, missingParent, crossItemParent, cycle
            case multipleRoots, unresolvedHeads, missingPayload, invalidPayload, conflictingPayload
        }
        let kind: Kind
        let itemID: String?
        let revisionID: String?
        let location: Location?
        let detail: String
    }
    struct Item: Equatable, Sendable {
        let itemID: String
        /// Physical DAG heads, including tombstones. No timestamp-based winner is selected.
        let heads: [String]
        let revisionCount: Int
        let hasDiagnostics: Bool
    }
    struct ReferencedOriginal: Sendable {
        let itemID: String
        let descriptor: AttachmentDescriptor
        var verifiedLocations: [Location]
    }
    struct ReferencedSavedDocument: Sendable {
        let itemID: String
        let representationID: String
        let attachmentID: String
        let source: AttachmentDocumentSource
        let content: DocumentContentReference
        let verifiedLocations: [Location]
    }
    struct Result: Sendable {
        let records: [String: Record]
        let items: [String: Item]
        /// Only locators whose complete immutable manifest/node/page closure passed validation.
        let validatedDocumentLocations: [String: [Location]]
        let referencedOriginals: [String: ReferencedOriginal]
        let referencedSavedDocuments: [String: ReferencedSavedDocument]
        let diagnostics: [Diagnostic]
        let entriesVisited: Int
        let stagedEntriesExcluded: Int
        /// Actual descriptor sizes/chunks charged before reads, including failed validation attempts.
        let recordBytesBudgeted: UInt64
        let payloadBytesBudgeted: UInt64
        /// Structural readiness only; runtime startup, ACL projection and publication are separate.
        var isStructurallyComplete: Bool { diagnostics.isEmpty }
    }

    static func inspect(
        _ sources: [Source], limits: Limits = Limits(),
        check: @escaping @Sendable () throws -> Void = {},
        activity: @escaping @Sendable () throws -> Void = {},
        graphActivity: () throws -> Void = {},
        originalVerified: @escaping @Sendable (Int64) throws -> Void = { _ in },
        pageVerified: @escaping @Sendable () throws -> Void = {}, documentReadFailureForTesting: Int32? = nil
    ) throws -> Result {
        guard !sources.isEmpty, sources.count <= limits.maximumSources, limits.maximumEntries > 0,
            limits.maximumRevisions > 0,
            limits.maximumEdges > 0, limits.maximumMetadataBytes > 0,
            limits.maximumDiagnostics > 0, limits.maximumDocumentPages > 0
        else { throw TractandaError("resourceLimit", "Invalid recovery inventory limits.") }
        var records: [String: Record] = [:]
        var diagnostics: [Diagnostic] = []
        var attachments: [String: (String, AttachmentDescriptor)] = [:]
        var referencedOriginals: [String: ReferencedOriginal] = [:]
        var documents: [String: (String, AttachmentDocumentRepresentation)] = [:]
        var payloadPaths: [String: [Location]] = [:]
        var documentPaths: [String: [Location]] = [:]
        var validatedDocumentLocations: [String: [Location]] = [:]
        var entries = 0
        var excluded = 0
        var edges = 0
        var metadataBytes = 0
        var recordBytes: UInt64 = 0
        var payloadBytes: UInt64 = 0
        func chargeMetadata(_ count: Int) throws {
            guard count >= 0, count <= limits.maximumMetadataBytes - metadataBytes else {
                throw TractandaError("resourceLimit", "Recovery inventory metadata budget exceeded.")
            }
            metadataBytes += count
        }
        func problem(
            _ kind: Diagnostic.Kind, item: String? = nil, revision: String? = nil,
            at location: Location? = nil, _ detail: String
        ) throws {
            guard diagnostics.count < limits.maximumDiagnostics else {
                throw TractandaError("resourceLimit", "Recovery diagnostic budget exceeded.")
            }
            try chargeMetadata(256 + detail.utf8.count + (location?.path.utf8.count ?? 0))
            var itemID = item
            var revisionID = revision
            if kind == .invalidEntry, let location {
                let parts = location.path.split(separator: "/")
                if parts.count == 8, parts[7].hasSuffix(".tractanda") {
                    let pathItem = String(parts[6])
                    let pathRevision = String(parts[7].dropLast(".tractanda".count))
                    if CanonicalRecordPath.validate(location.path, itemID: pathItem, revisionID: pathRevision)
                    {
                        itemID = itemID ?? pathItem
                        revisionID = revisionID ?? pathRevision
                    }
                }
            }
            diagnostics.append(
                .init(
                    kind: kind, itemID: itemID, revisionID: revisionID, location: location, detail: detail))
        }
        func charge(_ count: UInt64, total: inout UInt64, maximum: UInt64) throws {
            guard count <= maximum - total else {
                throw TractandaError("resourceLimit", "Recovery inventory read budget exceeded.")
            }
            total += count
            try check()
        }
        func mustPropagate(_ error: Error) -> Bool {
            if let failure = error as? TractandaError, failure.code == "documentIntegrity",
                failure.osError.map({
                    [EIO, ENOSPC, EDQUOT, EBUSY, EMFILE, ENFILE, ENOMEM, EINTR].contains($0)
                }) == true
            {
                return true
            }
            if case FileMetadataError.posix(let code) = error,
                [EIO, ENOSPC, EDQUOT, EBUSY, EMFILE, ENFILE, ENOMEM, EINTR].contains(code)
            {
                return true
            }
            return error is CancellationError
                || ["resourceLimit", "cancelled", "rebuildNoProgress"].contains(
                    (error as? TractandaError)?.code ?? "")
        }

        // Pin each selected root once. Later reads cannot follow a replaced root pathname.
        var rootDescriptors: [Int32] = []
        defer { for fd in rootDescriptors.reversed() { _ = close(fd) } }
        for source in sources {
            let root = source.root.standardizedFileURL
            guard root.path != "/", !root.path.utf8.contains(0) else {
                throw TractandaError("invalidRecoveryScope", "Invalid selected canonical root.")
            }
            let fd = root.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw FileMetadataError.posix(errno) }
            rootDescriptors.append(fd)
            let metadata = try PooledCanonicalRecord.inventoryMetadata(for: fd)
            guard metadata.uid == source.ownerUID, metadata.mode & 0o077 == 0 else {
                throw TractandaError("invalidRecoveryScope", "Selected canonical root is not owner-private.")
            }
        }

        // Descriptor-relative traversal streams one directory entry at a time. It never enters
        // hidden work/intake/staging trees or follows a symlink, including replaced directories.
        func walk(
            _ source: Int, base: [String], leafDepth: Int, directoryLeaf: Bool,
            visit: (Location, FileMetadata, Int32) throws -> Void
        ) throws {
            let rootFD = rootDescriptors[source]
            func descend(_ parent: Int32, _ parts: [String]) throws {
                try POSIXDirectory.withEntries(descriptor: parent) { name in
                    guard entries < limits.maximumEntries else {
                        throw TractandaError("resourceLimit", "Recovery entry budget exceeded.")
                    }
                    entries += 1
                    try activity()
                    if name.hasPrefix(".") {
                        excluded += 1
                        return true
                    }
                    let path = parts + [name]
                    let location = Location(source: source, path: path.joined(separator: "/"))
                    // O_NONBLOCK prevents special files from blocking before type validation.
                    let fd = name.withCString {
                        openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    }
                    guard fd >= 0 else {
                        try problem(
                            .invalidEntry, at: location, "Cannot open selected entry without following links."
                        )
                        return true
                    }
                    defer { _ = close(fd) }
                    let metadata = try PooledCanonicalRecord.inventoryMetadata(for: fd)
                    guard metadata.uid == sources[source].ownerUID, metadata.mode & 0o077 == 0 else {
                        try problem(.invalidEntry, at: location, "Selected entry is not owner-private.")
                        return true
                    }
                    if path.count == leafDepth {
                        guard metadata.type == (directoryLeaf ? .directory : .regular) else {
                            try problem(.invalidEntry, at: location, "Unexpected published entry type.")
                            return true
                        }
                        // Temporary atomic-write siblings are never published revisions.
                        if !directoryLeaf, path.first == "items", !name.hasSuffix(".tractanda") {
                            if name.contains(".tractanda.") {
                                excluded += 1
                                return true
                            }
                        }
                        try visit(location, metadata, fd)
                    } else if path.count < leafDepth, metadata.type == .directory {
                        try descend(fd, path)
                    } else {
                        try problem(.invalidEntry, at: location, "Unexpected entry in published tree.")
                    }
                    return true
                }
            }
            var descriptors: [Int32] = []
            defer { for fd in descriptors.reversed() { _ = close(fd) } }
            var parent = rootFD
            for component in base {
                let fd = component.withCString {
                    openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                if fd < 0, errno == ENOENT {
                    if base == ["items"] {
                        try problem(
                            .invalidEntry, at: Location(source: source, path: "items"),
                            "Selected root has no canonical items directory.")
                    }
                    return
                }
                guard fd >= 0 else { throw FileMetadataError.posix(errno) }
                descriptors.append(fd)
                let metadata = try PooledCanonicalRecord.inventoryMetadata(for: fd)
                guard metadata.uid == sources[source].ownerUID, metadata.mode & 0o077 == 0 else {
                    throw TractandaError(
                        "invalidRecoveryScope", "Selected published tree is not owner-private.")
                }
                parent = fd
            }
            try descend(parent, base)
        }
        for source in sources.indices {
            try walk(source, base: ["items"], leafDepth: 8, directoryLeaf: false) { location, _, descriptor in
                do {
                    let loaded = try PooledCanonicalRecord.readForInventory(
                        path: location.path, descriptor: descriptor, ownerUID: sources[source].ownerUID,
                        readBudget: {
                            try charge(
                                UInt64($0), total: &recordBytes, maximum: limits.maximumTotalRecordBytes)
                        }, progress: activity)
                    let revision = loaded.record.revision
                    let parents = try revision.provenance?.parents ?? revision.supersedes.map { [$0] } ?? []
                    try chargeMetadata(
                        512 + location.path.utf8.count + parents.reduce(0) { $0 + $1.utf8.count + 64 })
                    if records[revision.revisionID] != nil {
                        guard records[revision.revisionID]!.sha256 == loaded.digest else {
                            let old = records[revision.revisionID]!
                            try problem(
                                .conflictingRevision, item: old.itemID, revision: revision.revisionID,
                                at: location, "One revision ID has conflicting canonical bytes.")
                            if old.itemID != revision.itemID {
                                try problem(
                                    .conflictingRevision, item: revision.itemID,
                                    revision: revision.revisionID,
                                    at: location, "The conflicting revision also claims this item.")
                            }
                            return
                        }
                        records[revision.revisionID]!.locations.append(location)
                        return
                    }
                    guard records.count < limits.maximumRevisions,
                        parents.count <= limits.maximumEdges - edges
                    else { throw TractandaError("resourceLimit", "Recovery DAG count budget exceeded.") }
                    edges += parents.count
                    records[revision.revisionID] = Record(
                        itemID: revision.itemID, revisionID: revision.revisionID, parents: parents,
                        isDeleted: revision.isDeleted, sha256: loaded.digest,
                        byteCount: loaded.record.metadata.size,
                        locations: [location])
                    for attachment in try AttachmentDescriptor.descriptors(in: revision.fields) {
                        if let old = attachments[attachment.attachmentID] {
                            if old.0 != revision.itemID || old.1 != attachment {
                                try problem(
                                    .conflictingPayload, item: revision.itemID,
                                    revision: revision.revisionID, at: location,
                                    "Attachment identity has conflicting ownership or descriptors.")
                            }
                        } else {
                            try chargeMetadata(512 + (try JSON.encode(attachment).count))
                            attachments[attachment.attachmentID] = (revision.itemID, attachment)
                        }
                    }
                    for document in try AttachmentDocumentRepresentation.representations(in: revision.fields)
                    {
                        guard let content = document.content else { continue }
                        if let old = documents[content.contentID] {
                            if old.0 != revision.itemID || old.1 != document {
                                try problem(
                                    .conflictingPayload, item: revision.itemID,
                                    revision: revision.revisionID, at: location,
                                    "Document identity has conflicting ownership or descriptors.")
                            }
                        } else {
                            try chargeMetadata(512 + (try JSON.encode(document).count))
                            documents[content.contentID] = (revision.itemID, document)
                        }
                    }
                } catch {
                    if mustPropagate(error) { throw error }
                    try problem(.invalidEntry, at: location, "Invalid canonical record: \(error)")
                }
            }
            try walk(source, base: ["attachments", "payloads"], leafDepth: 8, directoryLeaf: false) {
                location, _, _ in
                let name = URL(fileURLWithPath: location.path).deletingPathExtension().lastPathComponent
                do { try PayloadPlacement.validate(location.path, id: name) } catch {
                    try problem(.invalidEntry, at: location, "Invalid original payload placement.")
                    return
                }
                try chargeMetadata(128 + location.path.utf8.count)
                payloadPaths[name, default: []].append(location)
            }
            try walk(source, base: ["documents", "content"], leafDepth: 8, directoryLeaf: true) {
                location, _, _ in
                let name = URL(fileURLWithPath: location.path).lastPathComponent
                do { try DocumentPlacement.validate(location.path, id: name) } catch {
                    try problem(.invalidEntry, at: location, "Invalid saved document placement.")
                    return
                }
                try chargeMetadata(128 + location.path.utf8.count)
                documentPaths[name, default: []].append(location)
            }
        }
        for (id, (item, attachment)) in attachments {
            try chargeMetadata(256)
            referencedOriginals[id] = .init(itemID: item, descriptor: attachment, verifiedLocations: [])
            guard let locations = payloadPaths[id] else {
                try problem(.missingPayload, item: item, "Missing original attachment \(id).")
                continue
            }
            for location in locations {
                try Task.checkCancellation()
                do {
                    let source = sources[location.source]
                    try AttachmentPayloadStore.validateForInventory(
                        attachment, path: location.path, root: source.root,
                        rootDescriptor: rootDescriptors[location.source], ownerUID: source.ownerUID,
                        readBudget: {
                            try charge(
                                UInt64($0), total: &payloadBytes, maximum: limits.maximumTotalPayloadBytes)
                        }, progress: { _ in try activity() })
                    try originalVerified(attachment.byteCount)
                    try chargeMetadata(128)
                    referencedOriginals[id]!.verifiedLocations.append(location)
                } catch {
                    if mustPropagate(error) { throw error }
                    try problem(
                        .invalidPayload, item: item, at: location, "Original attachment invalid: \(error)")
                }
            }
        }
        for (id, (item, document)) in documents {
            let content = document.content!
            guard let locations = documentPaths[id] else {
                try problem(.missingPayload, item: item, "Missing saved document \(id).")
                continue
            }
            for location in locations {
                try Task.checkCancellation()
                guard content.pageCount <= limits.maximumDocumentPages else {
                    throw TractandaError("resourceLimit", "Recovery document page budget exceeded.")
                }
                do {
                    let source = sources[location.source]
                    try DocumentContentStore.validateForInventory(
                        document, path: location.path, root: source.root,
                        rootDescriptor: rootDescriptors[location.source], ownerUID: source.ownerUID,
                        readBudget: {
                            try charge(
                                UInt64($0), total: &payloadBytes, maximum: limits.maximumTotalPayloadBytes)
                        },
                        progress: { _ in
                            try activity()
                            try pageVerified()
                        }, readFailureForTesting: documentReadFailureForTesting)
                    try chargeMetadata(128)
                    validatedDocumentLocations[id, default: []].append(location)
                } catch {
                    if mustPropagate(error) { throw error }
                    try problem(.invalidPayload, item: item, at: location, "Saved document invalid: \(error)")
                }
            }
        }

        var referencedSavedDocuments: [String: ReferencedSavedDocument] = [:]
        for (id, (item, document)) in documents {
            try chargeMetadata(512)
            referencedSavedDocuments[id] = .init(
                itemID: item, representationID: document.representationID,
                attachmentID: document.attachmentID, source: document.source,
                content: document.content!, verifiedLocations: validatedDocumentLocations[id] ?? [])
        }

        // Kahn traversal visits each edge once. No ancestor sets, repeated scans or timestamp sorting.
        var children: [String: [String]] = [:]
        var byItem: [String: [String]] = [:]
        var roots: [String: Int] = [:]
        var ready: [String] = []
        for (id, record) in records {
            byItem[record.itemID, default: []].append(id)
            if record.parents.isEmpty { roots[record.itemID, default: 0] += 1 }
            for parent in record.parents {
                guard let prior = records[parent] else {
                    try problem(
                        .missingParent, item: record.itemID, revision: id, "Missing parent \(parent).")
                    continue
                }
                guard prior.itemID == record.itemID else {
                    try problem(
                        .crossItemParent, item: record.itemID, revision: id, "Parent belongs to another item."
                    )
                    continue
                }
                children[parent, default: []].append(id)
            }
        }
        // Removing absent/cross-item edges before the peel distinguishes missing ancestry from
        // cycles. Every retained node downstream from a cycle belongs to an affected item.
        var cycleDegree: [String: Int] = [:]
        ready.removeAll(keepingCapacity: true)
        for (id, record) in records {
            let count = record.parents.filter { records[$0]?.itemID == record.itemID }.count
            cycleDegree[id] = count
            if count == 0 { ready.append(id) }
        }
        var cursor = 0
        while cursor < ready.count {
            try Task.checkCancellation()
            if cursor % 128 == 0 {
                try graphActivity()
                try activity()
            }
            let id = ready[cursor]
            cursor += 1
            for child in children[id] ?? [] {
                cycleDegree[child]! -= 1
                if cycleDegree[child] == 0 { ready.append(child) }
            }
        }
        var cyclicItems: Set<String> = []
        for (id, degree) in cycleDegree where degree > 0 {
            cyclicItems.insert(records[id]!.itemID)
        }
        for item in cyclicItems {
            try problem(.cycle, item: item, "Ancestry contains a cycle; no current projection is chosen.")
        }
        var headsByItem: [String: [String]] = [:]
        for (id, record) in records where children[id] == nil {
            headsByItem[record.itemID, default: []].append(id)
        }
        for item in byItem.keys {
            if roots[item, default: 0] != 1 {
                try problem(.multipleRoots, item: item, "An item must have one initial revision.")
            }
        }
        let affected = Set(diagnostics.compactMap(\.itemID))
        var items: [String: Item] = [:]
        for (item, revisions) in byItem {
            items[item] = Item(
                itemID: item, heads: headsByItem[item, default: []].sorted(),
                revisionCount: revisions.count, hasDiagnostics: affected.contains(item))
        }
        return Result(
            records: records, items: items, validatedDocumentLocations: validatedDocumentLocations,
            referencedOriginals: referencedOriginals, referencedSavedDocuments: referencedSavedDocuments,
            diagnostics: diagnostics, entriesVisited: entries,
            stagedEntriesExcluded: excluded, recordBytesBudgeted: recordBytes,
            payloadBytesBudgeted: payloadBytes)
    }
}
