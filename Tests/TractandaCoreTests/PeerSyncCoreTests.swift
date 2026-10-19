import XCTest

@testable import TractandaCore

final class PeerSyncCoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func fixture() throws -> Fixture {
        try Fixture(directory: GuardedFixtureDirectory.create(prefix: "c", source: "PeerSyncCoreTests", test: name))
    }
    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add(_ bytes: Int) { lock.lock(); value += bytes; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func compare(_ f: Fixture, _ objects: [PeerPackage.Object], after: Int = 0,
        bytes: UInt64 = 32 * 1024 * 1024) throws -> PeerNeedsTransfer.Page {
        try f.receiver.peerNeedsTransfer(context: f.context, objects: objects, after: after,
            limits: .init(maximumReadBytes: bytes), progress: {})
    }

    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for relative in ["items", "authority/records", "authority/intake", "authority/locators"] {
            let folder = root.appendingPathComponent(relative)
            guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in iterator {
                let metadata = try FileMetadata.read(at: file)
                guard metadata.type == .regular else { continue }
                let path = String(file.path.dropFirst(root.path.count + 1))
                result[path] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
            }
        }
        return result
    }

    private func binding(_ f: Fixture) throws -> PeerExchangeBinding {
        try PeerExchangeBinding(peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: try XCTUnwrap(f.receiver.replicaID),
            remoteReplicaID: f.origin, pairingID: try Fixture.id(), localIsInitiator: false,
            configurationDigest: f.context.configurationDigest)
    }

    func testAcceptedAndStoredHeldObjectsAreKnownCompleteWithoutCanonicalWrites() throws {
        let f = try fixture()
        try f.bootstrap()
        let accepted = try f.source.peerMetadataObjects(revisionID: f.base.revisionID)
        let before = try snapshot(f.receiverRoot)
        let acceptedPage = try compare(f, accepted.map(\.0))
        XCTAssertEqual(acceptedPage.objects.map(\.state), Array(repeating: .knownComplete, count: accepted.count))
        XCTAssertEqual(try snapshot(f.receiverRoot), before)

        f.receiverAccounts.bobHasGroup = false
        let held = try f.edit(uid: f.sourceAccounts.bob)
        let heldObjects = try f.source.peerMetadataObjects(revisionID: held.revisionID)
        XCTAssertEqual(try f.send(f.packet(heldObjects)).held, 1)
        let heldBefore = try snapshot(f.receiverRoot)
        let heldPage = try compare(f, heldObjects.map(\.0))
        XCTAssertEqual(heldPage.objects.map(\.state), Array(repeating: .knownComplete, count: heldObjects.count))
        XCTAssertEqual(try snapshot(f.receiverRoot), heldBefore)
        try f.capacity()
    }

    func testPinnedLegacyProofIsRecognizedForRelayedObject() throws {
        let f = try fixture()
        func legacy() throws -> (PeerPackage.Object, Data) {
            var fields = f.base.fields
            fields.removeValue(forKey: "revisionAncestry")
            fields["itemID"] = .text(try Fixture.id())
            let id = try Fixture.id()
            fields["revisionID"] = .text(id)
            fields["actor"] = .text("user:retired")
            let raw = try RecordCodec.encode(Revision(fields: fields, formatVersion: 1))
            return (.init(kind: .item, id: id, length: raw.count, sha256: AuthorityRecordCodec.sha256(raw)), raw)
        }
        let pinned = try legacy()
        try f.bootstrap(extra: [pinned])
        let page = try compare(f, [pinned.0])
        XCTAssertEqual(page.objects.map(\.state), [.knownComplete])
        try f.capacity()
    }

    func testComparisonReadWindowAdvancesDescriptorOffsetInsteadOfRestartingPrefix() throws {
        let f = try fixture()
        for n in 0..<24 { _ = try f.edit(subject: "bounded-prefix-\(n)") }
        try f.bootstrap()
        var descriptors: [String: PeerPackage.Object] = [:]
        for row in try f.source.exportCatalogueForVerification() {
            for (object, _) in try f.source.peerMetadataObjects(revisionID: row.revisionID) {
                descriptors[object.id] = object
            }
        }
        let objects = descriptors.values.sorted { $0.id < $1.id }
        XCTAssertGreaterThan(objects.count, 8)
        let cap: UInt64 = 64 * 1024
        let first = try compare(f, objects, bytes: cap)
        XCTAssertFalse(first.objects.isEmpty)
        XCTAssertTrue(first.objects.allSatisfy { $0.state == .knownComplete })
        XCTAssertGreaterThan(first.nextOffset, 0)
        XCTAssertEqual(first.objects.count, first.nextOffset)
        XCTAssertFalse(first.complete)
        XCTAssertLessThan(first.nextOffset, objects.count)
        var page = first
        var previousOffset = 0
        for _ in 0..<128 where !page.complete {
            XCTAssertGreaterThan(page.nextOffset, previousOffset)
            XCTAssertTrue(page.objects.allSatisfy { $0.state == .knownComplete })
            XCTAssertEqual(page.objects.count, page.nextOffset - previousOffset)
            previousOffset = page.nextOffset
            page = try compare(f, objects, after: previousOffset, bytes: cap)
        }
        XCTAssertTrue(page.complete)
        XCTAssertGreaterThan(page.nextOffset, previousOffset)
        try f.capacity()
    }

    func testComparisonRejectsTooManyAndCollidingDescriptors() throws {
        let f = try fixture()
        try f.bootstrap()
        let object = try XCTUnwrap(f.source.peerMetadataObjects(revisionID: f.base.revisionID).first?.0)
        let many = try (0..<129).map { _ in
            PeerPackage.Object(kind: .item, id: try Fixture.id(), length: 1,
                sha256: AuthorityRecordCodec.sha256(Data("x".utf8)))
        }
        XCTAssertThrowsError(try compare(f, many), "Descriptor count must be capped at 128.")
        let collision = PeerPackage.Object(kind: object.kind, id: object.id,
            length: object.length + 1, sha256: AuthorityRecordCodec.sha256(Data("different".utf8)))
        XCTAssertThrowsError(try compare(f, [object, collision]))
        XCTAssertThrowsError(try compare(f, [collision])) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
        try f.capacity()
    }

    func testOneStreamedOriginalCanAdvanceUnderTheSameSmallReadWindow() throws {
        let f = try fixture()
        let payload = Data((0..<262_771).map { UInt8($0 % 251) })
        let (revision, attachment) = try f.source.withAccess(forUID: f.sourceAccounts.alice) {
            let upload = try f.source.beginAttachment(.init(itemID: f.base.itemID,
                expectedRevisionID: f.base.revisionID, operationID: try Fixture.id(),
                filename: "small-window.bin", mediaType: "application/octet-stream",
                byteCount: Int64(payload.count), sha256: AuthorityRecordCodec.sha256(payload)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            for offset in stride(from: 0, to: payload.count, by: PeerPackage.maximumPayloadChunkBytes) {
                _ = try f.source.appendAttachment(uploadID: uploadID, offset: Int64(offset),
                    data: Data(payload[offset..<min(payload.count, offset + PeerPackage.maximumPayloadChunkBytes)]))
            }
            return (try f.source.finishAttachment(uploadID: uploadID).revision, upload.attachment)
        }
        let object = PeerPackage.Object(kind: .attachment, id: attachment.attachmentID,
            length: payload.count, sha256: attachment.sha256)
        try f.bootstrap(extra: [(object, payload)])
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        let limits = PeerNeedsTransfer.Limits(maximumReadBytes: 64 * 1024)
        let revisionObject = try XCTUnwrap(f.source.peerMetadataObjects(revisionID: revision.revisionID)
            .first(where: { $0.0.id == revision.revisionID })?.0)
        let metadataReads = ReadCounter(), payloadReads = ReadCounter()
        func comparePayload() throws -> PeerNeedsTransfer.Page {
            try f.receiver.observePeerOriginalReadsForTesting({ actual, count in
                if actual == object { payloadReads.add(count) }
            }) {
                try DocumentContentFiles.observeReadsForTesting(root: f.receiverRoot,
                    observation: { _, count in metadataReads.add(count) }) {
                    try f.receiver.peerNeedsTransfer(context: f.context, objects: [revisionObject],
                        limits: limits, progress: {})
                }
            }
        }
        let first = try comparePayload()
        XCTAssertEqual(first.objects.map(\.state), [.deferred])
        XCTAssertGreaterThan(payloadReads.total, 0)
        XCTAssertLessThanOrEqual(payloadReads.total + metadataReads.total, Int(limits.maximumReadBytes))
        var page = first
        for _ in 0..<32 where page.objects.first?.state != .knownComplete {
            let payloadBefore = payloadReads.total, metadataBefore = metadataReads.total
            page = try comparePayload()
            let payloadDelta = payloadReads.total - payloadBefore
            XCTAssertGreaterThan(payloadDelta, 0, "Same fixed allowance advances actual payload hashing.")
            XCTAssertLessThanOrEqual(payloadDelta + metadataReads.total - metadataBefore,
                Int(limits.maximumReadBytes), "Metadata and actual body reads share the fixed allowance.")
        }
        XCTAssertEqual(page.objects.map(\.state), [.knownComplete])
        XCTAssertEqual(payloadReads.total, payload.count, "Exact payload bytes are read cumulatively once, without restarting the hash prefix.")
        let scope = PeerIntakeCoordinator(root: f.receiverRoot, ownerUID: f.receiver.ownerUID, storeID: f.storeID)
        let charge = scope.admissionReadBudget()
        try scope.withOperation(maximumReadBytes: 1024) {
            try charge(100)
            do {
                try scope.withOperation(maximumReadBytes: 200) {
                    try charge(150)
                    XCTAssertThrowsError(try charge(51), "Nested cap cannot spend parent allowance.")
                    throw TractandaError("fixtureBudgetAbort", "Unwind this bounded test scope.")
                }
            } catch { XCTAssertEqual((error as? TractandaError)?.code, "fixtureBudgetAbort") }
            XCTAssertEqual(scope.operationReadBytesForTesting, 250, "Unwind restores parent capacity but never refunds consumed bytes.")
            try charge(774)
            XCTAssertThrowsError(try charge(1))
        }
        XCTAssertEqual(try f.receiver.get(revision.itemID).revisionID, revision.revisionID)
        try f.capacity()
    }

    func testLostAdmittedSealRequiresRepairWarmAndColdFromLocatorEvidence() throws {
        let f = try fixture()
        try f.bootstrap()
        let objects = try f.source.peerMetadataObjects(revisionID: f.base.revisionID)
        let packet = try f.packet(objects)
        _ = try f.send(packet)
        let intake = f.receiverRoot.appendingPathComponent("authority/intake/\(packet.manifest.packageID)")
        let seal = intake.appendingPathComponent("sealed.json")
        try FileManager.default.removeItem(at: seal)
        let evidence = f.receiverRoot.appendingPathComponent(
            "authority/locators/\(packet.manifest.packageID)/\(objects[0].0.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidence.path))
        let applied = intake.appendingPathComponent("applied.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: applied.path))
        XCTAssertThrowsError(try f.receiver.commitPeerIntake(context: f.context,
            packageID: packet.manifest.packageID, expectedContextToken: f.receiver.peerIntakeContextToken())) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerRepairRequired")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path), "Repair denial must not reseal the package.")
        try FileManager.default.removeItem(at: applied)
        f.receiver = nil
        try FileManager.default.removeItem(at: f.receiverRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try Fixture.open(f.receiverRoot, f.receiverAccounts)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerRepairRequired")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path), "Cold recovery must not recreate the lost seal.")
        try f.capacity()
    }

    func testNeverSealedInitialPackageRemainsAnOrdinaryIncompleteStage() throws {
        let f = try fixture()
        try f.bootstrap()
        let incoming = try f.edit(subject: "ordinary unsealed stage")
        let object = try XCTUnwrap(f.source.peerMetadataObjects(revisionID: incoming.revisionID)
            .first(where: { $0.0.id == incoming.revisionID })?.0)
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: incoming.revisionID))
        _ = try f.receiver.beginPeerIntake(context: f.context, manifestBytes: JSON.encode(packet.manifest))
        let rootPage = packet.objects[0]
        XCTAssertEqual(rootPage.0.kind, .index)
        _ = try f.receiver.appendPeerObject(context: f.context, packageID: packet.manifest.packageID,
            object: rootPage.0, offset: 0, bytes: rootPage.1)
        let staged = try f.receiver.resumePeerIntake(context: f.context, packageID: packet.manifest.packageID)
        XCTAssertEqual(staged.state.phase, .staged)
        XCTAssertTrue(staged.objects.contains { $0.descriptor.id == object.id && !$0.verifiedComplete })
        for body in packet.objects.dropFirst() {
            for offset in stride(from: 0, to: body.1.count, by: body.0.chunkBytes) {
                _ = try f.receiver.appendPeerObject(context: f.context, packageID: packet.manifest.packageID,
                    object: body.0, offset: offset,
                    bytes: Data(body.1[offset..<min(body.1.count, offset + body.0.chunkBytes)]))
            }
        }
        let result = try f.receiver.commitPeerIntake(context: f.context,
            packageID: packet.manifest.packageID, expectedContextToken: f.receiver.peerIntakeContextToken())
        XCTAssertGreaterThan(result.accepted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.receiverRoot
            .appendingPathComponent("authority/intake/\(packet.manifest.packageID)/sealed.json").path))
        try f.capacity()
    }

    func testMissingInterruptedMalformedCASAndSecurityResetCheckpointBehavior() throws {
        let f = try fixture()
        let b = try binding(f)
        let files = DocumentContentFiles(root: f.receiverRoot, ownerUID: f.receiver.ownerUID,
            minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        let store = PeerSyncWorkStore(files: files)
        var initial = try store.load(binding: b, security: "security-a")
        XCTAssertEqual(initial.sequence, 0)
        XCTAssertNil(initial.outbound)
        initial.outbound = try PeerSyncWork.transfer(roots: [Fixture.id()])

        let checkpointDir = f.receiverRoot.appendingPathComponent("authority/sync-work/\(b.pairingID)")
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let interrupted = checkpointDir.appendingPathComponent(".peer-checkpoint-\(try Fixture.id()).tmp")
        try Data("partial publication".utf8).write(to: interrupted)
        XCTAssertEqual(try store.load(binding: b, security: "security-a").sequence, 0)

        let firstSaved = try store.save(initial, binding: b, security: "security-a")
        XCTAssertEqual(firstSaved.sequence, 1)
        XCTAssertEqual(try store.load(binding: b, security: "security-a").outbound?.packageID,
            initial.outbound?.packageID)
        XCTAssertThrowsError(try store.save(initial, binding: b, security: "security-a"),
            "A stale sequence must fail compare-and-swap.")
        let reset = try store.load(binding: b, security: "security-b")
        XCTAssertEqual(reset.sequence, 1)
        XCTAssertNil(reset.outbound)
        let cleared = try store.save(reset, binding: b, security: "security-b")
        XCTAssertEqual(cleared.sequence, 2)
        XCTAssertNil(try store.load(binding: b, security: "security-b").outbound)

        let checkpoint = checkpointDir.appendingPathComponent("checkpoint.json")
        try FileManager.default.removeItem(at: checkpoint)
        let missingAgain = try store.load(binding: b, security: "security-a")
        XCTAssertEqual(missingAgain.sequence, 0)
        XCTAssertNil(missingAgain.outbound, "Missing scheduling state is advisory and starts empty.")
        _ = try store.save(missingAgain, binding: b, security: "security-a")
        try Data("{malformed".utf8).write(to: checkpoint, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.path)
        let malformed = try Data(contentsOf: checkpoint)
        XCTAssertThrowsError(try store.load(binding: b, security: "security-a"),
            "Malformed present state must not be treated as a missing checkpoint.")
        XCTAssertEqual(try Data(contentsOf: checkpoint), malformed, "Malformed state must not be silently replaced.")
        try f.capacity()
    }
}
