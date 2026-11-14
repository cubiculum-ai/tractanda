import CTractandaPlatform
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct ImportExportEntry: Codable, Equatable, Sendable {
    public var sourceID: String
    public var aliases: [String]
    public var itemID: String
    public var revisionID: String
    public var originalSourcePath: String?
    public var originalSHA256: String?
    public var originalAttachmentID: String?
    public var readablePath: String
    public var nativeDirectory: String
    public var importState: String
}

public struct ImportExportManifest: Codable, Equatable, Sendable {
    public var schema = "tractanda.memory-export.v1"
    public var namespace: String
    public var storeID: String
    public var entries: [ImportExportEntry]
    public var diagnostics: [ImportDiagnostic]
}

/// Readable current memories plus selected native revisions and their verified byte dependencies.
/// Original-source evidence and current readable projections are deliberately distinct files.
public enum ImportBundleExport {
    @discardableResult
    public static func export(
        client: ItemClient, namespace: String, destination: URL, endpoint: String,
        limits: ImportLimits = ImportLimits()
    ) throws -> ImportReport {
        try limits.validate()
        guard ImportHash.validIdentity(namespace), destination.isFileURL,
            destination.path.hasPrefix("/"), !destination.path.contains("\0")
        else {
            throw TractandaError("importExport", "Export requires a namespace and absolute new directory.")
        }
        let transport = CoreImportTransport(client: client, endpoint: endpoint)
        let binding = try transport.binding()
        let selected = try transport.imported(namespace: namespace, limits: limits)
        let identities = Dictionary(grouping: selected, by: { $0.fields["importSourceID"]?.string ?? "" })
        guard identities.values.allSatisfy({ $0.count == 1 }) else {
            throw TractandaError(
                "importDuplicate", "Resolve duplicate source identities before exporting a bundle.")
        }
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw TractandaError("importExport", "Invalid export directory name.")
        }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw failure("Cannot open selected export parent.") }
        defer { _ = close(parentFD) }
        var existing = stat()
        guard fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else {
            throw TractandaError("importExport", "Export destination must not already exist.")
        }
        let stageName = ".tractanda-memory-export-" + UUID().uuidString
        guard mkdirat(parentFD, stageName, 0o700) == 0 else {
            throw failure("Cannot create private memory export stage.")
        }
        let stage = parent.appendingPathComponent(stageName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let stageFD = openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw failure("Cannot open private memory export stage.") }
        defer { _ = close(stageFD) }
        guard mkdirat(stageFD, "items", 0o700) == 0, mkdirat(stageFD, "memories", 0o700) == 0 else {
            throw failure("Cannot create export component directories.")
        }
        var entries: [ImportExportEntry] = []
        var report = ImportReport(
            namespace: namespace,
            diagnostics: [
                ImportDiagnostic(
                    "exportSemantics",
                    "Original bytes and current readable projections may differ after local edits. Native revision fields, ACLs, imported claims and instructions are evidence; this export transfers no identity, permission or active harness configuration.",
                    severity: .information),
                ImportDiagnostic(
                    "exportSnapshot",
                    "Each selected Item revision is pinned independently; this is not a store backup or an atomic multi-Item snapshot.",
                    severity: .information),
                ImportDiagnostic(
                    "okfExportBoundary",
                    "Readable Markdown and exact originals do not establish perfect Tractanda-to-OKF conversion or a native-memory writer integration.",
                    severity: .unsupported),
            ])
        var originalTotal: Int64 = 0
        for candidate in selected.sorted(by: {
            ($0.fields["importSourceID"]?.string ?? "") < ($1.fields["importSourceID"]?.string ?? "")
        }) {
            try Task.checkCancellation()
            if candidate.isDeleted {
                report.outcomes.append(
                    ImportOutcome(
                        sourceID: candidate.fields["importSourceID"]?.string ?? "", disposition: .tombstone,
                        itemID: candidate.itemID, revisionID: candidate.revisionID,
                        diagnostics: [
                            ImportDiagnostic(
                                "exportTombstone",
                                "Deleted Item omitted from the readable bundle; no restore was performed.",
                                severity: .information)
                        ]))
                continue
            }
            let descriptors = try AttachmentDescriptor.descriptors(in: candidate.fields)
            var itemOriginalBytes: Int64 = 0
            for descriptor in descriptors {
                let next = originalTotal.addingReportingOverflow(descriptor.byteCount)
                guard !next.overflow, next.partialValue <= limits.maximumOriginalBytes else {
                    throw TractandaError(
                        "importLimits", "Selected export originals exceed their byte budget.")
                }
                originalTotal = next.partialValue
                itemOriginalBytes += descriptor.byteCount
            }
            try reserve(parentFD, additional: itemOriginalBytes, minimum: limits.minimumFreeBytes)
            let nativePath = "items/" + candidate.itemID
            let revision = try ItemDirectoryExport.export(
                client: client, itemID: candidate.itemID,
                destination: stage.appendingPathComponent(nativePath, isDirectory: true),
                minimumFreeBytes: limits.minimumFreeBytes)
            // The exporter pins its actual selected revision. Never label a changed identity as the old selection.
            guard revision.revisionID == candidate.revisionID,
                revision.fields["importNamespace"]?.string == namespace,
                let sourceID = revision.fields["importSourceID"]?.string,
                revision.fields["importSchema"]?.string == ImportFields.schema
            else {
                throw TractandaError(
                    "stateChanged", "Imported Item changed during export; retry the selection.")
            }
            let readablePath = "memories/" + revision.itemID + ".md"
            let subject = revision.fields["subject"]?.string ?? sourceID
            let body = revision.fields["body"]?.string ?? ""
            let text = "# " + subject.replacingOccurrences(of: "\n", with: " ") + "\n\n" + body + "\n"
            guard text.utf8.count <= limits.maximumProjectionBytes + 16_384 else {
                throw TractandaError("importLimits", "Readable exported projection exceeds its byte budget.")
            }
            try write(
                Data(text.utf8), path: readablePath, directoryFD: stageFD,
                minimumFreeBytes: limits.minimumFreeBytes)
            let metadata = revision.fields["importMetadata"]?.map
            let originalID = metadata?["originalAttachmentID"]?.string
            let sourceHash = revision.fields["importSourceSHA256"]?.string
            if revision.fields["importState"]?.string == "complete" {
                guard let originalID, let sourceHash,
                    descriptors.contains(where: { $0.attachmentID == originalID && $0.sha256 == sourceHash })
                else {
                    throw TractandaError(
                        "importOriginalReadback",
                        "Completed imported Item has no matching canonical source original.")
                }
            }
            entries.append(
                ImportExportEntry(
                    sourceID: sourceID,
                    aliases: revision.fields["importSourceIDAliases"]?.array?.compactMap(\.string) ?? [],
                    itemID: revision.itemID, revisionID: revision.revisionID,
                    originalSourcePath: metadata?["sourcePath"]?.string, originalSHA256: sourceHash,
                    originalAttachmentID: originalID, readablePath: readablePath, nativeDirectory: nativePath,
                    importState: revision.fields["importState"]?.string ?? "incomplete"))
            report.outcomes.append(
                ImportOutcome(
                    sourceID: sourceID,
                    disposition: revision.fields["importState"]?.string == "complete"
                        ? .unchanged : .incomplete,
                    itemID: revision.itemID, revisionID: revision.revisionID))
        }
        guard try transport.binding() == binding else {
            throw TractandaError("importBinding", "Export store or principal changed.")
        }
        let manifest = ImportExportManifest(
            namespace: namespace, storeID: binding.storeID, entries: entries, diagnostics: report.diagnostics)
        let manifestBytes = try JSON.encode(manifest)
        guard manifestBytes.count <= limits.maximumPlanBytes else {
            throw TractandaError("importLimits", "Export manifest exceeds its byte budget.")
        }
        try write(
            manifestBytes, path: "manifest.json", directoryFD: stageFD,
            minimumFreeBytes: limits.minimumFreeBytes)
        try write(
            try JSON.encode(report), path: "report.json", directoryFD: stageFD,
            minimumFreeBytes: limits.minimumFreeBytes)
        for component in ["items", "memories"] {
            let descriptor = openat(stageFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure("Cannot synchronize export component.") }
            let synchronized = fsync(descriptor)
            _ = close(descriptor)
            guard synchronized == 0 else { throw failure("Cannot synchronize export component.") }
        }
        guard fsync(stageFD) == 0 else { throw failure("Cannot synchronize complete memory export.") }
        guard tractanda_publish_directory_at(parentFD, stageName, parentFD, name) == 0 else {
            throw failure("Cannot publish complete memory export without replacement.")
        }
        guard fsync(parentFD) == 0 else {
            throw failure("Export published but parent-directory durability is uncertain.")
        }
        return report
    }

    private static func write(_ data: Data, path: String, directoryFD: Int32, minimumFreeBytes: Int64) throws
    {
        try reserve(directoryFD, additional: Int64(data.count), minimum: minimumFreeBytes)
        let descriptor = openat(
            directoryFD, path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("Cannot write new export component.") }
        defer { _ = close(descriptor) }
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                    Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                #else
                    Glibc.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                #endif
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw failure("Cannot finish export component.") }
            offset += amount
        }
        guard fsync(descriptor) == 0 else { throw failure("Cannot synchronize export component bytes.") }
    }

    private static func reserve(_ descriptor: Int32, additional: Int64, minimum: Int64) throws {
        var capacity = statvfs()
        guard fstatvfs(descriptor, &capacity) == 0 else { throw failure("Cannot inspect export free space.") }
        let available = UInt64(capacity.f_bavail).multipliedReportingOverflow(by: UInt64(capacity.f_frsize))
        let required = UInt64(additional).addingReportingOverflow(UInt64(minimum))
        guard !available.overflow, !required.overflow, available.partialValue >= required.partialValue else {
            throw TractandaError("importCapacity", "Export would cross its free-space reserve.")
        }
    }
    private static func failure(_ message: String) -> TractandaError {
        TractandaError("importExport", message, osError: errno)
    }
}
