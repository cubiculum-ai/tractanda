import CTractandaPlatform
import Crypto
import Foundation
import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private func asciiLetter(_ value: UInt8) -> Bool { (65...90).contains(value) || (97...122).contains(value) }
private func asciiDigit(_ value: UInt8) -> Bool { (48...57).contains(value) }
private func asciiHex(_ value: UInt8) -> Bool {
    asciiDigit(value) || (65...70).contains(value) || (97...102).contains(value)
}
private func validAccountName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128
        && name.utf8.allSatisfy { asciiLetter($0) || asciiDigit($0) || "-_.".utf8.contains($0) }
}

public struct SetupError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The only accepted release description. It is deliberately data-only: a bundle cannot ask the
/// installer to run an arbitrary recipe.
public struct BundleManifest: Codable, Equatable, Sendable {
    public static let profile = "tractanda.bundle.v1"
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let size: UInt64
        public let mode: UInt16
        public init(path: String, sha256: String, size: UInt64, mode: UInt16) {
            self.path = path
            self.sha256 = sha256
            self.size = size
            self.mode = mode
        }
    }
    public let profile: String
    public let version: String
    public let platform: String
    public let arch: String
    public let files: [File]
    public let embedding: EmbeddingPayload?
    public let documentExtraction: DocumentExtractionPayload?
    public let canonicalFormats: CanonicalFormatSupport?
    public init(
        profile: String = Self.profile, version: String, platform: String, arch: String, files: [File],
        embedding: EmbeddingPayload? = nil, documentExtraction: DocumentExtractionPayload? = nil,
        canonicalFormats: CanonicalFormatSupport? = nil
    ) {
        self.profile = profile
        self.version = version
        self.platform = platform
        self.arch = arch
        self.files = files
        self.embedding = embedding
        self.documentExtraction = documentExtraction
        self.canonicalFormats = canonicalFormats
    }

    public func validate() throws {
        guard profile == Self.profile, !version.isEmpty, version.utf8.count <= 80,
            version.utf8.allSatisfy({ asciiLetter($0) || asciiDigit($0) || ".-_+".utf8.contains($0) })
        else { throw SetupError("Bundle version is invalid.") }
        guard ["macos", "linux"].contains(platform), ["arm64", "x86_64"].contains(arch), files.count <= 20_000
        else {
            throw SetupError("Bundle platform, architecture, or file count is invalid.")
        }
        var names = Set<String>()
        for file in files {
            try Self.validateRelativePath(file.path)
            guard names.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                file.sha256.count == 64,
                file.sha256.utf8.allSatisfy(asciiHex), file.mode & ~0o777 == 0, file.mode & 0o022 == 0,
                file.size <= 8 * 1024 * 1024 * 1024
            else {
                throw SetupError("Bundle file entry is invalid: \(file.path)")
            }
        }
        let required = ["bin/tractanda", "bin/tractanda-tui", "bin/tractanda-mcp", "bin/tractanda-setup"]
        guard required.allSatisfy({ name in files.contains { $0.path == name && $0.mode & 0o111 != 0 } })
        else { throw SetupError("Bundle is missing a required executable.") }
        if platform == "linux" && !names.contains("bin/tractanda-auth-helper") {
            throw SetupError("Linux bundle is missing bin/tractanda-auth-helper.")
        }
        for directory in ["lib/", "templates/", "docs/", "licenses/"] {
            guard names.contains(where: { $0.hasPrefix(directory) }) else {
                throw SetupError("Bundle is missing required \(directory) content.")
            }
        }
        guard
            files.contains(where: {
                $0.path.hasPrefix("bin/Tractanda_TractandaWeb.bundle/")
                    || $0.path.hasPrefix("bin/Tractanda_TractandaWeb.resources/")
            })
        else {
            throw SetupError("Bundle is missing the Tractanda web resource bundle.")
        }
        try canonicalFormats?.validate()
        try embedding?.validate(files: files)
        if let documentExtraction {
            try documentExtraction.validatePlatform(platform: platform, arch: arch)
            try documentExtraction.validate(files: files)
        } else if files.contains(where: {
            $0.path == "bin/tractanda-document-converter"
                || $0.path.hasPrefix("models/granite-docling-258m-mlx/")
        }) {
            throw SetupError("Document payload requires its complete descriptor.")
        }
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            }),
            !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw SetupError("Bundle paths must be safe relative paths: \(path.debugDescription)") }
    }
}

public enum SetupPlatform: String, Codable, Sendable {
    case macos, linux
    public static var host: SetupPlatform {
        #if os(macOS)
            .macos
        #else
            .linux
        #endif
    }
    public var serviceUser: String { "daemon" }
}

/// Root locations are explicit so fixtures never touch host data. Callers may change only data
/// and index roots; software/configuration roots remain platform-owned.
public struct SetupRoots: Sendable {
    public let platform: SetupPlatform
    public let software: URL
    public let configuration: URL
    public let launchDefinitions: URL
    public let runtime: URL
    public let data: URL
    public let indexes: URL
    public let commands: URL
    public init(
        platform: SetupPlatform = .host, software: URL? = nil, configuration: URL? = nil,
        launchDefinitions: URL? = nil, runtime: URL? = nil, data: URL? = nil, indexes: URL? = nil,
        commands: URL? = nil
    ) {
        self.platform = platform
        self.commands = commands ?? URL(fileURLWithPath: platform == .linux ? "/usr/bin" : "/usr/local/bin", isDirectory: true)
        switch platform {
        case .macos:
            self.software =
                software
                ?? URL(
                    fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda", isDirectory: true)
            self.configuration =
                configuration
                ?? URL(
                    fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda", isDirectory: true)
            self.launchDefinitions =
                launchDefinitions ?? URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
            self.runtime =
                runtime
                ?? URL(
                    fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda/runtime",
                    isDirectory: true)
            self.data =
                data ?? URL(fileURLWithPath: "/Users/Shared/Library/Tractanda/Stores", isDirectory: true)
            self.indexes =
                indexes
                ?? URL(
                    fileURLWithPath: "/Users/Shared/Library/Application Support/Tractanda/Indexes",
                    isDirectory: true)
        case .linux:
            self.software = software ?? URL(fileURLWithPath: "/opt/tractanda", isDirectory: true)
            self.configuration = configuration ?? URL(fileURLWithPath: "/etc/tractanda", isDirectory: true)
            self.launchDefinitions =
                launchDefinitions ?? URL(fileURLWithPath: "/etc/systemd/system", isDirectory: true)
            self.runtime = runtime ?? URL(fileURLWithPath: "/run/tractanda", isDirectory: true)
            self.data = data ?? URL(fileURLWithPath: "/var/lib/tractanda/stores", isDirectory: true)
            self.indexes = indexes ?? URL(fileURLWithPath: "/var/cache/tractanda/indexes", isDirectory: true)
        }
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public protocol SetupProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
        -> ProcessResult
}

public struct SetupOptions: Equatable, Sendable {
    public enum Mode: String, Sendable { case empty, sample }
    public enum StoreSelection: Equatable, Sendable {
        case unconfigured
        case standalone
        case prepared(storeID: String, replicaID: String)
    }
    public let storeSelection: StoreSelection
    public enum PeerRuntimeAction: Equatable, Sendable {
        case preserve
        case replace(URL)
        case disable
    }
    public let peerRuntime: PeerRuntimeAction
    public let name: String
    public let owner: String?
    public let mode: Mode
    public let port: Int
    public let bundle: URL
    public let uuidNode: String?
    public init(
        name: String = "default", owner: String? = nil, mode: Mode = .empty, port: Int = 48_728,
        bundle: URL, uuidNode: String? = nil, peerRuntime: PeerRuntimeAction = .preserve,
        storeSelection: StoreSelection = .unconfigured
    ) {
        self.name = name
        self.owner = owner
        self.mode = mode
        self.port = port
        self.bundle = bundle
        self.uuidNode = uuidNode
        self.peerRuntime = peerRuntime
        self.storeSelection = storeSelection
    }
    func validate() throws {
        guard name.utf8.count <= 32, !name.isEmpty,
            name.utf8.allSatisfy({ asciiLetter($0) || asciiDigit($0) || $0 == 45 }),
            name.first != "-", name.last != "-", (1...65_535).contains(port)
        else {
            throw SetupError("Instance name or port is invalid.")
        }
        if let owner, !validAccountName(owner) { throw SetupError("Account name is invalid.") }
        if case let .prepared(storeID, replicaID) = storeSelection {
            guard mode != .sample, storeID != replicaID,
                [storeID, replicaID].allSatisfy({ value in
                    guard let uuid = UUID(uuidString: value) else { return false }
                    return uuid.version1Components != nil && uuid.uuidString.lowercased() == value
                }) else { throw SetupError("Prepared adoption requires distinct canonical UUIDv1 store/replica pins and cannot seed sample content.") }
        }
        if let uuidNode {
            let compact = uuidNode.replacingOccurrences(of: ":", with: "")
            guard compact.count == 12, compact.utf8.allSatisfy(asciiHex) else {
                throw SetupError("UUID node override must be a host MAC address.")
            }
        }
    }
}

public struct SetupPlan: Codable, Equatable, Sendable {
    public let instance: String
    public let store: String
    public let indexDirectory: String
    public let socket: String
    public let definition: String
    public let executable: String
    public let actions: [String]
}

/// A pinned, data-only document payload. The ordinary file inventory remains authoritative.
public struct DocumentExtractionPayload: Codable, Equatable, Sendable {
    public let converterPath: String
    public let identity: DocumentConverterIdentity
    public let workerProtocol: String
    public let modelDirectory: String
    public let modelManifestPath: String
    public let modelManifestSHA256: String
    public let runtimeRepository: String
    public let runtimePatchManifestPath: String
    public let runtimePatchManifestSHA256: String
    public let runtimePatchIdentifier: String
    public let runtimePatchPath: String
    public let runtimePatchSHA256: String
    public let noticePaths: [String]

    public static let pinned = descriptor(identity: DocumentConverterIdentity())

    private static func descriptor(identity: DocumentConverterIdentity) -> Self {
        Self(
        converterPath: "bin/tractanda-document-converter", identity: identity,
        workerProtocol: "tractanda.native-document-worker.v1",
        modelDirectory: "models/granite-docling-258m-mlx",
        modelManifestPath: "licenses/Docling/ModelAssets.json",
        modelManifestSHA256: "64894c93726b0b76d2eb5c20f001c61d6fc2eea1ef848b23773ba60cae9e00ef",
        runtimeRepository: "osaurus-ai/vmlx-swift",
        runtimePatchManifestPath: "licenses/Docling/runtime-patches.json",
        runtimePatchManifestSHA256: "732b8d020e258b8ab5de5875f53bc3756143b089d9a1d7619f311ccbe4674635",
        runtimePatchIdentifier: "idefics3-vision-gelu-f32-v1",
        runtimePatchPath: "licenses/Docling/vmlx-61a4b20-idefics3-gelu-f32.patch",
        runtimePatchSHA256: "4b45ae94cd5a9a2545025cf5165cd9e617f3c30c5a7b02e236c036ee943b9321",
        noticePaths: [
            "licenses/Docling/Granite-Docling-LICENSE",
            "licenses/Docling/Granite-Docling-MODEL-NOTICE.md", "licenses/Docling/Pillow-LICENSE",
            "licenses/optional-embedding-host/vmlx-swift/LICENSE",
            "licenses/optional-embedding-host/vmlx-swift/ACKNOWLEDGMENTS.md",
        ])
    }

    func validatePlatform(platform: String, arch: String) throws {
        let expected: String?
        if platform == "macos", arch == "arm64" {
            expected = "tractanda.docling-native.v2-idefics3-gelu-f32"
        } else if platform == "linux" {
            expected = DocumentConverterIdentity.approvedLinuxConverter(architecture: arch)
        } else {
            expected = nil
        }
        guard let expected, identity.converter == expected else {
            throw SetupError("Document payload is not the finite current profile for its platform/architecture.")
        }
        try identity.validate()
    }

    static let assetNames: Set<String> = [
        "README.md", "config.json", "preprocessor_config.json", "processor_config.json",
        "chat_template.jinja", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
        "special_tokens_map.json", "added_tokens.json", "merges.txt", "vocab.json",
        "model.safetensors.index.json", "model.safetensors",
    ]

    func validate(files: [BundleManifest.File]) throws {
        try identity.validate()
        guard self == Self.descriptor(identity: identity) else { throw SetupError("Unsupported document payload descriptor.") }
        guard Set(files.map(\.path)).count == files.count else {
            throw SetupError("Duplicate document inventory paths.")
        }
        let entries = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let linuxPrefix = "tractanda.docling-native.v2-idefics3-gelu-f32+linux-raster."
        if identity.converter.hasPrefix(linuxPrefix) {
            let digest = String(identity.converter.dropFirst(linuxPrefix.count))
            guard entries["lib/tractanda/document-native-closure.json"]?.sha256 == digest,
                entries["lib/tractanda/document-native/libtractanda_docling_pdf.so.1"] != nil,
                entries["lib/tractanda/document-native/libtractanda_docling_images.so.1"] != nil else {
                throw SetupError("Linux document payload is missing its exact native closure or private providers.")
            }
        }
        guard let converter = entries[converterPath], converter.mode & 0o111 != 0,
            entries[modelManifestPath]?.sha256 == modelManifestSHA256,
            entries[runtimePatchManifestPath]?.sha256 == runtimePatchManifestSHA256,
            entries[runtimePatchPath]?.sha256 == runtimePatchSHA256,
            noticePaths.allSatisfy({ entries[$0] != nil }),
            files.contains(where: {
                ($0.path.hasPrefix("bin/TractandaDocuments_TractandaDocumentConverter.bundle/")
                    || $0.path.hasPrefix("bin/TractandaDocuments_TractandaDocumentConverter.resources/"))
                    && $0.path.hasSuffix("/ModelAssets.json") && $0.sha256 == modelManifestSHA256
            })
        else { throw SetupError("Document payload is missing its converter, resources, or pinned notices.") }
        let prefix = modelDirectory + "/"
        let names = Set(
            files.filter { $0.path.hasPrefix(prefix) }.map { String($0.path.dropFirst(prefix.count)) })
        guard names == Self.assetNames else {
            throw SetupError("Document model must contain exactly 14 pinned assets.")
        }
    }
}
