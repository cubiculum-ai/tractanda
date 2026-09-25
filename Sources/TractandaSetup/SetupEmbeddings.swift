import Crypto
import Foundation

/// The bounded operational configuration that a managed installer may recognize and restore.
/// It is deliberately separate from canonical items and is only used for the one Qwen-to-Granite
/// migration guarded by the receipt configuration ID and the native service's compare-and-swap.
struct BundledSemanticConfiguration: Codable, Equatable {
    var formatVersion: Int
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
    var pooling: String
    var normalization: String
    var inputEncoding: String

    func object() throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        guard let object = value as? [String: Any] else {
            throw SetupError("Invalid semantic configuration.")
        }
        return object
    }
}

extension SetupEngine {
    func embeddingDefinitionURL(_ name: String) -> URL {
        roots.launchDefinitions.appendingPathComponent("ai.tractanda.embeddings." + name + ".plist")
    }
    func embeddingLabel(_ name: String) -> String { "system/ai.tractanda.embeddings." + name }
    func unloadEmbedding(_ receipt: InstallationReceipt) throws {
        guard receipt.embedding != nil else { return }
        if try runner.run("/bin/launchctl", ["print", embeddingLabel(receipt.instance)], environment: [:])
            .status == 0
        {
            try successful("/bin/launchctl", ["bootout", embeddingLabel(receipt.instance)])
        }
    }
    func loadEmbedding(_ receipt: InstallationReceipt) throws {
        guard receipt.embedding != nil else { return }
        if try runner.run("/bin/launchctl", ["print", embeddingLabel(receipt.instance)], environment: [:])
            .status != 0
        {
            try successful(
                "/bin/launchctl", ["bootstrap", "system", embeddingDefinitionURL(receipt.instance).path])
        }
    }
    func replaceEmbeddingRegistration(_ receipt: inout InstallationReceipt) throws {
        guard let payload = receipt.embedding else { return }
        guard receipt.port < 65535 else {
            throw SetupError("A bundled embedding service needs a port after the HTTP port.")
        }
        let release = URL(fileURLWithPath: receipt.release)
        let arguments = [
            release.appendingPathComponent("bin/tractanda-embeddings").path,
            "--model", release.appendingPathComponent(payload.modelDirectory).path,
            "--port", String(receipt.port + 1),
        ]
        let dictionary: [String: Any] = [
            "Label": "ai.tractanda.embeddings." + receipt.instance, "ProgramArguments": arguments,
            "UserName": roots.platform.serviceUser, "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5, "Umask": 0o077,
            "StandardOutPath": roots.configuration.appendingPathComponent(
                "logs/" + receipt.instance + "-embeddings.log"
            ).path,
            "StandardErrorPath": roots.configuration.appendingPathComponent(
                "logs/" + receipt.instance + "-embeddings.log"
            ).path,
        ]
        let bytes = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try unloadEmbedding(receipt)
        try writeProtected(bytes, to: embeddingDefinitionURL(receipt.instance), mode: 0o644)
        receipt.embeddingDefinitionSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }
            .joined()
        try writeReceipt(receipt)
        try loadEmbedding(receipt)
        try waitForEmbedding(receipt)
    }
    func waitForEmbedding(_ receipt: InstallationReceipt) throws {
        guard let payload = receipt.embedding else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var observation = "No health response yet."
        repeat {
            let result = try runner.run(
                "/usr/bin/curl",
                [
                    "--noproxy", "*", "--fail", "--silent", "--max-time", "2",
                    "http://127.0.0.1:\(receipt.port + 1)/health",
                ], environment: [:])
            if result.status == 0, let bytes = result.output.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            {
                let ready = object["ready"] as? Bool == true
                let matchesModel = object["model"] as? String == payload.model
                let listener = try embeddingListenerState(receipt)
                if ready && matchesModel && listener.ownsPort { return }
                observation = "Health ready=\(ready), matching model=\(matchesModel); \(listener.detail)"
            } else {
                observation =
                    "Health request exit=\(result.status), response bytes=\(result.output.utf8.count)."
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw SetupError("The bundled embedding service did not become ready. " + observation)
    }

    func embeddingListenerState(_ receipt: InstallationReceipt) throws -> (ownsPort: Bool, detail: String) {
        let job = try runner.run(
            "/bin/launchctl", ["print", embeddingLabel(receipt.instance)], environment: [:])
        guard job.status == 0,
            let line = job.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("pid = ") }),
            let pid = Int(line.dropFirst(6)), pid > 1
        else { return (false, "launchd exit=\(job.status), no running PID reported.") }
        let listener = try runner.run(
            "/usr/sbin/lsof",
            [
                "-nP", "-a", "-p", String(pid),
                "-iTCP:" + String(receipt.port + 1), "-sTCP:LISTEN", "-Fpn",
            ], environment: [:])
        let fields = Set(listener.output.split(separator: "\n").map(String.init))
        let hasPID = fields.contains("p" + String(pid))
        let hasPort = fields.contains("n127.0.0.1:" + String(receipt.port + 1))
        return (
            listener.status == 0 && hasPID && hasPort,
            "PID=\(pid), listener query exit=\(listener.status), matching PID=\(hasPID), matching port=\(hasPort)."
        )
    }

    func semanticConfigurationSnapshot(_ receipt: InstallationReceipt) throws -> BundledSemanticConfiguration?
    {
        let url = URL(fileURLWithPath: receipt.store).appendingPathComponent("semantic.json")
        guard exists(url) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else { throw SetupError("Semantic configuration exceeds 64 KiB.") }
        return try JSONDecoder().decode(BundledSemanticConfiguration.self, from: data)
    }

    func legacyConfiguration(for receipt: InstallationReceipt) -> BundledSemanticConfiguration {
        BundledSemanticConfiguration(
            formatVersion: 2, configurationID: receipt.embeddingConfigurationID,
            operationID: "setup-embedding-v1-" + receipt.instance,
            endpoint: "http://127.0.0.1:\(receipt.port + 1)/v1/embeddings",
            model: EmbeddingPayload.legacyQwen.model,
            modelRevision: EmbeddingPayload.legacyQwen.modelRevision,
            dimensions: EmbeddingPayload.legacyQwen.dimensions, documentPrefix: "",
            queryPrefix:
                "Instruct: Given a Tractanda retrieval query, retrieve relevant item passages\nQuery:",
            chunkBytes: 384, overlapBytes: 64, pooling: "last", normalization: "l2",
            inputEncoding: "item-text-utf8-v2")
    }

    func isInstallerOwnedLegacyConfiguration(
        _ current: BundledSemanticConfiguration, receipt: InstallationReceipt
    ) -> Bool {
        let expected = legacyConfiguration(for: receipt)
        return current.formatVersion == expected.formatVersion
            && current.configurationID == expected.configurationID
            && current.endpoint == expected.endpoint
            && current.model == expected.model
            && current.modelRevision == expected.modelRevision
            && current.dimensions == expected.dimensions
            && current.documentPrefix == expected.documentPrefix
            && current.queryPrefix == expected.queryPrefix
            && current.chunkBytes == expected.chunkBytes
            && current.overlapBytes == expected.overlapBytes
            && current.pooling == expected.pooling
            && current.normalization == expected.normalization
            && current.inputEncoding == expected.inputEncoding
    }

    func graniteConfiguration(for receipt: InstallationReceipt, payload: EmbeddingPayload)
        -> BundledSemanticConfiguration
    {
        BundledSemanticConfiguration(
            formatVersion: 2, configurationID: receipt.embeddingConfigurationID,
            operationID: "setup-embedding-v2-" + receipt.instance,
            endpoint: "http://127.0.0.1:\(receipt.port + 1)/v1/embeddings",
            model: payload.model, modelRevision: payload.modelRevision, dimensions: payload.dimensions,
            documentPrefix: "", queryPrefix: "", chunkBytes: 384, overlapBytes: 64,
            pooling: "cls", normalization: "l2", inputEncoding: "item-text-utf8-v2")
    }

    func prepareBundledEmbeddingUpgrade(_ receipt: inout InstallationReceipt) throws {
        guard receipt.embedding == .legacyQwen, receipt.embeddingPreviousConfiguration == nil,
            let current = try semanticConfigurationSnapshot(receipt),
            isInstallerOwnedLegacyConfiguration(current, receipt: receipt)
        else {
            throw SetupError("A different semantic configuration exists; the installer did not replace it.")
        }
        receipt.embeddingPreviousConfiguration = current
        receipt.embeddingConfigurationID = try UUID.makeVersion1().uuidString.lowercased()
        receipt.embeddingConfigured = false
    }

    func restoreSemanticConfiguration(
        _ configuration: BundledSemanticConfiguration, after receipt: InstallationReceipt
    ) throws {
        _ = try semanticCall(
            receipt.socket, roots.platform.serviceUser, "TractandaSemantic/configure",
            [
                "configuration": try configuration.object(),
                "expectedConfigurationID": receipt.embeddingConfigurationID,
            ])
    }

    func configureEmbedding(_ receipt: inout InstallationReceipt) throws {
        guard let payload = receipt.embedding, !receipt.embeddingConfigured else { return }
        let candidate = graniteConfiguration(for: receipt, payload: payload)
        let expected = receipt.embeddingPreviousConfiguration?.configurationID
        let current = try semanticCall(
            receipt.socket, roots.platform.serviceUser, "TractandaSemantic/status", [:])
        if current["enabled"] as? Bool == true,
            current["configurationID"] as? String != receipt.embeddingConfigurationID,
            current["configurationID"] as? String != expected
        {
            throw SetupError("A different semantic configuration exists; the installer did not replace it.")
        }
        var arguments: [String: Any] = ["configuration": try candidate.object()]
        if let expected { arguments["expectedConfigurationID"] = expected }
        _ = try semanticCall(
            receipt.socket, roots.platform.serviceUser, "TractandaSemantic/configure", arguments)
        receipt.embeddingConfigured = true
        try writeReceipt(receipt)
    }
}
