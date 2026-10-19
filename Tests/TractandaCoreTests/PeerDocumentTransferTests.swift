import Crypto
import XCTest

@testable import TractandaCore

final class PeerDocumentTransferTests: XCTestCase {
    struct Fixture {
        let root: URL
        let contents: DocumentContentStore
        let quota: StagingByteQuota
        let originals: PeerOriginalTransfer
        let transfer: PeerDocumentTransfer
    }
    struct Tree {
        let manifest: PeerPackage.Object
        let raw: Data
        let reference: DocumentContentReference
        let parts: [(PeerPackage.Object, Data)]
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func fixture(
        root existing: URL? = nil, maximum: Int64 = 8 * 1024 * 1024,
        available: (@Sendable () throws -> UInt64)? = nil
    ) throws -> Fixture {
        // At most two 256KiB chunks plus 17 bytes and tiny proof trees; <4MiB per root.
        try AttachmentFixtureCapacity.requireFree()
        let root =
            try existing
            ?? (try GuardedFixtureDirectory.parent()).appendingPathComponent("peer-document-" + id())
        if existing == nil {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(CanonicalReaderRequirement.fileName).path)
        {
            // Establish genuine local format-2 history before private authority-work directories.
            let store = try ItemStore(root: root)
            _ = try store.commit(CommitRequest(classID: "Item", operationID: "document-receiver-marker"))
        }
        let recovery = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        try recovery.preparePlacement()
        let quota = try StagingByteQuota(
            root: root, ownerUID: getuid(), maximumBytes: maximum, documents: recovery)
        let payloads = try AttachmentPayloadStore(
            root: root, ownerUID: getuid(),
            reserveBytes: AttachmentFixtureCapacity.reserveBytes, stagingQuota: quota)
        let originals = try PeerOriginalTransfer(
            root: root, ownerUID: getuid(), payloads: payloads, quota: quota,
            reserveBytes: AttachmentFixtureCapacity.reserveBytes)
        try originals.cleanupOldVerificationWork()
        let contents = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes,
            stagingQuota: quota)
        let transfer = PeerDocumentTransfer(
            root: root, ownerUID: getuid(), contents: contents, originals: originals,
            quota: quota, reserveBytes: AttachmentFixtureCapacity.reserveBytes, availableBytes: available)
        return .init(root: root, contents: contents, quota: quota, originals: originals, transfer: transfer)
    }
    private func tree(
        opaquePage: Data? = nil, source suppliedSource: AttachmentDocumentSource? = nil,
        preservedWhitespace: Bool = false
    ) throws
        -> Tree
    {
        let content = try id()
        let source =
            try suppliedSource
            ?? AttachmentDocumentSource(
                itemID: id(), revisionID: id(), attachmentID: id(),
                sha256: String(repeating: "a", count: 64), byteCount: 32 * 1024 * 1024,
                mediaType: "application/pdf")
        var nodes: [(PeerPackage.Object, Data)] = []
        var pages: [(PeerPackage.Object, Data)] = []
        var children: [DocumentHashEntry] = []
        for number in 1...2 {
            var page =
                try opaquePage
                ?? JSON.encode(
                    DocumentStoredPage(
                        pageNumber: Int64(number), sourceSHA256: source.sha256,
                        status: number == 1 ? "failed" : "timeout", failureCode: "fixture"))
            if preservedWhitespace { page.append(Data(" \n\t".utf8)) }
            let descriptor = PeerPackage.Object(
                kind: .document, id: content, length: page.count, sha256: hash(page),
                part: .init(role: .page, level: 0, ordinal: Int64(number)))
            pages.append((descriptor, page))
            let entry = DocumentHashEntry(
                ordinal: Int64(number), firstPage: Int64(number), lastPage: Int64(number),
                byteCount: Int64(page.count), sha256: hash(page))
            let node = try JSON.encode(
                DocumentHashNode(
                    schema: "tractanda.document-node.v2", level: 0,
                    ordinal: Int64(number - 1), entries: [entry]))
            nodes.append(
                (
                    .init(
                        kind: .document, id: content, length: node.count, sha256: hash(node),
                        part: .init(role: .node, level: 0, ordinal: Int64(number - 1))), node
                ))
            children.append(
                .init(
                    ordinal: Int64(number - 1), firstPage: Int64(number), lastPage: Int64(number),
                    byteCount: Int64(node.count), sha256: hash(node)))
        }
        let root = try JSON.encode(
            DocumentHashNode(schema: "tractanda.document-node.v2", level: 1, ordinal: 0, entries: children))
        let rootObject = PeerPackage.Object(
            kind: .document, id: content, length: root.count, sha256: hash(root),
            part: .init(role: .node, level: 1, ordinal: 0))
        let coverage = try DocumentCoverage(converted: 0, timedOut: 1, failed: 1)
        let total = pages.reduce(Int64(0)) { $0 + Int64($1.1.count) }
        var raw = try JSON.encode(
            DocumentManifest(
                schema: "tractanda.document-manifest.v2", contentID: content,
                publicationID: id(), source: source, identity: .init(), extractedAt: "2026-10-16T00:00:00Z",
                rootLevel: 1,
                rootByteCount: Int64(root.count), rootSHA256: hash(root), pageCount: 2,
                totalEncodedBytes: total, coverage: coverage))
        raw.append(Data("\n".utf8))
        let manifest = PeerPackage.Object(
            kind: .document, id: content, length: raw.count, sha256: hash(raw), part: .manifest)
        let reference = try DocumentContentReference(
            contentID: content, manifestSHA256: hash(raw), rootSHA256: hash(root),
            pageCount: 2, totalEncodedBytes: total, coverage: coverage)
        return .init(
            manifest: manifest, raw: raw, reference: reference, parts: [(rootObject, root)] + nodes + pages)
    }
    private func send(_ part: (PeerPackage.Object, Data), package: String, transfer: PeerDocumentTransfer)
        throws
    {
        for offset in stride(from: 0, to: part.1.count, by: PeerPackage.maximumPayloadChunkBytes) {
            let end = min(part.1.count, offset + PeerPackage.maximumPayloadChunkBytes)
            try AttachmentFixtureCapacity.requireFree()
            try transfer.append(
                packageID: package, object: part.0, offset: offset, bytes: part.1.subdata(in: offset..<end))
        }
    }
    private func proofs(_ tree: Tree, package: String, transfer: PeerDocumentTransfer) throws {
        try transfer.anchor(packageID: package, manifest: tree.manifest)
        try send((tree.manifest, tree.raw), package: package, transfer: transfer)
        for part in tree.parts where part.0.part?.role == .node {
            try send(part, package: package, transfer: transfer)
        }
    }
    func testProofAuthorizedMultiNodePartsPublishExactPartialTreeAndRetainQuota() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let package = try id()
        let tree = try tree()
        XCTAssertThrowsError(
            try f.transfer.append(packageID: package, object: tree.manifest, offset: 0, bytes: tree.raw))
        try proofs(tree, package: package, transfer: f.transfer)
        for part in tree.parts where part.0.part?.role == .page {
            try send(part, package: package, transfer: f.transfer)
        }
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        let held = f.quota.usedBytes
        try f.contents.publishExact(stage: binding.stage, reference: tree.reference, manifestBytes: tree.raw)
        XCTAssertEqual(f.quota.usedBytes, held, "Published-unapplied tree stays pinned")
        XCTAssertEqual(try f.contents.manifest(tree.reference).rootLevel, 1)
        XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
        let canonical = try f.contents.directory(tree.manifest.id).reduce(f.root) {
            $0.appendingPathComponent($1)
        }
        XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent("manifest.json")), tree.raw)
        let restarted = try fixture(root: f.root)
        XCTAssertGreaterThanOrEqual(restarted.quota.usedBytes, tree.reference.totalEncodedBytes)
        XCTAssertTrue(
            try restarted.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
    }
    func testUnreachableAndChangedEdgeNeverAdmitPartBytes() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try f.transfer.anchor(packageID: package, manifest: tree.manifest)
        let node = tree.parts[0]
        XCTAssertThrowsError(try send(node, package: package, transfer: f.transfer))
        try proofs(tree, package: package, transfer: f.transfer)
        let page = try XCTUnwrap(tree.parts.last)
        var forged = page.0
        forged.part = .init(role: .page, level: 0, ordinal: 3)
        XCTAssertThrowsError(try send((forged, page.1), package: package, transfer: f.transfer))
        let changed = PeerPackage.Object(
            kind: .document, id: page.0.id, length: page.0.length,
            sha256: String(repeating: "f", count: 64), part: page.0.part)
        XCTAssertThrowsError(try send((changed, page.1), package: package, transfer: f.transfer))
        XCTAssertEqual(try f.transfer.resume(packageID: package, object: page.0).nextOffset, 0)
    }
    func testThreeChunkPartReopensAndVerifiesThroughTinyReadWindows() throws {
        var f: Fixture? = try fixture()
        let root = try XCTUnwrap(f).root
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x78, count: 2 * PeerPackage.maximumPayloadChunkBytes + 17)
        let tree = try tree(opaquePage: bytes)
        let package = try id()
        try proofs(tree, package: package, transfer: XCTUnwrap(f).transfer)
        let page = try XCTUnwrap(tree.parts.last).0
        for offset in [0, PeerPackage.maximumPayloadChunkBytes] {
            try XCTUnwrap(f).transfer.append(
                packageID: package, object: page, offset: offset,
                bytes: bytes.subdata(in: offset..<(offset + PeerPackage.maximumPayloadChunkBytes)))
        }
        let retryBudget = PeerOriginalReadBudget()
        try XCTUnwrap(f).transfer.append(
            packageID: package, object: page, offset: 0,
            bytes: Data(bytes.prefix(PeerPackage.maximumPayloadChunkBytes)), budget: retryBudget)
        XCTAssertGreaterThanOrEqual(
            retryBudget.used, UInt64(PeerPackage.maximumPayloadChunkBytes),
            "A partial-stage retry charges the actual byte comparison even when its prefix is cached")
        f = nil
        let reopened = try fixture(root: root)
        var continuations = 0
        while true {
            do {
                let state = try reopened.transfer.resume(
                    packageID: package, object: page,
                    budget: .init(bytes: 128 * 1024, maximumSteps: 64))
                XCTAssertEqual(state.nextOffset, 2 * PeerPackage.maximumPayloadChunkBytes)
                XCTAssertFalse(state.verifiedComplete)
                break
            } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
                continuations += 1
                XCTAssertLessThan(continuations, 16)
            }
        }
        XCTAssertGreaterThan(continuations, 0)
        try reopened.transfer.append(
            packageID: package, object: page, offset: 2 * PeerPackage.maximumPayloadChunkBytes,
            bytes: Data(bytes.suffix(17)))
        XCTAssertTrue(try reopened.transfer.resume(packageID: package, object: page).verifiedComplete)
        try reopened.transfer.append(
            packageID: package, object: page, offset: 0,
            bytes: Data(bytes.prefix(PeerPackage.maximumPayloadChunkBytes)))
        XCTAssertThrowsError(
            try reopened.transfer.append(
                packageID: package, object: page, offset: 0,
                bytes: Data(repeating: 0x79, count: PeerPackage.maximumPayloadChunkBytes)))
    }
    func testMissingAcknowledgmentAndAlignedTruncationFailClosed() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = Data(repeating: 0x78, count: 2 * PeerPackage.maximumPayloadChunkBytes + 17)
        let tree = try tree(opaquePage: bytes)
        let package = try id()
        try proofs(tree, package: package, transfer: f.transfer)
        let page = try XCTUnwrap(tree.parts.last).0
        try f.transfer.append(
            packageID: package, object: page, offset: 0,
            bytes: Data(bytes.prefix(PeerPackage.maximumPayloadChunkBytes)))
        let base = f.root.appendingPathComponent(
            "authority/document-transfers/\(package)/\(page.id)/parts/page/0/2")
        let binding = try PeerPackage.decode(
            PeerDocumentTransfer.PartBinding.self,
            Data(contentsOf: base.appendingPathComponent("binding.json")), maximum: 4096)
        let path = f.root.appendingPathComponent("attachments/.staging/" + binding.stageID + ".stage")
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 0)
        try handle.synchronize()
        try handle.close()
        XCTAssertThrowsError(try f.transfer.resume(packageID: package, object: page)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
        try FileManager.default.removeItem(at: base.appendingPathComponent("high-water.json"))
        XCTAssertThrowsError(try f.transfer.resume(packageID: package, object: page)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
    }
    func testProofIntentInterruptionResumesExactBytesAndRejectsAlteredRetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try f.transfer.anchor(packageID: package, manifest: tree.manifest)
        f.transfer.afterProofIntentForTesting = { throw TractandaError("injected", "Before part append") }
        XCTAssertThrowsError(try send((tree.manifest, tree.raw), package: package, transfer: f.transfer))
        f.transfer.afterProofIntentForTesting = nil
        XCTAssertEqual(try f.transfer.resume(packageID: package, object: tree.manifest).nextOffset, 0)
        try send((tree.manifest, tree.raw), package: package, transfer: f.transfer)
        var changed = tree.raw
        changed[0] ^= 1
        XCTAssertThrowsError(try send((tree.manifest, changed), package: package, transfer: f.transfer))
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
    }
    func testAdoptionRenameFailureRepairsDurabilityAndAccountingBeforeAcknowledgment() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        let binding = try f.transfer.anchor(packageID: package, manifest: tree.manifest)
        f.transfer.afterPartRenameForTesting = {
            throw TractandaError("injected", "After part rename before sync")
        }
        XCTAssertThrowsError(try send((tree.manifest, tree.raw), package: package, transfer: f.transfer))
        XCTAssertEqual(
            f.quota.usedBytes(path: binding.stage), 0, "Uncertain rename has not moved its accounting yet")
        f.transfer.afterPartRenameForTesting = nil
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
        XCTAssertEqual(f.quota.usedBytes(path: binding.stage), Int64(tree.raw.count))
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
        XCTAssertEqual(f.quota.usedBytes(path: binding.stage), Int64(tree.raw.count))
    }
    func testCapacityFailureDoesNotCreateAnUnaccountedTreeStage() throws {
        let f = try fixture(available: { 0 })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let before = f.quota.usedBytes
        XCTAssertThrowsError(try f.transfer.anchor(packageID: id(), manifest: tree.manifest)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertEqual(f.quota.usedBytes, before)
    }
    func testCallerBudgetIncludesRepeatedAnchorBindingReads() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try f.transfer.anchor(packageID: package, manifest: tree.manifest)
        let path = f.root.appendingPathComponent(
            "authority/document-transfers/\(package)/\(tree.manifest.id)/binding.json")
        let bindingBytes = try Data(contentsOf: path).count
        let before = f.quota.usedBytes
        let empty = PeerOriginalReadBudget(bytes: 0)
        XCTAssertThrowsError(
            try f.transfer.requireReachable(packageID: package, object: tree.manifest, budget: empty)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerPayloadVerifying")
        }
        XCTAssertEqual(empty.used, 0)
        let one = PeerOriginalReadBudget(bytes: UInt64(bindingBytes))
        try f.transfer.requireReachable(packageID: package, object: tree.manifest, budget: one)
        XCTAssertEqual(one.used, UInt64(bindingBytes))
        let limited = PeerOriginalReadBudget(bytes: UInt64(bindingBytes))
        XCTAssertThrowsError(
            try f.transfer.resume(packageID: package, object: tree.manifest, budget: limited)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerPayloadVerifying")
        }
        XCTAssertEqual(
            limited.used, UInt64(bindingBytes), "Second binding read cannot exceed the same caller allowance")
        XCTAssertEqual(f.quota.usedBytes, before)
        XCTAssertEqual(try f.transfer.resume(packageID: package, object: tree.manifest).nextOffset, 0)
    }
    private func document(_ tree: Tree) throws -> AttachmentDocumentRepresentation {
        let manifest = try DocumentValue.strictDecode(DocumentManifest.self, data: tree.raw)
        return try AttachmentDocumentRepresentation(
            representationID: id(), attachmentID: manifest.source.attachmentID,
            source: manifest.source, extractedAt: manifest.extractedAt, identity: manifest.identity,
            content: tree.reference)
    }
    private func verificationIndex(_ f: Fixture) throws -> ItemIndex {
        try ItemIndex(
            path: f.root.appendingPathComponent("index/document-verification-test.sqlite").path, create: true)
    }
    private func sendTree(_ tree: Tree, package: String, fixture f: Fixture) throws {
        try proofs(tree, package: package, transfer: f.transfer)
        for part in tree.parts where part.0.part?.role == .page {
            try send(part, package: package, transfer: f.transfer)
        }
    }
    private func finishVerification(
        _ verifier: PeerDocumentVerification, index: ItemIndex, document: AttachmentDocumentRepresentation,
        package: String, transfer: PeerDocumentTransfer, publish: Bool = false,
        callback: () throws -> Void = {}
    ) throws -> Int {
        var calls = 0
        while true {
            calls += 1
            guard calls < 200 else {
                throw TractandaError("fixture", "Tiny document cursor stopped making progress")
            }
            do {
                if try verifier.step(
                    scope: "test:" + package, document: document,
                    source: .incoming(packageID: package, transfer: transfer),
                    index: index, budget: .init(bytes: 128 * 1024, maximumSteps: 128), maximumUnits: 1,
                    publish: publish, beforePublication: callback)
                {
                    return calls
                }
            } catch let error as TractandaError where error.code == "peerPayloadVerifying" { continue }
        }
    }
    func testSQLCursorCrossesSmallMultiNodeWindowsFreezesAndPublishesExactTree() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let document = try document(tree)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        let calls = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer)
        XCTAssertGreaterThan(calls, 2, "Two-node depth and page edges cross distinct SQL work windows")
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        let files = DocumentContentFiles(
            root: f.root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        XCTAssertEqual(try files.frozenPeerStage(binding.stage)?.reference, tree.reference)
        XCTAssertThrowsError(try send((tree.manifest, tree.raw), package: package, transfer: f.transfer)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerDocumentFrozen")
        }
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
        var publicationChecks = 0
        _ = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer, publish: true
        ) {
            publicationChecks += 1
        }
        XCTAssertGreaterThan(publicationChecks, 0)
        XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
        let canonical = try f.contents.directory(tree.reference.contentID).reduce(f.root) {
            $0.appendingPathComponent($1)
        }
        XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent("manifest.json")), tree.raw)
        XCTAssertGreaterThanOrEqual(f.quota.usedBytes, tree.reference.totalEncodedBytes)
    }
    func testVerificationRestartRetainsTransferredBytesAndUndersizedWindowIsActionable() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let document = try document(tree)
        let index = try verificationIndex(f)
        var verifier: PeerDocumentVerification? = try PeerDocumentVerification(
            contents: f.contents, originals: f.originals)
        XCTAssertThrowsError(
            try XCTUnwrap(verifier).step(
                scope: "test:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(bytes: 4096, maximumSteps: 128), maximumUnits: 1)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        for _ in 0..<4 {
            _ = try XCTUnwrap(verifier).step(
                scope: "test:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(bytes: 128 * 1024, maximumSteps: 128), maximumUnits: 1)
        }
        let held = f.quota.usedBytes
        verifier = nil
        let resumed = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        XCTAssertGreaterThan(
            try finishVerification(
                resumed, index: index, document: document, package: package, transfer: f.transfer), 1)
        XCTAssertGreaterThanOrEqual(f.quota.usedBytes, held)
        for (part, _) in tree.parts {
            XCTAssertTrue(try f.transfer.resume(packageID: package, object: part).verifiedComplete)
        }
    }
    func testDriverRejectsUnusableInitialReadAndWorkWindowsBeforeReading() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let document = try document(tree)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        for budget in [
            PeerOriginalReadBudget(bytes: 0), PeerOriginalReadBudget(bytes: 1),
            PeerOriginalReadBudget(bytes: 128 * 1024, maximumSteps: 0),
        ] {
            XCTAssertThrowsError(
                try verifier.step(
                    scope: "test:" + package, document: document,
                    source: .incoming(packageID: package, transfer: f.transfer),
                    index: index, budget: budget)
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
            XCTAssertEqual(budget.used, 0)
        }
        _ = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer,
            publish: true)
        for budget in [
            PeerOriginalReadBudget(bytes: 0),
            PeerOriginalReadBudget(bytes: UInt64(tree.raw.count - 1)),
            PeerOriginalReadBudget(bytes: 128 * 1024, maximumSteps: 0),
        ] {
            XCTAssertThrowsError(
                try verifier.step(
                    scope: "canonical:" + package, document: document,
                    source: .canonical, index: index, budget: budget)
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
            XCTAssertEqual(budget.used, 0)
        }
        for budget in [
            PeerOriginalReadBudget(bytes: UInt64(tree.raw.count)),
            PeerOriginalReadBudget(bytes: 128 * 1024, maximumSteps: 1),
        ] {
            XCTAssertThrowsError(
                try verifier.step(
                    scope: "canonical:" + package, document: document,
                    source: .canonical, index: index, budget: budget)
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
            XCTAssertEqual(budget.used, UInt64(tree.raw.count), "Seed uses the already hydrated manifest")
        }
    }
    func testFrozenInspectionRejectsLoweredWindowWithoutDiscardingProgress() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let document = try document(tree)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        _ = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer)
        let before = try index.peerDocumentState(scope: "test:" + package, content: tree.manifest.id)
        XCTAssertThrowsError(
            try verifier.step(
                scope: "test:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(bytes: 32 * 1024), maximumUnits: 1, publish: true)
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit") }
        XCTAssertEqual(
            try index.peerDocumentState(scope: "test:" + package, content: tree.manifest.id), before)
        _ = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer,
            publish: true)
        XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 1).status, "failed")
    }
    func testFrozenVerificationDetectsNestedDamageBeforePublication() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let document = try document(tree)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        _ = try finishVerification(
            verifier, index: index, document: document, package: package, transfer: f.transfer)
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        let path = (binding.stage + ["pages", "0", "2.json"]).reduce(f.root) { $0.appendingPathComponent($1) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var raw = try Data(contentsOf: path)
        raw[raw.count / 2] ^= 1
        try raw.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        XCTAssertThrowsError(
            try finishVerification(
                verifier, index: index, document: document, package: package, transfer: f.transfer,
                publish: true)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
        XCTAssertNil(try f.contents.peerDirectory(tree.reference.contentID))
    }
    func testSourceMismatchAndMissingPagesNeverCloseOrPublishTree() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try proofs(tree, package: package, transfer: f.transfer)
        let original = try document(tree)
        let source = try AttachmentDocumentSource(
            itemID: original.source.itemID, revisionID: original.source.revisionID,
            attachmentID: original.source.attachmentID, sha256: original.source.sha256,
            byteCount: original.source.byteCount + 1, mediaType: original.source.mediaType)
        let wrong = try AttachmentDocumentRepresentation(
            representationID: original.representationID,
            attachmentID: original.attachmentID, source: source, extractedAt: original.extractedAt,
            identity: original.identity, content: tree.reference)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        XCTAssertThrowsError(
            try verifier.step(
                scope: "test:" + package, document: wrong,
                source: .incoming(packageID: package, transfer: f.transfer), index: index, budget: .init())
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
        }
        XCTAssertThrowsError(
            try verifier.step(
                scope: "test:" + package, document: original,
                source: .incoming(packageID: package, transfer: f.transfer), index: index, budget: .init())
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "missingDependencies")
        }
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        let files = DocumentContentFiles(
            root: f.root, ownerUID: getuid(), minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        XCTAssertNil(try files.frozenPeerStage(binding.stage))
        XCTAssertNil(try f.contents.peerDirectory(tree.reference.contentID))
    }
    func testJournalProofCursorTransfersMorePartsThanMetadataObjectLimit() throws {
        try exerciseJournalProofCursor(limit: 1, maximumWork: 64, pretransferred: false)
    }
    func testJournalProofCursorReturnsSafeContinuationAtSmallOperationWindows() throws {
        try exerciseJournalProofCursor(limit: 128, maximumWork: 32, pretransferred: true)
    }
    func testCoordinatorRequiresOriginalAndPublishesExactTreeBeforeMetadata() throws {
        try exerciseCoordinatorPublication(changeContext: false)
    }
    func testCoordinatorChecksCurrentContextAtFinalDocumentPublication() throws {
        try exerciseCoordinatorPublication(changeContext: true)
    }
    func testRecoveryYieldsForPositiveButInsufficientSharedReadRemainder() throws {
        try exerciseCoordinatorPublication(changeContext: false, poolRemainder: true)
    }
    func testAppliedDocumentCleanupWaitsForReceiptAndResumesAfterReopen() throws {
        try exerciseCoordinatorPublication(changeContext: false, cleanup: true)
    }
    func testDuplicatePrivateStageDisposalCrossesOneEntryWindows() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let first = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        try f.contents.publishExact(stage: first.stage, reference: tree.reference, manifestBytes: tree.raw)
        let duplicate = try f.transfer.anchor(packageID: id(), manifest: tree.manifest)
        let files = DocumentContentFiles(
            root: f.root, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes, stagingQuota: f.quota)
        for (object, bytes) in [(tree.manifest, tree.raw)] + tree.parts {
            try AttachmentFixtureCapacity.requireFree(at: f.root)
            try files.writeImmutable(
                bytes, path: duplicate.stage + XCTUnwrap(object.part).relativePath,
                maximumBytes: DocumentContentStore.maximumPageBytes)
        }
        try files.freezePeerStage(duplicate.stage, reference: tree.reference)
        var calls = 0
        while true {
            calls += 1
            guard calls < 40 else {
                throw TractandaError("fixture", "One-entry stage cleanup stopped advancing")
            }
            let step = try files.stepAppliedPeerDocumentStage(
                duplicate.stage, reference: tree.reference, maximumEntries: 1)
            XCTAssertLessThanOrEqual(step.used, 1)
            if step.complete { break }
        }
        XCTAssertGreaterThan(calls, tree.parts.count)
        try files.finishAppliedPeerDocumentStage(duplicate.stage, reference: tree.reference)
        XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
    }
    func testDepletedSubwindowRetainsInitialCapacityForAdmission() throws {
        let budget = PeerOriginalReadBudget(bytes: 0, maximumSteps: 32, workingCapacity: 128 * 1024)
        XCTAssertNoThrow(try budget.requireWorkingSet(bytes: 64 * 1024, steps: 16, label: "proof"))
        XCTAssertThrowsError(try budget.charge(1)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "peerPayloadVerifying")
        }
        XCTAssertEqual(budget.used, 0)
    }
    func testCorpusReservationIsReconciledWhenBeginningStepIsCancelled() throws {
        let maximum: Int64 = 512 * 1024
        let f = try fixture(maximum: maximum)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        verifier.corpusBoundary = { batch in
            if batch.phase == .before {
                try f.quota.reserveDerived(
                    workID: batch.workID, estimatedAdditionalBytes: batch.estimatedAdditionalBytes)
                throw TractandaError("cancelled", "Fixture cancellation after corpus reservation")
            } else if batch.phase == .afterCommit {
                try f.quota.observeDerived(
                    workID: batch.workID, retainedEncodedBytes: batch.retainedEncodedBytes)
            }
        }
        XCTAssertThrowsError(
            try verifier.step(
                scope: "test:" + package, document: document(tree),
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(bytes: 128 * 1024, maximumSteps: 128), maximumUnits: 1)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "cancelled")
        }
        XCTAssertNoThrow(try f.quota.require(additionalBytes: maximum - f.quota.usedBytes))
        XCTAssertTrue(try index.retainedCorpusWorkPage().isEmpty)
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
    }
    func testCorpusRebuildUsesAuthenticatedStoredPageLengthsWithoutReencoding() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree(preservedWhitespace: true)
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        try f.contents.publishExact(stage: binding.stage, reference: tree.reference, manifestBytes: tree.raw)
        let document = try document(tree)
        let original = try AttachmentDescriptor(
            attachmentID: document.attachmentID, filename: "tiny.pdf",
            mediaType: document.source.mediaType, byteCount: document.source.byteCount,
            sha256: document.source.sha256)
        let revision = try Revision(fields: [
            "itemID": .text(document.source.itemID), "revisionID": .text(id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
            "attachments": .list([original.itemValue]),
            "attachmentDocument": .list([document.itemValue]),
        ])
        let input = try PageCorpusInput(storeID: id(), revision: revision)
        let summary = try PageCorpusEmitter.emit(
            input, provider: StoredPageCorpusProvider(contents: f.contents, incoming: nil)
        ) { _ in }
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.timedOut, 1)
        for (part, raw) in tree.parts where part.part?.role == .page {
            let path = try f.contents.directory(tree.reference.contentID) + XCTUnwrap(part.part).relativePath
            XCTAssertEqual(try Data(contentsOf: path.reduce(f.root) { $0.appendingPathComponent($1) }), raw)
        }
    }
    func testCorpusProgressRenewsIdleLeaseButExhaustedCallsDoNotAndExpiryReprepares() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let index = try verificationIndex(f)
        let verifier = try PeerDocumentVerification(contents: f.contents, originals: f.originals)
        let document = try document(tree)
        try index.initializePeerDocumentSchema()
        let token = try index.beginPeerDocumentCorpus(packageID: package, document: document) { _ in }
        let old = Date().addingTimeInterval(-7200)
        try index.touchPeerDocumentCorpus(token, now: old)
        XCTAssertFalse(
            try verifier.step(
                scope: "lease:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(), maximumUnits: 1))
        XCTAssertGreaterThan(
            try XCTUnwrap(index.peerDocumentCorpusOwner(token.workID)).progressed,
            old.timeIntervalSince1970 + 1000)
        try index.touchPeerDocumentCorpus(token, now: old)
        XCTAssertThrowsError(
            try verifier.step(
                scope: "lease:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(bytes: 0, maximumSteps: 128, workingCapacity: 8 * 1024 * 1024), maximumUnits: 1)
        )
        XCTAssertLessThan(
            try XCTUnwrap(index.peerDocumentCorpusOwner(token.workID)).progressed,
            old.timeIntervalSince1970 + 1)
        XCTAssertEqual(try index.expirePeerDocumentCorpus(token.workID).count, 1)
        _ = try index.cleanupCorpus(limit: 1)
        var ready = false
        for _ in 0..<32 where !ready {
            ready = try verifier.step(
                scope: "lease:" + package, document: document,
                source: .incoming(packageID: package, transfer: f.transfer), index: index,
                budget: .init(), maximumUnits: 1)
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(try index.peerDocumentCorpusReady(document))
        XCTAssertTrue(try f.transfer.resume(packageID: package, object: tree.manifest).verifiedComplete)
    }
    func testCrossHistoryKindsCannotReuseDocumentOriginalOrMetadataIdentity() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        try sendTree(tree, package: package, fixture: f)
        let binding = try f.transfer.tree(packageID: package, contentID: tree.manifest.id)
        try f.contents.publishExact(stage: binding.stage, reference: tree.reference, manifestBytes: tree.raw)
        let bytes = Data("existing original".utf8)
        let attachment = try AttachmentDescriptor(
            attachmentID: id(), filename: "existing.bin",
            mediaType: "application/octet-stream", byteCount: Int64(bytes.count), sha256: hash(bytes))
        let original = PeerPackage.Object(
            kind: .attachment, id: attachment.attachmentID,
            length: bytes.count, sha256: attachment.sha256)
        let originalPackage = try id()
        try f.originals.append(packageID: originalPackage, object: original, offset: 0, bytes: bytes)
        try f.originals.publish(packageID: originalPackage, object: original, descriptor: attachment)
        let index = try verificationIndex(f)
        try index.initializeAuthoritySchema()
        try index.validateRecoveryGraph(requireLinearProjection: false)
        let revision = try Revision(fields: [
            "itemID": .text(id()), "revisionID": .text(id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-16T00:00:00Z"),
            "modifiedAt": .date("2026-10-16T00:00:00Z"), "actor": .text("fixture"),
            "operationID": .text("identity"), "requestIdentity": .text("identity fixture"),
        ])
        let raw = try RecordCodec.encode(revision)
        let metadata = PeerPackage.Object(
            kind: .item, id: revision.revisionID,
            length: raw.count, sha256: hash(raw))
        let coordinator = PeerIntakeCoordinator(
            root: f.root, ownerUID: getuid(), storeID: try id(), stagingQuota: f.quota)
        coordinator.journal.originals = f.originals
        coordinator.journal.documents = f.transfer
        let path = ["authority", "identity-fixture", revision.revisionID]
        try coordinator.journal.files.writeImmutable(raw, path: path, maximumBytes: raw.count)
        try index.retainAuthorityObject(
            .init(
                descriptor: metadata, path: path.joined(separator: "/"),
                packageID: id(), peerID: "fixture", configurationDigest: hash(Data("fixture".utf8)),
                permittedOrigin: true),
            revision: AuthorityRevision(originalBytes: raw), authority: nil)
        func reject(_ kind: PeerPackage.Kind, _ id: String) throws {
            let object = PeerPackage.Object(
                kind: kind, id: id, length: 1, sha256: hash(Data([0])),
                part: kind == .document ? .manifest : nil)
            XCTAssertThrowsError(try coordinator.requireStorageIdentity(object, index: index)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
            }
        }
        for kind in [PeerPackage.Kind.item, .authority, .attachment, .index] {
            try reject(kind, tree.manifest.id)
        }
        for kind in [PeerPackage.Kind.item, .authority, .document, .index] {
            try reject(kind, attachment.attachmentID)
        }
        for kind in [PeerPackage.Kind.document, .attachment, .index, .authority] {
            try reject(kind, revision.revisionID)
        }
        try reject(.document, revision.itemID)
        XCTAssertNoThrow(try coordinator.requireStorageIdentity(tree.manifest, index: index))
        XCTAssertNoThrow(try coordinator.requireStorageIdentity(original, index: index))
        XCTAssertNoThrow(try coordinator.requireStorageIdentity(metadata, index: index))
    }
    private func exerciseCoordinatorPublication(
        changeContext: Bool, poolRemainder: Bool = false, cleanup: Bool = false
    ) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let package = try id()
        let item = try id()
        let sourceRevisionID = try id()
        let originalBytes = Data("tiny opaque document original; no converter".utf8)
        let attachment = try AttachmentDescriptor(
            attachmentID: id(), filename: "fixture.pdf", mediaType: "application/pdf",
            byteCount: Int64(originalBytes.count), sha256: hash(originalBytes))
        let source = try AttachmentDocumentSource(
            itemID: item, revisionID: sourceRevisionID, attachmentID: attachment.attachmentID,
            sha256: attachment.sha256, byteCount: attachment.byteCount, mediaType: attachment.mediaType)
        let tree = try tree(source: source)
        let document = try document(tree)
        func revision(_ revisionID: String, document: AttachmentDocumentRepresentation? = nil) throws
            -> Revision
        {
            var fields: [String: ItemValue] = [
                "itemID": .text(item), "revisionID": .text(revisionID), "classID": .text("Item"),
                "schemaVersion": .integer(1), "createdAt": .date("2026-10-16T00:00:00Z"),
                "modifiedAt": .date("2026-10-16T00:00:00Z"), "actor": .text("fixture"),
                "operationID": .text(revisionID), "requestIdentity": .text("document storage fixture"),
                "attachments": .list([attachment.itemValue]),
            ]
            if let document {
                fields["attachmentDocument"] = .list([try document.itemValue])
                fields["supersedes"] = .text(sourceRevisionID)
            }
            return try Revision(fields: fields)
        }
        let revisions = try [revision(sourceRevisionID), revision(id(), document: document)].map {
            let raw = try RecordCodec.encode($0)
            return (
                PeerPackage.Object(kind: .item, id: $0.revisionID, length: raw.count, sha256: hash(raw)), raw
            )
        }
        let original = PeerPackage.Object(
            kind: .attachment, id: attachment.attachmentID, length: originalBytes.count,
            sha256: attachment.sha256)
        let raw = try JSON.encode(
            PeerPackage.Page(objects: revisions.map(\.0) + [original, tree.manifest], children: []))
        let root = PeerPackage.Object(kind: .index, id: try id(), length: raw.count, sha256: hash(raw))
        let context = try PeerPackage.Context(
            peerID: "document-coordinator", storeID: id(), configurationDigest: hash(Data("context".utf8)),
            permittedOrigins: [id()])
        var limits = PeerPackage.Limits()
        if poolRemainder { limits.maximumRecoveryReadBytes = 128 * 1024 }
        let coordinator = PeerIntakeCoordinator(
            root: f.root, ownerUID: getuid(), storeID: context.storeID, limits: limits,
            stagingQuota: f.quota)
        coordinator.journal.originals = f.originals
        coordinator.journal.documents = f.transfer
        coordinator.documentVerification = try PeerDocumentVerification(
            contents: f.contents, originals: f.originals)
        try AuthorityStore.writeConfiguration(
            .init(profile: "tractanda.peer-configuration.v1", peers: [context], bootstrap: nil), root: f.root,
            files: coordinator.journal.files)
        _ = try coordinator.journal.begin(
            context: context,
            manifestBytes: JSON.encode(
                PeerPackage.Manifest(packageID: package, storeID: context.storeID, root: root)))
        for (object, data) in [(root, raw)] + revisions {
            _ = try coordinator.journal.append(
                context: context, packageID: package, object: object, offset: 0, bytes: data)
        }
        let index = try verificationIndex(f)
        try index.initializeAuthoritySchema()
        try index.validateRecoveryGraph(requireLinearProjection: false)
        XCTAssertThrowsError(
            try coordinator.prepareOriginals(packageID: package, index: index, publish: false)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "missingDependencies")
        }
        XCTAssertNil(try f.contents.peerDirectory(tree.reference.contentID))
        _ = try coordinator.journal.append(
            context: context, packageID: package, object: original, offset: 0, bytes: originalBytes)
        try sendTree(tree, package: package, fixture: f)
        try coordinator.prepareOriginals(packageID: package, index: index, publish: false)
        XCTAssertNil(try f.contents.peerDirectory(tree.reference.contentID))
        if poolRemainder {
            let publication = PeerIntakeJournal.Publication(
                packageID: package,
                manifestDigest: hash(try JSON.encode(coordinator.journal.beginRecord(package).manifest)),
                context: context, contextToken: "fixture",
                arrivalMinute: try PeerIntakeJournal.currentArrivalMinute())
            try coordinator.journal.prepare(publication)
            try CanonicalReaderRequirement.beforePeerDocumentPublication(root: f.root, ownerUID: getuid())
            try coordinator.journal.seal(package)
            let filler = Data(repeating: 0, count: Int(limits.maximumRecoveryReadBytes - 1))
            let path = ["authority", "fixture-read-pool"]
            try coordinator.journal.files.writeImmutable(filler, path: path, maximumBytes: 128 * 1024)
            let row = AuthorityStore.RetainedObject(
                descriptor: .init(kind: .authority, id: try id(), length: filler.count, sha256: hash(filler)),
                path: path.joined(separator: "/"), packageID: package, peerID: context.peerID,
                configurationDigest: context.configurationDigest, permittedOrigin: true)
            var checks = 0
            coordinator.progress = {
                checks += 1
                if checks > 64 { throw TractandaError("fixtureBusyLoop", "Recovery failed to yield") }
            }
            XCTAssertThrowsError(
                try coordinator.withOperation(recovery: true) {
                    XCTAssertEqual(try coordinator.bytes(row), filler)
                    try coordinator.prepareOriginals(
                        packageID: package, index: index, publish: true, recovering: true)
                }
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "peerPayloadVerifying") }
            XCTAssertLessThan(checks, 64)
            coordinator.progress = nil
            try coordinator.withOperation(recovery: true) {
                try coordinator.prepareOriginals(
                    packageID: package, index: index, publish: true, recovering: true)
            }
            XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
            return
        }
        if changeContext {
            try AuthorityStore.writeConfiguration(
                .init(profile: "tractanda.peer-configuration.v1", peers: [], bootstrap: nil), root: f.root,
                files: coordinator.journal.files)
            XCTAssertThrowsError(
                try coordinator.prepareOriginals(packageID: package, index: index, publish: true)
            ) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "untrustedPeer")
            }
            XCTAssertNil(try f.contents.peerDirectory(tree.reference.contentID))
        } else {
            try coordinator.prepareOriginals(packageID: package, index: index, publish: true)
            XCTAssertTrue(try f.originals.payloads.isVerified(attachment))
            XCTAssertEqual(try f.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
            XCTAssertTrue(try coordinator.verifiedCanonicalDocument(document, index: index))
        }
        if cleanup {
            let publication = PeerIntakeJournal.Publication(
                packageID: package,
                manifestDigest: hash(try JSON.encode(coordinator.journal.beginRecord(package).manifest)),
                context: context, contextToken: "fixture",
                arrivalMinute: try PeerIntakeJournal.currentArrivalMinute())
            try coordinator.journal.prepare(publication)
            try CanonicalReaderRequirement.beforePeerDocumentPublication(root: f.root, ownerUID: getuid())
            try coordinator.journal.seal(package)
            let held = try f.transfer.accountedUsage(packageID: package).bytes
            XCTAssertThrowsError(try f.transfer.complete(packageID: package, maximumParts: 1)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "peerObjectCollision")
            }
            XCTAssertEqual(try f.transfer.accountedUsage(packageID: package).bytes, held)
            let journal = ["authority", "intake", package]
            let beginBytes = try coordinator.journal.files.read(
                path: journal + ["begin.json"], maximumBytes: PeerPackage.maximumPageBytes)
            let sealed = try coordinator.journal.files.read(
                path: journal + ["sealed.json"], maximumBytes: PeerPackage.maximumPageBytes)
            try coordinator.journal.files.writeImmutable(
                sealed, path: journal + ["applied.json"], maximumBytes: PeerPackage.maximumPageBytes)
            XCTAssertFalse(try f.transfer.complete(packageID: package, maximumParts: 1))
            let reopened = try fixture(root: f.root)
            XCTAssertGreaterThan(try reopened.transfer.accountedUsage(packageID: package).bytes, 0)
            var calls = 0
            while try !reopened.transfer.complete(packageID: package, maximumParts: 1) {
                calls += 1
                XCTAssertLessThan(calls, 32)
                if calls >= 32 { throw TractandaError("fixture", "Cleanup stopped making progress") }
            }
            XCTAssertGreaterThan(calls, 1)
            XCTAssertEqual(try reopened.transfer.accountedUsage(packageID: package).bytes, 0)
            XCTAssertTrue(try reopened.transfer.complete(packageID: package, maximumParts: 1))
            XCTAssertEqual(try reopened.contents.readPage(tree.reference, pageNumber: 2).status, "timeout")
            XCTAssertEqual(
                try coordinator.journal.files.read(
                    path: journal + ["begin.json"], maximumBytes: PeerPackage.maximumPageBytes), beginBytes)
            XCTAssertEqual(
                try coordinator.journal.files.read(
                    path: journal + ["sealed.json"], maximumBytes: PeerPackage.maximumPageBytes), sealed)
            return
        }
        XCTAssertNil(try coordinator.journal.publication(package))
    }
    private func exerciseJournalProofCursor(limit: Int, maximumWork: Int, pretransferred: Bool) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let tree = try tree()
        let package = try id()
        let context = try PeerPackage.Context(
            peerID: "document-cursor", storeID: id(), configurationDigest: hash(Data("context".utf8)),
            permittedOrigins: [id()])
        let raw = try JSON.encode(PeerPackage.Page(objects: [tree.manifest], children: []))
        let root = PeerPackage.Object(kind: .index, id: try id(), length: raw.count, sha256: hash(raw))
        var limits = PeerPackage.Limits()
        limits.maximumObjects = 2  // one metadata index plus one manifest; six tree parts follow
        limits.maximumWork = maximumWork
        limits.maximumReadBytes = 128 * 1024
        let journal = PeerIntakeJournal(
            root: f.root, ownerUID: getuid(), limits: limits, stagingQuota: f.quota)
        journal.originals = f.originals
        journal.documents = f.transfer
        _ = try journal.begin(
            context: context,
            manifestBytes: JSON.encode(
                PeerPackage.Manifest(packageID: package, storeID: context.storeID, root: root)))
        if pretransferred {
            try sendTree(tree, package: package, fixture: f)
        } else {
            let first = try XCTUnwrap(tree.parts.first)
            XCTAssertThrowsError(
                try journal.append(
                    context: context, packageID: package, object: first.0, offset: 0, bytes: first.1)
            ) { XCTAssertEqual(($0 as? TractandaError)?.code, "missingDependencies") }
        }
        _ = try journal.append(context: context, packageID: package, object: root, offset: 0, bytes: raw)
        let parts = Dictionary(
            uniqueKeysWithValues: ([(tree.manifest, tree.raw)] + tree.parts).map { ($0.0.key, $0.1) })
        var cursor: PeerPackage.ResumeCursor?
        var completed = Set<String>()
        var calls = 0
        var workContinuations = 0
        repeat {
            calls += 1
            guard calls <= 64 else { throw TractandaError("fixture", "Proof cursor failed to advance") }
            let page = try journal.resumePage(
                context: context, packageID: package, cursor: cursor, limit: limit)
            cursor = page.nextCursor
            if cursor != nil, !page.blockedOnIndex, page.objects.count < limit {
                workContinuations += 1
            }
            for value in page.objects where value.descriptor.kind == .document {
                if value.verifiedComplete {
                    XCTAssertTrue(completed.insert(value.descriptor.key).inserted)
                } else {
                    let bytes = try XCTUnwrap(parts[value.descriptor.key])
                    _ = try journal.append(
                        context: context, packageID: package, object: value.descriptor,
                        offset: value.nextOffset, bytes: Data(bytes[value.nextOffset...]))
                }
            }
        } while cursor != nil
        XCTAssertEqual(completed.count, 6)
        XCTAssertGreaterThan(calls, 1)
        if pretransferred { XCTAssertGreaterThan(workContinuations, 0) }
        XCTAssertGreaterThan(
            try journal.status(package).receivedBytes, UInt64(parts.values.reduce(0) { $0 + $1.count }))
        XCTAssertNil(try journal.publication(package))
    }
}
