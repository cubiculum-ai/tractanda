import CTractandaPlatform
import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Runs a detached inventory check with bounded Swift memory and a private read-only catalogue handle.
struct CanonicalVerifier: Sendable {
    struct Snapshot: Sendable {
        let rootPath: String
        let ownerUID: UInt32
        let indexPath: String
        let storeIdentity: String
        let generation: String
        let catalogueWatermark: Int64
    }

    struct Finding: Sendable, Equatable {
        enum Kind: String, Sendable { case missing, unexpected, changed, metadataChanged, unsafe }
        let kind: Kind
        let path: String
        let revisionID: String?
        let detail: String
    }

    enum Status: String, Sendable { case complete, incomplete, cancelled }

    struct ResourceCounters: Sendable, Equatable {
        let catalogueRows: Int
        let maximumPageRows: Int
        let findingsDelivered: Int
        let maximumFindingsBatch: Int
        let seenPathBytes: Int
        let temporaryPageLimit: Int
        let peakPendingDirectories: Int
        let maximumDirectoryDepth: Int
    }

    struct Result: Sendable, Equatable {
        let status: Status
        let exactCatalogueCount: Int?
        /// Raw findings handed to the callback, before caller-side current-state reconciliation.
        let exactFindingCount: Int?
        let detail: String?
        let resources: ResourceCounters
    }

    static let pageLimit = 128
    static let findingBatchLimit = 64
    static let seenPathByteLimit = 16 * 1024 * 1024
    static let directoryDepthLimit = 128
    static let pendingDirectoryLimit = 16

    private struct Directory {
        let url: URL
        let depth: Int
        let handle: UnsafeMutableRawPointer
    }

    static func scan(
        _ snapshot: Snapshot,
        seenPathByteLimit: Int = CanonicalVerifier.seenPathByteLimit,
        readMetadata: @Sendable (URL) throws -> FileMetadata = { try FileMetadata.read(at: $0) },
        onFindings: @escaping @Sendable ([Finding]) async throws -> Void
    ) async -> Result {
        var reader: CanonicalCatalogueReader?
        var batch: [Finding] = []
        batch.reserveCapacity(findingBatchLimit)
        var delivered = 0
        var maximumBatch = 0
        var pendingMaximum = 0
        var depthMaximum = 0
        var catalogueCount = 0
        var failure: String?
        var status: Status = .incomplete

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let outgoing = batch
            batch.removeAll(keepingCapacity: true)
            maximumBatch = max(maximumBatch, outgoing.count)
            try await onFindings(outgoing)
            delivered += outgoing.count
        }

        do {
            try Task.checkCancellation()
            let catalogue = try CanonicalCatalogueReader(
                path: snapshot.indexPath, identity: snapshot.storeIdentity,
                watermark: snapshot.catalogueWatermark,
                maxSeenBytes: seenPathByteLimit)
            reader = catalogue
            let itemsURL = URL(fileURLWithPath: snapshot.rootPath).appendingPathComponent("items")
            guard let itemsHandle = itemsURL.path.withCString({ tractanda_directory_open($0) }) else {
                throw FileMetadataError.posix(errno)
            }
            var directories = [Directory(url: itemsURL, depth: 0, handle: itemsHandle)]
            defer {
                for directory in directories.reversed() {
                    _ = tractanda_directory_close(directory.handle)
                }
            }
            pendingMaximum = 1
            var traversalComplete = true

            while let directory = directories.last {
                try Task.checkCancellation()
                depthMaximum = max(depthMaximum, directory.depth)
                var traversalError: Error?
                do {
                    while true {
                        try Task.checkCancellation()
                        var nameBuffer = [CChar](repeating: 0, count: 1024)
                        let readResult = nameBuffer.withUnsafeMutableBufferPointer {
                            tractanda_directory_next(directory.handle, $0.baseAddress, $0.count)
                        }
                        if readResult == 0 {
                            let closeStatus = tractanda_directory_close(directory.handle)
                            directories.removeLast()
                            guard closeStatus == 0 else { throw FileMetadataError.posix(errno) }
                            break
                        }
                        guard readResult == 1 else { throw FileMetadataError.posix(errno) }
                        let nameBytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                            throw FileMetadataError.invalidPath
                        }
                        let child = directory.url.appendingPathComponent(name, isDirectory: false)
                        let relative = Self.relativePath(child, rootPath: snapshot.rootPath)
                        let archived = tractanda_path_read_only(child.path) == 1
                        let metadata: FileMetadata
                        do { metadata = try readMetadata(child) } catch { throw error }

                        if metadata.type == .directory {
                            if !archived && (metadata.uid != snapshot.ownerUID || metadata.mode & 0o077 != 0)
                            {
                                batch.append(
                                    .init(
                                        kind: .unsafe, path: relative, revisionID: nil,
                                        detail: "Directory ownership or permissions changed"))
                            }
                            guard directory.depth < directoryDepthLimit,
                                directories.count < pendingDirectoryLimit
                            else { throw ScanFailure.directoryLimit }
                            guard let childHandle = child.path.withCString({ tractanda_directory_open($0) })
                            else { throw FileMetadataError.posix(errno) }
                            directories.append(
                                Directory(url: child, depth: directory.depth + 1, handle: childHandle))
                            pendingMaximum = max(pendingMaximum, directories.count)
                            if batch.count >= findingBatchLimit { try await flush() }
                            break
                        }

                        guard metadata.type == .regular else {
                            batch.append(
                                .init(
                                    kind: .unsafe, path: relative, revisionID: nil,
                                    detail: "Unexpected filesystem object"))
                            if batch.count >= findingBatchLimit { try await flush() }
                            continue
                        }

                        let staging = isLegalStagingName(name)
                        guard child.pathExtension == "tractanda" else {
                            if !archived && (metadata.uid != snapshot.ownerUID || metadata.mode & 0o077 != 0)
                            {
                                batch.append(
                                    .init(
                                        kind: .unsafe, path: relative, revisionID: nil,
                                        detail: "File ownership or permissions changed"))
                            } else if !staging {
                                batch.append(
                                    .init(
                                        kind: .unexpected, path: relative, revisionID: nil,
                                        detail: "Unrecognized file in canonical tree"))
                            }
                            if batch.count >= findingBatchLimit { try await flush() }
                            continue
                        }

                        guard let row = try catalogue.row(path: relative) else {
                            batch.append(
                                .init(
                                    kind: .unexpected, path: relative, revisionID: nil,
                                    detail: "No catalogue row matches this record"))
                            if batch.count >= findingBatchLimit { try await flush() }
                            continue
                        }
                        try catalogue.markSeen(relative)
                        guard metadata.uid == snapshot.ownerUID || archived,
                            metadata.mode & 0o077 == 0 || archived
                        else {
                            batch.append(
                                .init(
                                    kind: .unsafe, path: relative, revisionID: row.revisionID,
                                    detail: "File ownership or permissions changed"))
                            if batch.count >= findingBatchLimit { try await flush() }
                            continue
                        }
                        guard metadata.size <= 8 * 1024 * 1024 else {
                            batch.append(
                                .init(
                                    kind: .changed, path: relative, revisionID: row.revisionID,
                                    detail: "Canonical record exceeds the supported size limit"))
                            if batch.count >= findingBatchLimit { try await flush() }
                            continue
                        }
                        let metadataChanged =
                            metadata.size != row.size || metadata.inode != row.inode
                            || metadata.uid != row.uid || metadata.mode != row.mode
                            || metadata.modificationSeconds != row.modificationSeconds
                            || metadata.modificationNanoseconds != row.modificationNanoseconds
                        if metadataChanged {
                            do {
                                let bytes = try Data(contentsOf: child, options: [.mappedIfSafe])
                                let kind: Finding.Kind =
                                    Data(SHA256.hash(data: bytes)) == row.digest
                                    ? .metadataChanged : .changed
                                batch.append(
                                    .init(
                                        kind: kind, path: relative, revisionID: row.revisionID,
                                        detail: kind == .changed
                                            ? "Canonical record differs from its catalogue digest"
                                            : "Filesystem metadata differs; content digest still matches"))
                            } catch {
                                throw ScanFailure.recordRead
                            }
                        }
                        if batch.count >= findingBatchLimit { try await flush() }
                    }
                } catch {
                    traversalError = error
                }
                if let traversalError {
                    if Task.isCancelled || traversalError is CancellationError {
                        status = .cancelled
                        failure = "Verification cancelled"
                    } else {
                        status = .incomplete
                        failure = Self.failureDetail(traversalError)
                    }
                    traversalComplete = false
                    break
                }
            }

            if traversalComplete {
                var cursor: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let page = try catalogue.page(after: cursor, limit: pageLimit)
                    guard !page.rows.isEmpty else { break }
                    for row in page.rows {
                        if try !catalogue.wasSeen(row.path) {
                            batch.append(
                                .init(
                                    kind: .missing, path: row.path, revisionID: row.revisionID,
                                    detail: "Catalogue record is absent"))
                            if batch.count >= findingBatchLimit { try await flush() }
                        }
                    }
                    guard let next = page.nextRowID else { break }
                    cursor = next
                }
                try await flush()
                status = .complete
                catalogueCount = catalogue.catalogueRowsRead
            }
        } catch is CancellationError {
            status = .cancelled
            failure = "Verification cancelled"
        } catch {
            status = Task.isCancelled ? .cancelled : .incomplete
            failure = Task.isCancelled ? "Verification cancelled" : Self.failureDetail(error)
        }

        // Partial diagnostics may be delivered, but they never imply missing rows or a clean result.
        if status != .complete {
            do { try await flush() } catch { failure = failure ?? "Findings callback failed" }
        }
        let finalReader = reader
        let resources = ResourceCounters(
            catalogueRows: status == .complete ? catalogueCount : (finalReader?.catalogueRowsRead ?? 0),
            maximumPageRows: finalReader?.maxPageRows ?? 0,
            findingsDelivered: delivered,
            maximumFindingsBatch: maximumBatch,
            seenPathBytes: finalReader?.seenBytes ?? 0,
            temporaryPageLimit: finalReader?.tempPageLimit ?? 0,
            peakPendingDirectories: pendingMaximum,
            maximumDirectoryDepth: depthMaximum)
        finalReader?.close()
        return Result(
            status: status,
            exactCatalogueCount: status == .complete ? catalogueCount : nil,
            exactFindingCount: status == .complete ? delivered : nil,
            detail: failure,
            resources: resources)
    }

    private enum ScanFailure: Error { case directoryLimit, recordRead }

    private static func failureDetail(_ error: Error) -> String {
        if let scanFailure = error as? ScanFailure {
            switch scanFailure {
            case .directoryLimit:
                return "Directory traversal exceeded its fixed depth or pending-directory cap"
            case .recordRead: return "Cannot read changed canonical record"
            }
        }
        if let readerFailure = error as? CanonicalCatalogueReader.ReaderError,
            case .tempCap = readerFailure
        {
            return "Temporary seen-path storage exceeded its fixed cap"
        }
        if error is FileMetadataError { return "Cannot enumerate or read canonical filesystem metadata" }
        return "Canonical inventory scan failed"
    }

    private static func relativePath(_ url: URL, rootPath: String) -> String {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    static func isLegalStagingName(_ name: String) -> Bool {
        let pieces = name.components(separatedBy: ".tractanda.")
        guard pieces.count == 2, UUID(uuidString: pieces[0]) != nil,
            pieces[1].count == 6,
            pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return false }
        return true
    }
}
