#if !os(WASI)
    import Foundation
    #if canImport(FoundationNetworking)
        import FoundationNetworking
    #endif

    /// HTTP binding for native clients. Browser builds supply a same-origin fetch transport.
    public struct HTTPItemTransport: ItemTransport {
        private let endpoint: URL
        private let bearerToken: String?
        private let session: URLSession

        public init(endpoint: URL, bearerToken: String? = nil) {
            self.endpoint = endpoint
            self.bearerToken = bearerToken
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 35
            session = URLSession(configuration: configuration)
        }

        public func send(_ data: Data) async throws -> Data {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            let (result, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw TractandaError("transportError", "Missing HTTP response.")
            }
            guard response.statusCode == 200 else {
                if response.statusCode == 401 {
                    throw TractandaError("authenticationRequired", "Sign in to access this server.")
                }
                if response.statusCode == 403 {
                    throw TractandaError("accessDenied", "This request is not authorized.")
                }
                throw TractandaError("httpError", "The server returned HTTP \(response.statusCode).")
            }
            return result
        }
    }
#endif
