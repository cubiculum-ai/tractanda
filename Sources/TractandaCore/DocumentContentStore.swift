import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct DocumentManifest: Codable, Equatable, Sendable {
    let schema: String
    let contentID: String
    let publicationID: String
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let extractedAt: String
    let rootLevel: Int
    let rootByteCount: Int64
    let rootSHA256: String
    let pageCount: Int64
    let totalEncodedBytes: Int64
    let coverage: DocumentCoverage
}

struct DocumentHashEntry: Codable, Equatable, Sendable {
    let ordinal: Int64
    let firstPage: Int64
    let lastPage: Int64
    let byteCount: Int64
    let sha256: String
}

struct DocumentHashNode: Codable, Equatable, Sendable {
    let schema: String
    let level: Int
    let ordinal: Int64
    let entries: [DocumentHashEntry]
    func validate() throws {
        guard schema == "tractanda.document-node.v2", (0...8).contains(level), ordinal >= 0,
            (1...128).contains(entries.count)
        else {
            throw TractandaError("documentIntegrity", "Invalid bounded document hash node.")
        }
        var prior: DocumentHashEntry?
        for entry in entries {
            guard entry.ordinal >= 0, entry.firstPage > 0, entry.lastPage >= entry.firstPage,
                entry.byteCount > 0, Self.isDigest(entry.sha256),
                level != 0 || (entry.ordinal == entry.firstPage && entry.lastPage == entry.firstPage)
            else {
                throw TractandaError("documentIntegrity", "Invalid document dependency entry.")
            }
            if let prior {
                let next = prior.lastPage.addingReportingOverflow(1)
                let ordinal = prior.ordinal.addingReportingOverflow(1)
                guard !next.overflow, !ordinal.overflow, entry.firstPage == next.partialValue,
                    entry.ordinal == ordinal.partialValue
                else {
                    throw TractandaError("documentIntegrity", "Document hash ranges are not contiguous.")
                }
            }
            prior = entry
        }
    }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Self-contained immutable content. Every page read verifies one bounded proof path;
/// full recovery streams pages and never materializes a document-sized Swift collection.
final class DocumentContentStore: @unchecked Sendable {
    static let maximumPageBytes = 2 * 1024 * 1024
    static let maximumNodeBytes = 64 * 1024
    private let files: DocumentContentFiles
    private let root: URL
    private let ownerUID: UInt32
    private var placement: DocumentPlacement!
    var placementArrivalMinuteForTesting: () throws -> String {
        get { placement.arrivalMinute }
        set { placement.arrivalMinute = newValue }
    }
    var afterPlacementIntentForTesting: (() throws -> Void)? {
        get { placement.afterIntent }
        set { placement.afterIntent = newValue }
    }
    var afterPlacementTreeForTesting: (() throws -> Void)? {
        get { placement.afterFile }
        set { placement.afterFile = newValue }
    }
    var placementRecoveryScansForTesting: Int { placement.recoveryScans }
    var afterDirectoryRenameForTesting: (() throws -> Void)? {
        get { files.afterDirectoryRenameForTesting }
        set { files.afterDirectoryRenameForTesting = newValue }
    }
    var beforePublicationSyncForTesting: (() throws -> Void)? {
        get { files.beforePublicationSyncForTesting }
        set { files.beforePublicationSyncForTesting = newValue }
    }
    var beforeDirectoryPublicationForTesting: (() throws -> Void)?
    private let counterLock = NSLock()
    private var pageReadCount: Int64 = 0
    var pageReadsForTesting: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return pageReadCount
    }

    init(
        root: URL, ownerUID: UInt32, minimumFreeBytes: Int64 = AttachmentPayloadStore.defaultReserveBytes,
        availableBytes: (@Sendable () throws -> UInt64)? = nil, stagingQuota: StagingByteQuota? = nil,
        indexDirectory: URL? = nil, maintenance: CanonicalMaintenanceContext? = nil
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.ownerUID = ownerUID
        files = DocumentContentFiles(
            root: self.root, ownerUID: ownerUID, minimumFreeBytes: minimumFreeBytes,
            availableBytes: availableBytes, stagingQuota: stagingQuota
        )
        placement = DocumentPlacement(
            root: self.root, indexDirectory: indexDirectory, ownerUID: ownerUID, maintenance: maintenance
        ) {
            [weak self] bytes, location in
            guard let self else { throw TractandaError("documentIntegrity", "Document storage closed.") }
            try self.files.requireCapacity(bytes, at: location)
        }
    }
    func begin(
        source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String = Timestamp.now(), maximumWriteBytes: Int64 = .max
    ) throws -> DocumentContentWriter {
        try preparePlacement()
        try source.validate()
        try identity.validate()
        guard Timestamp.parse(extractedAt) != nil, maximumWriteBytes > 0 else {
            throw TractandaError("invalidDocumentContent", "Invalid extraction stage metadata.")
        }
        let id = try UUID.makeVersion1().uuidString.lowercased()
        let stage = ["documents", ".staging", id]
        try files.createUniqueDirectory(stage)
        return DocumentContentWriter(
            store: self, stage: stage, source: source, identity: identity,
            extractedAt: extractedAt, maximumWriteBytes: maximumWriteBytes)
    }
    func beginJob(
        id: String, source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String
    ) throws -> [String] {
        try preparePlacement()
        try Identifier.validate(id)
        guard UUID(uuidString: id)?.version1Components != nil else {
            throw integrity("Job stage identity must be UUIDv1.")
        }
        try source.validate()
        try identity.validate()
        guard Timestamp.parse(extractedAt) != nil else { throw integrity("Invalid job extraction date.") }
        let stage = ["documents", ".staging", id]
        do { try files.createUniqueDirectory(stage) } catch let error as TractandaError
            where error.osError == EEXIST
        {
            try files.synchronizeDirectory(stage)
        }
        return stage
    }
    /// Replays one page at a time and at most one page beyond the durable checkpoint.
    func reopenJob(
        stage: [String], source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String, acceptedPages: Int64, pageCount: Int64?, maximumWriteBytes: Int64 = .max
    ) throws -> DocumentContentWriter {
        guard stage.count == 3, stage.prefix(2) == ["documents", ".staging"],
            UUID(uuidString: stage[2])?.version1Components != nil, acceptedPages >= 0,
            pageCount.map({ $0 > 0 && acceptedPages <= $0 }) ?? (acceptedPages == 0)
        else { throw integrity("Invalid resumable page frontier.") }
        let writer = DocumentContentWriter(
            store: self, stage: stage, source: source, identity: identity,
            extractedAt: extractedAt, maximumWriteBytes: maximumWriteBytes)
        var number: Int64 = 1
        while number <= acceptedPages {
            try writer.append(
                readStagedPage(stage: stage, source: source, identity: identity, number: number))
            guard number < Int64.max else { return writer }
            number += 1
        }
        if let pageCount, number <= pageCount,
            let bytes = try files.readIfPresent(
                path: stage + pagePath(number), maximumBytes: Self.maximumPageBytes)
        {
            let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: bytes)
            try validate(page, source: source, identity: identity)
            try writer.append(page)
            guard number < Int64.max else { return writer }
            number += 1
        }
        if try files.readIfPresent(path: stage + pagePath(number), maximumBytes: Self.maximumPageBytes) != nil
        {
            throw integrity("More than one page lies beyond the durable job frontier.")
        }
        return writer
    }
    func readStagedPage(
        stage: [String], source: AttachmentDocumentSource, identity: DocumentConverterIdentity, number: Int64
    ) throws -> DocumentStoredPage {
        guard number > 0 else { throw integrity("Invalid provisional page number.") }
        let bytes = try files.read(path: stage + pagePath(number), maximumBytes: Self.maximumPageBytes)
        let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: bytes)
        try validate(page, source: source, identity: identity)
        guard page.pageNumber == number else { throw integrity("Provisional page ordinal changed.") }
        return page
    }
    func manifest(_ reference: DocumentContentReference) throws -> DocumentManifest {
        try reference.validate()
        let data = try files.read(
            path: try directory(reference.contentID) + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
        return try decodeManifest(data, reference: reference)
    }
    private func decodeManifest(_ data: Data, reference: DocumentContentReference) throws -> DocumentManifest
    {
        try reference.validate()
        guard digest(data) == reference.manifestSHA256 else {
            throw integrity("Document manifest checksum changed.")
        }
        let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: data)
        try manifest.source.validate()
        try manifest.identity.validate()
        guard manifest.schema == "tractanda.document-manifest.v2", manifest.contentID == reference.contentID,
            manifest.rootSHA256 == reference.rootSHA256, manifest.pageCount == reference.pageCount,
            manifest.totalEncodedBytes == reference.totalEncodedBytes,
            manifest.coverage == reference.coverage,
            UUID(uuidString: manifest.publicationID)?.version1Components != nil,
            Timestamp.parse(manifest.extractedAt) != nil, (0...8).contains(manifest.rootLevel),
            manifest.rootByteCount > 0, manifest.rootByteCount <= Self.maximumNodeBytes
        else {
            throw integrity("Manifest does not match its canonical reference.")
        }
        return manifest
    }
    func readPage(_ reference: DocumentContentReference, pageNumber: Int64) throws -> DocumentStoredPage {
        let manifest = try manifest(reference)
        guard pageNumber > 0, pageNumber <= reference.pageCount else {
            throw TractandaError("notFound", "Saved page is unavailable.")
        }
        let base = try directory(reference.contentID)
        var level = manifest.rootLevel
        var entry = DocumentHashEntry(
            ordinal: 0, firstPage: 1, lastPage: manifest.pageCount, byteCount: manifest.rootByteCount,
            sha256: manifest.rootSHA256)
        while true {
            let bytes = try files.read(
                path: base + nodePath(level: level, ordinal: entry.ordinal),
                maximumBytes: Self.maximumNodeBytes)
            guard Int64(bytes.count) == entry.byteCount, digest(bytes) == entry.sha256 else {
                throw integrity("Document proof node checksum changed.")
            }
            let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: bytes)
            try node.validate()
            guard node.level == level, node.ordinal == entry.ordinal,
                node.entries.first?.firstPage == entry.firstPage,
                node.entries.last?.lastPage == entry.lastPage,
                let selected = node.entries.first(where: {
                    $0.firstPage <= pageNumber && $0.lastPage >= pageNumber
                })
            else {
                throw integrity("Document proof path does not cover its page.")
            }
            entry = selected
            if level == 0 { break }
            level -= 1
        }
        let data = try files.read(path: base + pagePath(pageNumber), maximumBytes: Self.maximumPageBytes)
        guard Int64(data.count) == entry.byteCount, digest(data) == entry.sha256 else {
            throw integrity("Saved page checksum changed.")
        }
        let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: data)
        try validate(page, source: manifest.source, identity: manifest.identity)
        guard page.pageNumber == pageNumber else { throw integrity("Saved page identity changed.") }
        counterLock.lock()
        pageReadCount += 1
        counterLock.unlock()
        return page
    }
    func validate(
        _ reference: DocumentContentReference, source: AttachmentDocumentSource,
        identity: DocumentConverterIdentity, extractedAt: String, boundary: () throws -> Void = {},
        progress: (Int64) throws -> Void = { _ in }
    ) throws {
        try validateStoredContent(
            reference, source: source, identity: identity, extractedAt: extractedAt,
            base: directory(reference.contentID), boundary: boundary, progress: progress)
    }
    private func validateStoredContent(
        _ reference: DocumentContentReference, source: AttachmentDocumentSource,
        identity: DocumentConverterIdentity, extractedAt: String, base: [String],
        boundary: () throws -> Void = {}, progress: (Int64) throws -> Void = { _ in },
        readBudget: ((Int) throws -> Void)? = nil,
        visit: (DocumentStoredPage, Int) throws -> Void = { _, _ in }
    ) throws {
        let data = try files.read(
            path: base + ["manifest.json"], maximumBytes: Self.maximumNodeBytes, readBudget: readBudget)
        let manifest = try decodeManifest(data, reference: reference)
        guard manifest.source == source, manifest.identity == identity, manifest.extractedAt == extractedAt
        else {
            throw integrity("Document provenance differs from its canonical representation.")
        }
        var total: Int64 = 0
        var counts = [Int64](repeating: 0, count: 5)
        try visitClosure(
            base: base,
            rootEntry: .init(
                ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
                byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256),
            level: manifest.rootLevel, source: source, identity: identity, boundary: boundary,
            readBudget: readBudget
        ) { page, encodedCount in
            let sum = total.addingReportingOverflow(Int64(encodedCount))
            guard !sum.overflow else { throw integrity("Saved document byte count overflowed.") }
            total = sum.partialValue
            counts[try statusIndex(page.status)] += 1
            try progress(page.pageNumber)
            try visit(page, encodedCount)
        }
        let coverage = try DocumentCoverage(
            converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
            failed: counts[4])
        guard total == manifest.totalEncodedBytes, coverage == manifest.coverage else {
            throw integrity("Document closure count or coverage changed.")
        }
    }

    private init(inventoryRoot: URL, ownerUID: UInt32, rootDescriptor: Int32) {
        root = inventoryRoot
        self.ownerUID = ownerUID
        files = DocumentContentFiles(
            root: inventoryRoot, ownerUID: ownerUID, minimumFreeBytes: 0, rootDescriptor: rootDescriptor)
    }
    /// Read-only recovery borrows the selected root descriptor and never resolves placement SQLite.
    static func validateForInventory(
        _ representation: AttachmentDocumentRepresentation, path: String, root: URL,
        rootDescriptor: Int32, ownerUID: UInt32, readBudget: @escaping (Int) throws -> Void,
        progress: (Int64) throws -> Void = { _ in }
    ) throws {
        guard let reference = representation.content else {
            throw TractandaError("documentIntegrity", "Recovery requires a saved document reference.")
        }
        try DocumentPlacement.validate(path, id: reference.contentID)
        let validator = Self(inventoryRoot: root, ownerUID: ownerUID, rootDescriptor: rootDescriptor)
        try validator.validateStoredContent(
            reference, source: representation.source, identity: representation.identity,
            extractedAt: representation.extractedAt, base: path.split(separator: "/").map(String.init),
            progress: progress, readBudget: readBudget)
    }

    /// Streams the same authenticated immutable closure against an explicitly selected base.
    /// No placement database, local store identity or canonical operational state is consulted.
    /// The caller keeps the borrowed root descriptor open until this synchronous visit returns.
    static func forEachRecoveryPage(
        document: PageCorpusDocumentPlan, path: String, root: URL, rootDescriptor: Int32,
        ownerUID: UInt32, readBudget: @escaping (Int) throws -> Void,
        visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        guard !document.isIncoming, let reference = document.savedContent,
            document.rootSHA256 == reference.rootSHA256, document.pageCount == reference.pageCount,
            document.totalEncodedBytes == reference.totalEncodedBytes, document.coverage == reference.coverage
        else {
            throw TractandaError("documentIntegrity", "Recovery requires committed saved document content.")
        }
        try DocumentPlacement.validate(path, id: reference.contentID)
        let reader = Self(inventoryRoot: root, ownerUID: ownerUID, rootDescriptor: rootDescriptor)
        try reader.validateStoredContent(
            reference, source: document.source, identity: document.identity,
            extractedAt: document.extractedAt, base: path.split(separator: "/").map(String.init),
            readBudget: readBudget, visit: visit)
    }
    func part(
        _ reference: DocumentContentReference, kind: String, level requestedLevel: Int = 0,
        index: Int64 = 0, offset: Int64 = 0, limit: Int = 262_144
    ) throws -> DocumentContentPart {
        let manifest = try manifest(reference)
        guard offset >= 0, (1...262_144).contains(limit) else {
            throw TractandaError("invalidArguments", "Use a bounded document dependency byte window.")
        }
        let base = try directory(reference.contentID)
        let path: [String]
        let expected: String
        if kind == "manifest" {
            guard index == 0, requestedLevel == 0 else {
                throw TractandaError("invalidArguments", "Manifest has no ordinal.")
            }
            path = ["manifest.json"]
            expected = reference.manifestSHA256
        } else {
            guard ["node", "page"].contains(kind), index >= 0, requestedLevel >= 0,
                requestedLevel <= manifest.rootLevel
            else { throw TractandaError("invalidArguments", "Invalid document dependency selection.") }
            var level = manifest.rootLevel
            var entry = DocumentHashEntry(
                ordinal: 0, firstPage: 1, lastPage: manifest.pageCount, byteCount: manifest.rootByteCount,
                sha256: manifest.rootSHA256)
            while true {
                let bytes = try files.read(
                    path: base + nodePath(level: level, ordinal: entry.ordinal),
                    maximumBytes: Self.maximumNodeBytes)
                guard digest(bytes) == entry.sha256, Int64(bytes.count) == entry.byteCount else {
                    throw integrity("Document proof node changed.")
                }
                let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: bytes)
                try node.validate()
                guard node.level == level, node.ordinal == entry.ordinal,
                    node.entries.first?.firstPage == entry.firstPage,
                    node.entries.last?.lastPage == entry.lastPage
                else { throw integrity("Document proof identity changed.") }
                if kind == "node", level == requestedLevel {
                    guard entry.ordinal == index else {
                        throw TractandaError("notFound", "Document node is not reachable.")
                    }
                    path = nodePath(level: level, ordinal: index)
                    expected = entry.sha256
                    break
                }
                if kind == "page", level == 0 {
                    guard let leaf = node.entries.first(where: { $0.ordinal == index }) else {
                        throw TractandaError("notFound", "Document page is not reachable.")
                    }
                    path = pagePath(index)
                    expected = leaf.sha256
                    break
                }
                if kind == "page" {
                    guard index > 0, index <= manifest.pageCount,
                        let child = node.entries.first(where: {
                            $0.firstPage <= index && $0.lastPage >= index
                        })
                    else { throw TractandaError("notFound", "Document page is not reachable.") }
                    entry = child
                } else {
                    var wanted = index
                    for _ in 0..<(level - requestedLevel - 1) { wanted /= 128 }
                    guard let child = node.entries.first(where: { $0.ordinal == wanted }) else {
                        throw TractandaError("notFound", "Document node is not reachable.")
                    }
                    entry = child
                }
                level -= 1
            }
        }
        let bytes = try files.read(
            path: base + path, maximumBytes: kind == "page" ? Self.maximumPageBytes : Self.maximumNodeBytes)
        guard digest(bytes) == expected, offset <= Int64(bytes.count) else {
            throw integrity("Document dependency bytes or range changed.")
        }
        let count = Int(min(Int64(limit), Int64(bytes.count) - offset))
        let start = Int(offset)
        return DocumentContentPart(
            contentID: reference.contentID, relativePath: path.joined(separator: "/"),
            byteCount: Int64(bytes.count),
            sha256: expected, offset: offset, nextOffset: offset + Int64(count),
            data: bytes.subdata(in: start..<(start + count)))
    }

    func forEachPage(
        _ reference: DocumentContentReference, boundary: () throws -> Void = {},
        _ visit: (DocumentStoredPage) throws -> Void
    )
        throws
    {
        try forEachEncodedPage(reference, boundary: boundary) { page, _ in try visit(page) }
    }
    func forEachEncodedPage(
        _ reference: DocumentContentReference, boundary: () throws -> Void = {},
        _ visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        let manifest = try manifest(reference)
        let rootEntry = DocumentHashEntry(
            ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
            byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256)
        try visitClosure(
            base: directory(reference.contentID), rootEntry: rootEntry, level: manifest.rootLevel,
            source: manifest.source, identity: manifest.identity, boundary: boundary,
            visit: visit)
    }
    private func visitClosure(
        base: [String], rootEntry: DocumentHashEntry, level: Int,
        source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        boundary: () throws -> Void = {}, part: () throws -> Void = {},
        readBudget: ((Int) throws -> Void)? = nil, visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        try Task.checkCancellation()
        try boundary()
        try part()
        let data = try files.read(
            path: base + nodePath(level: level, ordinal: rootEntry.ordinal),
            maximumBytes: Self.maximumNodeBytes, readBudget: readBudget)
        guard Int64(data.count) == rootEntry.byteCount, digest(data) == rootEntry.sha256 else {
            throw integrity("Document closure node checksum changed.")
        }
        let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: data)
        try node.validate()
        guard node.level == level, node.ordinal == rootEntry.ordinal,
            node.entries.first?.firstPage == rootEntry.firstPage,
            node.entries.last?.lastPage == rootEntry.lastPage
        else {
            throw integrity("Document closure range changed.")
        }
        for entry in node.entries {
            try Task.checkCancellation()
            try boundary()
            if level > 0 {
                try visitClosure(
                    base: base, rootEntry: entry, level: level - 1, source: source, identity: identity,
                    boundary: boundary, part: part, readBudget: readBudget, visit: visit)
            } else {
                try part()
                let bytes = try files.read(
                    path: base + pagePath(entry.ordinal), maximumBytes: Self.maximumPageBytes,
                    readBudget: readBudget)
                guard Int64(bytes.count) == entry.byteCount, digest(bytes) == entry.sha256 else {
                    throw integrity("Saved page checksum changed.")
                }
                let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: bytes)
                try validate(page, source: source, identity: identity)
                guard page.pageNumber == entry.ordinal else { throw integrity("Saved page number changed.") }
                try visit(page, bytes.count)
            }
        }
    }
    fileprivate func validatePrepared(_ prepared: PreparedDocumentContent) throws {
        var pages: Int64 = 0
        var bytes: Int64 = 0
        var counts = [Int64](repeating: 0, count: 5)
        try visitClosure(
            base: prepared.stage, rootEntry: prepared.rootEntry, level: prepared.rootLevel,
            source: prepared.source, identity: prepared.identity
        ) { page, encodedCount in
            let expected = pages.addingReportingOverflow(1)
            let sum = bytes.addingReportingOverflow(Int64(encodedCount))
            guard !expected.overflow, !sum.overflow, page.pageNumber == expected.partialValue else {
                throw integrity("Prepared document closure count overflowed or changed.")
            }
            pages = expected.partialValue
            bytes = sum.partialValue
            counts[try statusIndex(page.status)] += 1
        }
        let coverage = try DocumentCoverage(
            converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
            failed: counts[4])
        guard pages == prepared.rootEntry.lastPage, bytes == prepared.byteCount, coverage == prepared.coverage
        else {
            throw integrity("Prepared document closure differs from its publication metadata.")
        }
    }
    func revalidatePrepared(_ prepared: PreparedDocumentContent) throws {
        if try files.readIfPresent(
            path: prepared.stage + nodePath(level: prepared.rootLevel, ordinal: 0),
            maximumBytes: Self.maximumNodeBytes) != nil
        {
            return try validatePrepared(prepared)
        }
        let receiptPath = Array(prepared.stage.dropLast()) + [prepared.stage.last! + ".publication.json"]
        let data = try files.read(path: receiptPath, maximumBytes: Self.maximumNodeBytes)
        let receipt = try DocumentValue.strictDecode(DocumentPublicationReceipt.self, data: data)
        guard receipt.preparedSHA256 == digest(try JSON.encode(prepared)) else {
            throw integrity("Prepared publication intent changed.")
        }
        let manifestBytes = try JSON.encode(receipt.manifest)
        let reference = try DocumentContentReference(
            contentID: receipt.manifest.contentID, manifestSHA256: digest(manifestBytes),
            rootSHA256: prepared.rootEntry.sha256, pageCount: prepared.rootEntry.lastPage,
            totalEncodedBytes: prepared.byteCount, coverage: prepared.coverage)
        try validate(
            reference, source: prepared.source, identity: prepared.identity, extractedAt: prepared.extractedAt
        )
    }

    private func publishedJobReference(_ prepared: PreparedDocumentContent) throws
        -> DocumentContentReference?
    {
        let receiptPath = Array(prepared.stage.dropLast()) + [prepared.stage.last! + ".publication.json"]
        guard let bytes = try files.readIfPresent(path: receiptPath, maximumBytes: Self.maximumNodeBytes)
        else { return nil }
        let receipt = try DocumentValue.strictDecode(DocumentPublicationReceipt.self, data: bytes)
        guard receipt.preparedSHA256 == digest(try JSON.encode(prepared)),
            receipt.manifest.publicationID == prepared.stage.last!,
            receipt.manifest.source == prepared.source,
            receipt.manifest.identity == prepared.identity,
            receipt.manifest.extractedAt == prepared.extractedAt
        else {
            throw integrity("Private job publication receipt changed.")
        }
        let reference = try DocumentContentReference(
            contentID: receipt.manifest.contentID,
            manifestSHA256: digest(try JSON.encode(receipt.manifest)), rootSHA256: prepared.rootEntry.sha256,
            pageCount: prepared.rootEntry.lastPage, totalEncodedBytes: prepared.byteCount,
            coverage: prepared.coverage)
        return reference
    }
    func readPreparedJobPage(_ prepared: PreparedDocumentContent, number: Int64) throws -> DocumentStoredPage
    {
        do {
            return try readStagedPage(
                stage: prepared.stage, source: prepared.source, identity: prepared.identity, number: number)
        } catch let error as TractandaError where error.osError == ENOENT {
            guard let reference = try publishedJobReference(prepared) else { throw error }
            return try readPage(reference, pageNumber: number)
        }
    }
    /// Caller must reconcile immutable committed operation first; this removes only its uncommitted candidate.
    func discardJob(stage: [String], prepared: PreparedDocumentContent?) throws {
        try files.requireMutableDocumentPath(stage)
        if let prepared, let reference = try publishedJobReference(prepared) {
            if let path = try resolvedDirectory(reference.contentID) {
                let manifest = try manifest(reference)
                guard manifest.source == prepared.source, manifest.identity == prepared.identity,
                    manifest.publicationID == stage.last!
                else { throw integrity("Uncommitted job manifest changed.") }
                try files.removeUncommittedContent(path)
                try placement.forget(id: reference.contentID, path: path.joined(separator: "/"))
            }
        }
        try files.removePrivateTree(stage)
        try files.removeJobPublicationReceipt(id: stage.last!)
    }
    func clone(
        _ document: AttachmentDocumentRepresentation, attachmentID: String, representationID: String,
        maximumWriteBytes: Int64 = .max
    ) throws -> AttachmentDocumentRepresentation {
        let prepared = try prepareClone(document, maximumWriteBytes: maximumWriteBytes)
        let content = try publishPrepared(prepared)
        return try AttachmentDocumentRepresentation(
            representationID: representationID, attachmentID: attachmentID,
            source: document.source, extractedAt: document.extractedAt, identity: document.identity,
            content: content)
    }
    func prepareClone(_ document: AttachmentDocumentRepresentation, maximumWriteBytes: Int64 = .max) throws
        -> PreparedDocumentContent
    {
        let writer = try begin(
            source: document.source, identity: document.identity, extractedAt: document.extractedAt,
            maximumWriteBytes: maximumWriteBytes)
        if let reference = document.content {
            try forEachPage(reference) { try writer.append($0) }
        } else {
            for page in document.pages {
                try writer.append(
                    DocumentStoredPage(
                        pageNumber: Int64(page.pageNumber), sourceSHA256: document.source.sha256, page: page))
            }
        }
        return try writer.preparePublication()
    }
    func publishPrepared(_ prepared: PreparedDocumentContent) throws -> DocumentContentReference {
        try publish(
            stage: prepared.stage, source: prepared.source, identity: prepared.identity,
            extractedAt: prepared.extractedAt, rootEntry: prepared.rootEntry, rootLevel: prepared.rootLevel,
            byteCount: prepared.byteCount, coverage: prepared.coverage)
    }
    fileprivate func write(_ data: Data, stage: [String], path: [String]) throws {
        try files.requireMutableDocumentPath(stage)
        if let existing = try files.readIfPresent(path: stage + path, maximumBytes: Self.maximumPageBytes) {
            guard existing == data else { throw integrity("Replayed page or proof node changed.") }
            try files.synchronizeDirectory(Array((stage + path).dropLast()))
        } else {
            try files.writeImmutable(data, path: stage + path)
        }
    }
    fileprivate func publish(
        stage: [String], source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String, rootEntry: DocumentHashEntry, rootLevel: Int, byteCount: Int64,
        coverage: DocumentCoverage
    ) throws -> DocumentContentReference {
        let prepared = PreparedDocumentContent(
            stage: stage, source: source, identity: identity, extractedAt: extractedAt,
            rootEntry: rootEntry, rootLevel: rootLevel, byteCount: byteCount, coverage: coverage)
        let preparedDigest = digest(try JSON.encode(prepared))
        let receiptPath = Array(stage.dropLast()) + [stage.last! + ".publication.json"]
        let manifest: DocumentManifest
        if let receiptBytes = try files.readIfPresent(path: receiptPath, maximumBytes: Self.maximumNodeBytes)
        {
            let receipt = try DocumentValue.strictDecode(DocumentPublicationReceipt.self, data: receiptBytes)
            guard receipt.preparedSHA256 == preparedDigest else {
                throw integrity("Document publication intent changed.")
            }
            manifest = receipt.manifest
        } else {
            // Identity is assigned only after the bounded stage has been prepared.
            let id = try UUID.makeVersion1().uuidString.lowercased()
            manifest = DocumentManifest(
                schema: "tractanda.document-manifest.v2", contentID: id, publicationID: stage.last!,
                source: source,
                identity: identity, extractedAt: extractedAt, rootLevel: rootLevel,
                rootByteCount: rootEntry.byteCount,
                rootSHA256: rootEntry.sha256, pageCount: rootEntry.lastPage, totalEncodedBytes: byteCount,
                coverage: coverage)
            let receipt = try JSON.encode(
                DocumentPublicationReceipt(preparedSHA256: preparedDigest, manifest: manifest))
            guard receipt.count <= Self.maximumNodeBytes else {
                throw integrity("Publication receipt exceeds its metadata window.")
            }
            try files.writeImmutable(receipt, path: receiptPath)
        }
        guard manifest.schema == "tractanda.document-manifest.v2", manifest.publicationID == stage.last!,
            manifest.source == source,
            manifest.identity == identity,
            manifest.extractedAt == extractedAt, manifest.rootLevel == rootLevel,
            manifest.rootByteCount == rootEntry.byteCount,
            manifest.rootSHA256 == rootEntry.sha256, manifest.pageCount == rootEntry.lastPage,
            manifest.totalEncodedBytes == byteCount, manifest.coverage == coverage
        else { throw integrity("Publication receipt differs from its prepared content.") }
        let bytes = try JSON.encode(manifest)
        guard bytes.count <= Self.maximumNodeBytes else {
            throw integrity("Manifest exceeds its bounded metadata budget.")
        }
        let reference = try DocumentContentReference(
            contentID: manifest.contentID, manifestSHA256: digest(bytes), rootSHA256: rootEntry.sha256,
            pageCount: rootEntry.lastPage, totalEncodedBytes: byteCount, coverage: coverage)
        // The private local writer alone creates its manifest. Exact import below never rewrites it.
        if try files.readIfPresent(
            path: stage + nodePath(level: rootLevel, ordinal: 0), maximumBytes: Self.maximumNodeBytes) != nil
        {
            if let existing = try files.readIfPresent(
                path: stage + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
            {
                guard existing == bytes else { throw integrity("Private publication manifest changed.") }
            } else {
                try files.writeImmutable(bytes, path: stage + ["manifest.json"])
            }
        }
        try publishExact(stage: stage, reference: reference, manifestBytes: bytes)
        return reference
    }

    /// Internal storage entry point only. It preserves foreign identities/bytes; callers must
    /// separately close canonical source/current authority before publishing any item reference.
    func publishExact(stage: [String], reference: DocumentContentReference, manifestBytes: Data) throws {
        try files.requireMutableDocumentPath(stage)
        guard stage.count == 3, stage.prefix(2) == ["documents", ".staging"],
            UUID(uuidString: stage[2])?.version1Components != nil,
            manifestBytes.count <= Self.maximumNodeBytes
        else { throw integrity("Invalid exact document stage.") }
        _ = try decodeManifest(manifestBytes, reference: reference)
        try placement.publish(reference, recover: recoverPlacement, reconcile: reconcilePlacement) {
            path, existing in
            let destination = path.split(separator: "/").map(String.init)
            if existing {
                let raw = try files.read(
                    path: destination + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
                guard raw == manifestBytes else {
                    throw integrity("Document identity already names different bytes.")
                }
                _ = try validateTree(base: destination, reference: reference, synchronize: true)
                try files.synchronizePublication(stage, to: destination)
            } else {
                guard
                    try files.read(path: stage + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
                        == manifestBytes
                else { throw integrity("Exact stage manifest differs.") }
                _ = try validateTree(base: stage, reference: reference, synchronize: true)
                try CanonicalReaderRequirement.beforeDocumentPlacementPublication(
                    root: root, ownerUID: ownerUID)
                try beforeDirectoryPublicationForTesting?()
                try files.publishDirectory(stage, to: destination)
            }
        }
    }

    func beginPeerInspection(base: [String], parkable: Bool = false) throws
        -> DocumentContentFiles.PeerTreeInspection
    {
        try files.peerTreeInspection(base, parkable: parkable)
    }
    func validatePeerPage(
        _ data: Data, source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        number: Int64
    ) throws -> DocumentStoredPage {
        guard data.count <= Self.maximumPageBytes else {
            throw integrity("Peer page exceeds its representation budget.")
        }
        let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: data)
        try validate(page, source: source, identity: identity)
        guard page.pageNumber == number else { throw integrity("Peer page number differs from its address.") }
        return page
    }
    func peerManifestBytes(_ reference: DocumentContentReference, budget: PeerOriginalReadBudget) throws
        -> Data
    {
        try reference.validate()
        let path = try directory(reference.contentID) + ["manifest.json"]
        let file = try files.peerDocumentPartFile(path: path, maximumBytes: Self.maximumNodeBytes)
        try budget.requireWorkingSet(bytes: file.metadata.size, steps: 1, label: "One document manifest")
        let data = try files.read(
            path: path,
            maximumBytes: Self.maximumNodeBytes, readBudget: budget.charge)
        _ = try decodeManifest(data, reference: reference)
        return data
    }
    func peerManifestDescriptor(_ reference: DocumentContentReference) throws -> PeerPackage.Object {
        try reference.validate()
        let path = try directory(reference.contentID) + ["manifest.json"]
        let file = try files.peerDocumentPartFile(path: path, maximumBytes: Self.maximumNodeBytes)
        let object = PeerPackage.Object(
            kind: .document, id: reference.contentID,
            length: Int(file.metadata.size), sha256: reference.manifestSHA256, part: .manifest)
        try object.validate()
        return object
    }
    func validatePeerManifest(_ data: Data, reference: DocumentContentReference) throws -> DocumentManifest {
        try decodeManifest(data, reference: reference)
    }
    func peerRootMetadata(_ base: [String]) throws -> FileMetadata {
        try FileMetadata.read(at: base.reduce(root) { $0.appendingPathComponent($1) })
    }
    /// Resolve a typed canonical part through bounded proofs without reading a target page body.
    func peerExpectedPart(
        _ reference: DocumentContentReference, part: PeerPackage.DocumentPart,
        budget: PeerOriginalReadBudget
    ) throws -> PeerPackage.Object {
        try part.validate()
        let data = try peerManifestBytes(reference, budget: budget)
        if part == .manifest {
            return .init(
                kind: .document, id: reference.contentID, length: data.count,
                sha256: reference.manifestSHA256, part: part)
        }
        let manifest = try decodeManifest(data, reference: reference)
        let base = try directory(reference.contentID)
        var level = manifest.rootLevel
        var edge = DocumentHashEntry(
            ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
            byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256)
        while true {
            try budget.step()
            let address = PeerPackage.DocumentPart(role: .node, level: level, ordinal: edge.ordinal)
            if address == part {
                let result = PeerPackage.Object(
                    kind: .document, id: reference.contentID, length: Int(edge.byteCount),
                    sha256: edge.sha256, part: part)
                try result.validate()
                return result
            }
            let raw = try files.read(
                path: base + address.relativePath, maximumBytes: Self.maximumNodeBytes,
                readBudget: budget.charge)
            guard raw.count == Int(edge.byteCount), digest(raw) == edge.sha256 else {
                throw integrity("Peer proof bytes changed.")
            }
            let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: raw)
            try node.validate()
            guard node.level == level, node.ordinal == edge.ordinal,
                node.entries.first?.firstPage == edge.firstPage, node.entries.last?.lastPage == edge.lastPage
            else {
                throw integrity("Peer proof range changed.")
            }
            if level == 0 {
                guard part.role == .page,
                    let entry = node.entries.first(where: { $0.ordinal == part.ordinal })
                else {
                    throw integrity("Peer document part is unreachable.")
                }
                let result = PeerPackage.Object(
                    kind: .document, id: reference.contentID, length: Int(entry.byteCount),
                    sha256: entry.sha256, part: part)
                try result.validate()
                return result
            }
            let child: DocumentHashEntry?
            if part.role == .page {
                child = node.entries.first { $0.firstPage <= part.ordinal && part.ordinal <= $0.lastPage }
            } else {
                guard part.role == .node, part.level < level else {
                    throw integrity("Peer node level is unreachable.")
                }
                var ordinal = part.ordinal
                for _ in part.level..<(level - 1) { ordinal /= 128 }
                child = node.entries.first { $0.ordinal == ordinal }
            }
            guard let child else { throw integrity("Peer document part is unreachable.") }
            edge = child
            level -= 1
        }
    }
    func peerPartFile(base: [String], object: PeerPackage.Object) throws -> PeerOriginalFile {
        try object.validate()
        guard object.kind == .document, let part = object.part else { throw integrity("Invalid peer part.") }
        return try files.peerDocumentPartFile(path: base + part.relativePath, maximumBytes: object.length)
    }
    func freezePeerStage(_ stage: [String], reference: DocumentContentReference) throws {
        try files.freezePeerStage(stage, reference: reference)
    }
    /// Completion and publication occur in this one synchronous owner operation. A previously
    /// completed inspection cannot be retained as a reusable readiness token across operations.
    func stepFrozenPeerPublication(
        stage: [String], reference: DocumentContentReference, manifestBytes: Data,
        inspection: DocumentContentFiles.PeerTreeInspection, expectedParts: Int64,
        budget: PeerOriginalReadBudget, inspect: ([String], PeerOriginalFile) throws -> Void,
        beforePublication: () throws -> Void
    ) throws -> Bool {
        guard !inspection.complete,
            let frozen = try files.frozenPeerStage(stage, readBudget: budget.charge),
            frozen.reference == reference
        else {
            throw integrity("Peer publication requires its closed stage and a fresh inspection step.")
        }
        _ = try decodeManifest(manifestBytes, reference: reference)
        let finalBytes = manifestBytes.count + (try JSON.encode(frozen).count)
        try budget.requireWorkingSet(
            bytes: UInt64(finalBytes), steps: 1, label: "Final document publication metadata")
        guard
            try budget.reservingReadBytes(
                finalBytes,
                {
                    try inspection.step(budget: budget, synchronize: true, inspect: inspect)
                })
        else { return false }
        guard inspection.count == expectedParts else {
            throw integrity("Peer tree contains missing or extra parts.")
        }
        try beforePublication()
        try placement.publish(reference, recover: recoverPlacement, reconcile: reconcilePlacement) {
            path, existing in
            let destination = path.split(separator: "/").map(String.init)
            guard inspection.base == (existing ? destination : stage) else {
                throw TractandaError(
                    "peerDocumentLocationChanged", "Document publication location changed; inspect it again.")
            }
            let raw = try files.read(
                path: inspection.base + ["manifest.json"], maximumBytes: Self.maximumNodeBytes,
                readBudget: budget.charge)
            guard raw == manifestBytes else { throw integrity("Closed peer manifest changed.") }
            try inspection.checkRoot()
            if existing {
                try files.synchronizePublication(stage, to: destination)
            } else {
                try CanonicalReaderRequirement.beforeDocumentPlacementPublication(
                    root: root, ownerUID: ownerUID)
                try beforeDirectoryPublicationForTesting?()
                try beforePublication()
                try files.publishDirectory(
                    stage, to: destination, frozenReference: reference, readBudget: budget.charge)
            }
        }
        return true
    }

    private func validateTree(
        base: [String], reference: DocumentContentReference, synchronize: Bool
    ) throws -> DocumentManifest {
        let data = try files.read(path: base + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
        let manifest = try decodeManifest(data, reference: reference)
        var parts: Int64 = 1
        var pages: Int64 = 0
        var bytes: Int64 = 0
        var counts = [Int64](repeating: 0, count: 5)
        try visitClosure(
            base: base,
            rootEntry: .init(
                ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
                byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256),
            level: manifest.rootLevel, source: manifest.source, identity: manifest.identity,
            part: {
                let next = parts.addingReportingOverflow(1)
                guard !next.overflow else { throw self.integrity("Document part count overflowed.") }
                parts = next.partialValue
            },
            visit: { page, encodedCount in
                let next = pages.addingReportingOverflow(1)
                let total = bytes.addingReportingOverflow(Int64(encodedCount))
                guard !next.overflow, !total.overflow, page.pageNumber == next.partialValue else {
                    throw integrity("Document page coverage is not contiguous or addressable.")
                }
                pages = next.partialValue
                bytes = total.partialValue
                counts[try statusIndex(page.status)] += 1
            })
        let coverage = try DocumentCoverage(
            converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
            failed: counts[4])
        guard pages == reference.pageCount, bytes == reference.totalEncodedBytes,
            coverage == reference.coverage,
            try files.inspectDocumentTree(base, synchronize: synchronize) == parts
        else { throw integrity("Complete document tree differs from its canonical closure.") }
        return manifest
    }

    func preparePlacement() throws {
        do { try placement.prepare(recover: recoverPlacement, reconcile: reconcilePlacement) } catch let error
            as TractandaError where error.code == "documentIndexRecoveryRequired"
        { try rebuildPlacement() }
    }
    func rebuildPlacement() throws {
        try placement.rebuild(recover: recoverPlacement, reconcile: reconcilePlacement)
    }
    private func recoveredReference(_ data: Data, id: String) throws -> DocumentContentReference {
        let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: data)
        guard manifest.contentID == id else { throw integrity("Document archive identity differs.") }
        let reference = try DocumentContentReference(
            contentID: id, manifestSHA256: digest(data), rootSHA256: manifest.rootSHA256,
            pageCount: manifest.pageCount, totalEncodedBytes: manifest.totalEncodedBytes,
            coverage: manifest.coverage)
        _ = try decodeManifest(data, reference: reference)
        return reference
    }
    private func reconcilePlacement(_ reference: DocumentContentReference, path: String) throws -> Bool {
        let base = path.split(separator: "/").map(String.init)
        guard
            try files.readIfPresent(path: base + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
                != nil
        else { return false }
        _ = try validateTree(base: base, reference: reference, synchronize: true)
        try files.synchronizeDirectory(Array(base.dropLast()))
        return true
    }
    private func recoverPlacement(_ visit: (String, String) throws -> Void) throws {
        func walk(_ base: [String]) throws {
            try Task.checkCancellation()
            try files.withDirectoryEntries(path: base) { name in
                let path = base + [name]
                if base.count < 7 {
                    guard name.count == (base.count == 2 ? 4 : 2),
                        name.utf8.allSatisfy({ (48...57).contains($0) })
                    else { throw integrity("Unsafe document archive directory.") }
                    try walk(path)
                } else {
                    let relative = path.joined(separator: "/")
                    try DocumentPlacement.validate(relative, id: name)
                    let data = try files.read(
                        path: path + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
                    let reference = try recoveredReference(data, id: name)
                    _ = try validateTree(base: path, reference: reference, synchronize: true)
                    try files.synchronizeDirectory(Array(path.dropLast()))
                    try visit(name, relative)
                }
                return true
            }
        }
        try walk(["documents", "content"])
    }
    fileprivate func validate(
        _ page: DocumentStoredPage, source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        persisted: Bool = true
    ) throws {
        do {
            try page.validate()
            guard page.sourceSHA256 == source.sha256 else {
                throw TractandaError("invalidDocumentOutput", "Generated page original hash changed.")
            }
            if let output = page.page {
                guard try DoclingDocTagsParser.parse(Data(output.parsed.rawDocTags.utf8)) == output.parsed,
                    output.geometry.sourceUnit
                        == (source.mediaType == "application/pdf" ? "pdfPoint" : "pixel")
                else {
                    throw TractandaError(
                        "invalidDocumentOutput", "Generated page differs from raw output or source units.")
                }
                if identity.preprocessing == DocumentConverterIdentity().preprocessing {
                    try output.geometry.validateContentCrop()
                }
            }
        } catch {
            if persisted { throw integrity("Persisted document page structure or provenance changed.") }
            throw error
        }
    }
    fileprivate func pagePath(_ number: Int64) -> [String] {
        ["pages", String((number - 1) / 128), String(number) + ".json"]
    }
    fileprivate func nodePath(level: Int, ordinal: Int64) -> [String] {
        ["nodes", String(level), String(ordinal / 128), String(ordinal) + ".json"]
    }
    func directory(_ id: String) throws -> [String] {
        guard let path = try resolvedDirectory(id) else {
            throw integrity("Saved document content is missing.")
        }
        return path
    }
    private func resolvedDirectory(_ id: String) throws -> [String]? {
        _ = try AuthorityRecord.persistentID(.text(id))
        guard let path = try placement.path(id: id, recover: recoverPlacement, reconcile: reconcilePlacement)
        else { return nil }
        try DocumentPlacement.validate(path, id: id)
        return path.split(separator: "/").map(String.init)
    }
    func peerDirectory(_ id: String) throws -> [String]? { try resolvedDirectory(id) }
    func pageURLForTesting(_ reference: DocumentContentReference, number: Int64) throws -> URL {
        (try directory(reference.contentID) + pagePath(number)).reduce(root) { $0.appendingPathComponent($1) }
    }
    fileprivate func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    fileprivate func statusIndex(_ value: String) throws -> Int {
        guard
            let index = ["converted", "unsupported", "truncated", "timeout", "failed"].firstIndex(of: value)
        else { throw integrity("Unknown saved page outcome.") }
        return index
    }
    private func integrity(_ message: String) -> TractandaError {
        TractandaError("documentIntegrity", message)
    }
}

/// At most 128 entries per level and nine levels for signed 64-bit page ordinals.
final class DocumentContentWriter {
    private let store: DocumentContentStore
    private let stage: [String]
    private let source: AttachmentDocumentSource
    private let identity: DocumentConverterIdentity
    private let extractedAt: String
    private let maximumWriteBytes: Int64
    private var frontiers = [[DocumentHashEntry]](repeating: [], count: 10)
    private var nodeOrdinals = [Int64](repeating: 0, count: 9)
    private var count: Int64 = 0
    private var pageBytes: Int64 = 0
    private var writtenBytes: Int64 = 0
    private var counts = [Int64](repeating: 0, count: 5)
    private var published = false
    fileprivate init(
        store: DocumentContentStore, stage: [String], source: AttachmentDocumentSource,
        identity: DocumentConverterIdentity, extractedAt: String, maximumWriteBytes: Int64
    ) {
        self.store = store
        self.stage = stage
        self.source = source
        self.identity = identity
        self.extractedAt = extractedAt
        self.maximumWriteBytes = maximumWriteBytes
    }
    var acceptedPages: Int64 { count }
    var coverage: DocumentCoverage {
        get throws {
            try DocumentCoverage(
                converted: counts[0], unsupported: counts[1], truncated: counts[2],
                timedOut: counts[3], failed: counts[4])
        }
    }
    func append(_ page: DocumentStoredPage) throws {
        guard !published else { throw TractandaError("documentIntegrity", "Published content is immutable.") }
        try Task.checkCancellation()
        try store.validate(page, source: source, identity: identity, persisted: false)
        let next = count.addingReportingOverflow(1)
        guard !next.overflow, page.pageNumber == next.partialValue else {
            throw TractandaError("documentIntegrity", "Saved pages must be contiguous.")
        }
        let bytes = try JSON.encode(page)
        guard bytes.count <= DocumentContentStore.maximumPageBytes else {
            throw TractandaError("resourceLimit", "One saved page exceeds its working-set budget.")
        }
        try charge(bytes.count)
        try store.write(bytes, stage: stage, path: store.pagePath(page.pageNumber))
        count = page.pageNumber
        let total = pageBytes.addingReportingOverflow(Int64(bytes.count))
        guard !total.overflow else {
            throw TractandaError("resourceLimit", "Saved page byte count overflowed.")
        }
        pageBytes = total.partialValue
        counts[try store.statusIndex(page.status)] += 1
        frontiers[0].append(
            DocumentHashEntry(
                ordinal: count, firstPage: count, lastPage: count, byteCount: Int64(bytes.count),
                sha256: store.digest(bytes)))
        if frontiers[0].count == 128 { try flush(0) }
    }
    private func charge(_ count: Int) throws {
        let total = writtenBytes.addingReportingOverflow(Int64(count))
        guard !total.overflow, total.partialValue <= maximumWriteBytes else {
            throw TractandaError(
                "resourceLimit", "Document stage exceeds its operator or fixture byte quota.")
        }
        writtenBytes = total.partialValue
    }
    private func flush(_ level: Int) throws {
        guard level <= 8, !frontiers[level].isEmpty else {
            throw TractandaError("resourceLimit", "Document page count is not addressable.")
        }
        let ordinal = nodeOrdinals[level]
        let node = DocumentHashNode(
            schema: "tractanda.document-node.v2", level: level, ordinal: ordinal, entries: frontiers[level])
        try node.validate()
        let bytes = try JSON.encode(node)
        guard bytes.count <= DocumentContentStore.maximumNodeBytes else {
            throw TractandaError("resourceLimit", "Document proof node exceeds its metadata window.")
        }
        try charge(bytes.count)
        try store.write(bytes, stage: stage, path: store.nodePath(level: level, ordinal: ordinal))
        let entry = DocumentHashEntry(
            ordinal: ordinal, firstPage: frontiers[level].first!.firstPage,
            lastPage: frontiers[level].last!.lastPage, byteCount: Int64(bytes.count),
            sha256: store.digest(bytes))
        frontiers[level].removeAll(keepingCapacity: true)
        nodeOrdinals[level] += 1
        frontiers[level + 1].append(entry)
        if frontiers[level + 1].count == 128 { try flush(level + 1) }
    }
    func preparePublication() throws -> PreparedDocumentContent {
        guard !published, count > 0 else {
            throw TractandaError("documentIntegrity", "An empty or published stage cannot publish.")
        }
        if !frontiers[0].isEmpty { try flush(0) }
        for level in 1...9 {
            if frontiers[level].count == 1, frontiers[(level + 1)...].allSatisfy(\.isEmpty) {
                let coverage = try DocumentCoverage(
                    converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
                    failed: counts[4])
                let prepared = PreparedDocumentContent(
                    stage: stage, source: source, identity: identity,
                    extractedAt: extractedAt, rootEntry: frontiers[level][0], rootLevel: level - 1,
                    byteCount: pageBytes, coverage: coverage)
                try store.validatePrepared(prepared)
                published = true
                return prepared
            }
            if !frontiers[level].isEmpty { try flush(level) }
        }
        throw TractandaError("resourceLimit", "Document page count is not addressable.")
    }
}

struct PreparedDocumentContent: Codable, Sendable {
    let stage: [String]
    let source: AttachmentDocumentSource
    let identity: DocumentConverterIdentity
    let extractedAt: String
    let rootEntry: DocumentHashEntry
    let rootLevel: Int
    let byteCount: Int64
    let coverage: DocumentCoverage
}

extension DocumentContentWriter {
    func publish() throws -> DocumentContentReference { try store.publishPrepared(preparePublication()) }
}

struct DocumentPublicationReceipt: Codable {
    let preparedSHA256: String
    let manifest: DocumentManifest
}

extension DocumentContentStore {
    func makeNativeSession(
        intent: DocumentJobIntent, original: DocumentVerifiedOriginal,
        configuration: DocumentConverterConfiguration, executableSHA256: String,
        budgets: DocumentWorkerBudgets, cancellation: DocumentConversionCancellation,
        expectedPageCount: Int64?,
        runtimeVerifier: DocumentRuntimeVerifier = DocumentNativeSession.verifyRuntime
    ) throws -> DocumentNativeSession {
        try DocumentNativeSession(
            intent: intent, original: original, configuration: configuration,
            expectedExecutableSHA256: executableSHA256, files: files, root: root, budgets: budgets,
            cancellation: cancellation, expectedPageCount: expectedPageCount,
            runtimeVerifier: runtimeVerifier)
    }
}

extension DocumentContentStore {
    /// Authenticates one bounded proof/page at a time; caller checks complete summary against its plan.
    func forEachPreparedJobPage(
        _ prepared: PreparedDocumentContent,
        _ visit: (DocumentStoredPage) throws -> Void
    ) throws {
        try forEachEncodedPreparedJobPage(prepared) { page, _ in try visit(page) }
    }
    func forEachEncodedPreparedJobPage(
        _ prepared: PreparedDocumentContent,
        _ visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        if try files.readIfPresent(
            path: prepared.stage + nodePath(level: prepared.rootLevel, ordinal: 0),
            maximumBytes: Self.maximumNodeBytes) != nil
        {
            try visitClosure(
                base: prepared.stage, rootEntry: prepared.rootEntry,
                level: prepared.rootLevel, source: prepared.source, identity: prepared.identity,
                visit: visit)
        } else {
            guard let reference = try publishedJobReference(prepared) else {
                throw TractandaError(
                    "documentIntegrity", "Prepared corpus has no authenticated publication receipt.")
            }
            let manifest = try manifest(reference)
            guard manifest.source == prepared.source, manifest.identity == prepared.identity,
                manifest.extractedAt == prepared.extractedAt,
                manifest.rootSHA256 == prepared.rootEntry.sha256,
                manifest.pageCount == prepared.rootEntry.lastPage,
                manifest.totalEncodedBytes == prepared.byteCount,
                manifest.coverage == prepared.coverage
            else {
                throw TractandaError("documentIntegrity", "Prepared corpus publication binding changed.")
            }
            try forEachEncodedPage(reference, visit)
        }
    }
}

extension DocumentContentStore {
    func jobCorpusRoot(_ jobID: String) throws -> URL {
        try PageCorpusInput.validateID(jobID)
        let path = ["document-jobs", jobID, "corpus"]
        try files.ensurePrivateDirectory(path)
        return path.reduce(root) { $0.appendingPathComponent($1) }
    }
}

extension DocumentContentStore {
    func offlineCorpusRoot(_ id: String) throws -> URL {
        try PageCorpusInput.validateID(id)
        let path = ["documents", ".staging", "corpus-" + id]
        try files.ensurePrivateDirectory(path)
        return path.reduce(root) { $0.appendingPathComponent($1) }
    }
    func discardOfflineCorpus(_ id: String) throws {
        try PageCorpusInput.validateID(id)
        try files.removeOfflineCorpus(id)
    }
}
