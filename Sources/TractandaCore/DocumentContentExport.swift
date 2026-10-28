import CTractandaPlatform
import Crypto
import Foundation
import TractandaClient

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Selected current revision and its active dependencies; this is not a store backup/import format.
public enum ItemDirectoryExport {
    public static func export(client: ItemClient, itemID: String, destination: URL) throws -> Revision {
        let revision = try client.revision(for: itemID)
        guard revision.itemID == itemID else {
            throw TractandaError("protocolError", "Export revision returned a different item.")
        }
        let parent = destination.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("Cannot open export parent.") }
        defer { _ = close(parentFD) }
        var existing = stat()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
            name.withCString({ fstatat(parentFD, $0, &existing, AT_SYMLINK_NOFOLLOW) }) < 0,
            errno == ENOENT
        else { throw failure("Export directory must not already exist.") }
        let stageName = ".tractanda-item-export-" + UUID().uuidString
        guard stageName.withCString({ mkdirat(parentFD, $0, 0o700) }) == 0 else {
            throw failure("Cannot create private export staging.")
        }
        let staging = parent.appendingPathComponent(stageName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let files = DocumentContentFiles(
            root: staging, ownerUID: getuid(), minimumFreeBytes: 1024 * 1024 * 1024)
        // The selected revision stays pinned; current permission is checked by each server read.
        let pinned = client.checkedForwarding(transport: { request in
            try Task.checkCancellation()
            let envelope = try JMAPRequest.decode(request)
            guard envelope.methodCalls.count == 1, let call = envelope.methodCalls.first,
                call.arguments["itemID"]?.text == revision.itemID,
                call.arguments["revisionID"]?.text == revision.revisionID
            else {
                throw TractandaError("protocolError", "Unpinned export dependency request.")
            }
            let response = try client.sendNativeEnvelope(request)
            if call.name == "TractandaAttachment/list" {
                let data = try NativeMethodResult.unwrap(response, method: call.name, callID: call.callID)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard object?["revisionID"] as? String == revision.revisionID else {
                    throw TractandaError("protocolError", "Attachment list returned a different revision.")
                }
            }
            return response
        })
        let revisionBytes = try JSON.encode(revision)
        try files.writeImmutable(revisionBytes, path: ["revision.json"], maximumBytes: revisionBytes.count)
        let descriptors = try AttachmentDescriptor.descriptors(in: revision.fields)
        for descriptor in descriptors {
            let exported = try AttachmentFiles.export(
                client: pinned, itemID: revision.itemID, attachmentID: descriptor.attachmentID,
                destination: staging.appendingPathComponent(descriptor.attachmentID + ".original"),
                revisionID: revision.revisionID)
            guard exported == descriptor else {
                throw TractandaError("protocolError", "Export original differs from selected revision.")
            }
        }
        for document in try AttachmentDocumentRepresentation.representations(in: revision.fields) {
            guard let reference = document.content,
                let descriptor = descriptors.first(where: { $0.attachmentID == document.attachmentID }),
                descriptor.sha256 == document.source.sha256,
                descriptor.byteCount == document.source.byteCount,
                descriptor.mediaType == document.source.mediaType
            else { continue }
            try DocumentContentExport.write(
                client: pinned, revision: revision, document: document, reference: reference, files: files)
        }
        try files.synchronizeDirectory([])
        let published = stageName.withCString { source in
            name.withCString { tractanda_publish_directory_at(parentFD, source, parentFD, $0) }
        }
        guard published == 0 else { throw failure("Cannot publish export without replacement.") }
        guard fsync(parentFD) == 0 else {
            throw failure("Export was published but directory durability is uncertain.")
        }
        return revision
    }
    private static func failure(_ message: String) -> TractandaError {
        TractandaError("fileWriteFailed", message, osError: errno)
    }
}

/// At most nine bounded hash-node frames and one page are retained, irrespective of page count.
enum DocumentContentExport {
    static func write(
        client: ItemClient, revision: Revision, document: AttachmentDocumentRepresentation,
        reference: DocumentContentReference, files: DocumentContentFiles
    ) throws {
        try reference.validate()
        let base = ["document-content", reference.contentID]
        func read(
            kind: String, level: Int = 0, index: Int64 = 0, path: [String],
            expectedCount: Int64? = nil, expectedHash: String, maximum: Int
        ) throws -> Data {
            var bytes = Data()
            var count: Int64?
            var offset: Int64 = 0
            repeat {
                try Task.checkCancellation()
                let part = try client.documentContentPart(
                    itemID: revision.itemID, attachmentID: document.attachmentID,
                    revisionID: revision.revisionID, kind: kind, level: level, index: index,
                    offset: offset, limit: 262_144)
                guard part.contentID == reference.contentID, part.relativePath == path.joined(separator: "/"),
                    part.sha256 == expectedHash, part.byteCount > 0, part.byteCount <= Int64(maximum),
                    expectedCount == nil || part.byteCount == expectedCount,
                    count == nil || count == part.byteCount,
                    part.offset == offset, part.data.count <= 262_144,
                    part.nextOffset == offset + Int64(part.data.count), part.nextOffset <= part.byteCount,
                    part.isComplete == (part.nextOffset == part.byteCount), !part.data.isEmpty
                else { throw integrity("Invalid canonical export dependency continuation.") }
                count = part.byteCount
                bytes.append(part.data)
                offset = part.nextOffset
                if part.isComplete { break }
            } while true
            guard Int64(bytes.count) == count, digest(bytes) == expectedHash else {
                throw integrity("Canonical export dependency checksum or length changed.")
            }
            try files.writeImmutable(bytes, path: base + path, maximumBytes: maximum)
            return bytes
        }
        let manifestBytes = try read(
            kind: "manifest", path: ["manifest.json"], expectedHash: reference.manifestSHA256,
            maximum: DocumentContentStore.maximumNodeBytes)
        let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: manifestBytes)
        try manifest.source.validate()
        try manifest.identity.validate()
        guard manifest.schema == "tractanda.document-manifest.v2", manifest.contentID == reference.contentID,
            manifest.rootSHA256 == reference.rootSHA256, manifest.pageCount == reference.pageCount,
            manifest.totalEncodedBytes == reference.totalEncodedBytes,
            manifest.coverage == reference.coverage,
            manifest.source == document.source, manifest.identity == document.identity,
            manifest.extractedAt == document.extractedAt, Timestamp.parse(manifest.extractedAt) != nil,
            UUID(uuidString: manifest.publicationID)?.version1Components != nil,
            (0...8).contains(manifest.rootLevel), manifest.rootByteCount > 0,
            manifest.rootByteCount <= DocumentContentStore.maximumNodeBytes
        else { throw integrity("Export manifest differs from its selected representation.") }
        var totalBytes: Int64 = 0
        var pageCount: Int64 = 0
        var counts = [Int64](repeating: 0, count: 5)
        func visit(_ entry: DocumentHashEntry, level: Int) throws {
            let path = ["nodes", String(level), String(entry.ordinal / 128), String(entry.ordinal) + ".json"]
            let bytes = try read(
                kind: "node", level: level, index: entry.ordinal, path: path,
                expectedCount: entry.byteCount, expectedHash: entry.sha256,
                maximum: DocumentContentStore.maximumNodeBytes)
            let node = try DocumentValue.strictDecode(DocumentHashNode.self, data: bytes)
            try node.validate()
            guard node.level == level, node.ordinal == entry.ordinal,
                node.entries.first?.firstPage == entry.firstPage,
                node.entries.last?.lastPage == entry.lastPage
            else { throw integrity("Export proof range or identity changed.") }
            for child in node.entries {
                if level > 0 {
                    try visit(child, level: level - 1)
                } else {
                    let pageBytes = try read(
                        kind: "page", index: child.ordinal,
                        path: ["pages", String((child.ordinal - 1) / 128), String(child.ordinal) + ".json"],
                        expectedCount: child.byteCount, expectedHash: child.sha256,
                        maximum: DocumentContentStore.maximumPageBytes)
                    let page = try DocumentValue.strictDecode(DocumentStoredPage.self, data: pageBytes)
                    try page.validate()
                    guard page.pageNumber == child.ordinal, page.sourceSHA256 == manifest.source.sha256 else {
                        throw integrity("Export page identity or source changed.")
                    }
                    if let output = page.page {
                        guard
                            try DoclingDocTagsParser.parse(Data(output.parsed.rawDocTags.utf8))
                                == output.parsed,
                            output.geometry.sourceUnit
                                == (manifest.source.mediaType == "application/pdf" ? "pdfPoint" : "pixel")
                        else { throw integrity("Export parsed page differs from stored source output.") }
                        if manifest.identity.preprocessing == DocumentConverterIdentity().preprocessing {
                            try output.geometry.validateContentCrop()
                        }
                    }
                    guard
                        let status = ["converted", "unsupported", "truncated", "timeout", "failed"]
                            .firstIndex(of: page.status)
                    else { throw integrity("Unknown export page outcome.") }
                    let nextBytes = totalBytes.addingReportingOverflow(Int64(pageBytes.count))
                    let nextCount = pageCount.addingReportingOverflow(1)
                    guard !nextBytes.overflow, !nextCount.overflow else {
                        throw integrity("Export closure overflowed.")
                    }
                    totalBytes = nextBytes.partialValue
                    pageCount = nextCount.partialValue
                    counts[status] += 1
                }
            }
        }
        try visit(
            DocumentHashEntry(
                ordinal: 0, firstPage: 1, lastPage: manifest.pageCount,
                byteCount: manifest.rootByteCount, sha256: manifest.rootSHA256), level: manifest.rootLevel)
        let coverage = try DocumentCoverage(
            converted: counts[0], unsupported: counts[1], truncated: counts[2], timedOut: counts[3],
            failed: counts[4])
        guard pageCount == reference.pageCount, totalBytes == reference.totalEncodedBytes,
            coverage == reference.coverage
        else { throw integrity("Export document closure or coverage is incomplete.") }
    }
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func integrity(_ message: String) -> TractandaError {
        TractandaError("documentIntegrity", message)
    }
}
