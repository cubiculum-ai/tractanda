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
        availableBytes: (@Sendable () throws -> UInt64)? = nil, stagingQuota: StagingByteQuota? = nil
    ) {
        self.root = root
        self.ownerUID = ownerUID
        files = DocumentContentFiles(
            root: root, ownerUID: ownerUID, minimumFreeBytes: minimumFreeBytes,
            availableBytes: availableBytes, stagingQuota: stagingQuota
        )
    }
    func begin(
        source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        extractedAt: String = Timestamp.now(), maximumWriteBytes: Int64 = .max
    ) throws -> DocumentContentWriter {
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
        let manifest = try manifest(reference)
        guard manifest.source == source, manifest.identity == identity, manifest.extractedAt == extractedAt
        else {
            throw integrity("Document provenance differs from its canonical representation.")
        }
        var total: Int64 = 0
        var counts = [Int64](repeating: 0, count: 5)
        try forEachPage(reference, boundary: boundary) { page in
            let sum = total.addingReportingOverflow(Int64(try JSON.encode(page).count))
            guard !sum.overflow else { throw integrity("Saved document byte count overflowed.") }
            total = sum.partialValue
            counts[try statusIndex(page.status)] += 1
            try progress(page.pageNumber)
        }
        let coverage = try DocumentCoverage(
            converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
            failed: counts[4])
        guard total == manifest.totalEncodedBytes, coverage == manifest.coverage else {
            throw integrity("Document closure count or coverage changed.")
        }
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
        let manifest = try manifest(reference)
        let rootEntry = DocumentHashEntry(
            ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
            byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256)
        try visitClosure(
            base: directory(reference.contentID), rootEntry: rootEntry, level: manifest.rootLevel,
            source: manifest.source, identity: manifest.identity, boundary: boundary, visit: visit)
    }
    private func visitClosure(
        base: [String], rootEntry: DocumentHashEntry, level: Int,
        source: AttachmentDocumentSource, identity: DocumentConverterIdentity,
        boundary: () throws -> Void = {}, visit: (DocumentStoredPage) throws -> Void
    ) throws {
        try Task.checkCancellation()
        try boundary()
        let data = try files.read(
            path: base + nodePath(level: level, ordinal: rootEntry.ordinal),
            maximumBytes: Self.maximumNodeBytes)
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
                    boundary: boundary, visit: visit)
            } else {
                let bytes = try files.read(
                    path: base + pagePath(entry.ordinal), maximumBytes: Self.maximumPageBytes)
                guard Int64(bytes.count) == entry.byteCount, digest(bytes) == entry.sha256 else {
                    throw integrity("Saved page checksum changed.")
                }
                let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: bytes)
                try validate(page, source: source, identity: identity)
                guard page.pageNumber == entry.ordinal else { throw integrity("Saved page number changed.") }
                try visit(page)
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
        ) { page in
            let expected = pages.addingReportingOverflow(1)
            let sum = bytes.addingReportingOverflow(Int64(try JSON.encode(page).count))
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
        if let prepared, let reference = try publishedJobReference(prepared) {
            let path = try directory(reference.contentID)
            if try files.readIfPresent(path: path + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
                != nil
            {
                let manifest = try manifest(reference)
                guard manifest.source == prepared.source, manifest.identity == prepared.identity,
                    manifest.publicationID == stage.last!
                else { throw integrity("Uncommitted job manifest changed.") }
            }
            try files.removeUncommittedContent(path)
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
        let destination = try directory(manifest.contentID)
        // A durable sibling receipt survives directory rename and uncertain fsync replies.
        if let existing = try? files.read(
            path: destination + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
        {
            guard existing == bytes else {
                throw integrity("Document identity already names different content.")
            }
            try files.synchronizePublication(stage, to: destination)
            return reference
        }
        if let existing = try files.readIfPresent(
            path: stage + ["manifest.json"], maximumBytes: Self.maximumNodeBytes)
        {
            guard existing == bytes else { throw integrity("Private publication manifest changed.") }
        } else {
            try files.writeImmutable(bytes, path: stage + ["manifest.json"])
        }
        try beforeDirectoryPublicationForTesting?()
        try files.publishDirectory(stage, to: destination)
        return reference
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
        try Identifier.validate(id)
        guard let components = UUID(uuidString: id)?.version1Components else {
            throw integrity("Content ID is not UUIDv1.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: components.date)
        guard let year = date.year, (1...9999).contains(year), let month = date.month, let day = date.day,
            let hour = date.hour, let minute = date.minute
        else { throw integrity("Content ID has an invalid storage date.") }
        return [
            "documents", "content", String(format: "%04d", year), String(format: "%02d", month),
            String(format: "%02d", day), String(format: "%02d", hour), String(format: "%02d", minute), id,
        ]
    }
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
        expectedPageCount: Int64?
    ) throws -> DocumentNativeSession {
        try DocumentNativeSession(
            intent: intent, original: original, configuration: configuration,
            expectedExecutableSHA256: executableSHA256, files: files, root: root, budgets: budgets,
            cancellation: cancellation, expectedPageCount: expectedPageCount)
    }
}

extension DocumentContentStore {
    /// Authenticates one bounded proof/page at a time; caller checks complete summary against its plan.
    func forEachPreparedJobPage(
        _ prepared: PreparedDocumentContent,
        _ visit: (DocumentStoredPage) throws -> Void
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
            try forEachPage(reference, visit)
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
