import Foundation

/// Host-private input/snapshot. Deliberately neither Codable nor a service response.
/// Supplied bytes, their temporary serialization and TLS construction copies remain caller-owned.
package final class PeerCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    package static let supportedProfile = "org.tractanda.peer-proof/1"
    package let binding: PeerExchangeBinding
    private let secret: [UInt8]
    package init(
        binding: PeerExchangeBinding, profile: String = PeerCredential.supportedProfile, secret: [UInt8]
    ) throws {
        guard profile == Self.supportedProfile, secret.count == 32 else { throw Self.failure() }
        self.binding = binding
        self.secret = secret
        guard try encoded().count <= PeerCredentialStore.maximumBytes else { throw Self.failure() }
    }
    package var description: String { "PeerCredential(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

    /// Only the package's trusted TLS adapter consumes these already supplied private bytes.
    /// No random-secret extraction or ordinary serializable representation is exposed.
    package func withTLSInput<T>(_ body: (PeerExchangeBinding, [UInt8]) throws -> T) rethrows -> T {
        try body(binding, secret)
    }
    fileprivate static func failure() -> TractandaError {
        TractandaError("invalidPeerCredential", "Private peer credential is unavailable or invalid.")
    }
    // Only non-secret metadata is Codable. The secret is a fixed binary suffix, never JSON.
    private struct Metadata: Codable {
        let format: String
        let profile: String
        let peerID: String
        let storeID: String
        let localReplicaID: String
        let remoteReplicaID: String
        let pairingID: String
        let localIsInitiator: Bool
        let configurationDigest: String
    }
    private static func metadata(for binding: PeerExchangeBinding) -> Metadata {
        .init(
            format: "tractanda.private-peer-credential.v1", profile: Self.supportedProfile,
            peerID: binding.peerID, storeID: binding.storeID, localReplicaID: binding.localReplicaID,
            remoteReplicaID: binding.remoteReplicaID, pairingID: binding.pairingID,
            localIsInitiator: binding.localIsInitiator, configurationDigest: binding.configurationDigest)
    }
    static func commitment(for binding: PeerExchangeBinding) throws -> String {
        AuthorityRecordCodec.sha256(try JSON.encode(metadata(for: binding)))
    }
    var commitment: String { get throws { try Self.commitment(for: binding) } }
    /// Private operation witness only. Never included in public metadata or peer framing.
    var privateBytesDigest: String { get throws { AuthorityRecordCodec.sha256(try encoded()) } }
    // Core-only explicit local pair/accepted target handoff, never ordinary JSON.
    func privateEncodedBytes() throws -> Data { try encoded() }
    fileprivate func encoded() throws -> Data {
        let header = try JSON.encode(Self.metadata(for: binding))
        guard header.count <= PeerCredentialStore.maximumBytes - 36 else { throw Self.failure() }
        let count = UInt32(header.count)
        return Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
            + header + Data(secret)
    }
    static func decode(_ bytes: Data) throws -> PeerCredential {
        do {
            guard bytes.count >= 36, bytes.count <= PeerCredentialStore.maximumBytes else { throw failure() }
            let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(count) == bytes.count - 36 else { throw failure() }
            let header = Data(bytes.dropFirst(4).prefix(Int(count)))
            let metadata = try JSON.decode(Metadata.self, header)
            // Canonical re-encoding rejects extra/duplicate keys and ambiguous JSON spellings.
            guard try JSON.encode(metadata) == header,
                metadata.format == "tractanda.private-peer-credential.v1"
            else { throw failure() }
            return try .init(
                binding: PeerExchangeBinding(
                    peerID: metadata.peerID, storeID: metadata.storeID,
                    localReplicaID: metadata.localReplicaID, remoteReplicaID: metadata.remoteReplicaID,
                    pairingID: metadata.pairingID, localIsInitiator: metadata.localIsInitiator,
                    configurationDigest: metadata.configurationDigest),
                profile: metadata.profile, secret: Array(bytes.suffix(32)))
        } catch { throw failure() }
    }
}

/// Immutable private generations. Configuration/lifecycle commits, never file presence, activate keys.
struct PeerCredentialStore {
    static let maximumBytes = 4096
    let files: DocumentContentFiles
    var prefix: [String] = []
    static func path(peerID: String, configurationDigest: String) throws -> [String] {
        // Hash framed metadata; peer aliases are never paths, even when they contain slashes.
        let key = AuthorityRecordCodec.sha256(try JSON.encode([peerID, configurationDigest]))
        return [".peer-credentials", key + ".key"]
    }
    func stage(_ credential: PeerCredential) throws {
        do {
            let binding = credential.binding
            let path = try prefix + Self.path(peerID: binding.peerID, configurationDigest: binding.configurationDigest)
            let bytes = try credential.encoded()
            if let old = try files.readIfPresent(path: path, maximumBytes: Self.maximumBytes) {
                _ = try PeerCredential.decode(old)
                guard old == bytes else { throw PeerCredential.failure() }
                // A prior interrupted publication can have linked the file before directory fsync.
                try files.synchronizeDirectory(prefix + [".peer-credentials"])
            } else {
                try files.writeImmutable(bytes, path: path, maximumBytes: Self.maximumBytes)
            }
        } catch { throw PeerCredential.failure() }
    }
    func load(peerID: String, configurationDigest: String, readBudget: ((Int) throws -> Void)? = nil) throws -> PeerCredential {
        do {
            let credential = try PeerCredential.decode(
                files.read(path: prefix + Self.path(peerID: peerID, configurationDigest: configurationDigest),
                           maximumBytes: Self.maximumBytes, readBudget: readBudget))
            guard credential.binding.peerID == peerID,
                credential.binding.configurationDigest == configurationDigest
            else { throw PeerCredential.failure() }
            return credential
        } catch let error as TractandaError where error.code == "resourceLimit" { throw error }
        catch { throw PeerCredential.failure() }
    }
}
