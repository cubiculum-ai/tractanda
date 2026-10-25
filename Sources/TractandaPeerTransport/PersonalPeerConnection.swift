import Foundation
import NIOCore
import TractandaCore
import TractandaPeerTLS

/// Personal wire operations are deliberately disjoint from the historical authority gateway.
package struct PersonalPeerOperations: Sendable {
    package let validate: @Sendable (PeerExchangeBinding) async throws -> Void
    package let handle: @Sendable (PeerExchangeBinding, PeerExchangeRequest) async throws -> Data
    package init(
        validate: @escaping @Sendable (PeerExchangeBinding) async throws -> Void,
        handle: @escaping @Sendable (PeerExchangeBinding, PeerExchangeRequest) async throws -> Data
    ) {
        self.validate = validate
        self.handle = handle
    }
}

package struct PersonalPeerLimits: Sendable {
    package var handshakeSeconds: Double = 86_400
    /// A finite single-operation/partial-frame budget, not an overall transfer deadline.
    package var operationSeconds: Double = 86_400
    package init() {}
    package static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> Self
    {
        var value = Self()
        for (name, assign) in [
            ("TRACTANDA_PERSONAL_PEER_HANDSHAKE_SECONDS", true),
            ("TRACTANDA_PERSONAL_PEER_OPERATION_SECONDS", false),
        ] {
            if let text = environment[name] {
                guard let seconds = Double(text) else {
                    throw TractandaError(
                        "invalidConfiguration", "Invalid configured personal peer time budget.")
                }
                if assign { value.handshakeSeconds = seconds } else { value.operationSeconds = seconds }
            }
        }
        try value.validate()
        return value
    }
    package func validate() throws {
        guard handshakeSeconds.isFinite, handshakeSeconds > 0, handshakeSeconds <= 604_800,
            operationSeconds.isFinite, operationSeconds > 0, operationSeconds <= 604_800
        else { throw TractandaError("resourceLimit", "Invalid personal peer budgets.") }
    }
}

/// Both ends may issue requests after the symmetric personal capability exchange. Each
/// direction has one bounded outstanding request; no authority declaration can enter Core.
package final class PersonalPeerConnection: Sendable {
    package let ready: EventLoopFuture<PeerExchangeBinding>
    private let channel: any Channel
    private let handler: NIOLoopBound<PersonalPeerHandler>
    package var isActive: Bool { channel.isActive }
    package var closed: EventLoopFuture<Void> { channel.closeFuture }
    private init(channel: any Channel, handler: PersonalPeerHandler) {
        self.channel = channel
        self.handler = NIOLoopBound(handler, eventLoop: channel.eventLoop)
        ready = handler.ready.futureResult
    }
    package static func install(
        on channel: any Channel, pairing: PeerPairing, operations: PersonalPeerOperations,
        limits: PersonalPeerLimits = .init()
    ) -> EventLoopFuture<PersonalPeerConnection> {
        do { try limits.validate() } catch { return channel.eventLoop.makeFailedFuture(error) }
        return pairing.tls.install(on: channel) { _ in }.flatMap {
            channel.eventLoop.submit {
                let handler = PersonalPeerHandler(
                    pairings: [pairing.tls.profile.pairingID: pairing], operations: operations,
                    limits: limits, loop: channel.eventLoop)
                try channel.pipeline.syncOperations.addHandler(handler)
                return PersonalPeerConnection(channel: channel, handler: handler)
            }
        }
    }
    package static func install(
        on channel: any Channel, responder: PeerExchangeResponder,
        operations: PersonalPeerOperations, limits: PersonalPeerLimits = .init()
    ) -> EventLoopFuture<PersonalPeerConnection> {
        do { try limits.validate() } catch { return channel.eventLoop.makeFailedFuture(error) }
        return responder.tls.install(on: channel) { _ in }.flatMap {
            channel.eventLoop.submit {
                let handler = PersonalPeerHandler(
                    pairings: responder.pairings, operations: operations, limits: limits,
                    loop: channel.eventLoop)
                try channel.pipeline.syncOperations.addHandler(handler)
                return PersonalPeerConnection(channel: channel, handler: handler)
            }
        }
    }
    package func request(_ request: PeerExchangeRequest) -> EventLoopFuture<Data> {
        let handler = handler
        return channel.eventLoop.flatSubmit {
            do { return try handler.value.request(request) } catch {
                return self.channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
    package func close() -> EventLoopFuture<Void> { channel.close() }
}

private struct PersonalPeerHello: Codable, Equatable {
    let capability: String
    let storeID: String
    let senderReplicaID: String
    let receiverReplicaID: String
    let pairingID: String
    let configurationDigest: String
    init(_ binding: PeerExchangeBinding, remote: Bool = false) {
        capability = "tractanda.personal-sync.v1"
        storeID = binding.storeID
        senderReplicaID = remote ? binding.remoteReplicaID : binding.localReplicaID
        receiverReplicaID = remote ? binding.localReplicaID : binding.remoteReplicaID
        pairingID = binding.pairingID
        configurationDigest = binding.configurationDigest
    }
}

private struct PersonalPeerFailure: Codable {
    let code: String
    let message: String
}

private final class PersonalPeerHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let ready: EventLoopPromise<PeerExchangeBinding>
    private let pairings: [String: PeerPairing]
    private let operations: PersonalPeerOperations
    private let limits: PersonalPeerLimits
    private var context: ChannelHandlerContext?
    private var input: ByteBuffer?
    private var binding: PeerExchangeBinding?
    private var remoteHello: Data?
    private var helloSent = false
    private var established = false
    private var failed = false
    private var inboundID: UInt64 = 0
    private var outboundID: UInt64 = 0
    private var pending: (UInt64, EventLoopPromise<Data>)?
    private var inboundTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var handshakeTimer: Scheduled<Void>?
    private var inboundTimer: Scheduled<Void>?
    private var outboundTimer: Scheduled<Void>?
    private var frameTimer: Scheduled<Void>?

    init(
        pairings: [String: PeerPairing], operations: PersonalPeerOperations,
        limits: PersonalPeerLimits, loop: any EventLoop
    ) {
        self.pairings = pairings
        self.operations = operations
        self.limits = limits
        ready = loop.makePromise()
    }
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        handshakeTimer = context.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.handshakeSeconds * 1_000_000_000))
        ) {
            bound.value.fail(TractandaError("deadlineExceeded", "Personal capability handshake expired."))
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let session = event as? PeerTLSSession else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        guard binding == nil, attachTask == nil, !failed,
            let pairing = pairings[session.profile.pairingID]
        else {
            fail(TractandaError("untrustedPeer", "Unknown or repeated personal peer authentication."))
            return
        }
        do {
            let binding = try pairing.resolve(session)
            self.binding = binding
            let operations = operations
            let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            attachTask = Task {
                let result: Result<Void, Error>
                do {
                    try await operations.validate(binding)
                    try Task.checkCancellation()
                    result = .success(())
                } catch { result = .failure(error) }
                loop.execute {
                    let owner = bound.value
                    owner.attachTask = nil
                    guard !owner.failed else { return }
                    do {
                        try result.get()
                        try owner.write(
                            .init(
                                version: 3, requestID: 0, kind: .declaration,
                                body: JSON.encode(PersonalPeerHello(binding))))
                        owner.helloSent = true
                        try owner.finishHello()
                    } catch { owner.fail(error) }
                }
            }
        } catch { fail(error) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed, binding != nil else {
            fail(TractandaError("untrustedPeer", "Personal bytes preceded TLS authentication."))
            return
        }
        var incoming = unwrapInboundIn(data)
        do {
            while incoming.readableBytes > 0 {
                if input == nil {
                    let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
                    frameTimer = context.eventLoop.scheduleTask(
                        in: .nanoseconds(Int64(limits.operationSeconds * 1_000_000_000))
                    ) {
                        bound.value.fail(
                            TractandaError("deadlineExceeded", "Personal partial frame expired."))
                    }
                }
                var frame = input ?? context.channel.allocator.buffer(capacity: 4)
                if frame.readableBytes < 4 {
                    let count = min(4 - frame.readableBytes, incoming.readableBytes)
                    if var bytes = incoming.readSlice(length: count) { frame.writeBuffer(&bytes) }
                    guard frame.readableBytes == 4 else {
                        input = frame
                        return
                    }
                }
                guard let size = frame.getInteger(at: frame.readerIndex, as: UInt32.self),
                    size > 0, size <= (established ? PeerExchangeCodec.maximumFrameBytes : 8192)
                else {
                    throw TractandaError("resourceLimit", "Personal frame exceeds wire bound.")
                }
                let count = min(4 + Int(size) - frame.readableBytes, incoming.readableBytes)
                if var bytes = incoming.readSlice(length: count) { frame.writeBuffer(&bytes) }
                guard frame.readableBytes == 4 + Int(size) else {
                    input = frame
                    return
                }
                frame.moveReaderIndex(forwardBy: 4)
                let bytes = Data(frame.readBytes(length: Int(size))!)
                input = nil
                frameTimer?.cancel()
                frameTimer = nil
                let decoded = try PeerExchangeCodec.decode(bytes, expectedVersion: 3)
                try receive(decoded)
            }
        } catch { fail(error) }
    }
    private func finishHello() throws {
        guard helloSent, let binding, let remoteHello, !established else { return }
        guard remoteHello.count <= 4096,
            try JSON.decode(PersonalPeerHello.self, remoteHello) == PersonalPeerHello(binding, remote: true),
            try JSON.encode(JSON.decode(PersonalPeerHello.self, remoteHello)) == remoteHello
        else {
            throw TractandaError("incompatiblePeer", "Personal capability or authenticated identity differs.")
        }
        established = true
        handshakeTimer?.cancel()
        handshakeTimer = nil
        ready.succeed(binding)
    }
    private func receive(_ frame: PeerExchangeCodec.Frame) throws {
        if !established {
            guard frame.kind == .declaration, frame.requestID == 0, remoteHello == nil,
                frame.body.count <= 4096
            else {
                throw TractandaError("incompatiblePeer", "Personal capability must precede operations.")
            }
            remoteHello = frame.body
            try finishHello()
            return
        }
        switch frame.kind {
        case .request:
            guard inboundID < UInt64.max, frame.requestID == inboundID + 1, inboundTask == nil, let binding,
                let context
            else {
                throw TractandaError(
                    "invalidPeerFrame", "Personal request is out of order or already active.")
            }
            let request = try PeerExchangeRequest.decode(frame.body)
            guard request.operation.hasPrefix("personal."), request.operation.utf8.count <= 128 else {
                throw TractandaError("unsupportedPeerOperation", "Only personal operations are admitted.")
            }
            inboundID = frame.requestID
            let operations = operations
            let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
            let loop = context.eventLoop
            inboundTimer = timer(context)
            inboundTask = Task {
                let result: Result<Data, Error>
                do {
                    try await operations.validate(binding)
                    let response = try await operations.handle(binding, request)
                    try Task.checkCancellation()
                    try await operations.validate(binding)
                    result = .success(response)
                } catch { result = .failure(error) }
                loop.execute {
                    let owner = bound.value
                    owner.inboundTask = nil
                    owner.inboundTimer?.cancel()
                    owner.inboundTimer = nil
                    guard !owner.failed else { return }
                    do {
                        switch result {
                        case .success(let response):
                            try owner.write(
                                .init(version: 3, requestID: frame.requestID, kind: .response, body: response)
                            )
                        case .failure(let error):
                            let error = error as? TractandaError
                            try owner.write(
                                .init(
                                    version: 3, requestID: frame.requestID, kind: .failure,
                                    body: JSON.encode(
                                        PersonalPeerFailure(
                                            code: error?.code ?? "peerOperationFailed",
                                            message: error?.message ?? "Personal peer operation failed."))))
                        }
                    } catch { owner.fail(error) }
                }
            }
        case .response, .failure:
            guard let pending, pending.0 == frame.requestID else {
                throw TractandaError("invalidPeerFrame", "Unsolicited personal response.")
            }
            let failure = frame.kind == .failure ? try JSON.decode(PersonalPeerFailure.self, frame.body) : nil
            self.pending = nil
            outboundTimer?.cancel()
            outboundTimer = nil
            if let failure {
                pending.1.fail(TractandaError(failure.code, failure.message))
            } else {
                pending.1.succeed(frame.body)
            }
        default: throw TractandaError("invalidPeerFrame", "Repeated personal handshake control.")
        }
    }
    func request(_ request: PeerExchangeRequest) throws -> EventLoopFuture<Data> {
        guard established, !failed, pending == nil, let context,
            request.operation.hasPrefix("personal."), request.operation.utf8.count <= 128,
            outboundID < UInt64.max
        else {
            throw TractandaError(
                "serviceBusy", "Personal session is unavailable or has an outstanding request.")
        }
        let body = try JSON.encode(request)
        outboundID += 1
        let promise = context.eventLoop.makePromise(of: Data.self)
        pending = (outboundID, promise)
        do {
            try write(.init(version: 3, requestID: outboundID, kind: .request, body: body))
            outboundTimer = timer(context)
        } catch {
            pending = nil
            promise.fail(error)
            throw error
        }
        return promise.futureResult
    }
    private func timer(_ context: ChannelHandlerContext) -> Scheduled<Void> {
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        return context.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.operationSeconds * 1_000_000_000))
        ) {
            bound.value.fail(TractandaError("deadlineExceeded", "Personal peer operation expired."))
        }
    }
    private func write(_ frame: PeerExchangeCodec.Frame) throws {
        guard let context, !failed else { throw TractandaError("serviceClosed", "Personal peer is closed.") }
        let buffer = try PeerExchangeCodec.encode(frame, allocator: context.channel.allocator)
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenFailure { bound.value.fail($0) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        fail(TractandaError("connectionClosed", "Personal peer disconnected."))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error) }
    private func fail(_ error: any Error) {
        guard !failed else { return }
        failed = true
        handshakeTimer?.cancel()
        inboundTimer?.cancel()
        outboundTimer?.cancel()
        frameTimer?.cancel()
        attachTask?.cancel()
        inboundTask?.cancel()
        if !established { ready.fail(error) }
        pending?.1.fail(error)
        pending = nil
        input = nil
        context?.close(promise: nil)
    }
}
