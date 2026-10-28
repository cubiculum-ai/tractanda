import CTractandaPlatform
import Foundation
import TractandaClient
import TractandaCore
import TractandaServer

func daemonCommand(_ arguments: [String]) async throws {
    if arguments == ["daemon", "--help"] {
        print(usage)
        return
    }
    let configuration = try daemonConfiguration(from: arguments)
    guard tractanda_start_signals() == 0 else {
        throw TractandaError("signal", "Cannot install shutdown signals.")
    }
    defer { tractanda_restore_signals() }
    let startupWatchdog = Task.detached {
        while !Task.isCancelled && tractanda_stopping() == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled, tractanda_stopping() != 0 else { return }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch { return }
        guard !Task.isCancelled else { return }
        // Only the C startup guard can restore default SIGTERM handling. It is cleared before
        // the daemon advertises endpoints, so normal serving writes keep coordinated shutdown.
        _ = tractanda_terminate_if_stopping()
    }
    tractanda_startup_shutdown_guard_begin()
    let daemon: SharedDaemon
    do {
        daemon = try await SharedDaemon.start(
            configuration: configuration,
            claimStartupReadiness: { tractanda_startup_shutdown_guard_ready() != 0 })
    } catch {
        tractanda_startup_shutdown_guard_end()
        startupWatchdog.cancel()
        throw error
    }
    tractanda_startup_shutdown_guard_end()
    startupWatchdog.cancel()
    do {
        if tractanda_stopping() != 0 {
            await daemon.close()
            return
        }
        output(try JSONEncoder().encode(await daemon.endpoints()))
        while tractanda_stopping() == 0 { try await Task.sleep(for: .milliseconds(100)) }
        await daemon.close()
    } catch {
        await daemon.close()
        throw error
    }
}

func daemonConfiguration(from arguments: [String]) throws -> DaemonConfiguration {
    guard arguments.count >= 3, arguments.first == "daemon" else { throw TractandaError("usage", usage) }
    let store = arguments[1]
    let socket = arguments[2]
    var port: Int? = 48_728
    var managed = false
    var view: String?
    var projectRoot: String?
    var statusRoot: String?
    var project: String?
    var indexDirectory: String?
    var documentExecutable: String?
    var documentModel: String?
    var documentScratch: String?
    var documentResourceValues: [String: Double] = [:]
    var rebuildNoProgressSeconds: Double?
    var uploadIdleSeconds: Double?
    var uploadStagedBytes: Int64?
    var attachmentMinimumFreeBytes: Int64?
    var peerRuntimeConfigurationPath: String?
    var modelManifest: String?
    var modelStorage: String?
    var modelAdoption: String?
    var publicJMAP: PublicJMAPConfiguration?
    var seen: Set<String> = []
    var index = 3
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--no-http":
            guard !seen.contains("http"), port != nil else { throw TractandaError("usage", usage) }
            seen.insert("http")
            port = nil
            index += 1
        case "--managed":
            guard !managed else { throw TractandaError("usage", usage) }
            managed = true
            index += 1
        case "--http-port", "--view", "--project-root", "--status-root", "--project", "--index-directory",
            "--document-converter", "--document-model-directory", "--document-scratch-directory",
            "--document-inspect-seconds", "--document-model-load-seconds", "--document-page-seconds",
            "--document-no-progress-seconds", "--document-termination-grace-seconds",
            "--attachment-upload-idle-seconds", "--attachment-staged-byte-quota",
            "--attachment-minimum-free-bytes", "--rebuild-no-progress-seconds", "--peer-runtime-config",
            "--public-jmap-config", "--model-provisioning-manifest", "--model-storage-directory",
            "--model-adoption-directory":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw TractandaError("usage", usage)
            }
            let value = arguments[index + 1]
            switch flag {
            case "--http-port":
                guard !seen.contains("http"), port != nil, let parsed = Int(value),
                    (0...65_535).contains(parsed)
                else { throw TractandaError("usage", usage) }
                seen.insert("http")
                port = parsed
            case "--view":
                guard view == nil else { throw TractandaError("usage", usage) }
                view = value
            case "--project-root":
                guard projectRoot == nil else { throw TractandaError("usage", usage) }
                projectRoot = value
            case "--status-root":
                guard statusRoot == nil else { throw TractandaError("usage", usage) }
                statusRoot = value
            case "--project":
                guard project == nil else { throw TractandaError("usage", usage) }
                project = value
            case "--index-directory":
                guard indexDirectory == nil else { throw TractandaError("usage", usage) }
                indexDirectory = value
            case "--document-converter":
                guard documentExecutable == nil else { throw TractandaError("usage", usage) }
                documentExecutable = value
            case "--document-model-directory":
                guard documentModel == nil else { throw TractandaError("usage", usage) }
                documentModel = value
            case "--document-scratch-directory":
                guard documentScratch == nil else { throw TractandaError("usage", usage) }
                documentScratch = value
            case "--document-inspect-seconds", "--document-model-load-seconds", "--document-page-seconds",
                "--document-no-progress-seconds", "--document-termination-grace-seconds":
                guard documentResourceValues[flag] == nil, let seconds = Double(value),
                    seconds.isFinite, seconds > 0
                else { throw TractandaError("usage", usage) }
                documentResourceValues[flag] = seconds
            case "--rebuild-no-progress-seconds":
                guard rebuildNoProgressSeconds == nil, let seconds = Double(value), seconds.isFinite,
                    seconds > 0
                else { throw TractandaError("usage", usage) }
                rebuildNoProgressSeconds = seconds
            case "--attachment-upload-idle-seconds":
                guard uploadIdleSeconds == nil, let seconds = Double(value), seconds.isFinite, seconds > 0
                else { throw TractandaError("usage", usage) }
                uploadIdleSeconds = seconds
            case "--attachment-minimum-free-bytes":
                guard attachmentMinimumFreeBytes == nil, let bytes = Int64(value), bytes >= 0
                else { throw TractandaError("usage", usage) }
                attachmentMinimumFreeBytes = bytes
            case "--attachment-staged-byte-quota":
                guard uploadStagedBytes == nil, let bytes = Int64(value), bytes > 0
                else { throw TractandaError("usage", usage) }
                uploadStagedBytes = bytes
            case "--model-provisioning-manifest":
                guard modelManifest == nil else { throw TractandaError("usage", usage) }
                modelManifest = value
            case "--model-storage-directory":
                guard modelStorage == nil else { throw TractandaError("usage", usage) }
                modelStorage = value
            case "--model-adoption-directory":
                guard modelAdoption == nil else { throw TractandaError("usage", usage) }
                modelAdoption = value
            case "--public-jmap-config":
                guard publicJMAP == nil else { throw TractandaError("usage", usage) }
                publicJMAP = try PublicJMAPConfiguration.load(from: value)
            case "--peer-runtime-config":
                guard peerRuntimeConfigurationPath == nil, value.hasPrefix("/"), value != "/",
                    value.utf8.count <= 4096, !value.contains("\0")
                else { throw TractandaError("usage", usage) }
                peerRuntimeConfigurationPath = value
            default: throw TractandaError("usage", usage)
            }
            index += 2
        default: throw TractandaError("usage", usage)
        }
    }
    let documentValues = [documentExecutable, documentModel, documentScratch].compactMap { $0 }
    guard documentValues.isEmpty || documentValues.count == 3 else { throw TractandaError("usage", usage) }
    guard (modelManifest == nil) == (modelStorage == nil), modelAdoption == nil || modelManifest != nil else {
        throw TractandaError("usage", usage)
    }
    let provisioning = modelManifest.map {
        ModelProvisioningConfiguration(
            manifestPath: $0, storageDirectory: modelStorage!, adoptionDirectory: modelAdoption)
    }
    let documentArtifact =
        try modelManifest.map {
            try ModelProvisioningCatalog.load($0).artifacts.first {
                $0.identifier == "granite-docling-258m-mlx"
            }
        } ?? nil
    let converter = documentExecutable.map {
        DocumentConverterConfiguration(
            executablePath: $0, modelDirectory: documentModel!, scratchDirectory: documentScratch!,
            modelArtifact: documentArtifact,
            modelStorageDirectory: documentArtifact == nil ? nil : modelStorage)
    }
    let documentResources: DocumentJobResources? =
        documentResourceValues.isEmpty
        ? nil
        : .init(
            inspectSeconds: documentResourceValues["--document-inspect-seconds"]
                ?? DocumentJobResources.defaultInspectSeconds,
            modelLoadSeconds: documentResourceValues["--document-model-load-seconds"]
                ?? DocumentJobResources.defaultModelLoadSeconds,
            pageSeconds: documentResourceValues["--document-page-seconds"]
                ?? DocumentJobResources.defaultPageSeconds,
            noProgressSeconds: documentResourceValues["--document-no-progress-seconds"]
                ?? DocumentJobResources.defaultNoProgressSeconds,
            terminationGraceSeconds: documentResourceValues["--document-termination-grace-seconds"]
                ?? DocumentJobResources.defaultTerminationGraceSeconds)
    let configuration = DaemonConfiguration(
        storePath: store, indexDirectory: indexDirectory, socketPath: socket, httpPort: port,
        managed: managed, viewItemID: view,
        projectRootID: projectRoot, statusRootID: statusRoot, initialProjectID: project,
        documentConverter: converter, documentJobResources: documentResources,
        modelProvisioning: provisioning,
        attachmentUploadPolicy: AttachmentUploadPolicy(
            idleRetentionSeconds: uploadIdleSeconds ?? 3600,
            maximumStagedBytes: uploadStagedBytes ?? 8 * 1024 * 1024 * 1024,
            minimumFreeBytes: attachmentMinimumFreeBytes ?? 1024 * 1024 * 1024),
        rebuildNoProgressTimeoutSeconds: rebuildNoProgressSeconds ?? 120,
        peerRuntimeConfigurationPath: peerRuntimeConfigurationPath, publicJMAP: publicJMAP)
    try configuration.validate()
    return configuration
}
