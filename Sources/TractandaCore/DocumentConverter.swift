import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Operator-only startup configuration. Requests never supply paths or programs.
public struct DocumentConverterConfiguration: Codable, Sendable {
    public let executablePath: String
    public let modelDirectory: String
    public let scratchDirectory: String
    public let timeoutSeconds: Double
    public let preparationDirectory: String?

    public init(
        executablePath: String, modelDirectory: String, scratchDirectory: String,
        timeoutSeconds: Double = 360, preparationDirectory: String? = nil
    ) {
        self.executablePath = executablePath
        self.modelDirectory = modelDirectory
        self.scratchDirectory = scratchDirectory
        self.timeoutSeconds = timeoutSeconds
        self.preparationDirectory = preparationDirectory
    }

    func validate(storeRoot: URL, indexDirectory: URL) throws {
        for path in [executablePath, modelDirectory, scratchDirectory] {
            guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096, !path.contains("\0") else {
                throw TractandaError(
                    "invalidDocumentConfiguration",
                    "Document converter paths must be dedicated absolute paths.")
            }
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 360 else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Document timeout must be positive and at most 360 seconds.")
        }
        if let preparationDirectory {
            var metadata = stat()
            guard preparationDirectory.hasPrefix("/"), !preparationDirectory.contains("\0"),
                preparationDirectory.utf8.count <= 4096,
                lstat(preparationDirectory, &metadata) == 0,
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_uid == getuid(),
                metadata.st_mode & 0o077 == 0
            else {
                throw TractandaError(
                    "invalidDocumentConfiguration", "Preparation gate must be a private local directory.")
            }
        }
        let scratch = URL(fileURLWithPath: scratchDirectory).standardizedFileURL.resolvingSymlinksInPath()
        for canonical in [storeRoot, indexDirectory] {
            let path = canonical.standardizedFileURL.resolvingSymlinksInPath().path
            guard scratch.path != path, !scratch.path.hasPrefix(path + "/"),
                !path.hasPrefix(scratch.path + "/")
            else {
                throw TractandaError(
                    "invalidDocumentConfiguration",
                    "Document scratch must not overlap canonical or index storage.")
            }
        }
        let executable = try DocumentProcess.regularMetadata(executablePath, maximumBytes: 256 * 1024 * 1024)
        guard executable.st_mode & 0o111 != 0, executable.st_mode & 0o6022 == 0,
            executable.st_uid == getuid() || executable.st_uid == 0
        else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Document converter must be a trusted local executable.")
        }
        var model = stat()
        guard lstat(modelDirectory, &model) == 0, model.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw TractandaError("invalidDocumentConfiguration", "Document model directory is unavailable.")
        }
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(scratchDirectory, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else {
            throw TractandaError(
                "invalidDocumentConfiguration", "Document scratch must be private and owned by the service.")
        }
    }
}

final class DocumentConversionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum DocumentProcess {
    static let maximumResultBytes = 2 * 1024 * 1024
    private static let maximumLogBytes = 64 * 1024
    private static let reserveBytes: UInt64 = 10 * 1024 * 1024 * 1024

    static func executableSHA256(_ path: String) throws -> String {
        _ = try regularMetadata(path, maximumBytes: 256 * 1024 * 1024)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw TractandaError("documentConverter", "Configured converter is unavailable.")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func regularMetadata(_ path: String, maximumBytes: Int) throws -> stat {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw TractandaError(
                "documentConverter", "Document converter file is unavailable or exceeds its limit.")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw TractandaError("resourceLimit", "Document converter file exceeds its limit.")
        }
        return metadata
    }

    private static func capacity(_ root: URL, availableBytes: (@Sendable () throws -> UInt64)? = nil) throws {
        if let availableBytes {
            let available: UInt64
            do { available = try availableBytes() } catch {
                throw TractandaError("resourceLimit", "Cannot determine genuine document scratch capacity.")
            }
            guard available >= reserveBytes + 16 * 1024 * 1024 else {
                throw TractandaError(
                    "resourceLimit", "Document conversion requires a genuine 10 GiB reserve.")
            }
            return
        }
        var value = statvfs()
        guard statvfs(root.path, &value) == 0, value.f_frsize > 0 else {
            throw TractandaError("resourceLimit", "Cannot determine genuine document scratch capacity.")
        }
        let bytes = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_frsize))
        guard !bytes.overflow, bytes.partialValue >= reserveBytes + 16 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Document conversion requires a genuine 10 GiB reserve.")
        }
    }

    private static func boundedData(_ path: URL, maximumBytes: Int) throws -> Data {
        _ = try regularMetadata(path.path, maximumBytes: maximumBytes)
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TractandaError("documentConverter", "Cannot open document output safely.")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            opened.st_size >= 0, opened.st_size <= maximumBytes
        else { throw TractandaError("resourceLimit", "Document output exceeds its limit.") }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw TractandaError("resourceLimit", "Document output exceeds its limit.")
        }
        return data
    }

    static func convert(
        _ snapshot: DocumentExtractionSnapshot, configuration: DocumentConverterConfiguration,
        expectedExecutableSHA256: String, cancellation: DocumentConversionCancellation,
        availableBytes: (@Sendable () throws -> UInt64)? = nil
    ) throws -> [AttachmentDocumentPage] {
        let base = URL(fileURLWithPath: configuration.scratchDirectory, isDirectory: true)
        try cancellation.check()
        try capacity(base, availableBytes: availableBytes)
        let stage = base.appendingPathComponent("operation-" + Identifier.make(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainStage = false
        defer { if !retainStage { try? FileManager.default.removeItem(at: stage) } }
        let input = stage.appendingPathComponent("original.payload")
        let output = stage.appendingPathComponent("result.json")
        let log = stage.appendingPathComponent("stderr.log")
        try snapshot.input.write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: input.path)
        guard
            FileManager.default.createFile(
                atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw TractandaError("documentConverter", "Cannot create private converter log.")
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.currentDirectoryURL = stage
        process.arguments = [
            "convert", configuration.modelDirectory, input.path, snapshot.source.mediaType, output.path,
        ]
        if let preparationDirectory = configuration.preparationDirectory {
            let prepared = URL(fileURLWithPath: preparationDirectory).appendingPathComponent(
                snapshot.source.sha256, isDirectory: true)
            var metadata = stat()
            guard lstat(prepared.path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw TractandaError(
                    "unpreparedDocumentInput", "This original has no frozen preparation gate.")
            }
            process.arguments!.append(prepared.path)
        }
        process.standardOutput = handle
        process.standardError = handle
        let deadline = ContinuousClock.now.advanced(by: .seconds(configuration.timeoutSeconds))
        var pageDeadline = ContinuousClock.now.advanced(by: .seconds(min(180, configuration.timeoutSeconds)))
        var activePage = 0
        do {
            guard try executableSHA256(configuration.executablePath) == expectedExecutableSHA256 else {
                throw TractandaError(
                    "documentConverterChanged", "Configured converter changed after startup.")
            }
            try process.run()
            while process.isRunning {
                try cancellation.check()
                let progress = stage.appendingPathComponent("page-progress.json")
                if FileManager.default.fileExists(atPath: progress.path) {
                    let data = try boundedData(progress, maximumBytes: 256)
                    if let value = try JSONSerialization.jsonObject(with: data) as? [String: Int],
                        Set(value.keys) == ["pageNumber"], let page = value["pageNumber"], page > activePage
                    {
                        guard page == activePage + 1, page <= 2 else {
                            throw TractandaError("invalidDocumentOutput", "Invalid converter page progress.")
                        }
                        activePage = page
                        pageDeadline = ContinuousClock.now.advanced(
                            by: .seconds(min(180, configuration.timeoutSeconds)))
                    }
                }
                guard ContinuousClock.now <= deadline, ContinuousClock.now <= pageDeadline else {
                    throw TractandaError("documentTimeout", "Document conversion exceeded its deadline.")
                }
                try capacity(base, availableBytes: availableBytes)
                _ = try regularMetadata(log.path, maximumBytes: maximumLogBytes)
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try regularMetadata(output.path, maximumBytes: maximumResultBytes)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            try cancellation.check()
            try handle.synchronize()
            _ = try regularMetadata(log.path, maximumBytes: maximumLogBytes)
            try capacity(base, availableBytes: availableBytes)
            guard process.terminationStatus == 0 else {
                if let data = try? boundedData(output, maximumBytes: 4096),
                    let failure = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                    let code = failure["code"],
                    ["unsupportedDocumentInput", "truncatedDocumentOutput", "resourceLimit"].contains(code)
                {
                    throw TractandaError(code, "Configured document converter rejected this input or output.")
                }
                throw TractandaError("documentConverterFailed", "Configured document converter failed.")
            }
            let result = try DocumentValue.strictDecode(
                DocumentConversionResult.self, data: boundedData(output, maximumBytes: maximumResultBytes))
            try result.identity.validateCurrent()
            guard result.identity == snapshot.identity, result.inputSHA256 == snapshot.source.sha256,
                (1...2).contains(result.pages.count),
                result.pages.map(\.pageNumber) == Array(1...result.pages.count),
                snapshot.source.mediaType == "application/pdf" || result.pages.count == 1
            else {
                throw TractandaError(
                    "invalidDocumentOutput", "Converter identity, original or pages changed.")
            }
            let pages = try result.pages.map {
                try $0.geometry.validateContentCrop()
                return try AttachmentDocumentPage(
                    pageNumber: $0.pageNumber, geometry: $0.geometry, rasterSHA256: $0.rasterSHA256,
                    parsed: DoclingDocTagsParser.parse(Data($0.rawDocTags.utf8)),
                    generatedTokens: $0.generatedTokens, stopReason: $0.stopReason)
            }
            if configuration.preparationDirectory != nil {
                let completed = base.appendingPathComponent("completed", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: completed, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for page in 1...result.pages.count {
                    for suffix in ["output.doctags", "generation.json"] {
                        let file = stage.appendingPathComponent("page-\(page)." + suffix)
                        let bytes = try boundedData(file, maximumBytes: DoclingParsedPage.maximumRawBytes)
                        try bytes.write(
                            to: completed.appendingPathComponent(
                                stage.lastPathComponent + ".page-\(page)." + suffix), options: .atomic)
                    }
                }
            }
            return pages
        } catch {
            // Durably save the original reason before termination/temporary cleanup.
            let failureDirectory = base.appendingPathComponent("failures", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: failureDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let failure = [
                "inputSHA256": snapshot.source.sha256, "operationID": snapshot.operationID,
                "code": (error as? TractandaError)?.code ?? "cancelled",
                "message": String(describing: error).prefix(1024).description,
            ]
            do {
                try JSON.encode(failure).write(
                    to: failureDirectory.appendingPathComponent(stage.lastPathComponent + ".json"),
                    options: .atomic)
            } catch { retainStage = true }
            if process.isRunning {
                process.terminate()
                let stop = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < stop { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            let diagnosticDescriptor = log.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            if diagnosticDescriptor >= 0 {
                let file = FileHandle(fileDescriptor: diagnosticDescriptor, closeOnDealloc: true)
                if let bytes = try? file.read(upToCount: maximumLogBytes), !bytes.isEmpty {
                    do {
                        try bytes.write(
                            to: failureDirectory.appendingPathComponent(
                                stage.lastPathComponent + ".stderr.log"), options: .atomic)
                    } catch { retainStage = true }
                }
                try? file.close()
            }
            // Retain bounded raw/stop evidence for a rejected or interrupted page.
            // Originals remain in canonical storage; private stage duplicates can then go.
            for page in 1...2 {
                for suffix in ["output.doctags", "generation.json"] {
                    let evidence = stage.appendingPathComponent("page-\(page)." + suffix)
                    guard FileManager.default.fileExists(atPath: evidence.path) else { continue }
                    do {
                        let bytes = try boundedData(evidence, maximumBytes: DoclingParsedPage.maximumRawBytes)
                        try bytes.write(
                            to: failureDirectory.appendingPathComponent(
                                stage.lastPathComponent + ".page-\(page)." + suffix), options: .atomic)
                    } catch { retainStage = true }
                }
            }
            throw error
        }
    }
}
