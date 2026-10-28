import Foundation
import XCTest
import CNIOBoringSSL
import NIOCore
import NIOEmbedded
import NIOTLS
import NIOSSL
@testable import TractandaHTTPSIdentity
#if os(macOS)
import Security
#endif

enum FixtureFailure: Error { case failed }
private func checked(_ value: Bool) throws { if !value { throw FixtureFailure.failed } }

/// Entirely ephemeral fixture PKI; no operating-system Keychain or certificate provisioning.
private final class CertificateFixture {
    let key: OpaquePointer
    let certificate: OpaquePointer
    init(issuer: CertificateFixture? = nil, ca: Bool = false, hostname: String = "api.example.test",
         keyUsage: String? = "digitalSignature", eku: String? = "serverAuth", expired: Bool = false,
         publicPoint: Data? = nil, includeSAN: Bool = true, caName: String = "Fixture Root",
         notBeforeOffset: Int = -3600, notAfterOffset: Int = 86400) throws {
        guard let key = EVP_PKEY_new(), let ec = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1), let cert = X509_new() else { throw FixtureFailure.failed }
        self.key = key; certificate = cert
        defer { EC_KEY_free(ec) }
        if let publicPoint {
            let point = EC_POINT_new(EC_KEY_get0_group(ec)); defer { EC_POINT_free(point) }
            try checked(publicPoint.withUnsafeBytes { EC_POINT_oct2point(EC_KEY_get0_group(ec), point, $0.bindMemory(to: UInt8.self).baseAddress, publicPoint.count, nil) } == 1)
            try checked(EC_KEY_set_public_key(ec, point) == 1)
        } else { try checked(EC_KEY_generate_key(ec) == 1) }
        try checked(EVP_PKEY_set1_EC_KEY(key, ec) == 1)
        try checked(X509_set_version(cert, 2) == 1)
        try checked(ASN1_INTEGER_set(X509_get_serialNumber(cert), Int.random(in: 1...1_000_000)) == 1)
        try checked(X509_gmtime_adj(X509_getm_notBefore(cert), notBeforeOffset) != nil)
        try checked(X509_gmtime_adj(X509_getm_notAfter(cert), expired ? -60 : notAfterOffset) != nil)
        try checked(X509_set_pubkey(cert, key) == 1)
        let name = X509_get_subject_name(cert)
        let cn = Array((ca ? caName : hostname).utf8)
        try checked(cn.withUnsafeBufferPointer { X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, $0.baseAddress, $0.count, -1, 0) } == 1)
        try checked(X509_set_issuer_name(cert, issuer.map { X509_get_subject_name($0.certificate) } ?? name) == 1)
        func ext(_ nid: Int32, _ value: String) throws {
            let bytes = Array(value.utf8CString)
            let extensionValue = bytes.withUnsafeBufferPointer { X509V3_EXT_nconf_nid(nil, nil, nid, $0.baseAddress) }
            guard let extensionValue else { throw FixtureFailure.failed }; defer { X509_EXTENSION_free(extensionValue) }
            try checked(X509_add_ext(cert, extensionValue, -1) == 1)
        }
        try ext(NID_basic_constraints, ca ? "critical,CA:TRUE" : "critical,CA:FALSE")
        if ca { try ext(NID_key_usage, "critical,keyCertSign,cRLSign") }
        else {
            if let keyUsage { try ext(NID_key_usage, "critical," + keyUsage) }
            if let eku { try ext(NID_ext_key_usage, eku) }
        }
        if includeSAN { try ext(NID_subject_alt_name, "DNS:" + hostname) }
        try checked(X509_sign(cert, issuer?.key ?? key, EVP_sha256()) > 0)
    }
    deinit { EVP_PKEY_free(key); X509_free(certificate) }
    var der: Data {
        var result = Data(count: Int(i2d_X509(certificate, nil)))
        result.withUnsafeMutableBytes { raw in
            var pointer = raw.bindMemory(to: UInt8.self).baseAddress
            _ = i2d_X509(certificate, &pointer)
        }
        return result
    }
    var pem: Data { pemData { PEM_write_bio_X509($0, certificate) } }
    var privatePEM: Data { pemData { PEM_write_bio_PrivateKey($0, key, nil, nil, 0, nil, nil) } }
    private func pemData(_ write: (OpaquePointer?) -> Int32) -> Data {
        let bio = BIO_new(BIO_s_mem()); defer { BIO_free(bio) }
        precondition(write(bio) == 1)
        var bytes = [UInt8](repeating: 0, count: Int(BIO_ctrl_pending(bio)))
        let count = BIO_read(bio, &bytes, Int32(bytes.count))
        return Data(bytes.prefix(Int(count)))
    }
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ time: Date) { value = time }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ time: Date) { lock.lock(); value = time; lock.unlock() }
}

private final class Capture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var handshakes = 0
    var received: [UInt8] = []
    var errors: [Error] = []
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { handshakes += 1 }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { received += unwrapInboundIn(data).readableBytesView }
    func errorCaught(context: ChannelHandlerContext, error: Error) { errors.append(error) }
}
private final class TLSConnection {
    let client = EmbeddedChannel(), server = EmbeddedChannel()
    let received = Capture(), clientState = Capture()
    init(identity: HTTPSIdentityContext, root: Data, hostname: String = "api.example.test") throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.trustRoots = .certificates([try NIOSSLCertificate(bytes: [UInt8](root), format: .der)])
        configuration.applicationProtocols = ["http/1.1"]
        try client.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: NIOSSLContext(configuration: configuration), serverHostname: hostname))
        try client.pipeline.syncOperations.addHandler(clientState)
        try server.pipeline.syncOperations.addHandler(identity.makeServerHandler())
        try server.pipeline.syncOperations.addHandler(received)
        server.pipeline.fireChannelActive()
        _ = client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1))
    }
    func pump() throws {
        for _ in 0..<200 {
            client.embeddedEventLoop.run(); server.embeddedEventLoop.run()
            var progress = false
            for (from, to) in [(client, server), (server, client)] {
                while let data = try from.readOutbound(as: IOData.self) {
                    if case .byteBuffer(let buffer) = data { _ = try to.writeInbound(buffer) }; progress = true
                }
            }
            if !progress { return }
        }
        throw FixtureFailure.failed
    }
    func payload(_ text: String = "GET /jmap HTTP/1.1\r\n\r\n") throws {
        _ = client.writeAndFlush(ByteBuffer(string: text)); try pump()
        XCTAssertTrue(String(decoding: received.received, as: UTF8.self).contains(text))
    }
    deinit {
        client.close(promise: nil); server.close(promise: nil)
        client.embeddedEventLoop.advanceTime(by: .hours(1)); server.embeddedEventLoop.advanceTime(by: .hours(1))
        _ = try? client.finish(acceptAlreadyClosed: true); _ = try? server.finish(acceptAlreadyClosed: true)
    }
}

final class HTTPSIdentityTests: XCTestCase {
    private func load(_ leaf: CertificateFixture, chain: Data? = nil, key: Data? = nil,
                      host: String = "api.example.test", now: Date = Date(), roots: Data? = nil) throws -> HTTPSIdentityContext {
        let files = ["cert": chain ?? leaf.pem, "key": key ?? leaf.privatePEM, "roots": roots ?? Data()]
        let loader = HTTPSIdentityLoader(reader: { guard let value = files[$0] else { throw FixtureFailure.failed }; return value })
        return try loader.loadPEM(certificateChainFile: "cert", privateKeyFile: "key",
            configuration: HTTPSIdentityConfiguration(hostnames: [host], trust: roots == nil ? .chainOnly : .rootsPEMFile("roots")), now: now)
    }
    func testIndependentVerifiedClientHandshakeAndEncryptedPayload() throws {
        let root = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root)
        let identity = try load(leaf, chain: leaf.pem + root.pem)
        let connection = try TLSConnection(identity: identity, root: root.der); try connection.pump()
        XCTAssertEqual(connection.clientState.handshakes, 1); XCTAssertEqual(connection.received.handshakes, 1)
        XCTAssertTrue(connection.clientState.errors.isEmpty); try connection.payload()
    }
    func testClientRejectsWrongHostnameAndUntrustedIssuer() throws {
        let root = try CertificateFixture(ca: true), other = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root)
        let identity = try load(leaf, chain: leaf.pem + root.pem)
        for (trusted, host) in [(root.der, "wrong.example.test"), (other.der, "api.example.test")] {
            let connection = try TLSConnection(identity: identity, root: trusted, hostname: host); try connection.pump()
            XCTAssertEqual(connection.clientState.handshakes, 0); XCTAssertFalse(connection.clientState.errors.isEmpty)
        }
    }
    func testLoaderRejectsHostnameWrongKeyExpiredAndFutureIdentity() throws {
        let root = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root), other = try CertificateFixture(issuer: root)
        XCTAssertThrowsError(try load(CertificateFixture(issuer: root, includeSAN: false))) { XCTAssertEqual($0 as? HTTPSIdentityError, .hostnameMismatch) }
        XCTAssertThrowsError(try load(leaf, host: "wrong.example.test")) { XCTAssertEqual($0 as? HTTPSIdentityError, .hostnameMismatch) }
        XCTAssertThrowsError(try load(leaf, key: other.privatePEM)) { XCTAssertEqual($0 as? HTTPSIdentityError, .privateKeyMismatch) }
        XCTAssertThrowsError(try load(CertificateFixture(issuer: root, expired: true))) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
        XCTAssertThrowsError(try load(leaf, now: Date().addingTimeInterval(-7200))) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
    }
    func testLoaderRejectsIncompatibleUsagesAndCALeaf() throws {
        let root = try CertificateFixture(ca: true)
        XCTAssertThrowsError(try load(CertificateFixture(issuer: root, keyUsage: "keyEncipherment"))) { XCTAssertEqual($0 as? HTTPSIdentityError, .unsuitableKeyUsage) }
        XCTAssertThrowsError(try load(CertificateFixture(issuer: root, eku: "clientAuth"))) { XCTAssertEqual($0 as? HTTPSIdentityError, .unsuitableKeyUsage) }
        XCTAssertThrowsError(try load(root, host: "api.example.test")) { XCTAssertEqual($0 as? HTTPSIdentityError, .unsuitableKeyUsage) }
    }
    func testAbsentUsageExtensionsPermitServerUse() throws {
        let root = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root, keyUsage: nil, eku: nil)
        _ = try load(leaf)
    }
    func testSuppliedChainOrderingSignatureAndOptionalTrustConstraint() throws {
        let root = try CertificateFixture(ca: true), wrong = try CertificateFixture(ca: true)
        let intermediate = try CertificateFixture(issuer: root, ca: true, caName: "Fixture Intermediate"), leaf = try CertificateFixture(issuer: intermediate)
        _ = try load(leaf, chain: leaf.pem + intermediate.pem, roots: root.pem)
        XCTAssertThrowsError(try load(leaf, chain: leaf.pem + root.pem + intermediate.pem)) { XCTAssertEqual($0 as? HTTPSIdentityError, .untrustedChain) }
        XCTAssertThrowsError(try load(leaf, chain: leaf.pem + wrong.pem)) { XCTAssertEqual($0 as? HTTPSIdentityError, .untrustedChain) }
        let nonCAIssuer = try CertificateFixture(issuer: root, keyUsage: "digitalSignature,keyCertSign")
        let forgedLeaf = try CertificateFixture(issuer: nonCAIssuer)
        XCTAssertThrowsError(try load(forgedLeaf, chain: forgedLeaf.pem + nonCAIssuer.pem)) { XCTAssertEqual($0 as? HTTPSIdentityError, .untrustedChain) }
        XCTAssertThrowsError(try load(leaf, roots: wrong.pem)) { XCTAssertEqual($0 as? HTTPSIdentityError, .untrustedChain) }
        XCTAssertThrowsError(try load(leaf, chain: leaf.pem + Data("corrupt renewal".utf8)))
    }
    func testRenewalFailureRetainsValidContextThenValidReloadPreservesExistingConnection() throws {
        let root = try CertificateFixture(ca: true), old = try CertificateFixture(issuer: root), replacement = try CertificateFixture(issuer: root)
        let store = HTTPSIdentityContextStore(); let first = try store.reload { try load(old, chain: old.pem + root.pem) }
        let existing = try TLSConnection(identity: first, root: root.der); try existing.pump(); try existing.payload("before renewal")
        XCTAssertThrowsError(try store.reload { try load(replacement, chain: Data("incomplete external renewal".utf8)) })
        XCTAssertTrue(try store.contextForNewConnection() === first)
        XCTAssertThrowsError(try store.reload { try load(replacement, key: old.privatePEM) })
        XCTAssertTrue(try store.contextForNewConnection() === first)
        let second = try store.reload { try load(replacement, chain: replacement.pem + root.pem) }
        XCTAssertFalse(first === second); XCTAssertTrue(try store.contextForNewConnection() === second)
        let fresh = try TLSConnection(identity: store.contextForNewConnection(), root: root.der); try fresh.pump(); try fresh.payload()
        try existing.payload("after renewal")
        XCTAssertEqual(existing.clientState.handshakes, 1); XCTAssertEqual(fresh.clientState.handshakes, 1)
    }
    func testExternalPEMFileRotationRejectsIncompletePairThenReloads() throws {
        let root = try CertificateFixture(ca: true), old = try CertificateFixture(issuer: root), renewed = try CertificateFixture(issuer: root)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tractanda-https-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = directory.appendingPathComponent("fullchain.pem"), key = directory.appendingPathComponent("key.pem")
        try (old.pem + root.pem).write(to: certificate, options: .atomic)
        try old.privatePEM.write(to: key, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let configuration = try HTTPSIdentityConfiguration(hostnames: ["api.example.test"])
        let loader = HTTPSIdentityLoader(), store = HTTPSIdentityContextStore()
        func loadFiles() throws -> HTTPSIdentityContext {
            try loader.loadPEM(certificateChainFile: certificate.path, privateKeyFile: key.path, configuration: configuration)
        }
        let first = try store.reload { try loadFiles() }
        try (renewed.pem + root.pem).write(to: certificate, options: .atomic)
        XCTAssertThrowsError(try store.reload { try loadFiles() })
        XCTAssertTrue(try store.contextForNewConnection() === first)
        try renewed.privatePEM.write(to: key, options: .atomic)
        let second = try store.reload { try loadFiles() }
        XCTAssertFalse(first === second)
        let connection = try TLSConnection(identity: second, root: root.der); try connection.pump()
        XCTAssertEqual(connection.clientState.handshakes, 1)
        try Data("broken renewal".utf8).write(to: certificate, options: .atomic)
        XCTAssertThrowsError(try store.reload { try loadFiles() })
        XCTAssertTrue(try store.contextForNewConnection() === second)
    }
    func testSlowRenewalValidationDoesNotBlockNewConnectionSnapshot() throws {
        let old = try load(CertificateFixture()), replacement = try load(CertificateFixture())
        let store = HTTPSIdentityContextStore(); _ = try store.reload { old }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0), acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? store.reload { entered.signal(); release.wait(); return replacement }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            XCTAssertTrue((try? store.contextForNewConnection()) === old)
            acquired.signal()
        }
        let result = acquired.wait(timeout: .now() + 1)
        release.signal()
        XCTAssertEqual(result, .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(try store.contextForNewConnection() === replacement)
    }
    func testExpiredPreviousContextFailsNewConnectionsWithoutMutatingExistingContext() throws {
        let leaf = try CertificateFixture(), store = HTTPSIdentityContextStore()
        XCTAssertThrowsError(try store.contextForNewConnection())
        let old = try store.reload { try load(leaf) }
        let late = HTTPSIdentityContextStore(clock: { old.expiresAt })
        XCTAssertThrowsError(try late.reload { old }) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
        XCTAssertThrowsError(try late.contextForNewConnection())
        XCTAssertThrowsError(try old.makeServerHandler(now: old.expiresAt))
        XCTAssertThrowsError(try store.contextForNewConnection(now: old.expiresAt)) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
        XCTAssertThrowsError(try store.reload { throw HTTPSIdentityError.identityUnavailable })
        XCTAssertTrue(try store.contextForNewConnection() === old)
    }
    func testValidityIntersectionIncludesLeafAndIssuerStartAndEndBounds() throws {
        let root = try CertificateFixture(ca: true, notBeforeOffset: -7200, notAfterOffset: 7200)
        let issuer = try CertificateFixture(issuer: root, ca: true, caName: "Fixture Intermediate", notBeforeOffset: -60, notAfterOffset: 3600)
        let leaf = try CertificateFixture(issuer: issuer, notBeforeOffset: -120, notAfterOffset: 7200)
        let identity = try load(leaf, chain: leaf.pem + issuer.pem + root.pem)
        let certificates = try [leaf, issuer, root].map { try NIOSSLCertificate(bytes: [UInt8]($0.der), format: .der) }
        let expectedStart = try XCTUnwrap(certificates.map { Date(timeIntervalSince1970: TimeInterval($0.notValidBefore)) }.max())
        let expectedEnd = try XCTUnwrap(certificates.map { Date(timeIntervalSince1970: TimeInterval($0.notValidAfter)) }.min())
        XCTAssertEqual(identity.validFrom, expectedStart); XCTAssertEqual(identity.expiresAt, expectedEnd)
        XCTAssertTrue(identity.isValid(at: expectedStart))
        XCTAssertFalse(identity.isValid(at: expectedStart.addingTimeInterval(-1)))
        XCTAssertTrue(identity.isValid(at: expectedEnd.addingTimeInterval(-1)))
        XCTAssertFalse(identity.isValid(at: expectedEnd))
        let store = HTTPSIdentityContextStore(); _ = try store.reload { identity }
        XCTAssertThrowsError(try store.contextForNewConnection(now: expectedStart.addingTimeInterval(-1)))
        XCTAssertThrowsError(try store.makeServerHandler(now: expectedStart.addingTimeInterval(-1)))
        XCTAssertThrowsError(try identity.makeServerHandler(now: expectedStart.addingTimeInterval(-1)))
        XCTAssertNoThrow(try store.makeServerHandler(now: expectedStart))
        XCTAssertThrowsError(try store.makeServerHandler(now: expectedEnd))
    }
    func testClockJumpsDuringRenewalPreserveStillValidOldContext() throws {
        let now = Date(), clock = FixtureClock(Date())
        let old = try load(CertificateFixture(), now: now)
        let laterStart = try load(CertificateFixture(notBeforeOffset: -30), now: now)
        let earlierEnd = try load(CertificateFixture(notAfterOffset: 30), now: now)
        let store = HTTPSIdentityContextStore(clock: { clock.now() })
        _ = try store.reload { old }
        XCTAssertThrowsError(try store.reload {
            clock.set(laterStart.validFrom.addingTimeInterval(-1))
            return laterStart
        }) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
        XCTAssertTrue(old.isValid(at: clock.now()))
        XCTAssertTrue(try store.contextForNewConnection(now: clock.now()) === old)
        XCTAssertNoThrow(try store.makeServerHandler(now: clock.now()))
        clock.set(now)
        XCTAssertThrowsError(try store.reload {
            clock.set(earlierEnd.expiresAt)
            return earlierEnd
        }) { XCTAssertEqual($0 as? HTTPSIdentityError, .expiredOrNotYetValid) }
        XCTAssertTrue(old.isValid(at: clock.now()))
        XCTAssertTrue(try store.contextForNewConnection(now: clock.now()) === old)
        XCTAssertNoThrow(try store.makeServerHandler(now: clock.now()))
    }
    func testCaseNormalizedSingleLabelDNSIdentityUsesSANAndVerifiedClient() throws {
        let configuration = try HTTPSIdentityConfiguration(hostnames: ["LOCALHOST", "Host", "API.Example.Test"])
        XCTAssertEqual(configuration.hostnames, ["localhost", "host", "api.example.test"])
        let root = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root, hostname: "LOCALHOST")
        let identity = try load(leaf, chain: leaf.pem + root.pem, host: "LoCaLhOsT")
        let connection = try TLSConnection(identity: identity, root: root.der, hostname: "localhost")
        try connection.pump(); XCTAssertEqual(connection.clientState.handshakes, 1); try connection.payload()
        XCTAssertThrowsError(try load(leaf, host: "otherhost")) { XCTAssertEqual($0 as? HTTPSIdentityError, .hostnameMismatch) }
    }
    func testConfigurationAndReaderBoundaries() throws {
        for name in ["", "*.example.test", "api.example.test:443", "127.0.0.1", "::1", "[::1]", "https://api.example.test", "api.example.test\u{0000}", "api..example.test", "-host", "host-", "host.", "K.example.test"] {
            XCTAssertThrowsError(try HTTPSIdentityConfiguration(hostnames: [name]))
        }
        XCTAssertThrowsError(try HTTPSIdentityLoader.readBoundedFile("relative"))
        let loader = HTTPSIdentityLoader(reader: { _ in Data(repeating: 0, count: 1_048_577) })
        XCTAssertThrowsError(try loader.loadPEM(certificateChainFile: "cert", privateKeyFile: "key", configuration: HTTPSIdentityConfiguration(hostnames: ["api.example.test"])))
    }
    #if os(macOS)
    func testHeadlessProcessInteractionPrerequisite() throws {
        // This changes only this private test process's policy for its remaining lifetime; no key lookup.
        XCTAssertEqual(SecKeychainSetUserInteractionAllowed(false), errSecSuccess)
        XCTAssertNoThrow(try HTTPSIdentityLoader.requireNoninteractiveKeychainProcess())
    }
    func testSecKeyReferenceSignsUnhashedMessageWithoutPrivateExportAndRejectsUnsupportedScheme() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecAttrIsPermanent: false]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let signer = try HTTPSKeyReferenceSigner(key: key)
        XCTAssertThrowsError(try HTTPSKeyReferenceSigner(key: publicKey))
        try signer.validateUnattendedMatchingKey(publicKey)
        let message = Data("unhashed fixture message".utf8)
        let signature = try signer.signature(scheme: .ecdsaSecp256R1Sha256, message: message)
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil))
        XCTAssertThrowsError(try signer.signature(scheme: .rsaPkcs1Sha1, message: message))
        let denied = try HTTPSKeyReferenceSigner(key: key, unattendedPolicy: { throw HTTPSIdentityError.unattendedKeyAccessDenied })
        XCTAssertThrowsError(try denied.signature(scheme: .ecdsaSecp256R1Sha256, message: message)) {
            XCTAssertEqual($0 as? HTTPSIdentityError, .unattendedKeyAccessDenied)
        }
        let smallRSA: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024, kSecAttrIsPermanent: false]
        if let weak = SecKeyCreateRandomKey(smallRSA as CFDictionary, nil) { XCTAssertThrowsError(try HTTPSKeyReferenceSigner(key: weak)) }
    }
    func testSecKeyRSAPSSMessageSchemesWithoutPrivateExport() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let signer = try HTTPSKeyReferenceSigner(key: key)
        XCTAssertEqual(signer.signatureAlgorithms, [.rsaPssRsaeSha256, .rsaPssRsaeSha384, .rsaPssRsaeSha512])
        try signer.validateUnattendedMatchingKey(publicKey)
        for (scheme, algorithm) in [(SignatureAlgorithm.rsaPssRsaeSha256, SecKeyAlgorithm.rsaSignatureMessagePSSSHA256),
                                    (.rsaPssRsaeSha384, .rsaSignatureMessagePSSSHA384), (.rsaPssRsaeSha512, .rsaSignatureMessagePSSSHA512)] {
            let message = Data("unhashed RSA-PSS fixture message".utf8)
            let signature = try signer.signature(scheme: scheme, message: message)
            XCTAssertTrue(SecKeyVerifySignature(publicKey, algorithm, message as CFData, signature as CFData, nil))
        }
    }
    func testInjectedSecKeyIdentityValidatesCorrespondenceAndServesHandshakeWithoutExport() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecAttrIsPermanent: false]
        let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        // Only public material is exported to construct the ephemeral certificate.
        let point = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let root = try CertificateFixture(ca: true), leaf = try CertificateFixture(issuer: root, publicPoint: point)
        let bundle = HTTPSKeychainIdentity(certificateChainDER: [leaf.der, root.der], privateKey: key)
        let config = try HTTPSIdentityConfiguration(hostnames: ["api.example.test"])
        let identity = try HTTPSIdentityLoader().loadKeychain(selection: .persistentReference(Data([1])), configuration: config, lookup: { _ in bundle })
        let connection = try TLSConnection(identity: identity, root: root.der)
        // SecKey's async signer finishes off-loop; drain bounded event-loop passes until handshake completes.
        let deadline = Date().addingTimeInterval(3)
        while connection.clientState.handshakes == 0 && Date() < deadline {
            try connection.pump(); Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(connection.clientState.handshakes, 1); try connection.payload()
        let wrong = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let bad = HTTPSKeychainIdentity(certificateChainDER: [leaf.der], privateKey: wrong)
        XCTAssertThrowsError(try HTTPSIdentityLoader().loadKeychain(selection: .systemDomain("fixture"), configuration: config, lookup: { _ in bad })) {
            XCTAssertEqual($0 as? HTTPSIdentityError, .privateKeyMismatch)
        }
    }
    #endif
}
