import CSQLite
import Crypto
import TractandaClient
import TractandaVectors
import XCTest

@testable import TractandaCore

final class AttachmentTextIntegrationTests: XCTestCase {
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("attachment-text-" + Identifier.make())
    }
    private func create(_ store: ItemStore, body: String = "owned body", operation: String = "create") throws
        -> Revision
    {
        try store.commit(
            CommitRequest(
                classID: "Item", changes: ["subject": .text("document"), "body": .text(body)],
                operationID: operation)
        ).revision
    }
    private func attach(
        _ store: ItemStore, base: Revision, data: Data, media: String = "text/plain",
        operation: String = "attach"
    ) throws -> (Revision, AttachmentDescriptor) {
        let upload = try store.beginAttachment(
            AttachmentUploadRequest(
                itemID: base.itemID,
                expectedRevisionID: base.revisionID, operationID: operation,
                filename: "metadata-noise-name.txt",
                mediaType: media, byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        let id = try XCTUnwrap(upload.uploadID)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 262_144, data.count)
            _ = try store.appendAttachment(
                uploadID: id, offset: Int64(offset), data: data.subdata(in: offset..<end))
            offset = end
        }
        return (try store.finishAttachment(uploadID: id).revision, upload.attachment)
    }
    private func extract(_ store: ItemStore, base: Revision, id: String, operation: String = "extract") throws
        -> Revision
    {
        let result = try store.extractAttachmentText(
            itemID: base.itemID, expectedRevisionID: base.revisionID,
            attachmentID: id, operationID: operation)
        return try store.get(result.itemID, revisionID: result.revisionID)
    }
    private func assertCode(
        _ expected: String, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)", file: file, line: line)
        }
    }
    private func client(_ store: ItemStore) -> ItemClient {
        let service = ItemService(store: store)
        return ItemClient(transport: { service.handle($0, peerUID: store.ownerUID) })
    }
    func testBOMUnicodeCRLFExactlyOnceFTSAndDiagnosticByteMap() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let text = "# Überschrift\r\nneedle café ☃\r\n"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let (attached, descriptor) = try attach(
            store, base: create(store), data: original, media: "text/markdown")
        XCTAssertTrue(try store.candidates(text: "needle").isEmpty)
        let saved = try extract(store, base: attached, id: descriptor.attachmentID)
        let representation = try XCTUnwrap(
            AttachmentTextRepresentation.representations(in: saved.fields).first)
        XCTAssertEqual(representation.text, text)
        XCTAssertEqual(representation.sourceByteStart, 3)
        XCTAssertEqual(representation.source.itemID, attached.itemID)
        XCTAssertEqual(representation.source.revisionID, attached.revisionID)
        XCTAssertEqual(representation.source.attachmentID, descriptor.attachmentID)
        let corpus = ItemTextContent.corpus(for: saved)
        XCTAssertEqual(corpus.sourceText.components(separatedBy: text).count, 2)
        XCTAssertFalse(corpus.sourceText.contains(descriptor.filename))
        XCTAssertFalse(corpus.sourceText.contains(descriptor.sha256))
        XCTAssertFalse(corpus.sourceText.contains(representation.representationID))
        XCTAssertFalse(corpus.sourceText.contains("utf8-v1"))
        XCTAssertEqual(try store.candidates(text: "needle").map(\.itemID), [saved.itemID])
        let source = try XCTUnwrap(corpus.sourceSegments.first)
        XCTAssertEqual(source.itemID, saved.itemID)
        XCTAssertEqual(source.revisionID, saved.revisionID)
        XCTAssertEqual(source.sourceByteStart, 3)
        XCTAssertEqual(source.sourceByteEnd, original.count)
        XCTAssertEqual(
            Data(Array(corpus.sourceText.utf8)[source.corpusByteStart..<source.corpusByteEnd]),
            Data(text.utf8))
        let response =
            try JSONSerialization.jsonObject(
                with: client(store).call("TractandaItem/extractedText", arguments: ["ids": [saved.itemID]]))
            as! [String: Any]
        let row = try XCTUnwrap((response["list"] as? [[String: Any]])?.first)
        let maps = try XCTUnwrap(row["sources"] as? [[String: Any]])
        XCTAssertEqual((maps[0]["location"] as? [String: Any])?["byteStart"] as? Int, 3)
        XCTAssertEqual(maps[0]["corpusByteEnd"] as? Int, source.corpusByteEnd)
        XCTAssertEqual(response["extractionProfile"] as? String, "tractanda.item-text.v8")
        XCTAssertEqual(
            ((row["index"] as? [String: Any])?["fts"] as? [String: Any])?["status"] as? String, "current")
        try store.rebuildIndex()
        XCTAssertEqual(try store.candidates(text: "needle").map(\.itemID), [saved.itemID])
    }
    func testReplayDoesNotAllocateOrDecodeAndCASPreservesInterveningEdit() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try attach(store, base: create(store), data: Data("known text".utf8))
        let extracted = try extract(store, base: attached, id: descriptor.attachmentID)
        let after = try store.commit(
            CommitRequest(
                action: .revise, itemID: extracted.itemID,
                expectedRevisionID: extracted.revisionID, changes: ["subject": .text("later")],
                operationID: "later")
        ).revision
        store.makePersistentUUID = { throw TractandaError("allocation", "Retry must not allocate") }
        let helper = try AttachmentPayloadStore(root: root, ownerUID: store.ownerUID)
        try FileManager.default.removeItem(at: helper.payloadURL(for: descriptor.attachmentID))
        let replay = try store.extractAttachmentText(
            itemID: attached.itemID, expectedRevisionID: attached.revisionID,
            attachmentID: descriptor.attachmentID, operationID: "extract")
        XCTAssertTrue(replay.wasReplayed)
        XCTAssertEqual(replay.revisionID, extracted.revisionID)
        XCTAssertEqual(try store.get(attached.itemID).revisionID, after.revisionID)
        assertCode("operationMismatch") {
            try store.extractAttachmentText(
                itemID: attached.itemID,
                expectedRevisionID: after.revisionID, attachmentID: descriptor.attachmentID,
                operationID: "extract")
        }
    }
    func testCASAndInvalidInputsDoNotPublishRepresentations() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        var current = try create(store)
        for (ordinal, pair) in [
            (Data([0xC3, 0x28]), "text/plain"), (Data("pdf".utf8), "application/pdf"),
            (Data(repeating: 65, count: 524_289), "text/plain"),
        ].enumerated() {
            let attached = try attach(
                store, base: current, data: pair.0, media: pair.1, operation: "attach\(ordinal)")
            current = attached.0
            XCTAssertThrowsError(
                try store.extractAttachmentText(
                    itemID: current.itemID, expectedRevisionID: current.revisionID,
                    attachmentID: attached.1.attachmentID, operationID: "bad\(ordinal)"))
            XCTAssertEqual(try store.get(current.itemID).revisionID, current.revisionID)
            XCTAssertNil(current.fields["attachmentText"])
        }
        let (attached, descriptor) = try attach(
            store, base: current, data: Data("CAS source".utf8), operation: "cas-attach")
        store.beforeAttachmentTextCommitForTesting = {
            _ = try store.commit(
                CommitRequest(
                    action: .revise, itemID: attached.itemID,
                    expectedRevisionID: attached.revisionID, changes: ["body": .text("intervening")],
                    operationID: "concurrent"))
        }
        assertCode("revisionConflict") {
            try store.extractAttachmentText(
                itemID: attached.itemID,
                expectedRevisionID: attached.revisionID, attachmentID: descriptor.attachmentID,
                operationID: "cas-extract")
        }
        XCTAssertEqual(try store.get(attached.itemID).fields["body"]?.string, "intervening")
        XCTAssertNil(try store.get(attached.itemID).fields["attachmentText"])
    }
    func testDetachStaleProjectionAndIndependentCopyRemap() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try attach(
            store, base: create(store), data: Data("unique extracted needle".utf8))
        let saved = try extract(store, base: attached, id: descriptor.attachmentID)
        let oldRepresentation = try XCTUnwrap(
            AttachmentTextRepresentation.representations(in: saved.fields).first)
        let copy = try store.commit(
            CommitRequest(
                action: .copy, itemID: saved.itemID,
                expectedRevisionID: saved.revisionID, operationID: "copy")
        ).revision
        let copiedRepresentation = try XCTUnwrap(
            AttachmentTextRepresentation.representations(in: copy.fields).first)
        let copiedDescriptor = try XCTUnwrap(AttachmentDescriptor.descriptors(in: copy.fields).first)
        XCTAssertNotEqual(copiedDescriptor.attachmentID, descriptor.attachmentID)
        XCTAssertEqual(copiedRepresentation.attachmentID, copiedDescriptor.attachmentID)
        XCTAssertNotEqual(copiedRepresentation.representationID, oldRepresentation.representationID)
        XCTAssertEqual(copiedRepresentation.source, oldRepresentation.source)
        XCTAssertEqual(ItemTextContent.corpus(for: copy).sourceSegments.first?.itemID, copy.itemID)
        XCTAssertEqual(ItemTextContent.corpus(for: copy).sourceSegments.first?.revisionID, copy.revisionID)
        let detached = try store.detachAttachment(
            itemID: saved.itemID, expectedRevisionID: saved.revisionID,
            attachmentID: descriptor.attachmentID, operationID: "detach"
        ).revision
        XCTAssertFalse(ItemTextContent.corpus(for: detached).sourceText.contains("unique extracted needle"))
        XCTAssertTrue(
            ItemTextContent.corpus(for: try store.get(saved.itemID, revisionID: saved.revisionID)).sourceText
                .contains("unique extracted needle"))
        XCTAssertEqual(try store.candidates(text: "unique extracted needle").map(\.itemID), [copy.itemID])
        var fields = saved.fields
        let mismatch = try AttachmentDescriptor(
            attachmentID: descriptor.attachmentID, filename: descriptor.filename,
            mediaType: descriptor.mediaType, byteCount: descriptor.byteCount,
            sha256: String(repeating: "a", count: 64))
        fields["attachments"] = .list([mismatch.itemValue])
        XCTAssertFalse(
            ItemTextContent.corpus(for: try Revision(fields: fields, formatVersion: saved.formatVersion))
                .sourceText.contains(
                    "unique extracted needle"))
        assertCode("invalidAttachmentText") {
            try store.commit(
                CommitRequest(
                    action: .revise, itemID: copy.itemID,
                    expectedRevisionID: copy.revisionID, unset: ["attachmentText"], operationID: "clear"))
        }
        assertCode("invalidAttachmentText") {
            try store.commit(
                CommitRequest(
                    classID: "Item",
                    changes: ["attachmentText": .list([oldRepresentation.itemValue])], operationID: "forge"))
        }
    }
    func testHeavySavedTextSummaryBudgetAndCanonicalOnlyRestore() throws {
        let root = root()
        let restored = self.root()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restored)
        }
        var store: ItemStore? = try AttachmentFixtureCapacity.makeStore(root: root)
        let (attached, descriptor) = try attach(
            XCTUnwrap(store), base: create(XCTUnwrap(store)),
            data: Data(String(repeating: "searchable text\n", count: 4_000).utf8))
        let saved = try extract(XCTUnwrap(store), base: attached, id: descriptor.attachmentID)
        let response = try client(XCTUnwrap(store)).call(
            "TractandaItem/getBounded",
            arguments: ["ids": [saved.itemID], "projection": "summary", "maxBytes": 8_192])
        XCTAssertLessThan(response.count, 8_192)
        let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let encoded = try JSONSerialization.data(withJSONObject: object["list"]!)
        let list = try JSONDecoder().decode([TractandaClient.JMAPItemRecord].self, from: encoded)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, saved.itemID)
        XCTAssertNil(list[0].fields?["attachmentText"])
        let full = try client(XCTUnwrap(store)).call(
            "TractandaItem/getBounded", arguments: ["ids": [saved.itemID], "maxBytes": 8_192])
        let fullObject = try JSONSerialization.jsonObject(with: full) as! [String: Any]
        XCTAssertEqual(fullObject["oversizedIDs"] as? [String], [saved.itemID])
        let row = try XCTUnwrap(
            store?.exportCatalogueForVerification().first { $0.revisionID == saved.revisionID })
        XCTAssertEqual(
            try PooledCanonicalRecord.read(row: row, root: root, ownerUID: XCTUnwrap(store).ownerUID)
                .revision, saved)
        let sourceIndex = try XCTUnwrap(store).indexDirectory
        store = nil
        try FileManager.default.copyItem(at: root, to: restored)
        let physicalRoot = root.resolvingSymlinksInPath()
        let physicalIndex = sourceIndex.resolvingSymlinksInPath()
        if physicalIndex.path.hasPrefix(physicalRoot.path + "/") {
            let relative = String(physicalIndex.path.dropFirst(physicalRoot.path.count + 1))
            let copiedIndex = restored.appendingPathComponent(relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copiedIndex.path))
            try FileManager.default.removeItem(at: copiedIndex)
        }
        let rebuiltIndex = restored.appendingPathComponent("rebuilt-index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rebuiltIndex.path))
        let recovered = try AttachmentFixtureCapacity.makeStore(
            root: restored, indexDirectory: rebuiltIndex)
        XCTAssertEqual(
            recovered.indexDirectory.resolvingSymlinksInPath(), rebuiltIndex.resolvingSymlinksInPath())
        XCTAssertEqual(
            try recovered.get(saved.itemID).fields["attachmentText"], saved.fields["attachmentText"])
        XCTAssertEqual(try recovered.candidates(text: "searchable text").map(\.itemID), [saved.itemID])
    }
    func testOldCorpusCheckpointRequiresRebuildAndSemanticProfileChanges() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try AttachmentFixtureCapacity.makeStore(root: root)
        let saved = try create(XCTUnwrap(store))
        store = nil
        let index = try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
        try index.execute(
            "UPDATE checkpoint_meta SET value='tractanda.item-text.v3' WHERE key='itemTextProfile'")
        try index.closeChecked()
        store = try AttachmentFixtureCapacity.makeStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "fullRecovery")
        XCTAssertEqual(try store?.get(saved.itemID), saved)
        let configuration = SemanticConfiguration(
            operationID: "semantic", endpoint: "http://127.0.0.1:11434/v1/embeddings",
            model: "fake", modelRevision: "fake", dimensions: 2, documentPrefix: "", queryPrefix: "")
        let legacy = SemanticProfileIdentity(
            formatVersion: 1, model: configuration.model, modelRevision: configuration.modelRevision,
            dimensions: configuration.dimensions, documentPrefix: configuration.documentPrefix,
            queryPrefix: configuration.queryPrefix,
            chunkBytes: configuration.chunkBytes, overlapBytes: configuration.overlapBytes,
            pooling: configuration.pooling,
            normalization: configuration.normalization, inputEncoding: configuration.inputEncoding,
            itemTextProfile: "tractanda.item-text.v3")
        XCTAssertNotEqual(
            try SemanticSource.profileID(configuration), SemanticChunker.hash(try JSON.encode(legacy)))
        XCTAssertEqual(configuration.chunkBytes, 384)
        XCTAssertEqual(configuration.overlapBytes, 64)
        let activeStore = try XCTUnwrap(store)
        do {
            _ = try Vec1Index(
                path: activeStore.indexDirectory.appendingPathComponent("semantic.sqlite").path,
                dimensions: 2, profileID: SemanticChunker.hash(try JSON.encode(legacy)),
                makeGenerationID: { try UUID.makeVersion1().uuidString.lowercased() })
        }
        let service = SemanticService(store: activeStore) { _, inputs, _ in inputs.map { _ in [1, 0] } }
        _ = try activeStore.withAccess(forUID: activeStore.ownerUID) {
            try service.configure(configuration, expectedConfigurationID: nil)
        }
        for _ in 0..<50 {
            service.maintain()
            usleep(10_000)
        }
        let status = try activeStore.withAccess(forUID: activeStore.ownerUID) { try service.status() }
        XCTAssertEqual(status["profileID"] as? String, try SemanticSource.profileID(configuration))
        XCTAssertEqual(status["coverage"] as? String, "complete")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: activeStore.indexDirectory.path)
                .contains { $0.hasPrefix("semantic.quarantine.") })
    }
    func testUnicodeSemanticCrossSectionPassageMapsOriginalOffsets() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root)
        let body = String(repeating: "b", count: 20)
        let firstText = "first café ☃\r\n"
        let secondText = "second λ résumé\n"
        let firstData = Data([0xEF, 0xBB, 0xBF]) + Data(firstText.utf8)
        let (firstAttached, first) = try attach(
            store, base: create(store, body: body), data: firstData, operation: "first")
        let firstSaved = try extract(
            store, base: firstAttached, id: first.attachmentID, operation: "first-text")
        let (secondAttached, second) = try attach(
            store, base: firstSaved, data: Data(secondText.utf8), operation: "second")
        let saved = try extract(
            store, base: secondAttached, id: second.attachmentID, operation: "second-text")
        let service = SemanticService(store: store, storage: SemanticMemoryStorage()) { _, inputs, isQuery in
            inputs.map { input in
                if isQuery { return input.contains("second-query") ? [0, 1] : [1, 0] }
                if input.contains(firstText) { return [1, 0] }
                if input.contains(secondText) { return [0, 1] }
                return [-1, -1]
            }
        }
        let configuration = SemanticConfiguration(
            operationID: "config", endpoint: "http://127.0.0.1:11434/v1/embeddings", model: "fake",
            modelRevision: "fake", dimensions: 2, documentPrefix: "", queryPrefix: "")
        _ = try store.withAccess(forUID: store.ownerUID) {
            try service.configure(configuration, expectedConfigurationID: nil)
        }
        for _ in 0..<30 {
            service.maintain()
            usleep(10_000)
        }
        var rows: [[String: Any]] = []
        for queryText in ["first-query", "second-query"] {
            let query = try store.withAccess(forUID: store.ownerUID) {
                try service.search(
                    text: queryText, expression: nil,
                    categoryPath: [], excludedCategoryIDs: [], viewID: nil, limit: 20)["queryID"] as! String
            }
            for _ in 0..<30 {
                service.maintain()
                usleep(10_000)
            }
            let result = try store.withAccess(forUID: store.ownerUID) { try service.results(queryID: query) }
            rows += try XCTUnwrap(result["results"] as? [[String: Any]])
        }
        var checked = Set<String>()
        for passage in rows {
            guard let maps = passage["sources"] as? [[String: Any]], !maps.isEmpty else { continue }
            // Each attachment is an independent unit; neither passage may cross the other unit.
            XCTAssertEqual(maps.count, 1)
            let passageText = try XCTUnwrap(passage["passage"] as? String)
            let passageBytes = Array(passageText.utf8)
            let base = try XCTUnwrap(passage["byteStart"] as? Int)
            let end = try XCTUnwrap(passage["byteEnd"] as? Int)
            XCTAssertEqual(end - base, passageBytes.count)
            for map in maps {
                XCTAssertEqual(map["itemID"] as? String, saved.itemID)
                XCTAssertEqual(map["revisionID"] as? String, saved.revisionID)
                let attachmentID = try XCTUnwrap(map["attachmentID"] as? String)
                checked.insert(attachmentID)
                let data = attachmentID == first.attachmentID ? firstData : Data(secondText.utf8)
                let location = try XCTUnwrap(map["location"] as? [String: Any])
                XCTAssertEqual(location["kind"] as? String, "originalBytes")
                let sourceRange = (location["byteStart"] as! Int)..<(location["byteEnd"] as! Int)
                let corpusRange = (map["corpusByteStart"] as! Int)..<(map["corpusByteEnd"] as! Int)
                let relative = (corpusRange.lowerBound - base)..<(corpusRange.upperBound - base)
                XCTAssertTrue(relative.lowerBound >= 0 && relative.upperBound <= passageBytes.count)
                XCTAssertEqual(data.subdata(in: sourceRange), Data(passageBytes[relative]))
                XCTAssertEqual(
                    map["sourceSHA256"] as? String,
                    attachmentID == first.attachmentID ? first.sha256 : second.sha256)
                let representation = try XCTUnwrap(
                    AttachmentTextRepresentation.representations(in: saved.fields)
                        .first { $0.attachmentID == attachmentID })
                XCTAssertEqual(map["representationID"] as? String, representation.representationID)
            }
        }
        XCTAssertEqual(checked, Set([first.attachmentID, second.attachmentID]))
    }
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 61001, bob: UInt32 = 61002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case getuid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [71001])
        }
        func user(named name: String) throws -> AccountIdentity {
            switch name {
            case "admin": return try user(forUID: getuid())
            case "alice": return try user(forUID: alice)
            case "bob": return try user(forUID: bob)
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
            }
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
            return 71001
        }
    }
    func testCurrentPermissionsGateExtractionReplaySavedHistoryAndDiagnostics() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let store = try AttachmentFixtureCapacity.makeStore(root: root, accounts: accounts)
        _ = try store.configureAccess(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "users": .list([.text("alice"), .text("bob")]),
            ]), operationID: "access")
        func permissions(_ owner: String, _ mode: Int64) -> ItemValue {
            .object([
                "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text("staff"),
                "mode": .integer(mode), "acl": .object([:]),
            ])
        }
        let base = try store.withAccess(forUID: accounts.alice) {
            try store.commit(
                CommitRequest(
                    classID: "Item", changes: ["permissions": permissions("alice", 0o640)],
                    operationID: "create")
            ).revision
        }
        let (attached, descriptor) = try store.withAccess(forUID: accounts.alice) {
            try attach(store, base: base, data: Data("private extracted truth".utf8))
        }
        let saved = try store.withAccess(forUID: accounts.alice) {
            try extract(store, base: attached, id: descriptor.attachmentID)
        }
        try store.withAccess(forUID: accounts.bob) {
            XCTAssertEqual(try store.get(saved.itemID, revisionID: saved.revisionID), saved)
            assertCode("forbidden") {
                try store.extractAttachmentText(
                    itemID: saved.itemID,
                    expectedRevisionID: saved.revisionID, attachmentID: descriptor.attachmentID,
                    operationID: "bob-extract")
            }
        }
        let readonly = try store.commit(
            CommitRequest(
                action: .revise, itemID: saved.itemID,
                expectedRevisionID: saved.revisionID, changes: ["permissions": permissions("admin", 0o640)],
                operationID: "readonly")
        ).revision
        try store.withAccess(forUID: accounts.alice) {
            XCTAssertTrue(
                try store.extractAttachmentText(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: descriptor.attachmentID, operationID: "extract"
                ).wasReplayed)
        }
        _ = try store.commit(
            CommitRequest(
                action: .revise, itemID: saved.itemID,
                expectedRevisionID: readonly.revisionID,
                changes: ["permissions": permissions("admin", 0o600)], operationID: "revoke"))
        for uid in [accounts.alice, accounts.bob] {
            try store.withAccess(forUID: uid) {
                assertCode("forbidden") { try store.get(saved.itemID, revisionID: saved.revisionID) }
                assertCode("forbidden") {
                    try store.extractAttachmentText(
                        itemID: attached.itemID,
                        expectedRevisionID: attached.revisionID, attachmentID: descriptor.attachmentID,
                        operationID: "extract")
                }
                XCTAssertTrue(try store.candidates(text: "private extracted truth").isEmpty)
            }
            let service = ItemService(store: store)
            let client = ItemClient(transport: { service.handle($0, peerUID: uid) })
            let response =
                try JSONSerialization.jsonObject(
                    with: client.call("TractandaItem/extractedText", arguments: ["ids": [saved.itemID]]))
                as! [String: Any]
            XCTAssertEqual(response["notFound"] as? [String], [saved.itemID])
            XCTAssertEqual((response["list"] as? [[String: Any]])?.count, 0)
        }
    }

    func testSemanticChunkWindowPreservesAnInternalBOM() throws {
        let text = String(repeating: "a", count: 32) + "\u{FEFF}café"
        let chunks = try SemanticChunker.chunks(text, chunkBytes: 32, overlapBytes: 0)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Data(chunks[1].text.utf8), Data(Array(text.utf8)[chunks[1].byteRange]))
        XCTAssertEqual(chunks[1].text.unicodeScalars.first?.value, 0xFEFF)
    }

}
