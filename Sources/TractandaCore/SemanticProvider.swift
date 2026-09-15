import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Narrow OpenAI-compatible local embedding client. Configuration has already restricted the
/// endpoint to numeric loopback; requests never accept an endpoint supplied by a search caller.
protocol SemanticEmbedding: Sendable {
    func embed(_ inputs: [String], query: Bool) async throws -> [[Double]]
}

actor SemanticEmbeddingProvider: SemanticEmbedding {
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }

    private let configuration: SemanticConfiguration
    private let session: URLSession

    init(configuration: SemanticConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 20
        settings.httpShouldSetCookies = false
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Numeric loopback alone does not suppress an OS PAC/proxy setting.
        // An empty proxy dictionary keeps this local-only provider direct.
        settings.connectionProxyDictionary = [:]
        session = URLSession(configuration: settings, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func embed(_ inputs: [String], query: Bool) async throws -> [[Double]] {
        guard !inputs.isEmpty, inputs.count <= 16,
            inputs.allSatisfy({ $0.utf8.count <= 32_768 })
        else { throw TractandaError("semanticProvider", "Embedding batch exceeds local pilot limits.") }
        guard let endpoint = URL(string: configuration.endpoint) else {
            throw TractandaError("semanticEndpoint", "Configured local endpoint is invalid.")
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "input": inputs.map { (query ? configuration.queryPrefix : configuration.documentPrefix) + $0 },
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TractandaError("semanticProvider", "Local embedding provider returned an invalid response.")
        }
        guard data.count <= 4 * 1024 * 1024 else {
            throw TractandaError("semanticProvider", "Local embedding response exceeds the pilot limit.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["model"] as? String == configuration.model,
            let entries = object["data"] as? [[String: Any]], entries.count == inputs.count
        else { throw TractandaError("semanticProvider", "Local embedding response has an unexpected shape.") }
        let vectors = try entries.enumerated().map { index, entry -> [Double] in
            guard let entryIndex = entry["index"] as? NSNumber,
                String(cString: entryIndex.objCType) != "c",
                entryIndex.doubleValue == Double(index),
                let numbers = entry["embedding"] as? [NSNumber]
            else { throw TractandaError("semanticProvider", "Local embedding response order is invalid.") }
            guard numbers.allSatisfy({ String(cString: $0.objCType) != "c" && $0.doubleValue.isFinite })
            else {
                throw TractandaError("semanticProvider", "Local embedding response contains invalid values.")
            }
            let vector = numbers.map(\.doubleValue)
            try SemanticVectorValidation.validate(vector, dimensions: configuration.dimensions)
            return vector
        }
        return vectors
    }
}
