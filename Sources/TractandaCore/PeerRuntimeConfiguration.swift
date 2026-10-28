import Crypto
import Foundation
import TractandaClient

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private struct PeerRuntimeDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFields(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: PeerRuntimeDynamicCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw PeerRuntimeConfiguration.invalid("Peer runtime configuration contains an unknown field.")
    }
}

/// Local endpoint and bounded synchronization settings; all networking remains explicitly opt-in.
/// This value contains no credentials and grants no trust or enrollment authority.
public struct PeerRuntimeConfiguration: Codable, Equatable, Sendable {
    public static let maximumFileBytes = 64 * 1024
    public static let maximumPeers = 256
    public static let minimumSyncIntervalSeconds = 15
    public static let maximumSyncIntervalSeconds = 86_400

    public struct Endpoint: Codable, Equatable, Sendable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) throws {
            let normalized = host.lowercased()
            try Self.validateHost(normalized, allowWildcard: true)
            guard (1...65_535).contains(port) else {
                throw PeerRuntimeConfiguration.invalid("Peer endpoint port must be between 1 and 65535.")
            }
            self.host = normalized
            self.port = port
        }

        public init(from decoder: Decoder) throws {
            try rejectUnknownFields(decoder, allowed: ["host", "port"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                host: values.decode(String.self, forKey: .host), port: values.decode(Int.self, forKey: .port))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(host, forKey: .host)
            try values.encode(port, forKey: .port)
        }

        /// libc accepts legacy hexadecimal/octal/shorthand IPv4 spellings as numeric.
        /// This is a parser only: validation must not depend on DNS availability.
        package static func isNumericAddress(_ host: String) -> Bool {
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            return host.withCString { inet_aton($0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
        }

        fileprivate static func validateHost(_ host: String, allowWildcard: Bool) throws {
            guard !host.isEmpty, host.utf8.count <= 253,
                host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }),
                !host.contains("/"), !host.contains("\\"), !host.contains("@"), !host.contains("?")
            else { throw PeerRuntimeConfiguration.invalid("Peer endpoint host is malformed.") }
            if ["*", "0.0.0.0", "::"].contains(host) {
                guard allowWildcard else {
                    throw PeerRuntimeConfiguration.invalid(
                        "Remote peer destinations cannot be wildcard addresses.")
                }
                return
            }
            if host.contains(":") {
                var address = in6_addr()
                let parsed = host.withCString { inet_pton(AF_INET6, $0, &address) }
                guard parsed == 1 else {
                    throw PeerRuntimeConfiguration.invalid("Peer IPv6 address is malformed.")
                }
                let unspecified = withUnsafeBytes(of: &address) { bytes in
                    bytes.allSatisfy { $0 == 0 }
                        || (bytes.count == 16 && bytes.prefix(10).allSatisfy { $0 == 0 }
                            && bytes[10] == 0xff && bytes[11] == 0xff
                            && bytes.suffix(4).allSatisfy { $0 == 0 })
                }
                guard allowWildcard || !unspecified else {
                    throw PeerRuntimeConfiguration.invalid(
                        "Remote peer destinations cannot be wildcard addresses.")
                }
                return
            }
            if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                var address = in_addr()
                let parsed = host.withCString { inet_pton(AF_INET, $0, &address) }
                guard parsed == 1 else {
                    throw PeerRuntimeConfiguration.invalid("Peer IPv4 address is malformed.")
                }
                return
            }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard
                labels.allSatisfy({ label in
                    !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                        && label.utf8.allSatisfy {
                            (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                        }
                })
            else { throw PeerRuntimeConfiguration.invalid("Peer DNS host is malformed.") }
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case host, port }
    }

    public struct Peer: Codable, Equatable, Sendable {
        public let alias: String
        public let endpoint: Endpoint
        /// Ordered node-local alternatives; these grant no membership or pairing authority.
        public let fallbackEndpoints: [Endpoint]
        public var endpoints: [Endpoint] { [endpoint] + fallbackEndpoints }
        public static let maximumEndpoints = 4

        public init(
            alias: String, host: String, port: Int, fallbackEndpoints: [Endpoint] = []
        ) throws {
            do {
                _ = try AuthorityRecord.text(.text(alias))
            } catch {
                throw PeerRuntimeConfiguration.invalid("Peer alias is invalid.")
            }
            guard alias != "local" else {
                throw PeerRuntimeConfiguration.invalid(
                    "The reserved local peer alias cannot be configured remotely.")
            }
            self.alias = alias
            self.endpoint = try Endpoint(host: host, port: port)
            self.fallbackEndpoints = fallbackEndpoints
            guard fallbackEndpoints.count < Self.maximumEndpoints else {
                throw PeerRuntimeConfiguration.invalid("A peer permits at most four ordered destinations.")
            }
            for candidate in endpoints {
                try Endpoint.validateHost(candidate.host, allowWildcard: false)
            }
            guard Set(endpoints.map { $0.host + "|" + String($0.port) }).count == endpoints.count else {
                throw PeerRuntimeConfiguration.invalid("Peer destinations must be unique.")
            }
        }

        public init(from decoder: Decoder) throws {
            try rejectUnknownFields(decoder, allowed: ["alias", "endpoint", "fallbackEndpoints"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let alias = try values.decode(String.self, forKey: .alias)
            let endpoint = try values.decode(Endpoint.self, forKey: .endpoint)
            let fallback =
                values.contains(.fallbackEndpoints)
                ? try values.decode([Endpoint].self, forKey: .fallbackEndpoints) : []
            try self.init(alias: alias, host: endpoint.host, port: endpoint.port, fallbackEndpoints: fallback)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(alias, forKey: .alias)
            try values.encode(endpoint, forKey: .endpoint)
            if !fallbackEndpoints.isEmpty {
                try values.encode(fallbackEndpoints, forKey: .fallbackEndpoints)
            }
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case alias, endpoint, fallbackEndpoints }
    }

    public struct Synchronization: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let intervalSeconds: Int

        public init(enabled: Bool = false, intervalSeconds: Int = 300) throws {
            guard (Self.minimumInterval...Self.maximumInterval).contains(intervalSeconds) else {
                throw PeerRuntimeConfiguration.invalid("Synchronization interval is outside its bound.")
            }
            self.enabled = enabled
            self.intervalSeconds = intervalSeconds
        }

        public init(from decoder: Decoder) throws {
            try rejectUnknownFields(decoder, allowed: ["enabled", "intervalSeconds"])
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                enabled: values.decode(Bool.self, forKey: .enabled),
                intervalSeconds: values.decode(Int.self, forKey: .intervalSeconds))
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(enabled, forKey: .enabled)
            try values.encode(intervalSeconds, forKey: .intervalSeconds)
        }

        private static let minimumInterval = PeerRuntimeConfiguration.minimumSyncIntervalSeconds
        private static let maximumInterval = PeerRuntimeConfiguration.maximumSyncIntervalSeconds
        private enum CodingKeys: String, CodingKey, CaseIterable { case enabled, intervalSeconds }
    }

    public let listen: Endpoint?
    public let peers: [Peer]
    public let synchronization: Synchronization
    /// A digest of effective local settings only. It has no canonical trust meaning.
    public let settingsDigest: String

    public init(
        listen: Endpoint? = nil, peers: [Peer] = [], synchronization: Synchronization? = nil
    ) throws {
        guard peers.count <= Self.maximumPeers else {
            throw Self.invalid("Peer runtime configuration permits at most 256 peers.")
        }
        let aliases = peers.map(\.alias)
        guard Set(aliases).count == aliases.count else {
            throw Self.invalid("Peer runtime aliases must be unique.")
        }
        let orderedPeers = peers.sorted { $0.alias < $1.alias }
        let resolvedSynchronization = try synchronization ?? Synchronization()
        self.listen = listen
        self.peers = orderedPeers
        self.synchronization = resolvedSynchronization
        self.settingsDigest = try Self.digest(
            listen: listen, peers: orderedPeers, synchronization: resolvedSynchronization)
    }

    /// Decodes the established v1 optional/default grammar within the public document bound.
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else {
            throw Self.invalid("Peer runtime configuration is empty or exceeds 64 KiB.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw Self.invalid("Peer runtime configuration is invalid: \(error.localizedDescription)")
        }
    }

    /// Encodes effective settings deterministically within the established v1 byte bound.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else {
            throw Self.invalid("Encoded peer runtime configuration exceeds 64 KiB.")
        }
        return data
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFields(decoder, allowed: ["version", "listen", "peers", "synchronization"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw Self.invalid("Peer runtime configuration version is unsupported.")
        }
        let listen = values.contains(.listen) ? try values.decode(Endpoint.self, forKey: .listen) : nil
        let peers = values.contains(.peers) ? try values.decode([Peer].self, forKey: .peers) : []
        let synchronization =
            values.contains(.synchronization)
            ? try values.decode(Synchronization.self, forKey: .synchronization) : nil
        try self.init(listen: listen, peers: peers, synchronization: synchronization)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encodeIfPresent(listen, forKey: .listen)
        try values.encode(peers, forKey: .peers)
        try values.encode(synchronization, forKey: .synchronization)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, listen, peers, synchronization }

    private static func digest(
        listen: Endpoint?, peers: [Peer], synchronization: Synchronization
    ) throws -> String {
        struct EffectiveSettings: Encodable {
            let version = 1
            let listen: Endpoint?
            let peers: [Peer]
            let synchronization: Synchronization
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(
            EffectiveSettings(
                listen: listen, peers: peers, synchronization: synchronization))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    package static func invalid(_ message: String) -> TractandaError {
        TractandaError("invalidConfiguration", message)
    }
}
