import Foundation
import Synchronization
import TractandaClient
import TractandaCore
import TractandaHTTPSIdentity

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

#if os(macOS)
    import Security
#endif

/// Administrator-owned configuration only. Absence preserves the existing Unix/loopback bindings.
public struct PublicJMAPConfiguration: Codable, Sendable {
    public enum Identity: Codable, Sendable {
        case pem(certificateChainFile: String, privateKeyFile: String)
        case systemKeychain
        case keychainDomain(String)
        case keychainReference(Data)
    }
    public enum Transport: Codable, Sendable {
        case builtinTLS(host: String, port: Int, identity: Identity)
        /// A same-host proxy receives a protected Unix HTTP backend; Forwarded headers are ignored.
        case trustedProxyUnix(path: String)
    }
    public let baseURL: String
    public let transport: Transport
    public let callbackPolicy: JMAPCallbackPolicy
    public let maxSizeUpload: Int64
    public let maxConcurrentUpload: Int
    public let maximumStagedBytesPerUser: Int64
    public let minimumFreeBytes: Int64
    public let requestBodyIdleSeconds: Double
    public init(
        baseURL: String, transport: Transport, callbackPolicy: JMAPCallbackPolicy = .init(),
        maxSizeUpload: Int64 = 50_000_000, maxConcurrentUpload: Int = 8,
        maximumStagedBytesPerUser: Int64 = 1024 * 1024 * 1024,
        minimumFreeBytes: Int64 = 1024 * 1024 * 1024, requestBodyIdleSeconds: Double = 3600
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.callbackPolicy = callbackPolicy
        self.maxSizeUpload = maxSizeUpload
        self.maxConcurrentUpload = maxConcurrentUpload
        self.maximumStagedBytesPerUser = maximumStagedBytesPerUser
        self.minimumFreeBytes = minimumFreeBytes
        self.requestBodyIdleSeconds = requestBodyIdleSeconds
    }
    private enum CodingKeys: String, CodingKey {
        case baseURL, transport, callbackPolicy, maxSizeUpload, maxConcurrentUpload,
            maximumStagedBytesPerUser, minimumFreeBytes, requestBodyIdleSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try c.decode(String.self, forKey: .baseURL),
            transport: try c.decode(Transport.self, forKey: .transport),
            callbackPolicy: try c.decodeIfPresent(JMAPCallbackPolicy.self, forKey: .callbackPolicy)
                ?? .init(),
            maxSizeUpload: try c.decodeIfPresent(Int64.self, forKey: .maxSizeUpload) ?? 50_000_000,
            maxConcurrentUpload: try c.decodeIfPresent(Int.self, forKey: .maxConcurrentUpload) ?? 8,
            maximumStagedBytesPerUser: try c.decodeIfPresent(Int64.self, forKey: .maximumStagedBytesPerUser)
                ?? 1024 * 1024 * 1024,
            minimumFreeBytes: try c.decodeIfPresent(Int64.self, forKey: .minimumFreeBytes) ?? 1024 * 1024
                * 1024,
            requestBodyIdleSeconds: try c.decodeIfPresent(Double.self, forKey: .requestBodyIdleSeconds)
                ?? 3600)
        try validate()
    }
    public static func load(from path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
            throw TractandaError(
                "invalidConfiguration", "Choose an absolute public HTTPS configuration path.")
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw TractandaError("invalidConfiguration", "Cannot open public HTTPS configuration.")
        }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == geteuid() || metadata.st_uid == 0,
            metadata.st_mode & 0o022 == 0, metadata.st_size >= 0, metadata.st_size <= 262_144
        else {
            throw TractandaError("invalidConfiguration", "Unsafe or oversized public HTTPS configuration.")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var bytes = Data()
        while let chunk = try file.read(upToCount: 16_384), !chunk.isEmpty {
            guard bytes.count <= 262_144 - chunk.count else {
                throw TractandaError(
                    "invalidConfiguration", "Public HTTPS configuration grew beyond its bound.")
            }
            bytes.append(chunk)
        }
        guard bytes.count == metadata.st_size else {
            throw TractandaError("invalidConfiguration", "Public HTTPS configuration changed while reading.")
        }
        return try JSON.decode(Self.self, bytes)
    }
    public func validate() throws {
        _ = try JMAPHTTPSExposure(
            baseURL: baseURL, resources: .init(api: true, upload: true, download: true, eventSource: true))
        _ = try blobLimits()
        guard requestBodyIdleSeconds.isFinite, requestBodyIdleSeconds > 0,
            requestBodyIdleSeconds <= 9_000_000_000
        else { throw TractandaError("invalidConfiguration", "Invalid request body idle interval.") }
        guard maximumStagedBytesPerUser >= maxSizeUpload else {
            throw TractandaError("invalidConfiguration", "Blob user quota must hold a maximum upload.")
        }
        switch transport {
        case .builtinTLS(let host, let port, let identity):
            guard !host.isEmpty, host.utf8.count <= 253, !host.contains("\0"), (1...65535).contains(port),
                let hostname = URLComponents(string: baseURL)?.host
            else { throw TractandaError("invalidConfiguration", "Invalid public TLS endpoint.") }
            _ = try HTTPSIdentityConfiguration(hostnames: [hostname])
            switch identity {
            case .pem(let chain, let key):
                guard [chain, key].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
                    throw TractandaError("invalidConfiguration", "Choose absolute external identity paths.")
                }
            case .keychainDomain(let domain):
                guard !domain.isEmpty, domain.utf8.count <= 1024 else {
                    throw TractandaError("invalidConfiguration", "Invalid identity domain.")
                }
            case .keychainReference(let reference):
                guard !reference.isEmpty, reference.count <= 16_384 else {
                    throw TractandaError("invalidConfiguration", "Invalid identity reference.")
                }
            case .systemKeychain: break
            }
            #if !os(macOS)
                if case .pem = identity {
                } else {
                    throw TractandaError("unsupportedFeature", "Keychain identities require macOS.")
                }
            #endif
        case .trustedProxyUnix(let path):
            guard path.hasPrefix("/"), path.utf8.count <= 103, !path.contains("\0") else {
                throw TractandaError("invalidConfiguration", "Choose a protected Unix HTTP backend path.")
            }
        }
        for origin in callbackPolicy.privateOrigins {
            _ = try JMAPCallbackEndpoint(
                "https://" + (origin.host.contains(":") ? "[\(origin.host)]" : origin.host)
                    + ":\(origin.port)/")
        }
    }
    public func blobLimits() throws -> JMAPBlobLimits {
        try .init(
            maxSizeUpload: maxSizeUpload, maxConcurrentUpload: maxConcurrentUpload,
            maximumStagedBytesPerUser: maximumStagedBytesPerUser, minimumFreeBytes: minimumFreeBytes)
    }
    /// No-follow fd traversal proves ancestor custody before any pathname bind/chmod.
    func validateProtectedProxyParents() throws {
        guard case .trustedProxyUnix(let path) = transport,
            path == URL(fileURLWithPath: path).standardizedFileURL.path
        else { throw TractandaError("invalidConfiguration", "Invalid protected proxy path.") }
        let parts = path.split(separator: "/").dropLast()
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TractandaError("invalidConfiguration", "Cannot verify proxy path custody.")
        }
        defer { _ = close(descriptor) }
        for (index, part) in parts.enumerated() {
            let next = String(part).withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                throw TractandaError(
                    "invalidConfiguration", "Proxy path traverses a symlink or unavailable directory.")
            }
            _ = close(descriptor)
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == 0 || info.st_uid == geteuid(),
                info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0
            else { throw TractandaError("invalidConfiguration", "Proxy path has an unsafe ancestor.") }
            if index == parts.count - 1 {
                guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                    throw TractandaError(
                        "invalidConfiguration", "Proxy parent must be private and service-owned.")
                }
            }
        }
    }
    func prepareHeadlessPolicy() throws {
        guard case .builtinTLS(_, _, let source) = transport else { return }
        if case .pem = source { return }
        #if os(macOS)
            try Self.prepareHeadlessKeychainProcess()
        #else
            throw HTTPSIdentityError.configuration
        #endif
    }
    /// Called on a management worker, never a NIO event loop; no automatic identity creation.
    func loadIdentity() throws -> HTTPSIdentityContextStore? {
        guard case .builtinTLS(_, _, let source) = transport else { return nil }
        guard let host = URLComponents(string: baseURL)?.host else { throw HTTPSIdentityError.configuration }
        let configuration = try HTTPSIdentityConfiguration(hostnames: [host])
        let loader = HTTPSIdentityLoader()
        let store = HTTPSIdentityContextStore()
        try store.reload {
            switch source {
            case .pem(let chain, let key):
                return try loader.loadPEM(
                    certificateChainFile: chain, privateKeyFile: key, configuration: configuration)
            default:
                #if os(macOS)
                    try Self.prepareHeadlessKeychainProcess()
                    let selection: HTTPSKeychainIdentitySelection
                    switch source {
                    case .systemKeychain: selection = .systemDefault
                    case .keychainDomain(let domain): selection = .systemDomain(domain)
                    case .keychainReference(let reference): selection = .persistentReference(reference)
                    case .pem: throw HTTPSIdentityError.configuration
                    }
                    return try loader.loadKeychain(selection: selection, configuration: configuration)
                #else
                    throw HTTPSIdentityError.configuration
                #endif
            }
        }
        return store
    }
    #if os(macOS)
        private static let headlessPolicy = Mutex(false)
        private static func prepareHeadlessKeychainProcess() throws {
            try headlessPolicy.withLock { applied in
                if !applied {
                    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                        throw HTTPSIdentityError.unattendedKeyAccessDenied
                    }
                    applied = true
                }
            }
        }
    #endif
}
