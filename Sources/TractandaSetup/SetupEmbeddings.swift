import Crypto
import Foundation

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

    func configureEmbedding(_ receipt: inout InstallationReceipt) throws {
        guard let payload = receipt.embedding, !receipt.embeddingConfigured else { return }
        let client = SetupNativeClient(socket: receipt.socket, serverUser: roots.platform.serviceUser)
        let current = try client.call("TractandaSemantic/status")
        if current["enabled"] as? Bool == true {
            guard current["configurationID"] as? String == receipt.embeddingConfigurationID else {
                throw SetupError(
                    "A different semantic configuration exists; the installer did not replace it.")
            }
        } else {
            _ = try client.call(
                "TractandaSemantic/configure",
                [
                    "configuration": [
                        "formatVersion": 2, "configurationID": receipt.embeddingConfigurationID,
                        "operationID": "setup-embedding-v1-" + receipt.instance,
                        "endpoint": "http://127.0.0.1:\(receipt.port + 1)/v1/embeddings",
                        "model": payload.model, "modelRevision": payload.modelRevision,
                        "dimensions": payload.dimensions,
                        "documentPrefix": "",
                        "queryPrefix":
                            "Instruct: Given a Tractanda retrieval query, retrieve relevant item passages\nQuery:",
                        "chunkBytes": 384, "overlapBytes": 64, "pooling": "last", "normalization": "l2",
                        "inputEncoding": "item-text-utf8-v2",
                    ]
                ])
        }
        receipt.embeddingConfigured = true
        try writeReceipt(receipt)
    }
}
