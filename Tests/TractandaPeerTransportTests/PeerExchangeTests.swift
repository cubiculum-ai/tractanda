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
    enum Mode: Equatable { case normal, coalesceReadyWithFirstRequest, omitAck, oldDeclaration, readyBeforeAck, duplicateReady, precommitHeader }
    let mode: Mode
    private var heldReady: ByteBuffer?
    let didCoalesce = Mutex(false)
    let didOmitAck = Mutex(false)
    init(_ mode: Mode) { self.mode = mode }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        do {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self),
                let raw = buffer.getBytes(at: buffer.readerIndex + 4, length: Int(length)) else {
                context.write(wrapOutboundOut(buffer), promise: promise); return
            }
            let frame = try PeerExchangeCodec.decode(Data(raw))
            if mode == .omitAck, frame.kind == .acknowledgement || frame.kind == .ready {
                if frame.kind == .acknowledgement { didOmitAck.withLock { $0 = true } }
                promise?.succeed(()); return // Withhold the stream suffix, including later READY.
            }
            if mode == .oldDeclaration, frame.kind == .declaration {
                buffer = try PeerExchangeCodec.encode(.init(version: 1, requestID: 0, kind: .declaration, body: frame.body), allocator: context.channel.allocator)
            }
            if mode == .readyBeforeAck, frame.kind == .acknowledgement {
                buffer = try PeerExchangeCodec.encode(.init(version: 2, requestID: 0, kind: .ready, body: Data()), allocator: context.channel.allocator)
            }
            if mode == .duplicateReady, frame.kind == .ready { var duplicate = buffer; buffer.writeBuffer(&duplicate) }
            if mode == .precommitHeader, frame.kind == .ready { buffer.writeInteger(UInt32(PeerExchangeCodec.maximumFrameBytes)) }
            if mode == .coalesceReadyWithFirstRequest {
                if frame.kind == .ready { heldReady = buffer; promise?.succeed(()); return }
                if frame.kind == .request, var heldReady {
                    heldReady.writeBuffer(&buffer); buffer = heldReady; self.heldReady = nil
                    didCoalesce.withLock { $0 = true }
                }
            }
            context.write(wrapOutboundOut(buffer), promise: promise)
        } catch { promise?.fail(error); context.fireErrorCaught(error) }
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
            on: client, pairing: clientPairing, coordinator: source, limits: limits, authorizeAdmission: clientAdmission)
        FileHandle.standardError.write(Data("fixture: install client\n".utf8))
        a = try await left.get()
        let wire = compatibilityWire
        let clientChannel = client
        try await client.eventLoop.submit {
            let application = try clientChannel.pipeline.syncOperations.context(handlerType: PeerExchangeHandler.self)
            try clientChannel.pipeline.syncOperations.addHandler(wire, position: .before(application.handler))
        }.get()
        let right: EventLoopFuture<PeerExchangeConnection>
        if let responder {
            right = PeerExchangeConnection.install(
                on: server, responder: responder, coordinator: receiver, limits: limits, authorizeAdmission: serverAdmission)
        } else {
            right = PeerExchangeConnection.install(
                on: server, pairing: serverPairing, coordinator: receiver, limits: limits, authorizeAdmission: serverAdmission)
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
        if guardedRoot == nil { guardedRoot = try GuardedFixtureDirectory.create(prefix: "l", source: "PeerExchangeTests", test: name) }
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
    func testPersistedCurrentPairingsAuthenticateExchangeAfterServiceRestart() async throws {
        let f = try fixture()
        try f.bootstrap()
        let remote = try XCTUnwrap(f.receiver.replicaID)
        let pairingID = try Fixture.id()
        let secret = Array("private-test-key-never-exported!".utf8)
        let left = try PeerCredential(binding: PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID, localReplicaID: f.origin,
            remoteReplicaID: remote, pairingID: pairingID, localIsInitiator: true,
            configurationDigest: f.context.configurationDigest), secret: secret)
        let right = try PeerCredential(binding: PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID, localReplicaID: remote,
            remoteReplicaID: f.origin, pairingID: pairingID, localIsInitiator: false,
            configurationDigest: f.context.configurationDigest), secret: secret)
        let a = TransportAccounts(f.sourceAccounts), b = TransportAccounts(f.receiverAccounts)
        f.source = nil; f.receiver = nil
        let initialSource = try await coordinator(f.sourceRoot, a)
        let initialReceiver = try await coordinator(f.receiverRoot, b)
        do {
            try await initialSource.registerPeerCredential(left, permittedOrigins: f.context.permittedOrigins,
                expectedContextToken: initialSource.peerCredentialRegistrationContext(forUID: tractanda_uid()),
                operationID: Fixture.id(), forUID: tractanda_uid())
            try await initialReceiver.registerPeerCredential(right, permittedOrigins: f.context.permittedOrigins,
                expectedContextToken: initialReceiver.peerCredentialRegistrationContext(forUID: tractanda_uid()),
                operationID: Fixture.id(), forUID: tractanda_uid())
        } catch {
            await initialSource.close(); await initialReceiver.close(); throw error
        }
        await initialSource.close(); await initialReceiver.close()
        let source = try await coordinator(f.sourceRoot, a), receiver = try await coordinator(f.receiverRoot, b)
        var pair: ExchangePair?
        do {
            let restoredLeft = try await PeerPairing.load(peerID: f.context.peerID, coordinator: source)
            let restoredRight = try await PeerPairing.load(peerID: f.context.peerID, coordinator: receiver)
            pair = try await ExchangePair(clientPairing: restoredLeft, serverPairing: restoredRight,
                source: source, receiver: receiver)
            try await pair!.ready()
            let response = try await pair!.call(pair!.a, "inventory")
            XCTAssertFalse(response.isEmpty)
            await pair!.close(); await source.close(); await receiver.close()
        } catch {
            await pair?.close(); await source.close(); await receiver.close(); throw error
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
    func testFragmentedAndCoalescedInvalidPrefixesCloseAtHeaderBoundary() async throws {
        for declared in [UInt32(0), UInt32(PeerExchangeCodec.maximumFrameBytes + 1)] {
            try await withPair { pair in
                var header = ByteBufferAllocator().buffer(capacity: 4)
                header.writeInteger(declared)
                var first = try XCTUnwrap(header.readSlice(length: 3))
                _ = first.readableBytes
                pair.client.writeAndFlush(first, promise: nil)
                try await pair.pump()
                XCTAssertTrue(pair.server.isActive)
                pair.client.writeAndFlush(try XCTUnwrap(header.readSlice(length: 1)), promise: nil)
                try await pair.pump()
                XCTAssertFalse(pair.server.isActive)
            }
        }
        try await withPair { pair in
            var invalid = ByteBufferAllocator().buffer(capacity: 1024 * 1024 + 4)
            invalid.writeInteger(UInt32(0))
            invalid.writeRepeatingByte(0x31, count: 1024 * 1024)
            pair.client.writeAndFlush(invalid, promise: nil)
            try await pair.pump()
            XCTAssertFalse(pair.server.isActive)
        }
    }
    func testDuplicateUnorderedUnsolicitedAndPipelinedFramesAreRejected() async throws {
        for scenario in 0..<4 {
            try await withPair { pair in
                if scenario == 3 { _ = try await pair.call(pair.a, "inventory") }
                let body = try JSON.encode(PeerExchangeRequest("inventory"))
                let id: UInt64 = scenario == 0 ? 2 : 1
                let kind: PeerExchangeCodec.Kind = scenario == 1 ? .response : .request
                var frame = try PeerExchangeCodec.encode(
                    .init(version: 2, requestID: id, kind: kind, body: body), allocator: ByteBufferAllocator()
                )
                if scenario == 2 {
                    var second = try PeerExchangeCodec.encode(
                        .init(version: 2, requestID: 2, kind: .request, body: body),
                        allocator: ByteBufferAllocator())
                    frame.writeBuffer(&second)
                }
                pair.client.writeAndFlush(frame, promise: nil)
                try await pair.pump()
                XCTAssertFalse(pair.server.isActive)
            }
        }
    }
    func testRequestQuotaAndAbsoluteSessionDeadlineRejectFurtherWork() async throws {
        var limits = PeerExchangeLimits()
        limits.maximumRequests = 4
        try await withPair(limits: limits) { pair in
            _ = try await pair.call(pair.a, "inventory")
            do {
                _ = try await pair.value(pair.a.request(PeerExchangeRequest("inventory")))
                XCTFail("quota accepted")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerSessionExhausted") }
        }
        limits = .init()
        limits.sessionSeconds = 5
        try await withPair(limits: limits) { pair in
            await pair.client.testingEventLoop.advanceTime(by: .seconds(6))
            await pair.server.testingEventLoop.advanceTime(by: .seconds(6))
            try await pair.pump()
            XCTAssertFalse(pair.client.isActive)
            XCTAssertFalse(pair.server.isActive)
        }
    }
    private func nativeCommit(_ owner: ServiceCoordinator, _ request: CommitRequest, uid: UInt32) async throws
        -> Revision
    {
        let arguments = try JSONSerialization.jsonObject(with: JSON.encode(request))
        let envelope: [String: Any] = [
            "using": [ItemService.capability],
            "methodCalls": [["TractandaItem/commit", arguments, "fixture"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let response = try await owner.handle(data, forUID: uid)
        return try JSON.decode(
            CommitResult.self,
            NativeMethodResult.unwrap(response, method: "TractandaItem/commit", callID: "fixture")
        ).revision
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
    func testMissingParentRequiresLaterExactTransferAndExplicitCommitRetry() async throws {
        let f = try fixture()
        try f.bootstrap()
        let parent = try f.edit(subject: "missing parent")
        let child = try f.edit(subject: "child waits")
        let childPacket = try f.packet(f.source.peerMetadataObjects(revisionID: child.revisionID))
        let parentPacket = try f.packet(f.source.peerMetadataObjects(revisionID: parent.revisionID))
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
                clientPairing: left, serverPairing: right, source: source, receiver: receiver)
            try await pair!.ready()
            try await stage(childPacket, pair: pair!, importer: pair!.a, fixture: f)
            let missing = try await pair!.call(
                pair!.a, "commit", ["packageID": .text(childPacket.manifest.packageID)])
            XCTAssertEqual(missing["missing"], .integer(1))
            try await stage(parentPacket, pair: pair!, importer: pair!.a, fixture: f)
            _ = try await pair!.call(pair!.a, "commit", ["packageID": .text(parentPacket.manifest.packageID)])
            let retried = try await pair!.call(
                pair!.a, "commit", ["packageID": .text(childPacket.manifest.packageID)])
            XCTAssertEqual(retried["accepted"], .integer(1))
            await pair?.close()
            await source.close()
            await receiver.close()
        } catch {
            await pair?.close()
            await source.close()
            await receiver.close()
            throw error
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(child.itemID), child)
        try f.capacity()
    }
    func testEncryptedOriginalStreamsInBoundedFramesAndPublishesBeforeReference() async throws {
        let f = try fixture()
        try f.bootstrap()
        let bytes = Data((0..<(2 * PeerPackage.maximumPayloadChunkBytes + 17)).map { UInt8($0 % 251) })
        let attached = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID, expectedRevisionID: f.base.revisionID, operationID: Fixture.id(),
                    filename: "tiny.txt", mediaType: "text/plain", byteCount: Int64(bytes.count),
                    sha256: AuthorityRecordCodec.sha256(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            for offset in stride(from: 0, to: bytes.count, by: PeerPackage.maximumPayloadChunkBytes) {
                _ = try f.source.appendAttachment(
                    uploadID: id, offset: Int64(offset),
                    data: Data(
                        bytes[offset..<min(bytes.count, offset + PeerPackage.maximumPayloadChunkBytes)]))
            }
            return try f.source.finishAttachment(uploadID: id).revision
        }
        let (left, right) = try paired(f)
        let a = TransportAccounts(f.sourceAccounts)
        let b = TransportAccounts(f.receiverAccounts)
        f.source = nil
        f.receiver = nil
        let source = try await coordinator(f.sourceRoot, a)
        let receiver = try await coordinator(f.receiverRoot, b)
        await receiver.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("original receiver diagnostic: " + error.description + "\n").utf8))
        }
        await source.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("original source diagnostic: " + error.description + "\n").utf8))
        }
        var pair: ExchangePair?
        do {
            pair = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver)
            try await pair!.ready()
            let (_, manifest) = try await prepare(pair!, remote: pair!.b, revisionID: attached.revisionID)
            let transferred = try await transfer(
                pair!, exporter: pair!.b, importer: pair!.a, manifest: manifest)
            let attachment = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.fields).first)
            XCTAssertEqual(transferred[attachment.attachmentID], bytes)
            _ = try await pair!.call(pair!.a, "commit", ["packageID": .text(manifest.packageID)])
            await pair?.close()
            await source.close()
            await receiver.close()
        } catch {
            await pair?.close()
            await source.close()
            await receiver.close()
            throw error
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(attached.itemID).revisionID, attached.revisionID)
        let attachment = try XCTUnwrap(AttachmentDescriptor.descriptors(in: attached.fields).first)
        var actual = Data()
        while actual.count < bytes.count {
            actual.append(
                try f.receiver.attachmentContent(
                    itemID: attached.itemID, attachmentID: attachment.attachmentID,
                    offset: Int64(actual.count), limit: PeerPackage.maximumPayloadChunkBytes
                ).data)
        }
        XCTAssertEqual(actual, bytes)
        try f.capacity()
    }
    func testEncryptedDocumentPartsResumeAtChunkBoundaryAndRelayExactSavedOutcomes() async throws {
        let f = try fixture()
        try f.bootstrap()
        // Two stores plus <=3MiB of page/corpus/wire copies fit the fixture's32MiB cap.
        guard 19 * 1024 * 1024 <= AttachmentFixtureCapacity.fixtureCapBytes else {
            throw FixtureError.failed("document fixture estimate")
        }
        try f.capacity()
        let original = Data("%PDF-1.4\nsynthetic\n".utf8)
        let saved = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(
                .init(
                    itemID: f.base.itemID,
                    expectedRevisionID: f.base.revisionID, operationID: Fixture.id(), filename: "tiny.pdf",
                    mediaType: "application/pdf", byteCount: Int64(original.count),
                    sha256: AuthorityRecordCodec.sha256(original)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try f.source.appendAttachment(uploadID: uploadID, offset: 0, data: original)
            let attached = try f.source.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try f.source.prepareAttachmentDocument(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: upload.attachment.attachmentID, operationID: Fixture.id(), identity: .init()
                )
            else {
                throw FixtureError.failed("document snapshot")
            }
            let writer = try DocumentContentStore(
                root: f.sourceRoot, ownerUID: getuid(),
                minimumFreeBytes: Int64(AttachmentFixtureCapacity.reserveBytes)
            ).begin(
                source: snapshot.source, identity: .init(), maximumWriteBytes: 1024 * 1024)
            // Existing grammar limits: raw<=256KiB and text<=64KiB. Encoded page exceeds
            // one256KiB transfer chunk without large originals, inference or many pages.
            let raw =
                String(repeating: " ", count: 192 * 1024) + "<doctag><text>"
                + String(repeating: "x", count: 48 * 1024) + "</text></doctag>"
            let parsed = try DoclingDocTagsParser.parse(raw)
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256,
                sourceUnit: "pdfPoint", displayWidth: 512, displayHeight: 256,
                canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 1, sourceSHA256: snapshot.source.sha256,
                    page: AttachmentDocumentPage(
                        pageNumber: 1, geometry: geometry,
                        rasterSHA256: String(repeating: "b", count: 64), parsed: parsed,
                        generatedTokens: 512, stopReason: "stop")))
            try writer.append(
                DocumentStoredPage(
                    pageNumber: 2, sourceSHA256: snapshot.source.sha256,
                    status: "timeout", failureCode: "fixture"))
            let prepared = try writer.preparePublication()
            let corpus = try f.source.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            let result = try f.source.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
            return try f.source.get(result.itemID, revisionID: result.revisionID)
        }
        let document = try XCTUnwrap(AttachmentDocumentRepresentation.representations(in: saved.fields).first)
        let reference = try XCTUnwrap(document.content)
        let contents = DocumentContentStore(
            root: f.sourceRoot, ownerUID: getuid(),
            minimumFreeBytes: Int64(AttachmentFixtureCapacity.reserveBytes))
        var expected: [String: Data] = [:]
        for part in [
            PeerPackage.DocumentPart.manifest, .init(role: .node, level: 0, ordinal: 0),
            .init(role: .page, level: 0, ordinal: 1), .init(role: .page, level: 0, ordinal: 2),
        ] {
            let object = try contents.peerExpectedPart(reference, part: part, budget: .init())
            let path = try contents.directory(reference.contentID) + part.relativePath
            expected[object.key] = try Data(
                contentsOf: path.reduce(f.sourceRoot) { $0.appendingPathComponent($1) })
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(expected[reference.contentID + ":page:0:1"]).count,
            PeerPackage.maximumPayloadChunkBytes)
        let (left, right) = try paired(f)
        let a = TransportAccounts(f.sourceAccounts)
        let b = TransportAccounts(f.receiverAccounts)
        f.source = nil
        f.receiver = nil
        let source = try await coordinator(f.sourceRoot, a)
        let receiver = try await coordinator(f.receiverRoot, b)
        await receiver.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("document receiver diagnostic: " + String(error.description.prefix(512)) + "\n").utf8))
        }
        await source.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("document source diagnostic: " + String(error.description.prefix(512)) + "\n").utf8))
        }
        var pair: ExchangePair?
        do {
            pair = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver)
            try await pair!.ready()
            let (_, manifest) = try await prepare(pair!, remote: pair!.b, revisionID: saved.revisionID)
            let transferred = try await transfer(
                pair!, exporter: pair!.b, importer: pair!.a,
                manifest: manifest, inspectPartialDocument: true)
            for (key, raw) in expected { XCTAssertEqual(transferred[key], raw) }
            _ = try await pair!.call(pair!.a, "commit", ["packageID": .text(manifest.packageID)])
            let (_, relay) = try await prepare(pair!, remote: pair!.a, revisionID: saved.revisionID)
            _ = try await transfer(pair!, exporter: pair!.a, importer: pair!.b, manifest: relay)
            _ = try await pair!.call(pair!.b, "commit", ["packageID": .text(relay.packageID)])
            XCTAssertGreaterThan(pair!.wireBytes, PeerPackage.maximumPayloadChunkBytes)
            await pair?.close()
            await source.close()
            await receiver.close()
        } catch {
            await pair?.close()
            await source.close()
            await receiver.close()
            throw error
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(saved.itemID), saved)
        let received = DocumentContentStore(
            root: f.receiverRoot, ownerUID: getuid(),
            minimumFreeBytes: Int64(AttachmentFixtureCapacity.reserveBytes))
        XCTAssertEqual(try received.readPage(reference, pageNumber: 2).status, "timeout")
        for (key, bytes) in expected {
            let fields = key.split(separator: ":")
            let part = PeerPackage.DocumentPart(
                role: try XCTUnwrap(.init(rawValue: String(fields[1]))),
                level: try XCTUnwrap(Int(fields[2])), ordinal: try XCTUnwrap(Int64(fields[3])))
            let path = try received.directory(reference.contentID) + part.relativePath
            XCTAssertEqual(
                try Data(contentsOf: path.reduce(f.receiverRoot) { $0.appendingPathComponent($1) }), bytes)
        }
        try f.capacity()
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
    func testRetainedPairingCannotOpenAfterActualRemoteRetirement() async throws {
        try await withMembershipPair(retireBeforeOpening: true) { pair, _, _, _, _ in
            do {
                try await pair.value(pair.b.ready)
                XCTFail("retired remote opened a new session")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerRetired") }
        }
    }
    func testSharedResponderRetainedCredentialCannotOpenAfterActualRemoteRetirement() async throws {
        try await withMembershipPair(retireBeforeOpening: true, sharedResponder: true) { pair, _, _, _, _ in
            do {
                try await pair.value(pair.b.ready)
                XCTFail("shared responder admitted a disposed peer")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerRetired") }
        }
    }

    func testSharedResponderRetainedCredentialCannotOpenAfterRotation() async throws {
        let f = try fixture()
        try f.bootstrap()
        let (left, right) = try paired(f)
        let responder = try PeerExchangeResponder(pairings: [right])
        let replacement = try PeerPackage.Context(
            peerID: f.context.peerID, storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("rotated-before-handshake".utf8)),
            permittedOrigins: f.context.permittedOrigins)
        try f.receiver.rotatePeerIntakeCredential(
            peerID: f.context.peerID, replacement: replacement, operationID: Fixture.id())
        let a = TransportAccounts(f.sourceAccounts), b = TransportAccounts(f.receiverAccounts)
        f.source = nil; f.receiver = nil
        let source = try await coordinator(f.sourceRoot, a), receiver = try await coordinator(f.receiverRoot, b)
        defer { await source.close(); await receiver.close() }
        let pair = try await ExchangePair(clientPairing: left, serverPairing: right,
            source: source, receiver: receiver, responder: responder)
        defer { await pair.close() }
        do {
            try await pair.value(pair.b.ready)
            XCTFail("retained responder snapshot bypassed credential rotation")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerConfigurationChanged") }
        do {
            _ = try await pair.value(pair.b.request(.init("inventory")))
            XCTFail("stale responder exposed application data")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceBusy") }
        try f.capacity()
    }
    func testExistingSessionReturnsOnlySanitizedRemoteRetirementDenial() async throws {
        try await withMembershipPair { pair, _, receiver, f, _ in
            try await receiver.removePeerIntakeForTesting(
                peerID: "isolation-lifecycle", origins: [f.origin], operationID: Fixture.id())
            do {
                _ = try await pair.value(pair.a.request(.init("inventory")))
                XCTFail("retired remote received normal metadata")
            } catch {
                let denial = try XCTUnwrap(error as? TractandaError)
                XCTAssertEqual(denial.code, "peerRetired")
                XCTAssertEqual(denial.message, "Peer operation failed.")
                XCTAssertNil(denial.osError)
            }
        }
    }
    func testExistingSessionCannotInitiateRequestToRetiredActualRemote() async throws {
        try await withMembershipPair { pair, _, receiver, f, _ in
            try await receiver.removePeerIntakeForTesting(
                peerID: "isolation-lifecycle", origins: [f.origin], operationID: Fixture.id())
            do {
                _ = try await pair.value(pair.b.request(.init("inventory")))
                XCTFail("retired remote downloaded through old outgoing session")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerRetired") }
        }
    }
    func testDelayedServerResultReauthorizesBeforeReturningUserData() async throws {
        try await withMembershipPair { pair, _, receiver, f, _ in
            let gate = MembershipPause()
            await receiver.setPeerExchangeAuthorizationHookForTesting { await gate.visit() }
            let future = pair.a.request(.init("inventory"))
            try await pause(gate, pair: pair)
            try await receiver.removePeerIntakeForTesting(
                peerID: "isolation-lifecycle", origins: [f.origin], operationID: Fixture.id())
            await gate.release()
            do {
                _ = try await pair.value(future)
                XCTFail("delayed result escaped after remote retirement")
            } catch {
                XCTAssertEqual((error as? TractandaError)?.code, "peerRetired")
                XCTAssertEqual((error as? TractandaError)?.message, "Peer operation failed.")
            }
        }
    }
    func testDelayedReceivedResponseReauthorizesBeforeCallerSuccess() async throws {
        try await withMembershipPair { pair, source, _, _, remote in
            let gate = MembershipPause(stopAt: 2)
            await source.setPeerExchangeAuthorizationHookForTesting { await gate.visit() }
            let future = pair.a.request(.init("inventory"))
            try await pause(gate, pair: pair)
            try await source.removePeerIntakeForTesting(
                peerID: "isolation-lifecycle", origins: [remote], operationID: Fixture.id())
            await gate.release()
            do {
                _ = try await pair.value(future)
                XCTFail("received data succeeded after actual remote retirement")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "peerRetired") }
        }
    }
    func testDisconnectCancelsPausedResponseAuthorizationWithoutCallerSuccess() async throws {
        try await withMembershipPair { pair, source, _, _, _ in
            let gate = MembershipPause(stopAt: 2)
            await source.setPeerExchangeAuthorizationHookForTesting { await gate.visit() }
            let future = pair.a.request(.init("inventory"))
            try await pause(gate, pair: pair)
            _ = pair.a.close()
            // Process disconnect while the Store-authorization callback is still suspended.
            try await pair.pump()
            await gate.release()
            do {
                _ = try await pair.value(future)
                XCTFail("cancelled authorization returned normal response")
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "serviceClosed") }
        }
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
    func testAuthenticatedBidirectionalOriginalExchangeSurvivesOrdinaryWriteAndResume() async throws {
        let f = try fixture()
        try f.bootstrap()
        // Estimated two-store fixture including the >1MiB original and private copies is24MiB.
        XCTAssertLessThanOrEqual(24 * 1024 * 1024, AttachmentFixtureCapacity.fixtureCapBytes)
        try f.capacity()
        let child = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            try f.source.commit(
                CommitRequest(
                    action: .revise, itemID: f.base.itemID, expectedRevisionID: f.base.revisionID,
                    changes: [
                        "subject": .text("encrypted original"),
                        "body": .text(String(repeating: "x", count: 1024 * 1024)),
                    ],
                    operationID: "large-original"))
        }.revision
        try f.capacity()
        let (left, right) = try paired(f)
        let sourceAccounts = TransportAccounts(f.sourceAccounts)
        let receiverAccounts = TransportAccounts(f.receiverAccounts)
        f.source = nil
        f.receiver = nil
        let source = try await coordinator(f.sourceRoot, sourceAccounts)
        let receiver = try await coordinator(f.receiverRoot, receiverAccounts)
        await receiver.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("receiver gateway diagnostic: " + error.description + "\n").utf8))
        }
        await source.setPeerExchangeFailureHookForTesting { error in
            FileHandle.standardError.write(
                Data(("source gateway diagnostic: " + error.description + "\n").utf8))
        }
        do {
            var pair: ExchangePair? = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver)
            try await pair!.ready()
            FileHandle.standardError.write(Data("fixture: ready\n".utf8))
            // Requesting through b executes on a/source; through a executes on b/receiver.
            let (planID, manifest) = try await prepare(pair!, remote: pair!.b, revisionID: child.revisionID)
            let originals = try await transfer(
                pair!, exporter: pair!.b, importer: pair!.a, manifest: manifest, skip: [child.revisionID])
            let childBytes = try XCTUnwrap(originals[child.revisionID])
            let childDescriptor = PeerPackage.Object(
                kind: .item, id: child.revisionID,
                length: childBytes.count, sha256: AuthorityRecordCodec.sha256(childBytes))
            try f.capacity()
            _ = try await pair!.call(
                pair!.a, "append",
                [
                    "packageID": .text(manifest.packageID),
                    "descriptor": PeerExchangeState.descriptor(childDescriptor),
                    "offset": .integer(0),
                    "bytes": .bytes(Data(childBytes.prefix(PeerPackage.maximumChunkBytes))),
                ])
            try f.capacity()
            let incomplete = try await pair!.call(pair!.a, "resume", ["packageID": .text(manifest.packageID)])
            XCTAssertTrue(
                try AuthorityRecord.list(incomplete["objects"]).contains {
                    $0.map?["descriptor"]?.map?["id"] == .text(child.revisionID)
                        && $0.map?["nextOffset"] == .integer(Int64(PeerPackage.maximumChunkBytes))
                })
            FileHandle.standardError.write(Data("fixture: close pair\n".utf8))
            await pair?.close()
            pair = nil
            pair = try await ExchangePair(
                clientPairing: left, serverPairing: right, source: source, receiver: receiver)
            try await pair!.ready()
            FileHandle.standardError.write(Data("fixture: ready\n".utf8))
            _ = try await pair!.call(
                pair!.b, "exportReopen", ["planID": .text(planID), "packageID": .text(manifest.packageID)])
            let resume = try await pair!.call(pair!.a, "resume", ["packageID": .text(manifest.packageID)])
            let target = try XCTUnwrap(
                try AuthorityRecord.list(resume["objects"]).first {
                    $0.map?["descriptor"]?.map?["id"] == .text(child.revisionID)
                })
            let descriptor = try XCTUnwrap(target.map?["descriptor"])
            let original = try XCTUnwrap(originals[child.revisionID])
            let resumedOffset = try XCTUnwrap(target.map?["nextOffset"]?.integerValue)
            XCTAssertEqual(resumedOffset, Int64(PeerPackage.maximumChunkBytes))
            for offset in stride(
                from: Int(resumedOffset), to: original.count, by: PeerPackage.maximumChunkBytes)
            {
                try f.capacity()
                _ = try await pair!.call(
                    pair!.a, "append",
                    [
                        "packageID": .text(manifest.packageID), "descriptor": descriptor,
                        "offset": .integer(Int64(offset)),
                        "bytes": .bytes(
                            Data(
                                original[offset..<min(original.count, offset + PeerPackage.maximumChunkBytes)]
                            )),
                    ])
                try f.capacity()
            }
            _ = try await nativeCommit(
                receiver,
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("ordinary intervening write")],
                    operationID: "ordinary"), uid: receiverAccounts.base.user(named: "alice").uid)
            FileHandle.standardError.write(Data("fixture: commit incoming\n".utf8))
            let result = try await pair!.call(pair!.a, "commit", ["packageID": .text(manifest.packageID)])
            XCTAssertGreaterThan(result["accepted"]?.integerValue ?? 0, 0)
            let beforeRetry = try canonical(f.receiverRoot)
            let retry = try await pair!.call(pair!.a, "commit", ["packageID": .text(manifest.packageID)])
            XCTAssertEqual(retry, result)
            XCTAssertEqual(try canonical(f.receiverRoot), beforeRetry)
            // A new receiver-authored item goes back through the same protected connection.
            let reverse = try await nativeCommit(
                receiver,
                CommitRequest(
                    classID: "Item", changes: ["subject": .text("reverse original")], operationID: "reverse"),
                uid: receiverAccounts.base.user(named: "alice").uid)
            let (_, reverseManifest) = try await prepare(
                pair!, remote: pair!.a, revisionID: reverse.revisionID)
            let reverseBytes = try await transfer(
                pair!, exporter: pair!.a, importer: pair!.b, manifest: reverseManifest)
            XCTAssertEqual(try RecordCodec.decode(XCTUnwrap(reverseBytes[reverse.revisionID])), reverse)
            let accepted = try await pair!.call(
                pair!.b, "commit", ["packageID": .text(reverseManifest.packageID)])
            XCTAssertGreaterThan(accepted["accepted"]?.integerValue ?? 0, 0)
            FileHandle.standardError.write(Data("fixture: close pair\n".utf8))
            await pair?.close()
            pair = nil
            await source.close()
            await receiver.close()
        } catch {
            await source.close()
            await receiver.close()
            throw error
        }
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        XCTAssertEqual(try f.receiver.get(child.itemID).revisionID, child.revisionID)
        XCTAssertEqual(try RecordCodec.encode(f.receiver.get(child.itemID)), try RecordCodec.encode(child))
        try f.capacity()
    }
    func testCompatibilityReadyWaitsForBothSidesAndCoalescedFirstRequestSurvivesAsymmetricDelay() async throws {
        let f = try fixture(); try f.bootstrap()
        let (left, right) = try paired(f)
        let sourceAccounts = TransportAccounts(f.sourceAccounts), receiverAccounts = TransportAccounts(f.receiverAccounts)
        f.source = nil; f.receiver = nil
        let source = try await coordinator(f.sourceRoot, sourceAccounts), receiver = try await coordinator(f.receiverRoot, receiverAccounts)
        defer { await source.close(); await receiver.close() }
        let gate = MembershipPause()
        await receiver.setPeerExchangeAuthorizationHookForTesting { await gate.visit() }
        defer { await gate.release() }
        let pair = try await ExchangePair(clientPairing: left, serverPairing: right, source: source, receiver: receiver,
            clientMode: .coalesceReadyWithFirstRequest)
        defer { await pair.close() }
        let completed = ExchangeCompletion<Void>()
        pair.a.ready.whenComplete { result in completed.result.withLock { $0 = result.mapError { $0 as? TractandaError ?? .init("testFailure", "ready failed") } } }
        for _ in 0..<4096 {
            try await pair.pump()
            if await gate.paused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let paused = await gate.paused
        XCTAssertTrue(paused)
        XCTAssertNil(completed.result.withLock { $0 }, "Public ready cannot precede the remote final admission/READY")
        do { _ = try await pair.value(pair.a.request(.init("inventory"))); XCTFail("Outgoing work preceded remote READY") }
        catch {}
        await gate.release()
        // Client's local READY is held by the test wire, but its peer READY can now arrive.
        try await pair.value(pair.a.ready)
        let response = try await pair.call(pair.a, "inventory")
        XCTAssertNotNil(response["entries"])
        try await pair.value(pair.b.ready)
        XCTAssertTrue(pair.compatibilityWire.didCoalesce.withLock { $0 })
        try f.capacity()
    }

    func testCompatibilityOldMissingAndOutOfOrderReadyCannotReachOrdinaryExchange() async throws {
        for mode in [CompatibilityWireFixture.Mode.oldDeclaration, .readyBeforeAck, .duplicateReady, .omitAck] {
            let f = try fixture(); try f.bootstrap()
            let (left, right) = try paired(f)
            let before = try canonical(f.receiverRoot)
            let sourceAccounts = TransportAccounts(f.sourceAccounts), receiverAccounts = TransportAccounts(f.receiverAccounts)
            f.source = nil; f.receiver = nil
            let source = try await coordinator(f.sourceRoot, sourceAccounts), receiver = try await coordinator(f.receiverRoot, receiverAccounts)
            defer { await source.close(); await receiver.close() }
            var limits = PeerExchangeLimits(); limits.operationSeconds = 1
            var pair: ExchangePair?
            do {
                pair = try await ExchangePair(clientPairing: left, serverPairing: right, source: source, receiver: receiver,
                    limits: limits, clientMode: mode)
                if mode == .omitAck, let pair {
                    for _ in 0..<4096 {
                        try await pair.pump()
                        if pair.compatibilityWire.didOmitAck.withLock({ $0 }) { break }
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    XCTAssertTrue(pair.compatibilityWire.didOmitAck.withLock { $0 })
                    await pair.client.testingEventLoop.advanceTime(by: .seconds(2))
                    await pair.server.testingEventLoop.advanceTime(by: .seconds(2))
                    do { try await pair.value(pair.a.ready); XCTFail("Missing ACK did not time out") }
                    catch { XCTAssertEqual((error as? TractandaError)?.code, "deadlineExceeded") }
                } else {
                    try await pair!.ready()
                    if mode != .duplicateReady { XCTFail("Old/unordered compatibility controls admitted") }
                }
            } catch {}
            if let pair {
                for _ in 0..<256 {
                    try await pair.pump()
                    if !pair.server.isActive && !pair.client.isActive { break }
                    await Task.yield()
                }
                XCTAssertFalse(pair.server.isActive, "Invalid preflight must close before fixture cleanup")
                XCTAssertFalse(pair.client.isActive, "Invalid preflight must close before fixture cleanup")
                do { _ = try await pair.value(pair.a.request(.init("inventory"))); XCTFail("Refused session dispatched ordinary exchange") }
                catch {}
                await pair.close()
            }
            await source.close(); await receiver.close()
            XCTAssertEqual(try canonical(f.receiverRoot), before)
            try f.capacity()
        }
    }

    func testCompatibilityFinalFreshnessRejectsFloorAdvanceAndCancellationBeforeReady() async throws {
        for scenario in 0..<3 {
            let advance = scenario == 0
            let f = try fixture(); try f.bootstrap()
            let (left, right) = try paired(f)
            let sourceAccounts = TransportAccounts(f.sourceAccounts), receiverAccounts = TransportAccounts(f.receiverAccounts)
            f.source = nil; f.receiver = nil
            let source = try await coordinator(f.sourceRoot, sourceAccounts), receiver = try await coordinator(f.receiverRoot, receiverAccounts)
            defer { await source.close(); await receiver.close() }
            let gate = MembershipPause()
            defer { await gate.release() }
            await receiver.setPeerExchangeAuthorizationHookForTesting { await gate.visit() }
            let pair = try await ExchangePair(clientPairing: left, serverPairing: right, source: source, receiver: receiver,
                clientMode: scenario == 2 ? .precommitHeader : .normal)
            for _ in 0..<4096 {
                try await pair.pump()
                if await gate.paused { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let paused = await gate.paused
            XCTAssertTrue(paused)
            let floor = f.receiverRoot.appendingPathComponent(CanonicalReaderRequirement.fileName)
            let original = try Data(contentsOf: floor)
            if advance {
                let prior = try JSON.decode(CanonicalReaderRequirement.self, original)
                try JSON.encode(CanonicalReaderRequirement(storeID: prior.storeID, minimumReaderLevel: 15,
                    recordFormats: prior.recordFormats, capabilities: prior.capabilities)).write(to: floor)
            } else if scenario == 1 { try await pair.value(pair.b.close()) }
            else {
                for _ in 0..<4096 {
                    try await pair.pump()
                    if !pair.server.isActive { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertFalse(pair.server.isActive, "A precommit ordinary header must refuse without reading its 2 MiB body")
            }
            await gate.release()
            do { try await pair.ready(); XCTFail("Floor advance/cancel admitted ready") }
            catch {}
            await pair.close()
            try original.write(to: floor)
            await source.close(); await receiver.close()
            try f.capacity()
        }
    }

}
