import Foundation

enum SemanticPooling: String, Codable, Sendable {
    case last
    case mean
    case cls
}

enum SemanticNormalization: String, Codable, Sendable {
    case l2
}

enum SemanticInputEncoding: String, Codable, Sendable {
    case itemTextUTF8V2 = "item-text-utf8-v2"
}

/// Administrator-owned operational configuration for the disposable semantic index.
/// It deliberately lives beside canonical items, rather than in `index/`, so a derived-index
/// reset cannot lose the selected local runtime/model profile.
struct SemanticConfiguration: Codable, Equatable, Sendable {
    static let version = 2

    var formatVersion = version
    var configurationID: String
    var operationID: String
    var endpoint: String
    var model: String
    var modelRevision: String
    var dimensions: Int
    var documentPrefix: String
    var queryPrefix: String
    var chunkBytes: Int
    var overlapBytes: Int
    var pooling: SemanticPooling
    var normalization: SemanticNormalization
    var inputEncoding: SemanticInputEncoding

    init(
        configurationID: String = Identifier.make(), operationID: String,
        endpoint: String, model: String, modelRevision: String, dimensions: Int,
        documentPrefix: String, queryPrefix: String, chunkBytes: Int = 384, overlapBytes: Int = 64,
        pooling: SemanticPooling = .last, normalization: SemanticNormalization = .l2,
        inputEncoding: SemanticInputEncoding = .itemTextUTF8V2
    ) {
        self.configurationID = configurationID
        self.operationID = operationID
        self.endpoint = endpoint
        self.model = model
        self.modelRevision = modelRevision
        self.dimensions = dimensions
        self.documentPrefix = documentPrefix
        self.queryPrefix = queryPrefix
        self.chunkBytes = chunkBytes
        self.overlapBytes = overlapBytes
        self.pooling = pooling
        self.normalization = normalization
        self.inputEncoding = inputEncoding
    }

    func validate() throws {
        guard formatVersion == Self.version else {
            throw TractandaError("semanticConfiguration", "Unsupported semantic configuration version.")
        }
        guard !configurationID.isEmpty, configurationID.utf8.count <= 512,
            !operationID.isEmpty, operationID.utf8.count <= 512,
            endpoint.utf8.count <= 1024, !model.isEmpty, !modelRevision.isEmpty,
            model.utf8.count <= 256, modelRevision.utf8.count <= 256,
            documentPrefix.utf8.count <= 1024, queryPrefix.utf8.count <= 1024,
            (1...4096).contains(dimensions), (32...16_384).contains(chunkBytes),
            (0..<chunkBytes).contains(overlapBytes)
        else {
            throw TractandaError("semanticConfiguration", "Invalid semantic model or chunking profile.")
        }
        try Self.validateLoopbackEndpoint(endpoint)
    }

    func normalized() throws -> Self {
        var result = self
        result.endpoint = try Self.normalizedLoopbackEndpoint(endpoint)
        try result.validate()
        return result
    }

    /// The endpoint is deployment configuration, not a query argument.  Numeric loopback only
    /// avoids DNS, proxy and cloud routing surprises in the pilot.
    static func validateLoopbackEndpoint(_ value: String) throws {
        _ = try normalizedLoopbackEndpoint(value)
    }

    static func normalizedLoopbackEndpoint(_ value: String) throws -> String {
        guard let url = URL(string: value), url.scheme == "http", url.user == nil,
            url.password == nil, url.query == nil, url.fragment == nil,
            let host = url.host?.lowercased(), url.port != nil,
            host == "127.0.0.1" || host == "::1", url.path == "/v1/embeddings"
        else {
            throw TractandaError(
                "semanticEndpoint", "Use a numeric loopback /v1/embeddings HTTP endpoint with a port.")
        }
        let renderedHost = host == "::1" ? "[::1]" : host
        return "http://\(renderedHost):\(url.port!)/v1/embeddings"
    }
}

/// Persistent versioned configuration and exact-operation retry guard.
final class SemanticConfigurationStore {
    private let url: URL
    private let maintenanceURL: URL

    init(storeRoot: URL) {
        url = storeRoot.appendingPathComponent("semantic.json")
        maintenanceURL = storeRoot.appendingPathComponent("semantic-maintenance.json")
    }

    func load() throws -> SemanticConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try PrivateConfiguration.validate(url, directory: false)
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else {
            throw TractandaError("semanticConfiguration", "Semantic configuration exceeds 64 KiB.")
        }
        let configuration = try JSON.decode(SemanticConfiguration.self, data)
        try configuration.validate()
        return configuration
    }

    /// Reusing an operation ID with the already-effective configuration is an idempotent retry.
    func configure(_ candidate: SemanticConfiguration, expectedConfigurationID: String?) throws
        -> SemanticConfiguration
    {
        let candidate = try candidate.normalized()
        return try PrivateConfiguration.withLock(url) {
            let current = try load()
            if let current, current.operationID == candidate.operationID {
                guard current == candidate else {
                    throw TractandaError(
                        "operationMismatch", "operationID already configured a different profile.")
                }
                return current
            }
            guard current?.configurationID == expectedConfigurationID else {
                throw TractandaError(
                    "configurationConflict", "Semantic configuration changed; read status and retry.")
            }
            try PrivateConfiguration.write(try JSON.encode(candidate), to: url)
            return candidate
        }
    }

    struct MaintenanceReceipt: Codable, Equatable {
        let configurationID: String
        let operationID: String
        let action: String
    }

    private struct MaintenanceLedger: Codable {
        var receipts: [MaintenanceReceipt]
    }

    /// Returns false for an exact replay. A mismatched reuse is rejected rather than resetting a
    /// newly configured profile after an uncertain client outcome.
    /// Runs the derived-state action under the durable receipt lock. A receipt
    /// is published only after the action succeeds, so an interrupted reset is
    /// retryable with the same operation ID. Retaining a bounded ledger avoids
    /// forgetting an older replay after unrelated operations.
    func performMaintenance(
        configurationID: String, operationID: String, action: String, operation: () throws -> Void
    ) throws -> Bool {
        try PrivateConfiguration.withLock(maintenanceURL) {
            var ledger = MaintenanceLedger(receipts: [])
            if FileManager.default.fileExists(atPath: maintenanceURL.path) {
                try PrivateConfiguration.validate(maintenanceURL, directory: false)
                let data = try Data(contentsOf: maintenanceURL)
                if let decoded = try? JSON.decode(MaintenanceLedger.self, data) {
                    ledger = decoded
                } else {
                    // The short-lived pilot format contained one receipt.
                    ledger = MaintenanceLedger(receipts: [try JSON.decode(MaintenanceReceipt.self, data)])
                }
                if let receipt = ledger.receipts.first(where: { $0.operationID == operationID }) {
                    guard receipt.configurationID == configurationID, receipt.action == action else {
                        throw TractandaError(
                            "operationMismatch",
                            "operationID already performed different semantic maintenance.")
                    }
                    return false
                }
            }
            guard ledger.receipts.count < 256 else {
                throw TractandaError(
                    "semanticMaintenanceLimit", "Semantic maintenance receipt history is full.")
            }
            try operation()
            ledger.receipts.append(
                MaintenanceReceipt(
                    configurationID: configurationID, operationID: operationID, action: action))
            try PrivateConfiguration.write(
                try JSON.encode(ledger),
                to: maintenanceURL)
            return true
        }
    }
}
