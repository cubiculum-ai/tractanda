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
    var initialized: Bool
    var sampled: Bool
    var board: [String: String]
    var definitionSHA256: String?
    var releases: [String: String]
    var embedding: EmbeddingPayload?
    var embeddingDefinitionSHA256: String?
    var embeddingConfigured: Bool
    let embeddingConfigurationID: String

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
        definitionSHA256 = nil
        releases = [release.path: manifestSHA256]
        embedding = nil
        embeddingDefinitionSHA256 = nil
        embeddingConfigured = false
        embeddingConfigurationID = try UUID.makeVersion1().uuidString.lowercased()
    }
}
