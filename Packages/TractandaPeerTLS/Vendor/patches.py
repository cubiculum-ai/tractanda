"""Minimal, exact upstream Swift changes; C/C++ and public upstream API are unchanged."""
CONTEXT = r'''
// Tractanda addition: package-only immutable imported-PSK context construction.
extension NIOSSLContext {
    package convenience init(tractandaKey: UnsafeBufferPointer<UInt8>, identity: [UInt8], context: [UInt8], alpn: String) throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .none
        configuration.trustRoots = .certificates([])
        configuration.curves = [.x25519_MLKEM768]
        configuration.applicationProtocols = [alpn]
        try self.init(configuration: configuration)
        try self.tractandaInstallPSK(key: tractandaKey, identity: identity, context: context)
    }

    package func tractandaInstallPSK(key: UnsafeBufferPointer<UInt8>, identity: [UInt8], context: [UInt8]) throws {
        let credential = identity.withUnsafeBufferPointer { identity in
            context.withUnsafeBufferPointer { context in
                SSL_CREDENTIAL_new_pre_shared_key(key.baseAddress, key.count, identity.baseAddress,
                    identity.count, EVP_sha256(), context.baseAddress, context.count)
            }
        }
        guard let credential else { throw BoringSSLError.unknownError(BoringSSLError.buildErrorStack()) }
        defer { SSL_CREDENTIAL_free(credential) }
        guard SSL_CTX_add1_credential(self.sslContext, credential) == 1 else {
            throw BoringSSLError.unknownError(BoringSSLError.buildErrorStack())
        }
        SSL_CTX_set_num_tickets(self.sslContext, 0)
        SSL_CTX_set_session_cache_mode(self.sslContext, SSL_SESS_CACHE_OFF)
        SSL_CTX_set_early_data_enabled(self.sslContext, 0)
        SSL_CTX_set_options(self.sslContext, UInt32(SSL_OP_NO_TICKET))
        var cipher: UInt16 = 0x1302
        guard SSL_CTX_set1_tls13_ciphers(self.sslContext, &cipher, nil, 1) == 1 else {
            throw BoringSSLError.unknownError(BoringSSLError.buildErrorStack())
        }
    }
}
'''
CONNECTION = r'''
// Tractanda addition: package-only authentication facts; never exports keys/native pointers.
package struct TractandaTLSFacts {
    package let version: UInt16
    package let group: UInt16
    package let cipher: UInt16
    package let identity: [UInt8]?
    package let server: Bool
    package let certificate: Bool
    package let earlyData: Bool
    package let ticketMessages: Int
}
extension SSLConnection {
    func tractandaFacts() -> TractandaTLSFacts {
        .init(version: UInt16(SSL_version(self.ssl)), group: SSL_get_group_id(self.ssl),
            cipher: SSL_get_current_cipher(self.ssl).map { SSL_CIPHER_get_protocol_id($0) } ?? 0,
            identity: self.tractandaSelectedIdentity, server: SSL_is_server(self.ssl) != 0,
            certificate: SSL_get0_peer_certificates(self.ssl) != nil,
            earlyData: SSL_early_data_accepted(self.ssl) != 0, ticketMessages: self.tractandaTicketMessages)
    }
}
'''
HANDLER = r'''
// Tractanda addition: package-only facts on the owning event loop.
extension NIOSSLHandler {
    package func tractandaFacts() -> TractandaTLSFacts { self.connection.tractandaFacts() }
}
'''
CALLBACK = r'''
        // Capture only public credential identity and handshake message type, never message bodies.
        SSL_set_info_callback(self.ssl) { ssl, event, _ in
            guard let ssl, event & SSL_CB_HANDSHAKE_DONE != 0,
                  let credential = SSL_get0_selected_credential(ssl) else { return }
            var count = 0
            if let identity = SSL_CREDENTIAL_get0_pre_shared_key_id(credential, &count) {
                SSLConnection.loadConnectionFromSSL(ssl).tractandaSelectedIdentity =
                    Array(UnsafeBufferPointer(start: identity, count: count))
            }
        }
        SSL_set_msg_callback(self.ssl) { _, _, contentType, bytes, count, ssl, _ in
            guard contentType == 22, count > 0, let bytes, let ssl else { return }
            if bytes.load(as: UInt8.self) == 4 {
                SSLConnection.loadConnectionFromSSL(ssl).tractandaTicketMessages += 1
            }
        }
'''


def patch(path, original):
    text = original.decode()
    if path == "Sources/NIOSSL/SSLContext.swift":
        return (text + CONTEXT).encode()
    if path == "Sources/NIOSSL/SSLConnection.swift":
        needle = "    private let ssl: OpaquePointer"
        assert text.count(needle) == 1
        text = text.replace(needle, "    internal var tractandaSelectedIdentity: [UInt8]?\n    internal var tractandaTicketMessages = 0\n" + needle)
        needle = "        self.setRenegotiationSupport(self.parentContext.configuration.renegotiationSupport)"
        assert text.count(needle) == 1
        text = text.replace(needle, needle + "\n" + CALLBACK)
        return (text + CONNECTION).encode()
    if path == "Sources/NIOSSL/NIOSSLHandler.swift":
        return (text + HANDLER).encode()
    return original
