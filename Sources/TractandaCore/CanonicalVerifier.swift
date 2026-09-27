import CTractandaPlatform
import Crypto
import Foundation

/// Immutable input and output for the detached canonical inventory scan.
struct CanonicalVerifier: Sendable {
    struct Snapshot: Sendable {
        let rootPath: String
        let ownerUID: UInt32
        let rows: [ItemIndex.CatalogueRow]
    }

    struct Finding: Sendable, Equatable {
        enum Kind: String, Sendable { case missing, unexpected, changed, metadataChanged, unsafe }
        let kind: Kind
        let path: String
        let revisionID: String?
        let detail: String
    }

    static func scan(
        _ snapshot: Snapshot,
        readMetadata: @Sendable (URL) throws -> FileMetadata = { try FileMetadata.read(at: $0) }
    ) async -> [Finding] {
        // Keep one catalogue row array in the immutable snapshot. The path table only
        // stores offsets, avoiding another dictionary of full row values during a scan.
        var expected: [String: Int] = [:]
        expected.reserveCapacity(snapshot.rows.count)
        for (offset, row) in snapshot.rows.enumerated() {
            precondition(expected.updateValue(offset, forKey: row.path) == nil)
        }
        var findings: [Finding] = []
        var directories = [URL(fileURLWithPath: snapshot.rootPath).appendingPathComponent("items")]
        var count = 0
        while let directory = directories.popLast() {
            if Task.isCancelled { return findings }
            guard let handle = directory.path.withCString({ tractanda_directory_open($0) }) else {
                findings.append(
                    .init(
                        kind: .unsafe, path: directory.path, revisionID: nil,
                        detail: "Cannot enumerate directory"))
                continue
            }
            defer { _ = tractanda_directory_close(handle) }
            while true {
                if Task.isCancelled { return findings }
                var nameBuffer = [CChar](repeating: 0, count: 1024)
                let readResult = nameBuffer.withUnsafeMutableBufferPointer {
                    tractanda_directory_next(handle, $0.baseAddress, $0.count)
                }
                if readResult == 0 { break }
                guard readResult == 1 else {
                    findings.append(
                        .init(
                            kind: .unsafe, path: directory.path, revisionID: nil,
                            detail: "Cannot enumerate directory"))
                    break
                }
                let nameBytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                    findings.append(
                        .init(
                            kind: .unsafe, path: directory.path, revisionID: nil,
                            detail: "Directory contains a non-UTF-8 name"))
                    continue
                }
                count += 1
                if count.isMultiple(of: 256) {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let url = directory.appendingPathComponent(name, isDirectory: false)
                let relative = String(url.path.dropFirst(snapshot.rootPath.count + 1))
                let archived = tractanda_path_read_only(url.path) == 1
                let metadata: FileMetadata
                do { metadata = try readMetadata(url) } catch {
                    findings.append(
                        .init(
                            kind: .unsafe, path: relative, revisionID: nil,
                            detail: "Cannot read filesystem metadata"))
                    continue
                }
                if metadata.type == .directory {
                    if !archived && (metadata.uid != snapshot.ownerUID || metadata.mode & 0o077 != 0) {
                        findings.append(
                            .init(
                                kind: .unsafe, path: relative, revisionID: nil,
                                detail: "Directory ownership or permissions changed"))
                    }
                    directories.append(url)
                    continue
                }
                guard metadata.type == .regular else {
                    findings.append(
                        .init(
                            kind: .unsafe, path: relative, revisionID: nil,
                            detail: "Unexpected filesystem object"))
                    continue
                }
                let staging = Self.isLegalStagingName(name)
                if url.pathExtension != "tractanda" {
                    if !archived && (metadata.uid != snapshot.ownerUID || metadata.mode & 0o077 != 0) {
                        findings.append(
                            .init(
                                kind: .unsafe, path: relative, revisionID: nil,
                                detail: "File ownership or permissions changed"))
                        continue
                    }
                    if staging { continue }
                    findings.append(
                        .init(
                            kind: .unexpected, path: relative, revisionID: nil,
                            detail: "Unrecognized file in canonical tree"))
                    continue
                }
                guard let offset = expected.removeValue(forKey: relative) else {
                    findings.append(
                        .init(
                            kind: .unexpected, path: relative, revisionID: nil,
                            detail: "No catalogue row matches this record"))
                    continue
                }
                let row = snapshot.rows[offset]
                if !archived && (metadata.uid != snapshot.ownerUID || metadata.mode & 0o077 != 0) {
                    findings.append(
                        .init(
                            kind: .unsafe, path: relative, revisionID: row.revisionID,
                            detail: "File ownership or permissions changed"))
                    continue
                }
                guard metadata.size <= 8 * 1024 * 1024 else {
                    findings.append(
                        .init(
                            kind: .changed, path: relative, revisionID: row.revisionID,
                            detail: "Canonical record exceeds the supported size limit"))
                    continue
                }
                let metadataChanged =
                    metadata.size != row.size || metadata.inode != row.inode
                    || metadata.uid != row.uid || metadata.mode != row.mode
                    || metadata.modificationSeconds != row.modificationSeconds
                    || metadata.modificationNanoseconds != row.modificationNanoseconds
                if metadataChanged {
                    do {
                        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
                        let kind: Finding.Kind =
                            Data(SHA256.hash(data: bytes)) == row.digest
                            ? .metadataChanged : .changed
                        findings.append(
                            .init(
                                kind: kind, path: relative, revisionID: row.revisionID,
                                detail: kind == .changed
                                    ? "Canonical record differs from its catalogue digest"
                                    : "Filesystem metadata differs; content digest still matches"))
                    } catch {
                        findings.append(
                            .init(
                                kind: .unsafe, path: relative, revisionID: row.revisionID,
                                detail: "Cannot read changed canonical record"))
                    }
                }
            }
        }
        for (path, offset) in expected {
            let row = snapshot.rows[offset]
            findings.append(
                .init(
                    kind: .missing, path: path, revisionID: row.revisionID,
                    detail: "Catalogue record is absent"))
        }
        return findings
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
