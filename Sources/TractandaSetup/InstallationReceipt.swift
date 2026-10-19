import Foundation
import TractandaCore

struct InstallationReceipt: Codable, Equatable {
    enum State: String, Codable { case preparing, active, removed }
    let version: Int
    let instance: String
    let owner: String
    let store: String
    let indexDirectory: String
    let socket: String
    let port: Int
    let uuidNode: String?
    let sample: Bool
    var release: String
    var manifestSHA256: String
    var state: State
    var recoveryReason: String? = nil
    var initialized: Bool
    var sampled: Bool
    var board: [String: String]
    /// Desired nil is disabled, including legacy receipts. Snapshot never implies enablement.
    var peerRuntimeConfiguration: ManagedPeerConfiguration?
    var peerRuntimePrevious: ManagedPeerConfigurationSnapshot?
    var definitionSHA256: String?
    var authenticationDefinitionSHA256: String? = nil
    var packageSetupOwner: SetupPackageOwner? = nil
    var preparedStoreID: String? = nil
    var preparedReplicaID: String? = nil
    /// One bounded old/desired witness per mutable systemd definition, never program bytes.
    struct PackageDefinitionChange: Codable, Equatable {
        let old: String?
        let desired: String?
    }
    var packageDefinitions: [String: PackageDefinitionChange]? = nil
    var releases: [String: String]
    var documentExtraction: DocumentExtractionPayload?
    var documentScratchDirectory: String?
    var documentPreparationDirectory: String?
    var embedding: EmbeddingPayload?
    var embeddingDefinitionSHA256: String?
    var embeddingConfigured: Bool
    var embeddingConfigurationID: String
    /// A durable, installer-owned rollback record while moving the pilot model to Granite.
    var embeddingPreviousConfiguration: BundledSemanticConfiguration?

    init(options: SetupOptions, roots: SetupRoots, owner: String, release: URL, manifestSHA256: String) throws
    {
        version = 1
        instance = options.name
        self.owner = owner
        store = roots.data.appendingPathComponent(options.name).path
        indexDirectory = roots.indexes.appendingPathComponent(options.name).path
        socket = roots.runtime.appendingPathComponent(options.name).appendingPathComponent("server.sock").path
        port = options.port
        uuidNode = options.uuidNode
        sample = options.mode == .sample
        self.release = release.path
        self.manifestSHA256 = manifestSHA256
        state = .preparing
        initialized = false
        sampled = false
        board = [:]
        peerRuntimeConfiguration = nil
        peerRuntimePrevious = nil
        definitionSHA256 = nil
        releases = [release.path: manifestSHA256]
        documentExtraction = nil
        documentScratchDirectory = nil
        documentPreparationDirectory = nil
        embedding = nil
        embeddingDefinitionSHA256 = nil
        embeddingConfigured = false
        embeddingConfigurationID = try UUID.makeVersion1().uuidString.lowercased()
        embeddingPreviousConfiguration = nil
    }
}
