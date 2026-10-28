import Foundation
import NIOCore
import NIOSSL
import CHTTPSIdentityValidation

public enum HTTPSIdentityError: Error, Equatable, Sendable {
    case configuration, unreadableIdentity, oversizedIdentity, malformedCertificate
    case expiredOrNotYetValid, hostnameMismatch, unsuitableKeyUsage, privateKeyMismatch, untrustedChain
    case identityUnavailable, unsupportedKeyAlgorithm, unattendedKeyAccessDenied, signingFailed
}

public enum HTTPSIdentityTrust: Sendable {
    /// Validate supplied chain ordering/signatures without imposing the serving host's trust policy on clients.
    case chainOnly
    /// Operating-system trust; on Linux, the BoringSSL default CA paths.
    case system
    /// Explicit administrator-selected trust roots, separate from the server's certificate chain.
    case rootsPEMFile(String)
}

public struct HTTPSIdentityConfiguration: Sendable {
    public let hostnames: [String]
    public let trust: HTTPSIdentityTrust
    public init(hostnames: [String], trust: HTTPSIdentityTrust = .chainOnly) throws {
        guard !hostnames.isEmpty, hostnames.count <= 32,
              hostnames.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) else {
            throw HTTPSIdentityError.configuration
        }
        let normalized = hostnames.map { $0.lowercased() }
        guard normalized.allSatisfy(Self.validDNSName) else {
            throw HTTPSIdentityError.configuration
        }
        self.hostnames = normalized; self.trust = trust
    }
    private static func validDNSName(_ name: String) -> Bool {
        guard name.utf8.count <= 253, !name.hasSuffix("."),
              (try? SocketAddress(ipAddress: name, port: 0)) == nil else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

/// An immutable validated identity. The listener installs a new handler for each accepted channel.
public final class HTTPSIdentityContext: @unchecked Sendable {
    private let context: NIOSSLContext
    /// Intersection of the supplied leaf/issuer validity intervals: inclusive start, exclusive end.
    public let validFrom: Date
    public let expiresAt: Date
    internal init(context: NIOSSLContext, validFrom: Date, expiresAt: Date) {
        self.context = context; self.validFrom = validFrom; self.expiresAt = expiresAt
    }
    public func isValid(at time: Date) -> Bool { validFrom <= time && time < expiresAt }
    public func makeServerHandler(now: Date = Date()) throws -> NIOSSLServerHandler {
        guard isValid(at: now) else { throw HTTPSIdentityError.expiredOrNotYetValid }
        return NIOSSLServerHandler(context: context)
    }
}

/// Synchronous I/O/Keychain validation must run on the listener's management worker, never its NIO event loop.
public struct HTTPSIdentityLoader: Sendable {
    public typealias Reader = @Sendable (String) throws -> Data
    private let reader: Reader
    public init(reader: @escaping Reader = Self.readBoundedFile) { self.reader = reader }
    public static func readBoundedFile(_ path: String) throws -> Data {
        guard path.hasPrefix("/") else { throw HTTPSIdentityError.configuration }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw HTTPSIdentityError.oversizedIdentity }
            return data
        } catch let error as HTTPSIdentityError { throw error }
        catch { throw HTTPSIdentityError.unreadableIdentity }
    }
    private func boundedRead(_ path: String) throws -> Data {
        let data = try reader(path)
        guard !data.isEmpty, data.count <= 1_048_576 else { throw HTTPSIdentityError.oversizedIdentity }
        return data
    }
    public func loadPEM(certificateChainFile: String, privateKeyFile: String,
                        configuration: HTTPSIdentityConfiguration, now: Date = Date()) throws -> HTTPSIdentityContext {
        let chain = try boundedRead(certificateChainFile), key = try boundedRead(privateKeyFile)
        guard Self.strictPrivateKeyPEM(key) else { throw HTTPSIdentityError.privateKeyMismatch }
        let validity = try validate(chain: chain, key: key, configuration: configuration, now: now)
        let certs: [NIOSSLCertificate]
        let privateKey: NIOSSLPrivateKey
        do { certs = try NIOSSLCertificate.fromPEMBytes([UInt8](chain)); privateKey = try NIOSSLPrivateKey(bytes: [UInt8](key), format: .pem) }
        catch { throw HTTPSIdentityError.malformedCertificate }
        return try makeContext(certificates: certs, privateKey: privateKey, validity: validity)
    }
    internal func makeContext(certificates: [NIOSSLCertificate], privateKey: NIOSSLPrivateKey, validity: (validFrom: Date, expiresAt: Date)) throws -> HTTPSIdentityContext {
        var tls = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) }, privateKey: .privateKey(privateKey))
        tls.minimumTLSVersion = .tlsv13 // Signature-only: no RSA private decrypt and no legacy key exchange.
        tls.applicationProtocols = ["http/1.1"]
        tls.renegotiationSupport = .none
        return try HTTPSIdentityContext(context: NIOSSLContext(configuration: tls), validFrom: validity.validFrom, expiresAt: validity.expiresAt)
    }
    private static func strictPrivateKeyPEM(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        for label in ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"] {
            let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
            if text.hasPrefix(begin), text.hasSuffix(end) {
                let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
                return !body.isEmpty && Data(base64Encoded: String(body)) != nil
            }
        }
        return false
    }
    private static func strictCertificatePEM(_ data: Data) -> Bool {
        guard var text = String(data: data, encoding: .utf8) else { return false }
        var count = 0
        while true {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return count > 0 && count <= 16 }
            let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
            guard text.hasPrefix(begin), let range = text.range(of: end) else { return false }
            let body = text[text.index(text.startIndex, offsetBy: begin.count)..<range.lowerBound]
            let compact = body.filter { !$0.isWhitespace }
            guard Data(base64Encoded: String(compact)) != nil else { return false }
            count += 1
            text = String(text[range.upperBound...])
        }
    }
    internal func validate(chain: Data, key: Data?, configuration: HTTPSIdentityConfiguration, now: Date) throws -> (validFrom: Date, expiresAt: Date) {
        guard chain.count <= 1_048_576, Self.strictCertificatePEM(chain) else { throw HTTPSIdentityError.malformedCertificate }
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite, seconds > Double(Int64.min), seconds < Double(Int64.max) else {
            throw HTTPSIdentityError.configuration
        }
        let roots: Data?
        switch configuration.trust { case .chainOnly, .system: roots = nil; case .rootsPEMFile(let path): roots = try boundedRead(path) }
        var starts: Int64 = 0, expires: Int64 = 0
        for hostname in configuration.hostnames {
            let code = chain.withUnsafeBytes { chainBytes in
                let invoke: (UnsafePointer<UInt8>?, Int) -> Int32 = { keyBytes, keyCount in
                    let call: (UnsafePointer<UInt8>?, Int) -> Int32 = { rootBytes, rootCount in
                        #if os(macOS)
                        let verifyChain: Int32 = roots == nil ? 0 : 1
                        #else
                        let verifyChain: Int32 = { if case .chainOnly = configuration.trust { return 0 }; return 1 }()
                        #endif
                        return tractanda_https_validate(chainBytes.bindMemory(to: UInt8.self).baseAddress, chain.count,
                            keyBytes, keyCount, rootBytes, rootCount, verifyChain, hostname,
                            Int64(seconds), &starts, &expires)
                    }
                    if let roots { return roots.withUnsafeBytes { call($0.bindMemory(to: UInt8.self).baseAddress, roots.count) } }
                    return call(nil, 0)
                }
                if let key { return key.withUnsafeBytes { invoke($0.bindMemory(to: UInt8.self).baseAddress, key.count) } }
                return invoke(nil, 0)
            }
            switch code {
            case 1: break
            case -2: throw HTTPSIdentityError.expiredOrNotYetValid
            case -3: throw HTTPSIdentityError.hostnameMismatch
            case -4: throw HTTPSIdentityError.unsuitableKeyUsage
            case -5: throw HTTPSIdentityError.privateKeyMismatch
            case -6: throw HTTPSIdentityError.untrustedChain
            default: throw HTTPSIdentityError.malformedCertificate
            }
        }
        #if os(macOS)
        if case .system = configuration.trust { try Self.validateSystemTrust(chain: chain, hostnames: configuration.hostnames, now: now) }
        #endif
        return (Date(timeIntervalSince1970: TimeInterval(starts)), Date(timeIntervalSince1970: TimeInterval(expires)))
    }
}

/// Reloads are serialized. Failed reloads leave the prior context intact; an expired prior context cannot serve new connections.
/// Existing handlers own their immutable context and are unaffected by renewal or identity failure.
public final class HTTPSIdentityContextStore: @unchecked Sendable {
    private let lock = NSLock()
    private let reloadLock = NSLock()
    private let clock: @Sendable () -> Date
    private var current: HTTPSIdentityContext?
    public init() { self.clock = { Date() } }
    internal init(clock: @escaping @Sendable () -> Date) { self.clock = clock }
    @discardableResult public func reload(_ loader: () throws -> HTTPSIdentityContext) throws -> HTTPSIdentityContext {
        reloadLock.lock(); defer { reloadLock.unlock() }
        let replacement = try loader()
        // Check both bounds again after loading: wall time can move in either direction.
        guard replacement.isValid(at: clock()) else { throw HTTPSIdentityError.expiredOrNotYetValid }
        lock.lock(); current = replacement; lock.unlock()
        return replacement
    }
    public func contextForNewConnection(now: Date = Date()) throws -> HTTPSIdentityContext {
        lock.lock(); defer { lock.unlock() }
        guard let current else { throw HTTPSIdentityError.identityUnavailable }
        guard current.isValid(at: now) else { throw HTTPSIdentityError.expiredOrNotYetValid }
        return current
    }
    public func makeServerHandler(now: Date = Date()) throws -> NIOSSLServerHandler {
        try contextForNewConnection(now: now).makeServerHandler(now: now)
    }
}
