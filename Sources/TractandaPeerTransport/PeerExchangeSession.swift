import Dispatch
import Foundation
import NIOCore
import TractandaCore
import TractandaPeerTLS

package struct PeerExchangeLimits: Sendable {
    package var maximumRequests = 1024
    package var maximumWireBytes = 64 * 1024 * 1024
    package var operationSeconds: Double = 30
    package var sessionSeconds: Double = 300
    package init() {}
    func validate() throws {
        guard (1...4096).contains(maximumRequests), maximumWireBytes >= 4096,
            maximumWireBytes <= 256 * 1024 * 1024,
            operationSeconds.isFinite, operationSeconds > 0, operationSeconds <= 60,
            sessionSeconds.isFinite, sessionSeconds > 0, sessionSeconds <= 3600
        else { throw TractandaError("resourceLimit", "Invalid peer session limits.") }
    }
}

/// Host-private immutable admission snapshot. Current authority is checked by the gateway,
/// not by possession of a credential retained here.
package final class PeerExchangeResponder: Sendable {
    let tls: PeerTLSResponderContext
    let pairings: [String: PeerPairing]

    package init(pairings: [PeerPairing]) throws {
        guard Set(pairings.map { $0.tls.profile.pairingID }).count == pairings.count else {
            throw TractandaError(
                "invalidPeerCredential", "Duplicate TLS pairing identities are not admitted.")
        }
        tls = try PeerTLSResponderContext(contexts: pairings.map(\.tls))
        self.pairings = Dictionary(uniqueKeysWithValues: pairings.map { ($0.tls.profile.pairingID, $0) })
    }
}

package typealias PeerLogicalLeaseFactory =
    @Sendable (PeerExchangeBinding, @escaping @Sendable () async -> Void) async throws ->
    PeerLogicalExchange.Lease

/// Package-only connection, installed on an inactive channel before TLS/application activity.
package final class PeerExchangeConnection: Sendable {
    private let channel: any Channel
    private let handler: NIOLoopBound<PeerExchangeHandler>
    package let ready: EventLoopFuture<Void>
    package var isActive: Bool { channel.isActive }
    package var closed: EventLoopFuture<Void> { channel.closeFuture }
    fileprivate init(channel: any Channel, handler: PeerExchangeHandler) {
        self.channel = channel
        self.handler = NIOLoopBound(handler, eventLoop: channel.eventLoop)
        ready = handler.ready.futureResult
    }
    package static func install(
        on channel: any Channel, pairing: PeerPairing, coordinator: ServiceCoordinator,
        limits: PeerExchangeLimits = .init(),
        authorizeAdmission: @escaping @Sendable () async throws -> Void = {},
        logicalLease: PeerLogicalLeaseFactory? = nil
    ) -> EventLoopFuture<PeerExchangeConnection> {
        do { try limits.validate() } catch { return channel.eventLoop.makeFailedFuture(error) }
        return pairing.tls.install(on: channel) { _ in }.flatMap {
            channel.eventLoop.submit {
                let handler = PeerExchangeHandler(
                    pairings: [pairing.tls.profile.pairingID: pairing], coordinator: coordinator,
                    limits: limits, loop: channel.eventLoop, authorizeAdmission: authorizeAdmission,
                    logicalLease: logicalLease)
                try channel.pipeline.syncOperations.addHandler(handler)
                return PeerExchangeConnection(channel: channel, handler: handler)
            }
        }
    }
    package static func install(
        on channel: any Channel, responder: PeerExchangeResponder, coordinator: ServiceCoordinator,
        limits: PeerExchangeLimits = .init(),
        authorizeAdmission: @escaping @Sendable () async throws -> Void = {},
        logicalLease: PeerLogicalLeaseFactory? = nil
    ) -> EventLoopFuture<PeerExchangeConnection> {
        do { try limits.validate() } catch { return channel.eventLoop.makeFailedFuture(error) }
        return responder.tls.install(on: channel) { _ in }.flatMap {
            channel.eventLoop.submit {
                let handler = PeerExchangeHandler(
                    pairings: responder.pairings, coordinator: coordinator,
                    limits: limits, loop: channel.eventLoop, authorizeAdmission: authorizeAdmission,
                    logicalLease: logicalLease)
                try channel.pipeline.syncOperations.addHandler(handler)
                return PeerExchangeConnection(channel: channel, handler: handler)
            }
        }
    }
    package func request(_ request: PeerExchangeRequest) -> EventLoopFuture<Data> {
        let handler = handler
        let loop = channel.eventLoop
        return loop.flatSubmit {
            do { return try handler.value.request(request) } catch { return loop.makeFailedFuture(error) }
        }
    }
    /// Bind only this actual ready physical session into the host-owned local continuation.
    package func admitLocalContinuation(
        _ lease: PeerLogicalExchange.Lease, expectedBinding: PeerExchangeBinding,
        control: PeerExchangeControl
    ) async throws {
        let handler = handler
        let admission = try await channel.eventLoop.submit {
            try handler.value.currentAdmission(expectedBinding: expectedBinding, control: control)
        }.get()
        try await lease.adoptCompatibility(admission, expectedBinding: expectedBinding, control: control)
        // The session may have failed while adoption waited on the Store owner.
        _ = try await channel.eventLoop.submit {
            try handler.value.currentAdmission(expectedBinding: expectedBinding, control: control)
        }.get()
        try admission.checkLifetime()
        try control.check()
    }
    package func close() -> EventLoopFuture<Void> { channel.close() }
}

/// Mutable fields below are confined to the channel's event loop. Store work runs off-loop.
final class PeerExchangeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let ready: EventLoopPromise<Void>
    private let pairings: [String: PeerPairing]
    private let coordinator: ServiceCoordinator
    private let limits: PeerExchangeLimits
    private let authorizeAdmission: @Sendable () async throws -> Void
    private let logicalLease: PeerLogicalLeaseFactory?
    private var context: ChannelHandlerContext?
    private var input: ByteBuffer?
    private var gateway: PeerExchangeGateway?
    private var task: Task<Void, Never>?
    private var control: PeerExchangeControl?
    private var operationDeadline: Scheduled<Void>?
    private var partialFrameDeadline: Scheduled<Void>?
    private var preflightDeadline: Scheduled<Void>?
    private var preflightControl: PeerExchangeControl?
    private var sessionDeadline: Scheduled<Void>?
    private var inboundID: UInt64 = 0
    private var outboundID: UInt64 = 0
    private var requests = 0
    private var received = 0
    private var sent = 0
    private var failed = false
    private var readyFinished = false
    private var authenticating = false
    private var active = false
    private var pending: (UInt64, EventLoopPromise<Data>)?
    private var preflightReceived = 0
    private var preflightFrames: [PeerExchangeCodec.Frame] = []
    private var localCommitted = false
    private var remoteReadyReceived = false
    private var ownReadyFlushed = false
    private var ownAckSent = false
    private var ownAckFlushed = false
    private var remoteAckValidated = false
    private var finalizing = false
    private let compatibilityLifetime = PeerCompatibilityLifetime()
    private var admittedCompatibility: PeerCompatibilityAdmission?
    init(
        pairings: [String: PeerPairing], coordinator: ServiceCoordinator,
        limits: PeerExchangeLimits, loop: any EventLoop,
        authorizeAdmission: @escaping @Sendable () async throws -> Void,
        logicalLease: PeerLogicalLeaseFactory?
    ) {
        self.pairings = pairings
        self.coordinator = coordinator
        self.limits = limits
        self.authorizeAdmission = authorizeAdmission
        self.logicalLease = logicalLease
        ready = loop.makePromise()
    }
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        sessionDeadline = context.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.sessionSeconds * 1_000_000_000))
        ) {
            bound.value.fail(TractandaError("peerSessionExhausted", "Peer session deadline exceeded."))
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let session = event as? PeerTLSSession else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        guard task == nil, gateway == nil, !failed else {
            fail(TractandaError("untrustedPeer", "Repeated authentication event."))
            return
        }
        let binding: PeerExchangeBinding
        let control: PeerExchangeControl
        do {
            guard let pairing = pairings[session.profile.pairingID] else {
                throw TractandaError("untrustedPeer", "Authenticated TLS pairing is not admitted.")
            }
            binding = try pairing.resolve(session)
            control = try PeerExchangeControl(
                maximumSeconds: min(limits.operationSeconds, limits.sessionSeconds))
        } catch {
            fail(error)
            return
        }
        self.control = control
        self.preflightControl = control
        startDeadline(context)  // Binding, declarations/acks/READY and final readiness share this deadline.
        preflightDeadline = operationDeadline
        operationDeadline = nil
        authenticating = true
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        let coordinator = coordinator
        let authorizeAdmission = authorizeAdmission
        let logicalLease = logicalLease
        let channel = context.channel
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        task = Task {
            let result: Result<(PeerExchangeGateway, Data), Error>
            do {
                try await authorizeAdmission()
                let lease = try await logicalLease?(binding, { _ = try? await channel.close().get() })
                do {
                    let gateway = try await PeerExchangeGateway(
                        coordinator: coordinator,
                        binding: binding, control: control, logicalLease: lease)
                    do {
                        result = .success(
                            (gateway, try await gateway.advanceCompatibility(.declare, control: control)))
                    } catch {
                        await gateway.detachLogicalLease()
                        throw error
                    }
                } catch {
                    await lease?.detach()
                    throw error
                }
            } catch { result = .failure(error) }
            loop.execute {
                let handler = bound.value
                guard !handler.failed else {
                    if case .success(let (gateway, _)) = result {
                        Task { await gateway.detachLogicalLease() }
                    }
                    return
                }
                handler.task = nil
                switch result {
                case .success(let (gateway, declaration)):
                    do { try control.check() } catch {
                        Task { await gateway.detachLogicalLease() }
                        handler.fail(error)
                        return
                    }
                    handler.gateway = gateway
                    handler.authenticating = false
                    do {
                        _ = try handler.write(
                            .init(version: 2, requestID: 0, kind: .declaration, body: declaration))
                        if let context = handler.context {
                            _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
                            handler.processPreflight()
                            context.read()
                        }
                    } catch { handler.fail(error) }
                case .failure(let error): handler.fail(error)
                }
            }
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed, gateway != nil || authenticating else {
            fail(TractandaError("untrustedPeer", "Peer gateway is not authenticated/current."))
            return
        }
        var part = unwrapInboundIn(data)
        guard part.readableBytes <= limits.maximumWireBytes - received else {
            fail(TractandaError("peerSessionExhausted", "Peer inbound byte budget exhausted."))
            return
        }
        received += part.readableBytes
        do {
            while part.readableBytes > 0 {
                guard localCommitted || preflightReceived < 3 else {
                    throw TractandaError(
                        "invalidPeerFrame", "Ordinary bytes preceded local compatibility commit.")
                }
                if localCommitted, active {
                    throw TractandaError("serviceBusy", "Peer operation already active.")
                }
                if input == nil { startPartialFrameDeadline(context) }
                var buffer = input ?? context.channel.allocator.buffer(capacity: 4)
                if buffer.readableBytes < 4 {
                    let count = min(4 - buffer.readableBytes, part.readableBytes)
                    if var header = part.readSlice(length: count) { buffer.writeBuffer(&header) }
                    guard buffer.readableBytes == 4 else {
                        input = buffer
                        return
                    }
                }
                let maximum =
                    !localCommitted && preflightReceived < 3 ? 96 * 1024 : PeerExchangeCodec.maximumFrameBytes
                guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
                    length > 0, length <= maximum
                else { throw TractandaError("resourceLimit", "Invalid peer frame length.") }
                let count = min(4 + Int(length) - buffer.readableBytes, part.readableBytes)
                if var body = part.readSlice(length: count) { buffer.writeBuffer(&body) }
                guard buffer.readableBytes == 4 + Int(length) else {
                    input = buffer
                    return
                }
                buffer.moveReaderIndex(forwardBy: 4)
                guard let bytes = buffer.readBytes(length: Int(length)) else {
                    throw TractandaError("invalidPeerFrame", "Truncated peer frame.")
                }
                input = nil
                partialFrameDeadline?.cancel()
                partialFrameDeadline = nil
                let frame = try PeerExchangeCodec.decode(Data(bytes))
                if localCommitted && remoteReadyReceived && frame.kind == .request {
                    try receive(frame, context: context)
                } else if readyFinished {
                    try receive(frame, context: context)
                } else {
                    if preflightReceived < 3 {
                        let expected: PeerExchangeCodec.Kind =
                            preflightReceived == 0
                            ? .declaration : preflightReceived == 1 ? .acknowledgement : .ready
                        guard frame.kind == expected,
                            frame.body.count
                                <= (expected == .declaration
                                    ? PeerCompatibilityDeclaration.maximumBytes
                                    : expected == .acknowledgement ? 4096 : 0)
                        else {
                            throw TractandaError(
                                "invalidPeerFrame", "Missing, duplicate or unordered compatibility control.")
                        }
                        preflightReceived += 1
                        try chargeRequest()
                        // Exactly three bounded controls in the entire attempt.
                        preflightFrames.append(frame)
                        processPreflight()
                    } else {
                        throw TractandaError(
                            "invalidPeerFrame", "Ordinary peer work preceded local compatibility commit.")
                    }
                }
            }
        } catch { fail(error) }
    }
    private func processPreflight() {
        guard !failed, !readyFinished, !active, task == nil, let gateway, let control = preflightControl,
            let context, !preflightFrames.isEmpty
        else { return }
        let frame = preflightFrames.removeFirst()
        if frame.kind == .ready {
            guard remoteAckValidated else {
                fail(TractandaError("invalidPeerFrame", "READY preceded compatibility acknowledgement."))
                return
            }
            remoteReadyReceived = true
            publishReady()
            return
        }
        active = true
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loop = context.eventLoop
        task = Task {
            let result: Result<Data, Error>
            do {
                try control.check()
                result = .success(
                    try await gateway.advanceCompatibility(
                        frame.kind == .declaration ? .accept(frame.body) : .acknowledge(frame.body),
                        control: control))
            } catch { result = .failure(error) }
            loop.execute {
                let handler = bound.value
                guard !handler.failed else { return }
                handler.task = nil
                handler.active = false
                do {
                    let body = try result.get()
                    try control.check()
                    if frame.kind == .declaration {
                        handler.ownAckSent = true
                        let flushed = try handler.write(
                            .init(version: 2, requestID: 0, kind: .acknowledgement, body: body))
                        flushed.whenSuccess {
                            guard !bound.value.failed else { return }
                            bound.value.ownAckFlushed = true
                            bound.value.completePreflight()
                        }
                    } else {
                        handler.remoteAckValidated = true
                    }
                    handler.processPreflight()
                    handler.completePreflight()
                } catch { handler.fail(error) }
            }
        }
    }
    private func completePreflight() {
        guard !failed, !readyFinished, !finalizing, !active, task == nil,
            ownAckFlushed, remoteAckValidated, let gateway, let control = preflightControl, let context
        else { return }
        finalizing = true
        active = true
        let loop = context.eventLoop
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let lifetime = compatibilityLifetime
        task = Task {
            let result: Result<PeerCompatibilityAdmission, Error>
            do {
                result = .success(
                    try await gateway.compatibilityAdmission(lifetime: lifetime, control: control))
            } catch { result = .failure(error) }
            loop.execute {
                let handler = bound.value
                let context = boundContext.value
                guard !handler.failed else { return }
                handler.task = nil
                do {
                    let admission = try result.get()
                    try control.check()
                    try lifetime.check()
                    guard context.channel.isActive else {
                        throw TractandaError("serviceClosed", "Peer channel closed.")
                    }
                    handler.admittedCompatibility = admission
                    // Core admission/final freshness is committed before READY emission.
                    // No Store await separates this marker from the ordered READY write.
                    handler.active = false
                    handler.localCommitted = true
                    let flushed = try handler.write(
                        .init(version: 2, requestID: 0, kind: .ready, body: Data()))
                    flushed.whenSuccess {
                        guard !bound.value.failed else { return }
                        bound.value.ownReadyFlushed = true
                        bound.value.publishReady()
                    }
                    handler.processPreflight()
                    handler.publishReady()
                    _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
                    context.read()
                } catch { handler.fail(error) }
            }
        }
    }
    fileprivate func currentAdmission(
        expectedBinding: PeerExchangeBinding,
        control: PeerExchangeControl
    ) throws -> PeerCompatibilityAdmission {
        guard !failed, readyFinished, localCommitted, context?.channel.isActive == true,
            let admission = admittedCompatibility
        else {
            throw TractandaError("peerCompatibilityRequired", "Actual physical admission is unavailable.")
        }
        try control.check()
        try admission.requireBinding(expectedBinding)
        return admission
    }
    private func publishReady() {
        guard !failed, !readyFinished, localCommitted, remoteReadyReceived, ownReadyFlushed else { return }
        do { try preflightControl?.check() } catch {
            fail(error)
            return
        }
        if control === preflightControl { control = nil }
        preflightControl = nil
        preflightDeadline?.cancel()
        preflightDeadline = nil
        readyFinished = true
        ready.succeed(())
    }
    private func receive(_ frame: PeerExchangeCodec.Frame, context: ChannelHandlerContext) throws {
        guard localCommitted, remoteReadyReceived else {
            throw TractandaError("peerCompatibilityRequired", "Peer compatibility is incomplete.")
        }
        switch frame.kind {
        case .declaration, .acknowledgement, .ready:
            throw TractandaError("invalidPeerFrame", "Repeated peer compatibility control.")
        case .request:
            guard !active, pending == nil, frame.requestID == inboundID + 1, let gateway else {
                throw TractandaError("invalidPeerFrame", "Busy, duplicate or unordered peer request.")
            }
            try chargeRequest()
            inboundID = frame.requestID
            active = true
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            let request = try PeerExchangeRequest.decode(frame.body)
            let control =
                request.waitsForCommitCompletion
                ? PeerExchangeControl.commitCompletion()
                : try PeerExchangeControl(maximumSeconds: limits.operationSeconds)
            self.control = control
            if !request.waitsForCommitCompletion { startDeadline(context) }
            let loop = context.eventLoop
            let bound = NIOLoopBound(self, eventLoop: loop)
            task = Task {
                let result: Result<Data, Error>
                do { result = .success(try await gateway.execute(frame.body, control: control)) } catch {
                    result = .failure(error)
                }
                loop.execute { bound.value.finish(frame.requestID, result: result) }
            }
        case .response, .failure:
            guard !active, task == nil, let pending, frame.requestID == pending.0, let gateway,
                let control
            else {
                throw TractandaError("invalidPeerFrame", "Unexpected peer response identity.")
            }
            let failure: TractandaError?
            if frame.kind == .failure {
                let error = try JSON.decode(TractandaError.self, frame.body)
                guard error.message == "Peer operation failed.", error.osError == nil,
                    error.code.utf8.count <= 128, try JSON.encode(error) == frame.body
                else { throw TractandaError("invalidPeerFrame", "Invalid peer failure response.") }
                failure = error
            } else {
                failure = nil
            }
            try control.check()
            if let failure, ["peerRetired", "localReplicaRetired"].contains(failure.code) {
                // A canonical sanitized denial carries no normal data. Preserve it before
                // the sender's following TLS close can cancel asynchronous authorization.
                // This neither accepts a canonical removal root nor fences our own Store.
                self.pending = nil
                self.control = nil
                operationDeadline?.cancel()
                operationDeadline = nil
                pending.1.fail(failure)
                fail(TractandaError("serviceClosed", "Peer authorization ended."))
                return
            }
            active = true
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            let loop = context.eventLoop
            let bound = NIOLoopBound(self, eventLoop: loop)
            task = Task {
                let authorization: Result<Void, Error>
                do {
                    try await gateway.authorize(control: control)
                    authorization = .success(())
                } catch { authorization = .failure(error) }
                loop.execute {
                    bound.value.deliverReceived(
                        frame.body, failure: failure, requestID: frame.requestID,
                        authorization: authorization)
                }
            }
        }
    }
    private func chargeRequest() throws {
        guard requests < limits.maximumRequests else {
            throw TractandaError("peerSessionExhausted", "Peer request budget exhausted.")
        }
        requests += 1
    }
    fileprivate func request(_ request: PeerExchangeRequest) throws -> EventLoopFuture<Data> {
        guard let context, let gateway, readyFinished, !failed, !active, pending == nil else {
            throw TractandaError("serviceBusy", "Peer session is unavailable or busy.")
        }
        do { try chargeRequest() } catch {
            fail(error)
            throw error
        }
        outboundID += 1
        let promise = context.eventLoop.makePromise(of: Data.self)
        let requestID = outboundID
        pending = (requestID, promise)
        do {
            let control =
                request.waitsForCommitCompletion
                ? PeerExchangeControl.commitCompletion()
                : try PeerExchangeControl(maximumSeconds: limits.operationSeconds)
            self.control = control
            let body = try JSON.encode(request)
            if !request.waitsForCommitCompletion { startDeadline(context) }
            let loop = context.eventLoop
            let bound = NIOLoopBound(self, eventLoop: loop)
            task = Task {
                let authorization: Result<Void, Error>
                do {
                    try await gateway.authorize(control: control)
                    authorization = .success(())
                } catch { authorization = .failure(error) }
                loop.execute {
                    let handler = bound.value
                    guard !handler.failed, handler.pending?.0 == requestID else { return }
                    handler.task = nil
                    do {
                        try authorization.get()
                        try control.check()
                        _ = try handler.write(
                            .init(version: 2, requestID: requestID, kind: .request, body: body))
                    } catch { handler.fail(error) }
                }
            }
        } catch { fail(error) }
        return promise.futureResult
    }
    private func deliverReceived(
        _ bytes: Data, failure: TractandaError?, requestID: UInt64,
        authorization: Result<Void, Error>
    ) {
        guard !failed, let pending, pending.0 == requestID, let context else { return }
        task = nil
        do {
            try authorization.get()
            try control?.check()
            control = nil
            self.pending = nil
            operationDeadline?.cancel()
            operationDeadline = nil
            active = false
            if let failure { pending.1.fail(failure) } else { pending.1.succeed(bytes) }
            _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
            context.read()
        } catch { fail(error) }
    }
    private func startDeadline(_ context: ChannelHandlerContext) {
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        operationDeadline = context.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.operationSeconds * 1_000_000_000))
        ) {
            bound.value.fail(TractandaError("deadlineExceeded", "Peer operation deadline exceeded."))
        }
    }
    private func startPartialFrameDeadline(_ context: ChannelHandlerContext) {
        partialFrameDeadline?.cancel()
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        partialFrameDeadline = context.eventLoop.scheduleTask(
            in: .nanoseconds(Int64(limits.operationSeconds * 1_000_000_000))
        ) {
            bound.value.fail(TractandaError("deadlineExceeded", "Partial peer frame deadline exceeded."))
        }
    }
    private func finish(_ requestID: UInt64, result: Result<Data, Error>) {
        guard !failed, let context, let gateway, let control else { return }
        let loop = context.eventLoop
        let bound = NIOLoopBound(self, eventLoop: loop)
        // Store completion is not delivery authorization: retirement may have been learned
        // while this callback waited on the event loop. Never deliver that stale result.
        task = Task {
            let authorization: Result<Void, Error>
            do {
                try await gateway.authorize(control: control)
                authorization = .success(())
            } catch { authorization = .failure(error) }
            loop.execute {
                switch authorization {
                case .success: bound.value.deliver(requestID, result: result, closeAfterward: false)
                case .failure(let error):
                    bound.value.deliver(requestID, result: .failure(error), closeAfterward: true)
                }
            }
        }
    }
    private func deliver(
        _ requestID: UInt64, result: Result<Data, Error>, closeAfterward: Bool
    ) {
        guard !failed, let context else { return }
        task = nil
        do {
            try control?.check()
            let flushed: EventLoopFuture<Void>
            switch result {
            case .success(let bytes):
                flushed = try write(.init(version: 2, requestID: requestID, kind: .response, body: bytes))
            case .failure(let error):
                let raw = (error as? TractandaError)?.code ?? "peerOperationFailed"
                let code = raw.utf8.count <= 128 ? raw : "peerOperationFailed"
                let safe = TractandaError(code, "Peer operation failed.")
                flushed = try write(
                    .init(version: 2, requestID: requestID, kind: .failure, body: JSON.encode(safe)))
            }
            let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            flushed.whenSuccess {
                let handler = bound.value
                let context = boundContext.value
                guard !handler.failed else { return }
                if closeAfterward {
                    handler.fail(TractandaError("serviceClosed", "Peer authorization ended."))
                    return
                }
                do { try handler.control?.check() } catch {
                    handler.fail(error)
                    return
                }
                handler.control = nil
                handler.operationDeadline?.cancel()
                handler.operationDeadline = nil
                handler.active = false
                _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
                context.read()
            }
        } catch { fail(error) }
    }
    private func write(_ frame: PeerExchangeCodec.Frame) throws -> EventLoopFuture<Void> {
        guard let context else { throw TractandaError("serviceClosed", "Peer channel closed.") }
        let buffer = try PeerExchangeCodec.encode(frame, allocator: context.channel.allocator)
        guard buffer.readableBytes <= limits.maximumWireBytes - sent else {
            throw TractandaError("peerSessionExhausted", "Peer outbound byte budget exhausted.")
        }
        sent += buffer.readableBytes
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        try control?.check()
        let flushed = context.writeAndFlush(wrapOutboundOut(buffer))
        flushed.whenFailure { bound.value.fail($0) }
        return flushed
    }
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // Invalidate on close request, without waiting for graceful TLS shutdown to finish.
        compatibilityLifetime.cancel()
        admittedCompatibility = nil
        control?.cancel()
        preflightControl?.cancel()
        context.close(mode: mode, promise: promise)
    }
    func channelInactive(context: ChannelHandlerContext) {
        fail(TractandaError("serviceClosed", "Peer connection closed."))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error) }
    func handlerRemoved(context: ChannelHandlerContext) {
        fail(TractandaError("serviceClosed", "Peer transport removed."))
        self.context = nil
    }
    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        compatibilityLifetime.cancel()
        admittedCompatibility = nil
        control?.cancel()
        preflightControl?.cancel()
        task?.cancel()
        task = nil
        input = nil
        preflightFrames.removeAll()
        if let gateway { Task { await gateway.detachLogicalLease() } }
        gateway = nil
        operationDeadline?.cancel()
        partialFrameDeadline?.cancel()
        preflightDeadline?.cancel()
        sessionDeadline?.cancel()
        if !readyFinished {
            readyFinished = true
            ready.fail(error)
        }
        pending?.1.fail(error)
        pending = nil
        context?.close(promise: nil)
    }
}
