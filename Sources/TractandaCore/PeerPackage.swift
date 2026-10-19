import Foundation

/// Internal package framing. Authentication is supplied by the configured session boundary.
enum PeerPackage {
    static let profile = "tractanda.peer-package.v3"
    static let retainedOriginalProfile = "tractanda.peer-package.v2"
    static let retainedMetadataProfile = "tractanda.peer-package.v1"
    static let maximumPayloadChunkBytes = 256 * 1024
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let maximumPageBytes = 128 * 1024
    static let maximumChunkBytes = 1024 * 1024
    enum Kind: String, Codable, Sendable { case item, authority, index, attachment, document }
    /// Internal transport address; neither an invented canonical UUID nor a sender pathname.
    struct DocumentPart: Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case manifest, node, page }
        let role: Role
        let level: Int
        let ordinal: Int64
        static let manifest = Self(role: .manifest, level: 0, ordinal: 0)
        var key: String { role.rawValue + ":" + String(level) + ":" + String(ordinal) }
        var relativePath: [String] {
            switch role {
            case .manifest: ["manifest.json"]
            case .node: ["nodes", String(level), String(ordinal / 128), String(ordinal) + ".json"]
            case .page: ["pages", String((ordinal - 1) / 128), String(ordinal) + ".json"]
            }
        }
        func validate() throws {
            guard (0...8).contains(level), ordinal >= 0,
                role != .manifest || (level == 0 && ordinal == 0),
                role != .page || (level == 0 && ordinal > 0)
            else { throw TractandaError("invalidPeerPackage", "Invalid composite document part address.") }
        }
        static func from(relativePath path: [String]) throws -> Self {
            if path == ["manifest.json"] { return .manifest }
            let part: Self
            if path.count == 3, path[0] == "pages", path[2].hasSuffix(".json"),
                let ordinal = Int64(path[2].dropLast(5))
            {
                part = .init(role: .page, level: 0, ordinal: ordinal)
            } else if path.count == 4, path[0] == "nodes", path[3].hasSuffix(".json"),
                let level = Int(path[1]), let ordinal = Int64(path[3].dropLast(5))
            {
                part = .init(role: .node, level: level, ordinal: ordinal)
            } else {
                throw TractandaError("invalidPeerPackage", "Unknown document relative address.")
            }
            try part.validate()
            guard part.relativePath == path else {
                throw TractandaError("invalidPeerPackage", "Noncanonical document relative address.")
            }
            return part
        }
    }
    struct Object: Codable, Equatable, Sendable {
        let kind: Kind
        let id: String
        let length: Int
        let sha256: String
        var part: DocumentPart? = nil
        var key: String { part.map { id + ":" + $0.key } ?? id }
        var chunkBytes: Int {
            kind == .attachment || kind == .document
                ? PeerPackage.maximumPayloadChunkBytes : PeerPackage.maximumChunkBytes
        }
        func validate(retainedProfile: String = PeerPackage.profile) throws {
            _ = try AuthorityRecord.persistentID(.text(id))
            _ = try AuthorityRecord.digest(.text(sha256))
            if kind == .document, retainedProfile == PeerPackage.profile, let part {
                try part.validate()
                let maximum =
                    part.role == .page
                    ? DocumentContentStore.maximumPageBytes : DocumentContentStore.maximumNodeBytes
                guard length > 0, length <= maximum else {
                    throw TractandaError("resourceLimit", "Document part exceeds its bounded representation.")
                }
                return
            }
            guard part == nil else {
                throw TractandaError("invalidPeerPackage", "Only v3 document parts have composite addresses.")
            }
            if kind == .attachment,
                [PeerPackage.profile, PeerPackage.retainedOriginalProfile].contains(retainedProfile)
            {
                guard length >= 0, Int64(exactly: length) != nil,
                    length != 0 || sha256 == PeerPackage.emptySHA256
                else {
                    throw TractandaError("invalidPeerPackage", "Invalid original payload size/digest.")
                }
                return
            }
            let maximum = kind == .item ? 8 * 1024 * 1024 : maximumPageBytes
            guard [.item, .authority, .index].contains(kind), length > 0, length <= maximum else {
                throw TractandaError("resourceLimit", "Package object exceeds its metadata framing window.")
            }
        }
    }
    struct Page: Codable, Equatable, Sendable {
        let objects: [Object]
        let children: [Object]
        func validate(retainedProfile: String = PeerPackage.profile) throws {
            guard objects.count + children.count > 0, objects.count + children.count <= 256,
                objects.isEmpty || children.isEmpty,
                Set((objects + children).map(\.id)).count == objects.count + children.count,
                objects.allSatisfy({ $0.kind != .index }), children.allSatisfy({ $0.kind == .index })
            else { throw TractandaError("invalidPeerPackage", "Invalid package index page.") }
            for object in objects + children { try object.validate(retainedProfile: retainedProfile) }
            guard objects.allSatisfy({ $0.kind != .document || $0.part == .manifest }) else {
                throw TractandaError("invalidPeerPackage", "Package indexes anchor document manifests only.")
            }
        }
    }
    struct Manifest: Codable, Equatable, Sendable {
        let profile: String
        let packageID: String
        let storeID: String
        let root: Object
        init(packageID: String, storeID: String, root: Object, profile: String = PeerPackage.profile) {
            self.profile = profile
            self.packageID = packageID
            self.storeID = storeID
            self.root = root
        }
        func validate(retained: Bool = false) throws {
            _ = try AuthorityRecord.persistentID(.text(packageID))
            _ = try AuthorityRecord.persistentID(.text(storeID))
            try root.validate(retainedProfile: profile)
            guard
                profile == PeerPackage.profile
                    || (retained
                        && [PeerPackage.retainedMetadataProfile, PeerPackage.retainedOriginalProfile]
                            .contains(profile)),
                root.kind == .index
            else {
                throw TractandaError("invalidPeerPackage", "Unknown package profile/root.")
            }
        }
    }
    struct Limits: Sendable {
        var maximumStagedBytes: UInt64 = 256 * 1024 * 1024
        var maximumObjects = 1_000_000
        var maximumWork = 10_000_000
        var maximumReadBytes: UInt64 = 512 * 1024 * 1024
        var maximumRecoveryReadBytes: UInt64 = 256 * 1024 * 1024 * 1024
        var maximumDepth = 64
        var reserveBytes: Int64 = 10 * 1024 * 1024 * 1024
    }
    struct ControlReference: Codable, Equatable, Sendable {
        let recordID: String
        let sha256: String
    }
    struct Context: Codable, Equatable, Sendable {
        let peerID: String
        let storeID: String
        let configurationDigest: String
        let permittedOrigins: [String]
        /// Only the trusted configuration/session adapter calls this initializer. No wire API
        /// accepts a Context. The Store compares it against fresh private configuration each time.
        init(peerID: String, storeID: String, configurationDigest: String, permittedOrigins: [String]) throws
        {
            _ = try AuthorityRecord.text(.text(peerID))
            _ = try AuthorityRecord.persistentID(.text(storeID))
            _ = try AuthorityRecord.digest(.text(configurationDigest))
            guard !permittedOrigins.isEmpty, permittedOrigins == Array(Set(permittedOrigins)).sorted(),
                permittedOrigins.count <= 256
            else {
                throw TractandaError("invalidPeerConfiguration", "Explicit permitted origins are required.")
            }
            for id in permittedOrigins { _ = try AuthorityRecord.persistentID(.text(id)) }
            self.peerID = peerID
            self.storeID = storeID
            self.configurationDigest = configurationDigest
            self.permittedOrigins = permittedOrigins
        }
    }
    struct Status: Equatable, Sendable {
        let packageID: String
        let sealed: Bool
        let receivedBytes: UInt64
    }
    /// Exact canonical JSON framing rejects duplicate, unknown and ambiguous fields.
    static func decode<T: Codable>(_ type: T.Type, _ data: Data, maximum: Int = maximumPageBytes) throws -> T
    {
        guard data.count <= maximum else {
            throw TractandaError("resourceLimit", "Package metadata is too large.")
        }
        let value = try JSON.decode(type, data)
        guard try JSON.encode(value) == data else {
            throw TractandaError("invalidPeerPackage", "Noncanonical package metadata.")
        }
        return value
    }
}
