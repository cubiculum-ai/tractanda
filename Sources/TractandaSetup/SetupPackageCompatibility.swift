import Foundation
import TractandaCore

/// Public, data-only control metadata generated with a Linux package. It is not cluster authority
/// and cannot declare that coordinated maintenance has happened.
struct SetupPackageCompatibility: Codable, Equatable {
    static let profileName = "tractanda.linux-package.v1"
    static let maximumBytes = 65_536
    enum Upgrade: String, Codable {
        case compatible
        case coordinatedMaintenance = "coordinated-maintenance"
    }
    let profile: String
    let manifestSHA256: String
    let version: String
    let arch: String
    let canonicalFormats: CanonicalFormatSupport
    let semanticProfile: String
    let upgrade: Upgrade
    let embedding: EmbeddingPayload?
    let documentExtraction: DocumentExtractionPayload?

    init(
        manifestSHA256: String, version: String, arch: String, canonicalFormats: CanonicalFormatSupport,
        semanticProfile: String = PeerCompatibilityDeclaration.semanticProfile,
        upgrade: Upgrade = .compatible,
        embedding: EmbeddingPayload? = nil, documentExtraction: DocumentExtractionPayload? = nil
    ) {
        profile = Self.profileName
        self.manifestSHA256 = manifestSHA256
        self.version = version
        self.arch = arch
        self.canonicalFormats = canonicalFormats
        self.semanticProfile = semanticProfile
        self.upgrade = upgrade
        self.embedding = embedding
        self.documentExtraction = documentExtraction
    }

    func validate() throws {
        guard profile == Self.profileName, Self.isDigest(manifestSHA256),
            !version.isEmpty, version.utf8.count <= 80,
            version.utf8.allSatisfy({ Self.asciiIdentifier($0) || $0 == 43 || $0 == 95 }),
            ["arm64", "x86_64"].contains(arch),
            !semanticProfile.isEmpty, semanticProfile.utf8.count <= 128,
            semanticProfile.utf8.allSatisfy(Self.asciiIdentifier)
        else {
            throw SetupError("Unknown or invalid Linux package compatibility declaration.")
        }
        try canonicalFormats.validate()
    }

    func requireRollingUpgrade(from old: Self) throws {
        try validate()
        try old.validate()
        guard upgrade == .compatible, semanticProfile == old.semanticProfile,
            semanticProfile == PeerCompatibilityDeclaration.semanticProfile, arch == old.arch,
            embedding == old.embedding, documentExtraction == old.documentExtraction
        else {
            throw SetupError(
                "Package activation requires coordinated maintenance; ordinary package hooks cannot establish cluster coordination."
            )
        }
        try old.canonicalFormats.requireWriter(canonicalFormats)
        try canonicalFormats.requireWriter(old.canonicalFormats)
    }

    func requirePayload(_ manifest: BundleManifest, digest: String) throws {
        try validate()
        guard manifest.platform == "linux", digest == manifestSHA256,
            manifest.version == version, manifest.arch == arch,
            manifest.canonicalFormats == canonicalFormats, manifest.embedding == embedding,
            manifest.documentExtraction == documentExtraction,
            semanticProfile == PeerCompatibilityDeclaration.semanticProfile
        else {
            throw SetupError(
                "Actual Linux package payload differs from its pre-unpack compatibility commitment.")
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else {
            throw SetupError("Package declaration exceeds its bound.")
        }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set([
                "profile", "manifestSHA256", "version", "arch", "canonicalFormats", "semanticProfile",
                "upgrade",
            ]).isSubset(of: Set(object.keys)),
            Set(object.keys).isSubset(
                of: Set([
                    "profile", "manifestSHA256", "version", "arch", "canonicalFormats", "semanticProfile",
                    "upgrade", "embedding", "documentExtraction",
                ])),
            let support = object["canonicalFormats"] as? [String: Any],
            Set(support.keys) == [
                "profile", "readerLevel", "writerLevel", "read", "write", "capabilities", "writeCapabilities",
            ]
        else {
            throw SetupError("Unknown or oversized Linux package declaration fields.")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        // Generated control metadata has one canonical spelling. The control heredoc adds
        // exactly one LF; re-encoding otherwise rejects duplicate/ambiguous JSON keys.
        let canonicalInput = bytes.last == 10 ? Data(bytes.dropLast()) : bytes
        guard try value.encoded() == canonicalInput else {
            throw SetupError("Linux package declaration is not canonical JSON.")
        }
        return value
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func asciiIdentifier(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
            || value == 45 || value == 46
    }
}

extension SetupEngine {
    var packagePayload: URL { roots.software.appendingPathComponent("current") }

    func installedPackageCompatibility() throws -> SetupPackageCompatibility {
        guard roots.platform == .linux else { throw SetupError("Linux package custody is required.") }
        try requirePackageRelease(packagePayload.path)
        if trustedOwnership { try requireTrustedAncestry(of: packagePayload) }
        let manifest = try verifyBundle(at: packagePayload)
        if trustedOwnership, manifest.embedding == nil || manifest.documentExtraction == nil {
            throw SetupError(
                "A proper Linux package must include the complete bundled embedding and document components; core-only delivery is not admitted."
            )
        }
        guard let formats = manifest.canonicalFormats else {
            throw SetupError("Linux package payload has no explicit canonical compatibility declaration.")
        }
        return SetupPackageCompatibility(
            manifestSHA256: try sha256(packagePayload.appendingPathComponent("bundle-manifest.json")),
            version: manifest.version, arch: manifest.arch, canonicalFormats: formats,
            embedding: manifest.embedding, documentExtraction: manifest.documentExtraction)
    }
}
