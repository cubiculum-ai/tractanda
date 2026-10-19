internal import CNIOBoringSSL
internal import Foundation
// Tractanda first-party code; governed by the repository's LICENSE.
public import NIOCore
internal import NIOSSL
internal import NIOTLS

public enum PeerTLSError: Error, Equatable, Sendable {
    case invalidIdentity, invalidSecretLength, allocationFailed, randomGenerationFailed
    case authenticationPending, handshakeRejected, profileRejected, alreadyActive
}

/// The exact profile exercised by the macOS/Linux interoperability proof.
public struct PeerTLSProfile: Equatable, Sendable {
    public static let protocolName = "org.tractanda.peer-proof"
    public static let version = "1"
    public static let alpn = "tractanda-peer-proof/1"
    public let storeID: String
    public let initiatorReplicaID: String
    public let responderReplicaID: String
    public let pairingID: String

    public init(storeID: String, initiatorReplicaID: String, responderReplicaID: String, pairingID: String)
        throws
    {
        for value in [storeID, initiatorReplicaID, responderReplicaID, pairingID] {
            guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
                throw PeerTLSError.invalidIdentity
            }
            var bytes = uuid.uuid
            let valid = withUnsafeBytes(of: &bytes) { $0[6] >> 4 == 1 && $0[8] & 0xc0 == 0x80 }
            guard valid else { throw PeerTLSError.invalidIdentity }
        }
        guard initiatorReplicaID != responderReplicaID else { throw PeerTLSError.invalidIdentity }
        self.storeID = storeID
        self.initiatorReplicaID = initiatorReplicaID
        self.responderReplicaID = responderReplicaID
        self.pairingID = pairingID
    }

    internal var identity: [UInt8] { Array(pairingID.utf8) }
    internal var importerContext: [UInt8] {
        [
            Self.protocolName, Self.version, storeID, initiatorReplicaID, responderReplicaID,
            "initiator/tls-client", "responder/tls-server",
        ].flatMap { value in
            let bytes = Array(value.utf8)
            return [UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] + bytes
        }
    }
}

public enum PeerTLSRole: Equatable, Sendable { case initiator, responder }

/// Immutable, owned, cleansed storage. Callers own any copies supplied to the initializer.
/// Credentials are host-private inputs, never replicated configuration or session output.
public final class PeerTLSSecret: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let storage: UnsafeMutableRawPointer
    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw PeerTLSError.invalidSecretLength }
        guard let storage = OPENSSL_malloc(32) else { throw PeerTLSError.allocationFailed }
        self.storage = storage
        bytes.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: 32) }
    }
    private init(random: Void) throws {
        guard let storage = OPENSSL_malloc(32) else { throw PeerTLSError.allocationFailed }
        guard RAND_bytes(storage.assumingMemoryBound(to: UInt8.self), 32) == 1 else {
            OPENSSL_cleanse(storage, 32)
            OPENSSL_free(storage)
            throw PeerTLSError.randomGenerationFailed
        }
        self.storage = storage
    }
    public static func generate() throws -> PeerTLSSecret { try .init(random: ()) }
    deinit {
        OPENSSL_cleanse(storage, 32)
        OPENSSL_free(storage)
    }
    public var description: String { "PeerTLSSecret(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }
    internal func withBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try body(.init(start: storage.assumingMemoryBound(to: UInt8.self), count: 32))
    }
}

/// Initialized before channel use, then only read; upstream SSL_CTX is thread safe when immutable.
public final class PeerTLSContext: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public let profile: PeerTLSProfile
    public let role: PeerTLSRole
    private let native: NIOSSLContext
    fileprivate let secret: PeerTLSSecret
    public init(profile: PeerTLSProfile, role: PeerTLSRole, secret: PeerTLSSecret) throws {
        self.profile = profile
        self.role = role
        self.secret = secret
        self.native = try secret.withBytes {
            try NIOSSLContext(
                tractandaKey: $0, identity: profile.identity, context: profile.importerContext,
                alpn: PeerTLSProfile.alpn)
        }
    }
    public var description: String { "PeerTLSContext(profile-v1)" }
    public var customMirror: Mirror { Mirror(self, children: ["profile": profile], displayStyle: .class) }

    /// Install before activation/application handlers. No callback, active event or plaintext
    /// crosses the gate until the exact imported-PSK profile has authenticated.
    public func install(
        on channel: any Channel, onAuthenticated: @escaping @Sendable (PeerTLSSession) -> Void
    ) -> EventLoopFuture<Void> {
        installPeerTLS(
            on: channel, native: native, profiles: [profile.identity: profile], role: role,
            onAuthenticated: onAuthenticated)
    }
}

/// One immutable responder snapshot. Only authenticated selected identities escape its gate.
/// The caller must still check current Store configuration and membership before application use.
public final class PeerTLSResponderContext: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public static let maximumContexts = 256
    private let native: NIOSSLContext
    private let profiles: [[UInt8]: PeerTLSProfile]

    public init(contexts: [PeerTLSContext]) throws {
        guard !contexts.isEmpty, contexts.count <= Self.maximumContexts else {
            throw PeerTLSError.invalidIdentity
        }
        let first = contexts[0]
        var profiles: [[UInt8]: PeerTLSProfile] = [:]
        for context in contexts {
            let profile = context.profile
            guard context.role == .responder,
                profile.storeID == first.profile.storeID,
                profile.responderReplicaID == first.profile.responderReplicaID,
                profiles.updateValue(profile, forKey: profile.identity) == nil
            else { throw PeerTLSError.invalidIdentity }
        }
        let native = try first.secret.withBytes {
            try NIOSSLContext(
                tractandaKey: $0, identity: first.profile.identity, context: first.profile.importerContext,
                alpn: PeerTLSProfile.alpn)
        }
        for context in contexts.dropFirst() {
            try context.secret.withBytes {
                try native.tractandaInstallPSK(
                    key: $0, identity: context.profile.identity, context: context.profile.importerContext)
            }
        }
        self.native = native
        self.profiles = profiles
    }

    public var description: String { "PeerTLSResponderContext(profile-v1)" }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

    public func install(
        on channel: any Channel, onAuthenticated: @escaping @Sendable (PeerTLSSession) -> Void
    ) -> EventLoopFuture<Void> {
        installPeerTLS(
            on: channel, native: native, profiles: profiles, role: .responder,
            onAuthenticated: onAuthenticated)
    }
}

private func installPeerTLS(
    on channel: any Channel, native: NIOSSLContext, profiles: [[UInt8]: PeerTLSProfile], role: PeerTLSRole,
    onAuthenticated: @escaping @Sendable (PeerTLSSession) -> Void
) -> EventLoopFuture<Void> {
    channel.eventLoop.submit {
        guard !channel.isActive else { throw PeerTLSError.alreadyActive }
        let tls: NIOSSLHandler
        switch role {
        case .initiator: tls = try NIOSSLClientHandler(context: native, serverHostname: nil)
        case .responder: tls = NIOSSLServerHandler(context: native)
        }
        let gate = PeerTLSGate(
            tls: tls, profiles: profiles, role: role, onAuthenticated: onAuthenticated)
        try channel.pipeline.syncOperations.addHandlers([tls, gate])
    }
}

/// A TLS identity binding only. The Store separately validates current trust and permissions.
public struct PeerTLSSession: Equatable, Sendable {
    public let profile: PeerTLSProfile
    public let localReplicaID: String
    public let remoteReplicaID: String
    public let cipherSuite: UInt16
    public let keyExchangeGroup: UInt16
    internal init(profile: PeerTLSProfile, role: PeerTLSRole) {
        self.profile = profile
        self.localReplicaID = role == .initiator ? profile.initiatorReplicaID : profile.responderReplicaID
        self.remoteReplicaID = role == .initiator ? profile.responderReplicaID : profile.initiatorReplicaID
        self.cipherSuite = 0x1302
        self.keyExchangeGroup = 0x11ec
    }
}

private final class PeerTLSGate: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let tls: NIOSSLHandler
    private let profiles: [[UInt8]: PeerTLSProfile]
    private let role: PeerTLSRole
    private let onAuthenticated: @Sendable (PeerTLSSession) -> Void
    private var authenticated = false
    private var failed = false
    private var activeReceived = false

    init(
        tls: NIOSSLHandler, profiles: [[UInt8]: PeerTLSProfile], role: PeerTLSRole,
        onAuthenticated: @escaping @Sendable (PeerTLSSession) -> Void
    ) {
        self.tls = tls
        self.profiles = profiles
        self.role = role
        self.onAuthenticated = onAuthenticated
    }
    func channelActive(context: ChannelHandlerContext) { activeReceived = true }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case TLSUserEvent.handshakeCompleted(let negotiatedProtocol) = event else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        guard !failed && !authenticated else { return }
        let facts = tls.tractandaFacts()
        guard let identity = facts.identity, let profile = profiles[identity],
            facts.version == 0x0304, facts.group == 0x11ec, facts.cipher == 0x1302,
            facts.server == (role == .responder),
            !facts.certificate, !facts.earlyData, facts.ticketMessages == 0,
            negotiatedProtocol == PeerTLSProfile.alpn
        else {
            reject(context, error: .profileRejected)
            return
        }
        authenticated = true
        let session = PeerTLSSession(profile: profile, role: role)
        onAuthenticated(session)
        context.fireUserInboundEventTriggered(session)
        if activeReceived { context.fireChannelActive() }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard authenticated && !failed else {
            reject(context, error: .authenticationPending)
            return
        }
        context.fireChannelRead(data)
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        if authenticated && !failed { context.fireChannelReadComplete() }
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard authenticated && !failed else {
            promise?.fail(PeerTLSError.authenticationPending)
            return
        }
        context.write(data, promise: promise)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reject(context, error: .handshakeRejected)
    }
    private func reject(_ context: ChannelHandlerContext, error: PeerTLSError) {
        guard !failed else { return }
        failed = true
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
