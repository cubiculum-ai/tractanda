import Crypto
import Foundation
import TractandaClient
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ExtractedTextUnitTests: XCTestCase, @unchecked Sendable {
    private let cap: Int64 = 16 * 1024 * 1024
    private let reserve: Int64 = 10 * 1024 * 1024 * 1024
    private func root() throws -> URL {
        // All canonical/Index/metadata copies, including129 tiny synthetic outcomes, fit8MiB.
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: FileManager.default.temporaryDirectory, additionalBytes: 8 * 1024 * 1024)
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "source-unit-" + Identifier.make())
    }
    private func budget(_ root: URL) throws {
        try PageCorpusSpoolPolicy(maximumBytes: cap, minimumFreeBytes: reserve).check(
            at: root, additionalBytes: 0)
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw TractandaError("resourceLimit", "Cannot measure source fixture")
        }
        var total: Int64 = 0
        var count = 0
        for case let url as URL in entries {
            count += 1
            var value = stat()
            guard count <= 4096, lstat(url.path, &value) == 0, value.st_blocks >= 0 else {
                throw TractandaError("resourceLimit", "Unknown source fixture allocation")
            }
            let bytes = Int64(value.st_blocks).multipliedReportingOverflow(by: 512)
            let sum = total.addingReportingOverflow(bytes.partialValue)
            guard !bytes.overflow, !sum.overflow, sum.partialValue <= cap else {
                throw TractandaError("resourceLimit", "Source fixture exceeds16MiB")
            }
            total = sum.partialValue
        }
    }
    private func makeStore(_ root: URL, accounts: any AccountDirectory = SystemAccountDirectory()) throws
        -> ItemStore
    {
        try ItemStore(
            root: root, accounts: accounts,
            attachmentUploadPolicy: .init(maximumStagedBytes: cap, minimumFreeBytes: reserve))
    }
    private func source(_ root: URL, text: String = "held source") throws -> Revision {
        let store = try makeStore(root)
        return try store.commit(
            .init(classID: "Item", changes: ["body": .text(text)], operationID: "source")
        ).revision
    }
    private struct Transport: ItemTransport {
        let coordinator: ServiceCoordinator
        var uid: UInt32 = getuid()
        func send(_ request: Data) async throws -> Data { try await coordinator.handle(request, forUID: uid) }
    }
    private func client(_ coordinator: ServiceCoordinator, uid: UInt32 = getuid())
        -> TractandaClient.ItemClient
    {
        .init(transport: Transport(coordinator: coordinator, uid: uid))
    }
    private func code(_ operation: () async throws -> Void, _ expected: Set<String>) async {
        do {
            try await operation()
            XCTFail("Expected a source window failure")
        } catch { XCTAssertTrue(expected.contains((error as? TractandaError)?.code ?? ""), "\(error)") }
    }
    func testUTF8BOMContinuationAndArgumentBoundaries() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root, text: "\u{FEFF}é☃z")
        let coordinator = try await ServiceCoordinator(opening: root)
        let client = client(coordinator)
        let first = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0, limit: 3)
        XCTAssertEqual(first.unit.text, "\u{FEFF}")
        XCTAssertEqual(first.unit.nextOffset, 3)
        XCTAssertEqual(first.next?.offset, 3)
        let second = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0, offset: 3, limit: 4)
        XCTAssertEqual(second.unit.text, "é")
        XCTAssertEqual(second.next?.offset, 5)
        let last = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0, offset: 5)
        XCTAssertEqual(last.unit.text, "☃z")
        XCTAssertNil(last.next)
        for (offset, limit) in [(0, 1), (4, 16), (9, 16), (0, 262_145)] {
            await code(
                {
                    _ = try await client.extractedTextUnit(
                        itemID: revision.itemID, expectedRevisionID: revision.revisionID,
                        unit: 0, offset: Int64(offset), limit: limit)
                }, ["invalidArguments"])
        }
        let state = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.charge, 0)
        await coordinator.close()
        try budget(root)
    }
    private func document(_ root: URL) throws -> Revision {
        let store = try makeStore(root)
        let base = try store.commit(.init(classID: "Item", operationID: "doc-source")).revision
        let data = Data("%PDF-1.4\n% synthetic no model\n".utf8)
        let upload = try store.beginAttachment(
            .init(
                itemID: base.itemID, expectedRevisionID: base.revisionID, operationID: "original",
                filename: "fixture.pdf", mediaType: "application/pdf", byteCount: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        _ = try store.appendAttachment(uploadID: XCTUnwrap(upload.uploadID), offset: 0, data: data)
        let attached = try store.finishAttachment(uploadID: XCTUnwrap(upload.uploadID)).revision
        guard
            case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                attachmentID: upload.attachment.attachmentID, operationID: "extract", identity: .init())
        else { throw TractandaError("fixture", "Expected document preparation") }
        let contents = DocumentContentStore(root: root, ownerUID: getuid(), minimumFreeBytes: reserve)
        let writer = try contents.begin(source: snapshot.source, identity: .init(), maximumWriteBytes: cap)
        for number in 1...129 {
            if number % 16 == 1 { try budget(root) }
            let parsed = try DoclingDocTagsParser.parse("<doctag><text>page é \(number)</text></doctag>")
            let geometry = try DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: "pdfPoint", displayWidth: 512,
                displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024, contentLeft: 0, contentTop: 0,
                contentWidth: 2048, contentHeight: 1024)
            try writer.append(
                .init(
                    pageNumber: Int64(number), sourceSHA256: snapshot.source.sha256,
                    page: AttachmentDocumentPage(
                        pageNumber: number, geometry: geometry,
                        rasterSHA256: String(repeating: "b", count: 64),
                        parsed: parsed, generatedTokens: 16, stopReason: "stop")))
        }
        let prepared = try writer.preparePublication()
        let corpus = try store.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
        let saved = try store.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
        try budget(root)
        return try store.get(saved.itemID)
    }
    func testSavedPage129AndHonestDiagnosticsAndIndependentMismatch() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try document(root)
        let coordinator = try await ServiceCoordinator(opening: root)
        let client = client(coordinator)
        let window = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 128)
        XCTAssertEqual(window.unit.text, "page é 129")
        XCTAssertEqual(window.unit.origin.pageNumber, 129)
        XCTAssertEqual(window.sourceIdentity.unitCount, 129)
        XCTAssertEqual(window.unit.spans.count, 1)
        XCTAssertEqual(window.unit.coverage?.converted, 129)
        XCTAssertEqual(window.canonicalVerification.status, "verified")
        XCTAssertEqual(window.indexConsistency.status, "currentBinding")
        XCTAssertFalse(window.wholeDocumentVerified)
        XCTAssertFalse(window.globalPlacementVerified)
        XCTAssertNil(window.next)
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                ["TractandaItem/extractedText", ["ids": [revision.itemID], "projection": "summary"], "test"]
            ],
        ])
        let response = try await coordinator.handle(request, forUID: getuid())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
        let result = try XCTUnwrap(calls.first?[1] as? [String: Any])
        let record = try XCTUnwrap((result["list"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["sourceScope"] as? String, "inlineFieldsAndRepresentations")
        XCTAssertEqual(record["sourceComplete"] as? Bool, false)
        XCTAssertEqual((record["omittedDocumentRepresentationIDs"] as? [String])?.count, 1)
        let identity = try XCTUnwrap(
            (record["indexedCorpus"] as? [String: Any])?["identity"] as? [String: Any])
        XCTAssertEqual(identity["unitCount"] as? Int, 129)
        let index = try ItemIndex(path: root.appendingPathComponent("index/items.sqlite").path, create: false)
        try index.execute(
            "UPDATE page_text_index SET text=? WHERE rowid IN (SELECT u.id FROM corpus_unit u JOIN corpus_link l ON l.generation_id=u.generation_id WHERE l.item_id=? AND u.ordinal=128)",
            ["page ø 129", revision.itemID])
        await code(
            {
                _ = try await client.extractedTextUnit(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 128)
            }, ["indexSourceMismatch"])
        try index.execute(
            "UPDATE page_text_index SET text=? WHERE rowid IN (SELECT u.id FROM corpus_unit u JOIN corpus_link l ON l.generation_id=u.generation_id WHERE l.item_id=? AND u.ordinal=128)",
            ["page é 129", revision.itemID])
        let document = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: revision.fields).first)
        let reference = try XCTUnwrap(document.content)
        let contents = DocumentContentStore(root: root, ownerUID: getuid(), minimumFreeBytes: reserve)
        let pageURL = try contents.pageURLForTesting(reference, number: 129)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pageURL.path)
        try Data("corrupt".utf8).write(to: pageURL)
        await code(
            {
                _ = try await client.extractedTextUnit(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 128)
            }, ["documentIntegrity"])
        try index.execute(
            "UPDATE corpus_generation SET state='writing' WHERE id IN (SELECT generation_id FROM corpus_link WHERE item_id=?)",
            [revision.itemID])
        await code(
            {
                _ = try await client.extractedTextUnit(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 128)
            }, ["indexProjectionPending"])
        index.close()
        await coordinator.close()
        try budget(root)
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var started = false
        private var cancelled = false
        func hold() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                started = true
                lock.unlock()
            }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        func state() -> (Bool, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (started, cancelled)
        }
        func release() {
            lock.lock()
            let waiter = continuation
            continuation = nil
            lock.unlock()
            waiter?.resume()
        }
        func awaitState(cancelled: Bool = false) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(cancelled ? state().1 : state().0) {
                guard ContinuousClock.now < deadline else {
                    throw TractandaError("testTimeout", "Held reader gate")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    func testHeldPublicReaderCloseWaitsForIOAndPreservesFailedRetirementDebt() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root)
        let coordinator = try await ServiceCoordinator(opening: root)
        let gate = Gate()
        await coordinator.setExtractedUnitHookForTesting {
            await withTaskCancellationHandler {
                await gate.hold()
            } onCancel: {
                gate.cancel()
            }
        }
        let client = client(coordinator)
        let read = Task {
            try await client.extractedTextUnit(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0)
        }
        try await gate.awaitState()
        try await coordinator.setCorpusReaderReleaseFailureForTesting(true)
        let close = Task { await coordinator.close() }
        try await gate.awaitState(cancelled: true)
        let held = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(held.count, 1)
        XCTAssertGreaterThan(held.charge, 0)
        gate.release()
        do {
            _ = try await read.value
            XCTFail("Cancelled reader must not deliver")
        } catch {
            XCTAssertTrue(["cancelled", "serviceBusy"].contains((error as? TractandaError)?.code ?? ""))
        }
        await close.value
        let reopened = try makeStore(root)
        XCTAssertEqual(try reopened.corpusReadStateForTesting().count, 0)
        XCTAssertEqual(try reopened.corpusReadStateForTesting().charge, 0)
        try budget(root)
    }
    func testHeldPublicReaderRejectsChangedHeadBeforeDelivery() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root)
        let coordinator = try await ServiceCoordinator(opening: root)
        let gate = Gate()
        await coordinator.setExtractedUnitHookForTesting { await gate.hold() }
        let client = client(coordinator)
        let read = Task {
            try await client.extractedTextUnit(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0)
        }
        try await gate.awaitState()
        _ = try await client.commit(
            .init(
                action: .revise, itemID: revision.itemID, expectedRevisionID: revision.revisionID,
                changes: ["body": .text("new source")], operationID: "replace"))
        gate.release()
        do {
            _ = try await read.value
            XCTFail("Changed head must not deliver")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "revisionConflict") }
        let state = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.charge, 0)
        await coordinator.close()
        try budget(root)
    }
    func testSerializedNativeBudgetFailsWithoutTruncation() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root, text: String(repeating: "\"", count: 5000))
        let coordinator = try await ServiceCoordinator(opening: root)
        let client = client(coordinator)
        await code(
            {
                _ = try await client.extractedTextUnit(
                    itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0, maxBytes: 8192)
            }, ["responseTooLarge"])
        let small = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0, limit: 16,
            maxBytes: 8192)
        XCTAssertEqual(small.unit.text.utf8.count, 16)
        XCTAssertEqual(small.next?.offset, 16)
        await coordinator.close()
        try budget(root)
    }
    func testHeldPublicReaderResetDrainsBeforeValidationAndSuppressesDelivery() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root)
        let coordinator = try await ServiceCoordinator(opening: root)
        let gate = Gate()
        await coordinator.setExtractedUnitHookForTesting {
            await withTaskCancellationHandler {
                await gate.hold()
            } onCancel: {
                gate.cancel()
            }
        }
        let client = client(coordinator)
        let read = Task {
            try await client.extractedTextUnit(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0)
        }
        try await gate.awaitState()
        let request = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability], "methodCalls": [["TractandaSemantic/reset", [:], "test"]],
        ])
        let reset = Task { try await coordinator.handle(request, forUID: getuid()) }
        try await gate.awaitState(cancelled: true)
        let held = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(held.count, 1)
        gate.release()
        do {
            _ = try await read.value
            XCTFail("Lifecycle must suppress old reader delivery")
        } catch {
            XCTAssertTrue(["cancelled", "serviceBusy"].contains((error as? TractandaError)?.code ?? ""))
        }
        _ = try await reset.value
        let retired = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(retired.count, 0)
        XCTAssertEqual(retired.charge, 0)
        await coordinator.close()
        try budget(root)
    }
    private final class Accounts: AccountDirectory, @unchecked Sendable {
        let alice: UInt32 = 61314
        private let lock = NSLock()
        private var admitted = true
        func revoke() {
            lock.lock()
            admitted = false
            lock.unlock()
        }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            lock.lock()
            let allowed = admitted
            lock.unlock()
            return .init(
                uid: uid, name: uid == alice ? "alice" : "admin", primaryGroupName: "staff",
                groupIDs: uid == getuid() || allowed ? [71314] : [])
        }
        func user(named name: String) throws -> AccountIdentity {
            try user(forUID: name == "alice" ? alice : getuid())
        }
        func groupID(named name: String) throws -> UInt32 { 71314 }
    }
    func testHeldPublicReaderRechecksFreshACL() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let revision: Revision
        do {
            let store = try makeStore(root, accounts: accounts)
            _ = try store.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile), "groups": .list([.text("staff")]),
                ]), operationID: "access")
            revision = try store.commit(
                .init(
                    classID: "Item",
                    changes: [
                        "body": .text("private source"),
                        "permissions": .object([
                            "profile": .text(ItemPermissions.profile), "owner": .text("admin"),
                            "group": .text("staff"), "mode": .integer(0o660), "acl": .object([:]),
                        ]),
                    ], operationID: "shared-source")
            ).revision
        }
        let coordinator = try await ServiceCoordinator(opening: root, makeAccountDirectory: { accounts })
        let gate = Gate()
        await coordinator.setExtractedUnitHookForTesting { await gate.hold() }
        let client = client(coordinator, uid: accounts.alice)
        let read = Task {
            try await client.extractedTextUnit(
                itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0)
        }
        try await gate.awaitState()
        accounts.revoke()
        gate.release()
        do {
            _ = try await read.value
            XCTFail("Revoked ACL must not deliver")
        } catch { XCTAssertEqual((error as? TractandaError)?.code, "forbidden") }
        let state = try await coordinator.semanticReaderStateForTesting()
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.charge, 0)
        await coordinator.close()
        try budget(root)
    }

    func testFailureEnvelopePreservesErrorMeaningAndOmitsUnscopedState() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ItemService(store: try makeStore(root))
        let call = ExtractedTextUnitCall(callID: "test", arguments: Data("{}".utf8))
        for (error, expected): (Error, String) in [
            (TractandaError("forbidden", "denied"), "forbidden"),
            (CancellationError(), "cancelled"), (NSError(domain: "private-path", code: 1), "serverError"),
        ] {
            let data = try service.extractedTextUnitFailure(call, error: error)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["sessionState"])
            let calls = try XCTUnwrap(object["methodResponses"] as? [[Any]])
            let failure = try XCTUnwrap(calls.first?[1] as? [String: Any])
            XCTAssertEqual(failure["type"] as? String, expected)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-path"))
        }
        try budget(root)
    }

    func testDirectBackendOmitsUnitCapabilityAndDistinguishesSingleAndBatchCalls() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ItemService(store: try makeStore(root))
        let client = ItemClient(transport: { service.handle($0, peerUID: getuid()) })
        let info = try XCTUnwrap(
            JSONSerialization.jsonObject(with: client.call("TractandaStore/info")) as? [String: Any])
        let features = try XCTUnwrap(info["features"] as? [String])
        XCTAssertFalse(features.contains(ServerFeature.extractedTextUnits.rawValue))
        XCTAssertTrue(features.contains(ServerFeature.extractedTextDiagnostics.rawValue))
        let revision = try service.store.commit(
            .init(classID: "Item", changes: ["body": .text("direct source")], operationID: "direct-source")
        ).revision
        let arguments: [String: Any] = [
            "itemID": revision.itemID, "expectedRevisionID": revision.revisionID, "unit": 0,
        ]
        XCTAssertThrowsError(try client.call(ExtractedTextUnitCall.method, arguments: arguments)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "extractedTextUnitsRequireCoordinator")
        }
        let batch = try JSONSerialization.data(withJSONObject: [
            "using": [ItemService.capability],
            "methodCalls": [
                [ExtractedTextUnitCall.method, arguments, "unit"], ["TractandaStore/info", [:], "info"],
            ],
        ])
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: service.handle(batch, peerUID: getuid())) as? [String: Any])
        let calls = try XCTUnwrap(response["methodResponses"] as? [[Any]])
        XCTAssertEqual((calls[0][1] as? [String: Any])?["type"] as? String, "singleCallRequired")
        try budget(root)
    }
    func testCoordinatorDeclaresInstalledRouteWithoutConverterAndReadsUnit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = try source(root)
        let coordinator = try await ServiceCoordinator(opening: root)
        let client = client(coordinator)
        struct Arguments: Encodable, Sendable {}
        struct Info: Decodable, Sendable { let features: [String] }
        let info = try await client.call("TractandaStore/info", arguments: Arguments(), returning: Info.self)
        XCTAssertTrue(info.features.contains(ServerFeature.extractedTextUnits.rawValue))
        let unit = try await client.extractedTextUnit(
            itemID: revision.itemID, expectedRevisionID: revision.revisionID, unit: 0)
        XCTAssertEqual(unit.unit.text, "held source")
        await coordinator.close()
        try budget(root)
    }

}
