#if os(macOS)
import Foundation
import Security
import LocalAuthentication
import NIOCore
import NIOSSL

public enum HTTPSKeychainIdentitySelection: Sendable {
    /// The explicitly selected operating-system default identity domain.
    case systemDefault
    /// An explicitly configured identity domain; silent domain fallback is rejected.
    case systemDomain(String)
    /// An administrator-selected SecIdentity persistent reference; never a broad identity search.
    case persistentReference(Data)
}

/// Lookup results carry references, never exported private key bytes. Injected lookups must prohibit interaction.
public final class HTTPSKeychainIdentity: @unchecked Sendable {
    public let certificateChainDER: [Data]
    internal let key: SecKey
    // Retain the no-interaction authentication context with the key reference.
    internal let authenticationContext: LAContext?
    internal init(certificateChainDER: [Data], privateKey: SecKey) {
        self.certificateChainDER = certificateChainDER; self.key = privateKey; self.authenticationContext = nil
    }
    internal init(certificateChainDER: [Data], privateKey: SecKey, authenticationContext: LAContext) {
        self.certificateChainDER = certificateChainDER; self.key = privateKey; self.authenticationContext = authenticationContext
    }
}

extension HTTPSIdentityLoader {
    public typealias KeychainLookup = @Sendable (HTTPSKeychainIdentitySelection) throws -> HTTPSKeychainIdentity
    /// This performs only the exact configured lookup. It never enumerates identities or changes Keychain ACLs.
    public static func lookupKeychainIdentity(_ selection: HTTPSKeychainIdentitySelection) throws -> HTTPSKeychainIdentity {
        try requireNoninteractiveKeychainProcess()
        let authentication = LAContext(); authentication.interactionNotAllowed = true
        let identity: SecIdentity
        switch selection {
        case .systemDefault:
            return try lookupKeychainIdentity(.systemDomain(kSecIdentityDomainDefault as String))
        case .systemDomain(let domain):
            guard !domain.isEmpty else { throw HTTPSIdentityError.configuration }
            var result: SecIdentity?, actualDomain: CFString?
            guard SecIdentityCopySystemIdentity(domain as CFString, &result, &actualDomain) == errSecSuccess,
                  let result, let actualDomain, actualDomain as String == domain else {
                throw HTTPSIdentityError.identityUnavailable
            }
            identity = result
        case .persistentReference(let reference):
            var result: CFTypeRef?
            let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecValuePersistentRef: reference,
                kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: authentication]
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { throw HTTPSIdentityError.identityUnavailable }
            identity = (result as! SecIdentity)
        }
        var certificate: SecCertificate?, originalKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &originalKey) == errSecSuccess,
              let certificate, let originalKey else { throw HTTPSIdentityError.identityUnavailable }
        // Reopen the private-key reference with interaction explicitly forbidden. Fail if the provider cannot do so.
        var reference: CFTypeRef?
        let referenceQuery: [CFString: Any] = [kSecClass: kSecClassKey, kSecValueRef: originalKey,
            kSecReturnPersistentRef: true, kSecUseAuthenticationContext: authentication]
        guard SecItemCopyMatching(referenceQuery as CFDictionary, &reference) == errSecSuccess, let reference else {
            throw HTTPSIdentityError.unattendedKeyAccessDenied
        }
        var protectedKey: CFTypeRef?
        let keyQuery: [CFString: Any] = [kSecClass: kSecClassKey, kSecValuePersistentRef: reference,
            kSecReturnRef: true, kSecUseAuthenticationContext: authentication]
        guard SecItemCopyMatching(keyQuery as CFDictionary, &protectedKey) == errSecSuccess,
              let protectedKey, CFGetTypeID(protectedKey) == SecKeyGetTypeID() else {
            throw HTTPSIdentityError.unattendedKeyAccessDenied
        }
        return HTTPSKeychainIdentity(certificateChainDER: [SecCertificateCopyData(certificate) as Data],
            privateKey: protectedKey as! SecKey, authenticationContext: authentication)
    }
    /// The integrating daemon must deliberately disable legacy Security interaction for its process.
    /// Checking this policy avoids toggling a process-global setting around concurrent signing calls.
    public static func requireNoninteractiveKeychainProcess() throws {
        var allowed: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, !allowed.boolValue else {
            throw HTTPSIdentityError.unattendedKeyAccessDenied
        }
    }
    public func loadKeychain(selection: HTTPSKeychainIdentitySelection,
        configuration: HTTPSIdentityConfiguration, intermediateCertificatesDER: [Data] = [],
        now: Date = Date(), lookup: KeychainLookup = Self.lookupKeychainIdentity) throws -> HTTPSIdentityContext {
        let identity = try lookup(selection)
        let chain = identity.certificateChainDER + intermediateCertificatesDER
        guard !chain.isEmpty, chain.count <= 16, chain.allSatisfy({ !$0.isEmpty && $0.count < 65_536 }) else {
            throw HTTPSIdentityError.malformedCertificate
        }
        let pem = chain.map(Self.pemCertificate).reduce(Data(), +)
        let validity = try validate(chain: pem, key: nil, configuration: configuration, now: now)
        let signer = try HTTPSKeyReferenceSigner(key: identity.key, retainedIdentity: identity)
        guard let leaf = SecCertificateCreateWithData(nil, chain[0] as CFData), let publicKey = SecCertificateCopyKey(leaf) else {
            throw HTTPSIdentityError.malformedCertificate
        }
        try signer.validateUnattendedMatchingKey(publicKey)
        return try makeContext(certificates: chain.map { try NIOSSLCertificate(bytes: [UInt8]($0), format: .der) },
            privateKey: NIOSSLPrivateKey(customPrivateKey: signer), validity: validity)
    }
    internal static func pemCertificate(_ der: Data) -> Data {
        Data(("-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
            "\n-----END CERTIFICATE-----\n").utf8)
    }
    internal static func validateSystemTrust(chain: Data, hostnames: [String], now: Date) throws {
        let certificates = try NIOSSLCertificate.fromPEMBytes([UInt8](chain)).map { cert -> SecCertificate in
            guard let result = SecCertificateCreateWithData(nil, Data(try cert.toDERBytes()) as CFData) else {
                throw HTTPSIdentityError.malformedCertificate
            }
            return result
        }
        for hostname in hostnames {
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
                  let trust else { throw HTTPSIdentityError.untrustedChain }
            SecTrustSetNetworkFetchAllowed(trust, false)
            SecTrustSetVerifyDate(trust, now as CFDate)
            guard SecTrustEvaluateWithError(trust, nil) else { throw HTTPSIdentityError.untrustedChain }
        }
    }
}

/// NIOSSL supplies UNHASHED messages. Security's *Message* algorithms perform the required single hash.
/// Only TLS 1.3 signature schemes are exposed. All provider calls run off NIO event loops.
internal final class HTTPSKeyReferenceSigner: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    private let key: SecKey
    private let retainedIdentity: HTTPSKeychainIdentity?
    private let unattendedPolicy: @Sendable () throws -> Void
    private let worker = DispatchQueue(label: "ai.tractanda.https.key-signing")
    let signatureAlgorithms: [SignatureAlgorithm]
    init(key: SecKey, retainedIdentity: HTTPSKeychainIdentity? = nil,
         unattendedPolicy: (@Sendable () throws -> Void)? = nil) throws {
        self.key = key; self.retainedIdentity = retainedIdentity
        self.unattendedPolicy = unattendedPolicy ?? {
            if retainedIdentity?.authenticationContext != nil { try HTTPSIdentityLoader.requireNoninteractiveKeychainProcess() }
        }
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        let kind = attributes?[kSecAttrKeyType] as? String
        let size = attributes?[kSecAttrKeySizeInBits] as? Int ?? 0
        let candidates: [SignatureAlgorithm]
        if kind == (kSecAttrKeyTypeRSA as String), size >= 2048 {
            candidates = [.rsaPssRsaeSha256, .rsaPssRsaeSha384, .rsaPssRsaeSha512]
        } else if kind == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch size {
            case 256: candidates = [.ecdsaSecp256R1Sha256]
            case 384: candidates = [.ecdsaSecp384R1Sha384]
            case 521: candidates = [.ecdsaSecp521R1Sha512]
            default: throw HTTPSIdentityError.unsupportedKeyAlgorithm
            }
        } else { throw HTTPSIdentityError.unsupportedKeyAlgorithm }
        signatureAlgorithms = candidates.filter { scheme in
            guard let algorithm = Self.securityAlgorithm(scheme) else { return false }
            return SecKeyIsAlgorithmSupported(key, .sign, algorithm)
        }
        guard !signatureAlgorithms.isEmpty else { throw HTTPSIdentityError.unsupportedKeyAlgorithm }
    }
    static func == (lhs: HTTPSKeyReferenceSigner, rhs: HTTPSKeyReferenceSigner) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    static func securityAlgorithm(_ scheme: SignatureAlgorithm) -> SecKeyAlgorithm? {
        switch scheme {
        case .rsaPssRsaeSha256: return .rsaSignatureMessagePSSSHA256
        case .rsaPssRsaeSha384: return .rsaSignatureMessagePSSSHA384
        case .rsaPssRsaeSha512: return .rsaSignatureMessagePSSSHA512
        case .ecdsaSecp256R1Sha256: return .ecdsaSignatureMessageX962SHA256
        case .ecdsaSecp384R1Sha384: return .ecdsaSignatureMessageX962SHA384
        case .ecdsaSecp521R1Sha512: return .ecdsaSignatureMessageX962SHA512
        default: return nil
        }
    }
    internal func signature(scheme: SignatureAlgorithm, message: Data) throws -> Data {
        guard signatureAlgorithms.contains(scheme), let algorithm = Self.securityAlgorithm(scheme) else {
            throw HTTPSIdentityError.unsupportedKeyAlgorithm
        }
        try unattendedPolicy()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, message as CFData, &error) else {
            if let failure = error?.takeRetainedValue(), CFErrorGetCode(failure) == errSecInteractionNotAllowed {
                throw HTTPSIdentityError.unattendedKeyAccessDenied
            }
            throw HTTPSIdentityError.signingFailed
        }
        return signature as Data
    }
    func validateUnattendedMatchingKey(_ publicKey: SecKey) throws {
        let message = Data("Tractanda HTTPS identity unattended matching-key validation".utf8)
        for scheme in signatureAlgorithms {
            let signed = try signature(scheme: scheme, message: message)
            guard let algorithm = Self.securityAlgorithm(scheme),
                  SecKeyVerifySignature(publicKey, algorithm, message as CFData, signed as CFData, nil) else {
                throw HTTPSIdentityError.privateKeyMismatch
            }
        }
    }
    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let message = Data(data.readableBytesView)
        worker.async {
            do { promise.succeed(ByteBuffer(bytes: try self.signature(scheme: algorithm, message: message))) }
            catch { promise.fail(error) }
        }
        return promise.futureResult
    }
    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(HTTPSIdentityError.unsupportedKeyAlgorithm)
    }
}
#endif
