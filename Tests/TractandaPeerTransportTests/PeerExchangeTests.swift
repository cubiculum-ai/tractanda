import CTractandaPlatform
import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
import TractandaPeerTLS
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class TransportAccounts: AccountDirectory, @unchecked Sendable {
    let base: any AccountDirectory
    init(_ base: any AccountDirectory) { self.base = base }
    func user(forUID uid: UInt32) throws -> AccountIdentity { try base.user(forUID: uid) }
    func user(named name: String) throws -> AccountIdentity { try base.user(named: name) }
    func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
}
private final class ExchangeCompletion<T: Sendable>: Sendable {
    let result = Mutex<Result<T, TractandaError>?>(nil)
}
private actor MembershipPause {
    private let stopAt: Int
    private var visits = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var paused = false
    init(stopAt: Int = 1) { self.stopAt = stopAt }
    func visit() async {
        visits += 1
        guard visits == stopAt, !released else { return }
        paused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Test-only application-frame manipulation, before encryption. It never bypasses TLS.
private final class CompatibilityWireFixture: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    enum Mode: Equatable {
        case normal, coalesceReadyWithFirstRequest, omitAck, oldDeclaration, readyBeforeAck, duplicateReady,
            precommitHeader
    }
    let mode: Mode
    private var heldReady: ByteBuffer?
    let didCoalesce = Mutex(false)
    let didOmitAck = Mutex(false)
    init(_ mode: Mode) { self.mode = mode }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        do {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
                let raw = buffer.getBytes(at: buffer.readerIndex + 4, length: Int(length))
            else {
                context.write(wrapOutboundOut(buffer), promise: promise)
                return
            }
            let frame = try PeerExchangeCodec.decode(Data(raw))
            if mode == .omitAck, frame.kind == .acknowledgement || frame.kind == .ready {
                if frame.kind == .acknowledgement { didOmitAck.withLock { $0 = true } }
                promise?.succeed(())
                return  // Withhold the stream suffix, including later READY.
            }
            if mode == .oldDeclaration, frame.kind == .declaration {
                buffer = try PeerExchangeCodec.encode(
                    .init(version: 1, requestID: 0, kind: .declaration, body: frame.body),
                    allocator: context.channel.allocator)
            }
            if mode == .readyBeforeAck, frame.kind == .acknowledgement {
                buffer = try PeerExchangeCodec.encode(
                    .init(version: 2, requestID: 0, kind: .ready, body: Data()),
                    allocator: context.channel.allocator)
            }
            if mode == .duplicateReady, frame.kind == .ready {
                var duplicate = buffer
                buffer.writeBuffer(&duplicate)
            }
            if mode == .precommitHeader, frame.kind == .ready {
                buffer.writeInteger(UInt32(PeerExchangeCodec.maximumFrameBytes))
            }
            if mode == .coalesceReadyWithFirstRequest {
                if frame.kind == .ready {
                    heldReady = buffer
                    promise?.succeed(())
                    return
                }
                if frame.kind == .request, var heldReady {
                    heldReady.writeBuffer(&buffer)
                    buffer = heldReady
                    self.heldReady = nil
                    didCoalesce.withLock { $0 = true }
                }
            }
            context.write(wrapOutboundOut(buffer), promise: promise)
        } catch {
            promise?.fail(error)
            context.fireErrorCaught(error)
        }
    }
}

/// Embedded TLS uses real protected records; no native socket/listener is created.
private final class ExchangePair {
    let client = NIOAsyncTestingChannel(), server = NIOAsyncTestingChannel()
    let a: PeerExchangeConnection
    let b: PeerExchangeConnection
    let compatibilityWire: CompatibilityWireFixture
    var wireBytes = 0
    init(
        clientPairing: PeerPairing, serverPairing: PeerPairing,
        source: ServiceCoordinator, receiver: ServiceCoordinator,
        limits: PeerExchangeLimits = .init(), responder: PeerExchangeResponder? = nil,
        clientMode: CompatibilityWireFixture.Mode = .normal,
        clientAdmission: @escaping @Sendable () async throws -> Void = {},
        serverAdmission: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        compatibilityWire = CompatibilityWireFixture(clientMode)
        let left = PeerExchangeConnection.install(
            on: client, pairing: clientPairing, coordinator: source, limits: limits,
            authorizeAdmission: clientAdmission)
        FileHandle.standardError.write(Data("fixture: install client\n".utf8))
        a = try await left.get()
        let wire = compatibilityWire
        let clientChannel = client
        try await client.eventLoop.submit {
            let application = try clientChannel.pipeline.syncOperations.context(
                handlerType: PeerExchangeHandler.self)
            try clientChannel.pipeline.syncOperations.addHandler(wire, position: .before(application.handler))
        }.get()
        let right: EventLoopFuture<PeerExchangeConnection>
        if let responder {
            right = PeerExchangeConnection.install(
                on: server, responder: responder, coordinator: receiver, limits: limits,
                authorizeAdmission: serverAdmission)
        } else {
            right = PeerExchangeConnection.install(
                on: server, pairing: serverPairing, coordinator: receiver, limits: limits,
                authorizeAdmission: serverAdmission)
        }
        FileHandle.standardError.write(Data("fixture: install server\n".utf8))
        b = try await right.get()
        server.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1), promise: nil)
        client.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1), promise: nil)
        try await pump()
    }
    deinit {
        client.close(promise: nil)
        server.close(promise: nil)

    }
    func close() async {
        client.close(promise: nil)
        server.close(promise: nil)
        try? await pump()
        _ = try? await client.finish(acceptAlreadyClosed: true)
        _ = try? await server.finish(acceptAlreadyClosed: true)
    }
    func pump() async throws {
        for _ in 0..<64 {
            await client.testingEventLoop.run()
            await server.testingEventLoop.run()
            var progressed = false
            for (source, target) in [(client, server), (server, client)] {
                while let output = try await source.readOutbound(as: IOData.self) {
                    guard case .byteBuffer(let bytes) = output else {
                        throw FixtureError.failed("file region")
                    }
                    wireBytes += bytes.readableBytes
                    guard wireBytes <= 32 * 1024 * 1024 else { throw FixtureError.failed("fixture wire cap") }
                    if target.isActive { _ = try await target.writeInbound(bytes) }
                    progressed = true
                }
            }
            if !progressed { return }
        }
        throw FixtureError.failed("embedded progress window")
    }
    func value<T: Sendable>(_ future: EventLoopFuture<T>) async throws -> T {
        let completion = ExchangeCompletion<T>()
        future.whenComplete { result in
            completion.result.withLock {
                $0 = result.mapError {
                    $0 as? TractandaError ?? TractandaError("testFailure", String(describing: $0))
                }
            }
        }
        // Finite tiny fixture driver; native Store tasks run on the coordinator's GCD owner.
        for _ in 0..<4096 {
            try await pump()
            if let result = completion.result.withLock({ $0 }) { return try result.get() }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        throw FixtureError.failed("bounded async embedded deadline")
    }
    func ready() async throws {
        try await value(a.ready)
        try await value(b.ready)
    }
    func call(_ connection: PeerExchangeConnection, _ operation: String, _ fields: [String: ItemValue] = [:])
        async throws -> [String: ItemValue]
    {
        do {
            return try JSON.decode(
                [String: ItemValue].self,
                await value(connection.request(PeerExchangeRequest(operation, fields))))
        } catch {
            throw FixtureError.failed("peer operation " + operation + ": " + String(describing: error))
        }
    }
}

final class PeerExchangeTests: XCTestCase {
    typealias Fixture = PeerTransportStoreFixtures.Fixture
    private var guardedRoot: URL?
    private func fixture() throws -> Fixture {
        if guardedRoot == nil {
            guardedRoot = try GuardedFixtureDirectory.create(
                prefix: "l", source: "PeerExchangeTests", test: name)
        }
        return try Fixture(directory: guardedRoot!.appendingPathComponent(UUID().uuidString))
    }
    override func tearDownWithError() throws {
        if let guardedRoot { try FileManager.default.removeItem(at: guardedRoot) }
        guardedRoot = nil
        try super.tearDownWithError()
    }
    private func coordinator(_ root: URL, _ accounts: TransportAccounts) async throws -> ServiceCoordinator {
        try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil, requireInitializedStore: true,
            revisionProjectionEnabledForTesting: true, authorityIntakeEnabledForTesting: true,
            makeAccountDirectory: { accounts })
    }
    private func canonical(_ root: URL) throws -> [String: String] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let file as URL in files where ["tractanda", "authority"].contains(file.pathExtension) {
            result[file.path] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        return result
    }
    private func withPair(
        limits: PeerExchangeLimits = .init(),
        _ body: (ExchangePair) async throws -> Void
    ) async throws {
        let f = try fixture()
        try f.bootstrap()
        let (left, right) = try paired(f)
        let a = TransportAccounts(f.sourceAccounts)
        let b = TransportAccounts(f.receiverAccounts)
        f.source = nil
        f.receiver = nil
        let source = try await coordinator(f.sourceRoot, a)
        let receiver = try await coordinator(f.receiverRoot, b)
        var pair: ExchangePair?
        do {
            pair = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver, limits: limits)
            try await pair!.ready()
            try await body(pair!)
            await pair?.close()
            await source.close()
            await receiver.close()
        } catch {
            await pair?.close()
            await source.close()
            await receiver.close()
            throw error
        }
        try f.capacity()
    }

    func testCanonicalCodecPreservesFullChunkAndRejectsAmbiguousMetadata() throws {
        let chunk = Data(repeating: 0x5b, count: 1024 * 1024)
        let request = PeerExchangeRequest("append", ["bytes": .bytes(chunk)])
        let body = try JSON.encode(request)
        let frame = PeerExchangeCodec.Frame(version: 2, requestID: 1, kind: .request, body: body)
        var encoded = try PeerExchangeCodec.encode(frame, allocator: ByteBufferAllocator())
        let length = try XCTUnwrap(encoded.readInteger(as: UInt32.self))
        XCTAssertLessThanOrEqual(Int(length), PeerExchangeCodec.maximumFrameBytes)
        let decoded = try PeerExchangeCodec.decode(Data(XCTUnwrap(encoded.readBytes(length: Int(length)))))
        let recovered = try JSON.decode(PeerExchangeRequest.self, decoded.body)
        XCTAssertEqual(recovered.fields["bytes"], .bytes(chunk))
        for malformed in [
            Data("{}".utf8), try JSON.encode(frame) + Data([10]),
            Data(#"{"version":1,"version":1,"requestID":1,"kind":"request","body":""}"#.utf8),
        ] {
            XCTAssertThrowsError(try PeerExchangeCodec.decode(malformed))
        }
        XCTAssertThrowsError(
            try PeerExchangeCodec.encode(
                .init(
                    version: 2, requestID: 1, kind: .request, body: Data(repeating: 1, count: 2 * 1024 * 1024)
                ), allocator: ByteBufferAllocator()))
        XCTAssertThrowsError(
            try PeerExchangeCodec.decode(
                JSON.encode(PeerExchangeCodec.Frame(version: 2, requestID: 0, kind: .request, body: Data()))))
    }

    private func nativeCommit(_ owner: ServiceCoordinator, _ request: CommitRequest, uid: UInt32) async throws
        -> Revision
    {
        let context = NativeAsyncClientContext { bytes in try await owner.handle(bytes, forUID: uid) }
        let response = try await context.send(
            method: "TractandaItem/commit", arguments: JSON.encode(request), callID: "fixture")
        let receipt = try JSON.decode(
            MutationReceipt.self,
            NativeMethodResult.unwrap(response, method: "TractandaItem/commit", callID: "fixture"))
        let fetched = try await context.send(
            method: "TractandaRevision/get",
            arguments: JSONSerialization.data(withJSONObject: ["ids": [receipt.revisionID]]), callID: "pinned"
        )
        let result = try JSON.decode(
            JMAPRevisionGetResponse.self,
            NativeMethodResult.unwrap(fetched, method: "TractandaRevision/get", callID: "pinned"))
        let revision = try XCTUnwrap(result.list.first).canonicalRevision()
        XCTAssertEqual(revision.itemID, receipt.itemID)
        XCTAssertEqual(revision.revisionID, receipt.revisionID)
        return revision
    }

    private func stage(
        _ packet: PeerTransportStoreFixtures.Packet, pair: ExchangePair,
        importer: PeerExchangeConnection, fixture: Fixture
    ) async throws {
        try fixture.capacity()
        _ = try await pair.call(importer, "begin", ["manifest": .bytes(JSON.encode(packet.manifest))])
        for (descriptor, bytes) in packet.objects {
            try fixture.capacity()
            _ = try await pair.call(
                importer, "append",
                [
                    "packageID": .text(packet.manifest.packageID),
                    "descriptor": PeerExchangeState.descriptor(descriptor),
                    "offset": .integer(0), "bytes": .bytes(bytes),
                ])
            try fixture.capacity()
        }
    }

    private func paired(_ f: Fixture) throws -> (PeerPairing, PeerPairing) {
        let remote = try XCTUnwrap(f.receiver.replicaID)
        let old = f.context!
        let context = try PeerPackage.Context(
            peerID: old.peerID, storeID: old.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("transport-generation-2".utf8)),
            permittedOrigins: [f.origin, remote].sorted())
        try f.receiver.rotatePeerIntakeCredential(
            peerID: old.peerID, replacement: context, operationID: Fixture.id())
        try f.source.configurePeerIntake(peers: [context])
        f.context = context
        let profile = try PeerTLSProfile(
            storeID: f.storeID, initiatorReplicaID: f.origin, responderReplicaID: remote,
            pairingID: Fixture.id())
        let secret = try PeerTLSSecret.generate()
        return (
            try PeerPairing(
                peerID: context.peerID, profile: profile, role: .initiator,
                configurationDigest: context.configurationDigest, secret: secret),
            try PeerPairing(
                peerID: context.peerID, profile: profile, role: .responder,
                configurationDigest: context.configurationDigest, secret: secret)
        )
    }
    private func withMembershipPair(
        retireBeforeOpening: Bool = false, sharedResponder: Bool = false,
        _ body: (ExchangePair, ServiceCoordinator, ServiceCoordinator, Fixture, String) async throws -> Void
    ) async throws {
        let f = try fixture()
        try f.bootstrap()
        let remote = try XCTUnwrap(f.receiver.replicaID)
        let (left, right) = try paired(f)
        // Retiring this endpoint leaves the real paired endpoint's credential Context intact.
        let retirement = try PeerPackage.Context(
            peerID: "isolation-lifecycle", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("retirement-endpoint".utf8)),
            permittedOrigins: [f.origin, remote].sorted())
        try f.source.configurePeerIntake(peers: [f.context, retirement])
        try f.receiver.configurePeerIntake(peers: [f.context, retirement])
        if retireBeforeOpening {
            try f.receiver.removePeerIntake(
                peerID: retirement.peerID, retiredOriginIDs: [f.origin], operationID: Fixture.id())
        }
        let a = TransportAccounts(f.sourceAccounts)
        let b = TransportAccounts(f.receiverAccounts)
        f.source = nil
        f.receiver = nil
        let source = try await coordinator(f.sourceRoot, a)
        let receiver = try await coordinator(f.receiverRoot, b)
        var pair: ExchangePair?
        do {
            pair = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver,
                responder: sharedResponder ? PeerExchangeResponder(pairings: [right]) : nil)
            if !retireBeforeOpening { try await pair!.ready() }
            try await body(pair!, source, receiver, f, remote)
            await pair?.close()
            await source.close()
            await receiver.close()
        } catch {
            await pair?.close()
            await source.close()
            await receiver.close()
            throw error
        }
        try f.capacity()
    }
    private func pause(_ gate: MembershipPause, pair: ExchangePair) async throws {
        for _ in 0..<4096 {
            try await pair.pump()
            if await gate.paused { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        await gate.release()
        throw FixtureError.failed("membership authorization pause not reached")
    }

    private func prepare(_ pair: ExchangePair, remote: PeerExchangeConnection, revisionID: String)
        async throws -> (String, PeerPackage.Manifest)
    {
        var page = try await pair.call(remote, "inventory")
        let planID = try Fixture.id()
        let packageID = try Fixture.id()
        _ = try await pair.call(
            remote, "exportBegin", ["planID": .text(planID), "packageID": .text(packageID)])
        var found = false
        for _ in 0..<128 {
            let entries = try AuthorityRecord.list(page["entries"])
            let ids = entries.compactMap { $0.map?["descriptor"]?.map?["id"]?.string }.filter {
                $0 == revisionID
            }
            if !ids.isEmpty {
                found = true
                _ = try await pair.call(
                    remote, "exportSelect",
                    ["ids": .list(ids.map(ItemValue.text)), "finish": .boolean(false)])
            }
            if page["complete"]?.booleanValue == true { break }
            page = try await pair.call(remote, "inventoryNext")
        }
        XCTAssertTrue(found)
        _ = try await pair.call(remote, "exportSelect", ["ids": .list([]), "finish": .boolean(true)])
        for _ in 0..<512 {
            let status = try await pair.call(remote, "exportStep")
            if case .bytes(let manifest) = status["manifest"] {
                return (planID, try PeerPackage.decode(PeerPackage.Manifest.self, manifest))
            }
            XCTAssertEqual(status["missing"], .integer(0))
            XCTAssertEqual(status["unsupported"], .integer(0))
        }
        throw FixtureError.failed("tiny closure did not seal")
    }
    private func transfer(
        _ pair: ExchangePair, exporter: PeerExchangeConnection, importer: PeerExchangeConnection,
        manifest: PeerPackage.Manifest, skip: Set<String> = [], inspectPartialDocument: Bool = false
    ) async throws -> [String: Data] {
        _ = try await pair.call(importer, "begin", ["manifest": .bytes(JSON.encode(manifest))])
        var pending = [manifest.root]
        var originals: [String: Data] = [:]
        while let descriptor = pending.popLast() {
            var bytes = Data()
            for offset in stride(from: 0, to: descriptor.length, by: descriptor.chunkBytes) {
                let response = try await pair.call(
                    exporter, "exportRead",
                    [
                        "descriptor": PeerExchangeState.descriptor(descriptor),
                        "offset": .integer(Int64(offset)),
                    ])
                guard case .bytes(let chunk) = response["bytes"] else {
                    throw FixtureError.failed("missing bytes")
                }
                XCTAssertEqual(chunk.count, min(descriptor.chunkBytes, descriptor.length - offset))
                bytes.append(chunk)
                if !skip.contains(descriptor.id) {
                    _ = try await pair.call(
                        importer, "append",
                        [
                            "packageID": .text(manifest.packageID),
                            "descriptor": PeerExchangeState.descriptor(descriptor),
                            "offset": .integer(Int64(offset)),
                            "bytes": .bytes(chunk),
                        ])
                }
            }
            XCTAssertEqual(bytes.count, descriptor.length)
            XCTAssertEqual(AuthorityRecordCodec.sha256(bytes), descriptor.sha256)
            originals[descriptor.key] = bytes
            if descriptor.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                pending += page.objects + page.children
            }
        }
        var response = try await pair.call(importer, "resume", ["packageID": .text(manifest.packageID)])
        var partial = false
        for _ in 0..<128 {
            for value in try AuthorityRecord.list(response["objects"]) {
                let descriptor = try PeerExchangeState.decodeDescriptor(value.map?["descriptor"])
                guard descriptor.kind == .document, value.map?["verifiedComplete"] != .boolean(true) else {
                    continue
                }
                let offset = Int(try XCTUnwrap(value.map?["nextOffset"]?.integerValue))
                var bytes = Data()
                for start in stride(from: offset, to: descriptor.length, by: descriptor.chunkBytes) {
                    let chunk = try await pair.call(
                        exporter, "exportRead",
                        [
                            "descriptor": PeerExchangeState.descriptor(descriptor),
                            "offset": .integer(Int64(start)),
                        ])
                    guard case .bytes(let data) = chunk["bytes"] else {
                        throw FixtureError.failed("document bytes missing")
                    }
                    XCTAssertLessThanOrEqual(data.count, PeerPackage.maximumPayloadChunkBytes)
                    bytes.append(data)
                    _ = try await pair.call(
                        importer, "append",
                        [
                            "packageID": .text(manifest.packageID),
                            "descriptor": PeerExchangeState.descriptor(descriptor),
                            "offset": .integer(Int64(start)), "bytes": .bytes(data),
                        ])
                    if inspectPartialDocument, !partial, descriptor.part?.role == .page,
                        start == 0, descriptor.length > PeerPackage.maximumPayloadChunkBytes
                    {
                        partial = true
                        let checkpoint = try await pair.call(importer, "resumeNext")
                        let values = try AuthorityRecord.list(checkpoint["objects"])
                        let saved = try XCTUnwrap(
                            values.first { $0.map?["descriptor"] == PeerExchangeState.descriptor(descriptor) }
                        )
                        XCTAssertEqual(
                            saved.map?["nextOffset"], .integer(Int64(PeerPackage.maximumPayloadChunkBytes)))
                        XCTAssertEqual(saved.map?["verifiedComplete"], .boolean(false))
                        let state = try await pair.call(
                            importer, "status", ["packageID": .text(manifest.packageID)])
                        XCTAssertEqual(state["phase"], .text("staged"))
                    }
                }
                XCTAssertEqual(AuthorityRecordCodec.sha256(bytes), descriptor.sha256)
                originals[descriptor.key] = bytes
            }
            if response["complete"] == .boolean(true) { break }
            response = try await pair.call(importer, "resumeNext")
        }
        XCTAssertEqual(response["complete"], .boolean(true))
        if inspectPartialDocument { XCTAssertTrue(partial) }
        return originals
    }

}
