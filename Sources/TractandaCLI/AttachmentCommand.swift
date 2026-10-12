import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Narrow boundary for the resumable attachment commands. The CLI adapter uses the existing
/// native ItemClient method envelope; tests provide a bounded fake transport.
protocol AttachmentCommandTransport {
    func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult
    func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64
    func finishAttachmentOnce(uploadID: String) throws -> AttachmentCommitResult
    func attachmentUploadStatus(uploadID: String) throws -> AttachmentIntegrityStatus
    func abortAttachment(uploadID: String) throws
    func documentJobCall(_ method: String, arguments: [String: Any]) throws -> Data
}

/// Resume opens the same path again and proves its full content before using this new handle.
protocol AttachmentCommandSource {
    func open(path: String) throws -> any AttachmentSourceHandle
}
protocol AttachmentSourceHandle {
    var proof: AttachmentSourceProof { get }
    var filename: String { get }
    func chunk(offset: Int64, limit: Int) throws -> Data
    func verifyUnchanged() throws
}

struct CoreAttachmentCommandSource: AttachmentCommandSource {
    func open(path: String) throws -> any AttachmentSourceHandle {
        CoreAttachmentSourceHandle(try AttachmentFiles.Source(url: URL(fileURLWithPath: path)))
    }
}

private struct CoreAttachmentSourceHandle: AttachmentSourceHandle {
    let source: AttachmentFiles.Source
    init(_ source: AttachmentFiles.Source) { self.source = source }
    var proof: AttachmentSourceProof { .init(byteCount: source.byteCount, sha256: source.sha256) }
    var filename: String { source.filename }
    func chunk(offset: Int64, limit: Int) throws -> Data { try source.chunk(offset: offset, limit: limit) }
    func verifyUnchanged() throws { try source.verifyUnchanged() }
}

struct CoreAttachmentCommandTransport: AttachmentCommandTransport {
    let client: ItemClient

    func beginAttachment(_ request: AttachmentUploadRequest) throws -> AttachmentUploadResult {
        try client.beginAttachment(request)
    }
    func appendAttachment(uploadID: String, offset: Int64, data: Data) throws -> Int64 {
        try client.appendAttachment(uploadID: uploadID, offset: offset, data: data)
    }
    func finishAttachmentOnce(uploadID: String) throws -> AttachmentCommitResult {
        try JSON.decode(
            AttachmentCommitResult.self,
            client.call("TractandaAttachment/finish", arguments: ["uploadID": uploadID]))
    }
    func attachmentUploadStatus(uploadID: String) throws -> AttachmentIntegrityStatus {
        try client.attachmentUploadStatus(uploadID: uploadID)
    }
    func abortAttachment(uploadID: String) throws { try client.abortAttachment(uploadID: uploadID) }
    func documentJobCall(_ method: String, arguments: [String: Any]) throws -> Data {
        try client.call(method, arguments: arguments)
    }
}

struct AttachmentSourceProof: Codable, Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
    func validate() throws {
        guard byteCount >= 0, sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw TractandaError("invalidAttachment", "Invalid source byte count or SHA-256 digest.") }
    }
}

struct AttachmentUploadReceipt: Codable, Sendable {
    static let schema = "tractanda.cli-attachment-upload.v1"
    let schemaVersion: String
    let receiptID: String
    let endpoint: String
    var uploadID: String?
    var attachmentID: String?
    let itemID: String
    let expectedRevisionID: String
    let sourcePath: String
    let filename: String
    let mediaType: String
    let byteCount: Int64
    let sha256: String
    let source: AttachmentSourceProof
    /// Idempotency identity is part of the request and is safe to retain in private local state.
    let operationID: String
    var lastAcknowledgedOffset: Int64
    let createdAt: String

    func validate() throws {
        try source.validate()
        _ = try AttachmentDescriptor(
            attachmentID: receiptID, filename: filename, mediaType: mediaType,
            byteCount: byteCount, sha256: sha256)
        for id in [receiptID, itemID, expectedRevisionID] { try Identifier.validate(id) }
        if let uploadID { try Identifier.validate(uploadID) }
        if let attachmentID { try Identifier.validate(attachmentID) }
        guard (uploadID == nil) == (attachmentID == nil) else {
            throw TractandaError("clientStateInvalid", "Upload descriptor identity is missing.")
        }
        guard endpoint.hasPrefix("/"), endpoint.utf8.count <= 4096, !endpoint.contains("\0"),
            schemaVersion == Self.schema, !receiptID.isEmpty, receiptID.utf8.count <= 200,
            uploadID.map({ !$0.isEmpty && $0.utf8.count <= 200 }) ?? true,
            !itemID.isEmpty, itemID.utf8.count <= 200,
            !expectedRevisionID.isEmpty, expectedRevisionID.utf8.count <= 200,
            sourcePath.hasPrefix("/"), sourcePath.utf8.count <= 4096, !sourcePath.contains("\0"),
            !filename.isEmpty, filename.utf8.count <= 1024,
            mediaType.utf8.count <= 255, !operationID.isEmpty, operationID.utf8.count <= 200,
            !operationID.contains("\0"),
            byteCount == source.byteCount,
            sha256 == source.sha256, lastAcknowledgedOffset >= 0,
            lastAcknowledgedOffset <= byteCount,
            createdAt.utf8.count <= 64
        else { throw TractandaError("clientStateInvalid", "Upload receipt is invalid.") }
        guard try JSON.encode(self).count <= 16_384 else {
            throw TractandaError("clientStateInvalid", "Upload receipt exceeds its size bound.")
        }
    }

}

/// All receipt operations are anchored to a no-follow directory descriptor. No credentials are saved.
struct AttachmentReceiptStore {
    let directory: URL
    let endpoint: String
    static let maximumReceipts = 64
    static let maximumReceiptBytes = 16_384

    static func configured(endpoint: String) throws -> AttachmentReceiptStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return AttachmentReceiptStore(
            directory: base.appendingPathComponent("Tractanda/CLI/AttachmentUploads", isDirectory: true),
            endpoint: endpoint)
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.path.hasPrefix("/"), !directory.path.contains("\0") else { throw invalid() }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid() }
        defer { close(descriptor) }
        let components = directory.path.split(separator: "/")
        for component in components {
            let name = String(component)
            guard name != ".", name != ".." else { throw invalid() }
            var next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else { throw invalid() }
                guard fsync(descriptor) == 0 else { throw invalid() }
                next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw invalid() }
            close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & 0o777 == 0o700
        else { throw invalid() }
        return try body(descriptor)
    }

    /// The short lock covers receipt replacement/admission; data transfer has no global lock.
    func save(_ receipt: AttachmentUploadReceipt) throws {
        try receipt.validate()
        guard receipt.endpoint == endpoint else { throw invalid() }
        try withDirectory { directoryFD in
            guard flock(directoryFD, LOCK_EX) == 0 else { throw invalid() }
            defer { _ = flock(directoryFD, LOCK_UN) }
            let destination = try name(receipt.receiptID)
            var existing = stat()
            let replacing = fstatat(directoryFD, destination, &existing, AT_SYMLINK_NOFOLLOW) == 0
            if replacing {
                guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                    existing.st_uid == getuid(), existing.st_mode & 0o777 == 0o600
                else { throw invalid() }
            } else {
                guard errno == ENOENT else { throw invalid() }
                let duplicate = dup(directoryFD)
                guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                    if duplicate >= 0 { close(duplicate) }
                    throw invalid()
                }
                defer { closedir(stream) }
                var count = 0
                var scanned = 0
                while let entry = readdir(stream) {
                    scanned += 1
                    guard scanned <= 128 else { throw invalid() }
                    let entryName = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
                    }
                    if entryName.hasSuffix(".json") { count += 1 }
                }
                guard count < Self.maximumReceipts else {
                    throw TractandaError(
                        "resourceLimit", "Too many retained upload receipts; explicitly finish or abort one.")
                }
            }
            let data = try JSON.encode(receipt)
            let temporary = ".receipt-" + (try UUID.makeVersion1().uuidString.lowercased())
            let fd = openat(
                directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw invalid() }
            defer {
                close(fd)
                _ = unlinkat(directoryFD, temporary, 0)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw invalid() }
                    offset += written
                }
            }
            guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, destination) == 0,
                fsync(directoryFD) == 0
            else { throw invalid() }
        }
    }

    func load(_ receiptID: String) throws -> AttachmentUploadReceipt {
        try withDirectory { directoryFD in
            let descriptor = openat(
                directoryFD, try name(receiptID), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw invalid() }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
                metadata.st_mode & 0o777 == 0o600,
                metadata.st_size >= 0, metadata.st_size <= Self.maximumReceiptBytes
            else { throw invalid() }
            var bytes = [UInt8](repeating: 0, count: Self.maximumReceiptBytes + 1)
            var count = 0
            while count < bytes.count {
                let next = bytes.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress!.advanced(by: count), $0.count - count)
                }
                if next < 0, errno == EINTR { continue }
                guard next >= 0 else { throw invalid() }
                if next == 0 { break }
                count += next
            }
            guard count == metadata.st_size else { throw invalid() }
            let receipt = try JSON.decode(AttachmentUploadReceipt.self, Data(bytes.prefix(count)))
            try receipt.validate()
            guard receipt.receiptID == receiptID else { throw invalid() }
            guard receipt.endpoint == endpoint else {
                throw TractandaError(
                    "connectionChanged",
                    "Receipt belongs to another endpoint; explicitly select its original connection. Endpoint identity is not a store UUID."
                )
            }
            return receipt
        }
    }
    func contains(_ receiptID: String) throws -> Bool {
        try withDirectory { directoryFD in
            var metadata = stat()
            if fstatat(directoryFD, try name(receiptID), &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw invalid() }
            return false
        }
    }
    func remove(_ receiptID: String) throws {
        try withDirectory { directoryFD in
            guard unlinkat(directoryFD, try name(receiptID), 0) == 0, fsync(directoryFD) == 0 else {
                throw invalid()
            }
        }
    }
    private func name(_ id: String) throws -> String {
        try Identifier.validate(id)
        return Data(id.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".json"
    }
    private func invalid() -> TractandaError {
        TractandaError(
            "clientStateInvalid", "Private upload receipt storage is unsafe, unavailable, or changed.")
    }
}

/// Parses the attachment/document-job grammar separately from main.swift so the shared dispatcher
/// only needs to hand it the arguments after command and socket.
enum AttachmentCommand {
    static let chunkBytes = 262_144

    static func run(
        _ arguments: [String], transport: any AttachmentCommandTransport,
        source: any AttachmentCommandSource, receipts: AttachmentReceiptStore,
        emit: (Data) -> Void
    ) throws {
        guard let command = arguments.first else { throw usage() }
        let values = Array(arguments.dropFirst())
        switch command {
        case "attachment":
            try runAttachment(values, transport: transport, source: source, receipts: receipts, emit: emit)
        case "document-job":
            try runDocumentJob(values, transport: transport, emit: emit)
        default: throw usage()
        }
    }

    private static func runAttachment(
        _ values: [String], transport: any AttachmentCommandTransport,
        source: any AttachmentCommandSource, receipts: AttachmentReceiptStore,
        emit: (Data) -> Void
    ) throws {
        guard let command = values.first else { throw usage() }
        let values = Array(values.dropFirst())
        switch command {
        case "begin":
            guard (4...5).contains(values.count) else { throw usage() }
            try Identifier.validate(values[0])
            try Identifier.validate(values[1])
            guard !values[2].isEmpty, values[2].utf8.count <= 200, !values[2].contains("\0"),
                !values[3].contains("\0")
            else { throw usage() }
            let path = URL(fileURLWithPath: values[3]).standardizedFileURL.path
            let opened = try source.open(path: path)
            try opened.proof.validate()
            try opened.verifyUnchanged()
            let request = AttachmentUploadRequest(
                itemID: values[0], expectedRevisionID: values[1], operationID: values[2],
                filename: opened.filename,
                mediaType: values.count == 5 ? values[4] : "application/octet-stream",
                byteCount: opened.proof.byteCount, sha256: opened.proof.sha256)
            let receiptID = try UUID.makeVersion1().uuidString.lowercased()
            var receipt = AttachmentUploadReceipt(
                schemaVersion: AttachmentUploadReceipt.schema, receiptID: receiptID,
                endpoint: receipts.endpoint, uploadID: nil, attachmentID: nil,
                itemID: request.itemID, expectedRevisionID: request.expectedRevisionID,
                sourcePath: path, filename: request.filename, mediaType: request.mediaType,
                byteCount: opened.proof.byteCount, sha256: opened.proof.sha256, source: opened.proof,
                operationID: request.operationID, lastAcknowledgedOffset: 0,
                createdAt: Timestamp.now())
            try receipts.save(receipt)  // intent survives a lost begin reply
            emit(try JSON.encode(receipt))  // recoverable identity is visible even if begin throws
            let result = try transport.beginAttachment(request)
            try validateBegin(result, request: request)
            if let committed = result.committed {
                try validateCommit(committed, receipt: receipt)
                try receipts.remove(receiptID)
                emit(try JSON.encode(committed))
                return
            }
            guard let uploadID = result.uploadID, result.chunkBytes == chunkBytes,
                result.offset >= 0, result.offset <= opened.proof.byteCount
            else { throw TractandaError("protocolError", "Invalid upload continuation.") }
            receipt.uploadID = uploadID
            receipt.attachmentID = result.attachment.attachmentID
            receipt.lastAcknowledgedOffset = result.offset
            try persistContinuation(receipt, previousUploadID: nil, receipts: receipts, transport: transport)
            emit(try JSON.encode(receipt))
        case "resume":
            guard values.count == 1 else { throw usage() }
            var receipt = try receipts.load(values[0])
            // Reconcile server state before accessing local source: a lost finish reply needs no file.
            var status: AttachmentIntegrityStatus?
            if let uploadID = receipt.uploadID {
                do {
                    status = try transport.attachmentUploadStatus(uploadID: uploadID)
                    try validateStatus(status!, receipt: receipt)
                } catch let error as TractandaError where error.code == "uploadExpired" {
                    // Exact begin below distinguishes committed replay from same-intent fresh admission.
                    status = nil
                }
            }
            let request = request(for: receipt)
            // Exact replay gives received offset, independently of integrity hash progress.
            let begun = try transport.beginAttachment(request)
            try validateBegin(begun, request: request)
            if let committed = begun.committed {
                try validateCommit(committed, receipt: receipt)
                try receipts.remove(receipt.receiptID)
                emit(try JSON.encode(committed))
                return
            }
            guard let uploadID = begun.uploadID else {
                throw TractandaError("protocolError", "Upload replay returned no continuation identity.")
            }
            let previousUploadID = receipt.uploadID
            let restarted = previousUploadID != nil && previousUploadID != uploadID
            if restarted { status = nil }
            receipt.uploadID = uploadID
            receipt.attachmentID = begun.attachment.attachmentID
            receipt.lastAcknowledgedOffset = begun.offset
            try persistContinuation(
                receipt, previousUploadID: previousUploadID, receipts: receipts, transport: transport)
            emit(try JSON.encode(receipt))  // uploadID is visible before any data
            if restarted {
                emit(
                    try jsonData([
                        "uploadID": uploadID, "phase": "restarted", "receivedOffset": begun.offset,
                        "receiptID": receipt.receiptID, "operationID": receipt.operationID,
                    ]))
            }
            if status == nil {
                status = try transport.attachmentUploadStatus(uploadID: uploadID)
                try validateStatus(status!, receipt: receipt)
            }
            guard ["uploading", "paused", "verifying", "verified", "published"].contains(status!.phase) else {
                throw TractandaError("attachmentUploadUnavailable", "Server upload is no longer resumable.")
            }
            var offset = begun.offset
            if ["verifying", "verified", "published"].contains(status!.phase) || offset == receipt.byteCount {
                let committed = try transport.finishAttachmentOnce(uploadID: uploadID)
                try validateCommit(committed, receipt: receipt)
                try receipts.remove(receipt.receiptID)
                emit(try JSON.encode(committed))
                return
            }
            let currentSource = try source.open(path: receipt.sourcePath)
            guard currentSource.proof == receipt.source else {
                throw TractandaError(
                    "fileChanged",
                    "Original source changed; upload remains staged. Explicitly abort before beginning a different intent."
                )
            }
            try currentSource.verifyUnchanged()
            while offset < receipt.byteCount {
                let data = try currentSource.chunk(offset: offset, limit: chunkBytes)
                guard !data.isEmpty, data.count <= chunkBytes,
                    Int64(data.count) <= receipt.byteCount - offset
                else { throw TractandaError("fileChanged", "Source ended or changed during transfer.") }
                let acknowledged = try transport.appendAttachment(
                    uploadID: uploadID, offset: offset, data: data)
                let next = offset.addingReportingOverflow(Int64(data.count))
                guard !next.overflow, acknowledged == next.partialValue else {
                    throw TractandaError("protocolError", "Server acknowledged an unexpected upload offset.")
                }
                offset = acknowledged
                receipt.lastAcknowledgedOffset = offset
                try receipts.save(receipt)
                emit(
                    try jsonData(
                        statusLine(uploadID: uploadID, receivedOffset: offset, totalBytes: receipt.byteCount))
                )
            }
            try currentSource.verifyUnchanged()
            let committed = try transport.finishAttachmentOnce(uploadID: uploadID)
            try validateCommit(committed, receipt: receipt)
            try receipts.remove(receipt.receiptID)
            emit(try JSON.encode(committed))
        case "status":
            guard values.count == 1 else { throw usage() }
            emit(try JSON.encode(transport.attachmentUploadStatus(uploadID: values[0])))
        case "abort":
            guard values.count == 1 else { throw usage() }
            if try receipts.contains(values[0]) {
                var receipt = try receipts.load(values[0])
                var activeID: String?
                if let uploadID = receipt.uploadID {
                    do {
                        let status = try transport.attachmentUploadStatus(uploadID: uploadID)
                        try validateStatus(status, receipt: receipt)
                        activeID = uploadID
                    } catch let error as TractandaError where error.code == "uploadExpired" {
                        activeID = nil
                    }
                }
                if activeID == nil {
                    let begun = try transport.beginAttachment(request(for: receipt))
                    try validateBegin(begun, request: request(for: receipt))
                    if let committed = begun.committed {
                        try validateCommit(committed, receipt: receipt)
                        try receipts.remove(receipt.receiptID)
                        emit(try JSON.encode(committed))
                        return
                    }
                    guard let uploadID = begun.uploadID else {
                        throw TractandaError("protocolError", "Abort replay produced no upload identity.")
                    }
                    let previousUploadID = receipt.uploadID
                    receipt.uploadID = uploadID
                    receipt.attachmentID = begun.attachment.attachmentID
                    receipt.lastAcknowledgedOffset = begun.offset
                    try persistContinuation(
                        receipt, previousUploadID: previousUploadID, receipts: receipts, transport: transport)
                    activeID = uploadID
                }
                let uploadID = activeID!
                try transport.abortAttachment(uploadID: uploadID)
                try receipts.remove(receipt.receiptID)
                emit(try jsonData(["uploadID": uploadID, "aborted": true]))
            } else {
                try transport.abortAttachment(uploadID: values[0])
                emit(try jsonData(["uploadID": values[0], "aborted": true]))
            }
        default: throw usage()
        }
    }

    private static func persistContinuation(
        _ receipt: AttachmentUploadReceipt, previousUploadID: String?, receipts: AttachmentReceiptStore,
        transport: any AttachmentCommandTransport
    ) throws {
        do { try receipts.save(receipt) } catch {
            let primary = error
            guard let uploadID = receipt.uploadID, previousUploadID != uploadID else { throw primary }
            do { try transport.abortAttachment(uploadID: uploadID) } catch {
                throw TractandaError(
                    "clientStateInvalid",
                    "Could not persist new upload handle \(uploadID): \(primary). Best-effort abort also failed: \(error). Previous receipt is retained."
                )
            }
            throw TractandaError(
                "clientStateInvalid",
                "Could not persist new upload handle \(uploadID): \(primary). New uncommitted upload was aborted; previous receipt is retained."
            )
        }
    }

    private static func request(for receipt: AttachmentUploadReceipt) -> AttachmentUploadRequest {
        AttachmentUploadRequest(
            itemID: receipt.itemID, expectedRevisionID: receipt.expectedRevisionID,
            operationID: receipt.operationID, filename: receipt.filename, mediaType: receipt.mediaType,
            byteCount: receipt.byteCount, sha256: receipt.sha256)
    }
    private static func validateBegin(_ result: AttachmentUploadResult, request: AttachmentUploadRequest)
        throws
    {
        try Identifier.validate(result.attachment.attachmentID)
        if let uploadID = result.uploadID { try Identifier.validate(uploadID) }
        guard result.attachment.filename == request.filename,
            result.attachment.mediaType == request.mediaType,
            result.attachment.byteCount == request.byteCount, result.attachment.sha256 == request.sha256,
            result.offset >= 0, result.offset <= request.byteCount,
            result.committed != nil || (result.uploadID != nil && result.chunkBytes == chunkBytes)
        else {
            throw TractandaError("protocolError", "Upload replay changed the exact original intent.")
        }
    }
    private static func validateStatus(_ status: AttachmentIntegrityStatus, receipt: AttachmentUploadReceipt)
        throws
    {
        guard status.uploadID == receipt.uploadID, status.attachmentID == receipt.attachmentID,
            status.totalBytes == receipt.byteCount,
            status.verifiedBytes >= 0, status.verifiedBytes <= receipt.byteCount
        else {
            throw TractandaError("protocolError", "Server integrity progress does not match upload intent.")
        }
    }
    private static func validateCommit(_ result: AttachmentCommitResult, receipt: AttachmentUploadReceipt)
        throws
    {
        guard result.itemID == receipt.itemID, result.operationID == receipt.operationID else {
            throw TractandaError("protocolError", "Server commit does not match upload intent.")
        }
    }

    private static func runDocumentJob(
        _ values: [String], transport: any AttachmentCommandTransport, emit: (Data) -> Void
    ) throws {
        guard let action = values.first else { throw usage() }
        let args = Array(values.dropFirst())
        let method: String
        var body: [String: Any] = [:]
        switch action {
        case "start":
            guard args.count == 4 else { throw usage() }
            method = "start"
            body = [
                "itemID": args[0], "expectedRevisionID": args[1], "attachmentID": args[2],
                "operationID": args[3],
            ]
        case "status", "cancel", "resume", "discard":
            guard args.count == 1 else { throw usage() }
            method = action
            body = ["jobID": args[0]]
        case "list":
            guard args.count <= 2 else { throw usage() }
            method = "list"
            if let after = args.first, after != "-" { body["afterJobID"] = after }
            if args.count == 2 {
                guard let limit = Int(args[1]), (1...64).contains(limit) else { throw usage() }
                body["limit"] = limit
            } else {
                body["limit"] = 32
            }
        case "rebase":
            guard args.count == 2 else { throw usage() }
            method = "rebase"
            body = ["jobID": args[0], "expectedRevisionID": args[1]]
        case "page":
            guard args.count == 2, let number = Int64(args[1]), number > 0 else { throw usage() }
            method = "page"
            body = ["jobID": args[0], "pageNumber": number]
        default: throw usage()
        }
        for key in ["itemID", "expectedRevisionID", "attachmentID", "jobID", "afterJobID"] {
            if let id = body[key] as? String { try Identifier.validate(id) }
        }
        if let operation = body["operationID"] as? String {
            guard !operation.isEmpty, operation.utf8.count <= 200, !operation.contains("\0") else {
                throw usage()
            }
        }
        emit(try transport.documentJobCall("TractandaDocumentJob/" + method, arguments: body))
    }

    private static func statusLine(uploadID: String, receivedOffset: Int64, totalBytes: Int64) -> [String:
        Any]
    {
        [
            "uploadID": uploadID, "phase": "uploading", "receivedOffset": receivedOffset,
            "totalBytes": totalBytes,
        ]
    }

    private static func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }

    private static func usage() -> TractandaError {
        TractandaError(
            "usage",
            "Use attachment begin|status|resume|abort, or document-job start|status|list|cancel|resume|rebase|page|discard."
        )
    }
}
