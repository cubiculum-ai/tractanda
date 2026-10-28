import CTractandaPlatform
import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PersonalWorkgroupStoreTests: XCTestCase {
    private final class AvailableBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 64 * 1024 * 1024 * 1024
        private var directory: URL?
        func set(_ bytes: UInt64) {
            lock.lock()
            value = bytes
            lock.unlock()
        }
        func read(at directory: URL) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            self.directory = directory
            return value
        }
        func observedDirectory() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return directory
        }
    }
    private final class Accounts: AccountDirectory {
        let alice: UInt32 = 52001
        let bob: UInt32 = 52002
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            let name: String
            switch uid {
            case tractanda_uid(): name = "admin"
            case alice: name = "alice"
            case bob: name = "bob"
            default: throw TractandaError("unresolvedPrincipal", "Fixture user missing")
            }
            return AccountIdentity(uid: uid, name: name, primaryGroupName: "staff", groupIDs: [72001])
        }
        func user(named name: String) throws -> AccountIdentity {
            let uid: UInt32
            switch name {
            case "admin": uid = tractanda_uid()
            case "alice": uid = alice
            case "bob": uid = bob
            default: throw TractandaError("unresolvedPrincipal", "Fixture user missing")
            }
            return try user(forUID: uid)
        }
        func groupID(named name: String) throws -> UInt32 {
            guard name == "staff" else {
                throw TractandaError("unresolvedPrincipal", "Fixture group missing")
            }
            return 72001
        }
    }
    override func setUpWithError() throws { try AttachmentFixtureCapacity.requireFree() }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func policy(_ users: [String] = ["alice", "bob"]) -> ItemValue {
        .object(["profile": .text(AccessConfiguration.profile), "users": .list(users.map(ItemValue.text))])
    }
    private func permissions(_ mode: Int64 = 0o644) -> ItemValue {
        .object([
            "profile": .text(ItemPermissions.profile), "owner": .text("alice"), "group": .text("staff"),
            "mode": .integer(mode), "acl": .object([:]),
        ])
    }
    private func fixture(_ body: (URL, Accounts) throws -> Void) throws {
        // Estimate under16MiB including source, placement, live and staged indexes, below32MiB guard.
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-writable-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, Accounts())
    }
    private func open(
        _ root: URL, _ accounts: Accounts, _ opening: PersonalWorkgroupProfile.Opening,
        indexDirectory: URL? = nil
    ) throws
        -> ItemStore
    {
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        return try ItemStore(
            personalRoot: root, indexDirectory: indexDirectory, opening: opening, accounts: accounts,
            attachmentUploadPolicy: .init(minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes),
            recoveryLimits: limits)
    }
    private func create(_ store: ItemStore, operation: String = "create", subject: String = "original") throws
        -> CommitResult
    {
        try store.commit(
            .init(
                classID: "Item", changes: ["subject": .text(subject), "permissions": permissions()],
                operationID: operation))
    }
    private func assertCode(_ code: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, code) }
    }
    private func write(_ bytes: Data, root: URL, path: String) throws {
        try AttachmentFixtureCapacity.requireFree(at: root)
        guard bytes.count < 4 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Fixture byte limit")
        }
        let url = root.appendingPathComponent(path)
        try PrivateConfiguration.makeDirectory(url.deletingLastPathComponent())
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func save(_ revision: Revision, root: URL) throws {
        try write(
            RecordCodec.encode(revision), root: root,
            path: "items/2026/10/24/11/01/\(revision.itemID)/\(revision.revisionID).tractanda")
    }
    private func raw(
        item: String? = nil, parents: [String] = [], second: Int = 0, subject: String = "raw",
        operation: String? = nil, intent: String = "raw fixture", extra: [String: ItemValue] = [:]
    ) throws -> Revision {
        var fields: [String: ItemValue] = [
            "itemID": .text(try item ?? id()), "revisionID": .text(try id()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date("2026-10-24T10:00:00Z"),
            "modifiedAt": .date(String(format: "2026-10-24T10:00:%02dZ", second)),
            "actor": .text("user:alice"), "operationID": .text(try operation ?? id()),
            "requestIdentity": .text(intent), "subject": .text(subject), "permissions": permissions(),
        ]
        if parents.count == 1 { fields["supersedes"] = .text(parents[0]) }
        fields.merge(extra) { _, new in new }
        let seed = try Revision(fields: fields)
        fields["revisionAncestry"] = try RevisionProvenance(
            kind: parents.count > 1 ? .resolution : .authored, originReplicaID: id(),
            parents: parents.sorted(),
            writtenFields: parents.isEmpty ? RevisionMerge.semanticFields(seed).keys.sorted() : ["subject"],
            unsetFields: [], frontier: parents.count > 1 ? parents.sorted() : []
        ).itemValue
        return try Revision(fields: fields, formatVersion: 2)
    }
    private func fingerprint(_ root: URL) throws -> [String: String] {
        var output: [String: String] = [:]
        for name in ["items", "attachments/payloads", "documents/content"] {
            guard
                let entries = FileManager.default.enumerator(
                    at: root.appendingPathComponent(name), includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in entries {
                let metadata = try FileMetadata.read(at: url)
                if metadata.type == .regular {
                    output[String(url.path.dropFirst(root.path.count + 1))] = AuthorityRecordCodec.sha256(
                        try Data(contentsOf: url))
                }
            }
        }
        return output
    }
    private func page(_ number: Int = 1, text: String = "ordinarydocumentneedle", pdf: Bool = false) throws
        -> AttachmentDocumentPage
    {
        try AttachmentDocumentPage(
            pageNumber: number,
            geometry: DocumentPageGeometry(
                sourceWidth: 512, sourceHeight: 256, sourceUnit: pdf ? "pdfPoint" : "pixel",
                displayWidth: 512, displayHeight: 256, canvasWidth: 2048, canvasHeight: 1024,
                contentLeft: 0, contentTop: 0, contentWidth: 2048, contentHeight: 1024),
            rasterSHA256: String(repeating: "b", count: 64),
            parsed: DoclingDocTagsParser.parse(Data(("<doctag><text>" + text + "</text></doctag>").utf8)),
            generatedTokens: 16, stopReason: "stop")
    }

    private func savedDocumentForRecovery(_ store: ItemStore, accounts: Accounts) throws
        -> DocumentContentReference
    {
        try store.withAccess(forUID: accounts.alice) {
            let item = try create(store, operation: "document-io-base").revision
            let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
            let upload = try store.beginAttachment(
                .init(
                    itemID: item.itemID, expectedRevisionID: item.revisionID,
                    operationID: "document-io-original", filename: "io.png", mediaType: "image/png",
                    byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: bytes)
            let attached = try store.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                    itemID: item.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: upload.attachment.attachmentID, operationID: "document-io-page",
                    identity: .init())
            else { throw TractandaError("fixture", "Expected document admission") }
            _ = try store.finishAttachmentDocument(snapshot, pages: [page()])
            let revision = try store.get(item.itemID)
            return try XCTUnwrap(
                AttachmentDocumentRepresentation.representations(in: revision.fields).first?.content)
        }
    }

    func testExplicitNegativeDocumentReadIOPropagatesThroughInventoryAndRetries() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts, .fresh(policy()))
            _ = try savedDocumentForRecovery(store, accounts: accounts)
            var clock: Double = 100
            store.personalRecoveryClockForTesting = { clock }
            store.beforePersonalDurableAcknowledgementForTesting = {
                throw TractandaError("injected", "Uncertain publication")
            }
            let request = CommitRequest(
                classID: "Item",
                changes: ["subject": .text("read fault"), "permissions": permissions()],
                operationID: "read-fault-retry")
            assertCode("uncertainCommit") {
                _ = try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
            }
            store.beforePersonalDurableAcknowledgementForTesting = nil
            store.personalRecoveryDocumentReadFailureForTesting = EIO
            var attempts = 0
            store.personalRecoveryIndexWillReplace = { attempts += 1 }
            for _ in 0..<2 {
                XCTAssertThrowsError(
                    try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
                ) {
                    let failure = $0 as? TractandaError
                    XCTAssertEqual(failure?.code, "documentIntegrity")
                    XCTAssertEqual(
                        failure?.osError, EIO,
                        "Inventory must preserve explicit negative-read I/O instead of declaring corruption")
                }
            }
            XCTAssertEqual(attempts, 1)
            store.personalRecoveryDocumentReadFailureForTesting = nil
            clock += 31
            let result = try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
            XCTAssertTrue(result.wasReplayed)
            XCTAssertEqual(attempts, 2)
            XCTAssertTrue(store.isCanonicalTrusted)
            XCTAssertEqual(try store.history(result.revision.itemID).count, 1)
        }
    }

    func testLogicalDocumentIntegrityIgnoresStaleErrnoAndDoesNotRetry() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            let reference = try savedDocumentForRecovery(store!, accounts: accounts)
            let files = DocumentContentFiles(root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 0)
            errno = EIO
            let logical: TractandaError
            do {
                try files.freezePeerStage(["invalid-stage"], reference: reference)
                XCTFail("Expected logical stage validation failure")
                return
            } catch {
                logical = try XCTUnwrap(error as? TractandaError)
            }
            XCTAssertEqual(logical.code, "documentIntegrity")
            XCTAssertNil(logical.osError, "A logical guard must not attach ambient EIO")
            var clock: Double = 100
            store!.personalRecoveryClockForTesting = { clock }
            store!.beforePersonalDurableAcknowledgementForTesting = {
                throw TractandaError("injected", "Uncertain publication")
            }
            let request = CommitRequest(
                classID: "Item",
                changes: ["subject": .text("logical fault"), "permissions": permissions()],
                operationID: "logical-fault-retry")
            assertCode("uncertainCommit") {
                _ = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
            }
            store!.beforePersonalDurableAcknowledgementForTesting = nil
            var attempts = 0
            store!.personalRecoveryIndexWillReplace = { attempts += 1 }
            store!.beforeCanonicalDurabilitySync = { throw logical }
            assertCode("documentIntegrity") { try store!.withAccess(forUID: accounts.alice) {} }
            store!.beforeCanonicalDurabilitySync = nil
            clock += 1_000
            assertCode("documentIntegrity") { try store!.withAccess(forUID: accounts.alice) {} }
            XCTAssertEqual(
                attempts, 1, "Logical integrity remains terminal after the transient retry interval")
            store = nil
            store = try open(root, accounts, .existing)
            XCTAssertTrue(
                try store!.withAccess(forUID: accounts.alice) { try store!.commit(request).wasReplayed })
            store = nil
        }
    }

    func testFreshWriteReviseDeleteReopenIndexLossAndNativeService() throws {
        try fixture { root, accounts in
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("created"), "permissions": permissions()],
                operationID: "new")
            let first: Revision
            let tombstone: Revision
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            first = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request).revision }
            let updated = try store!.withAccess(forUID: accounts.alice) {
                try store!.commit(
                    .init(
                        action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                        changes: ["subject": .text("updated")], operationID: "revise")
                ).revision
            }
            tombstone = try store!.withAccess(forUID: accounts.alice) {
                try store!.commit(
                    .init(
                        action: .revise, itemID: first.itemID, expectedRevisionID: updated.revisionID,
                        changes: ["isDeleted": .boolean(true)], operationID: "delete")
                ).revision
            }
            do {
                let service = ItemService(store: store!)
                let call = try nativeFixtureEnvelope(
                    calls: [["TractandaItem/get", ["ids": [first.itemID]], "c"]],
                    accountID: store!.nativeProtocolSessionBasis.identity)
                let response = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: service.handle(call, peerUID: accounts.alice))
                        as? [String: Any])
                let responses = try XCTUnwrap(response["methodResponses"] as? [[Any]])
                XCTAssertEqual(responses.first?.first as? String, "TractandaItem/get")
                let payload = try XCTUnwrap(responses.first?[1] as? [String: Any])
                XCTAssertEqual((payload["list"] as? [Any])?.count, 1)
            }
            XCTAssertFalse(try store!.verificationSnapshot().authorityEnforced)
            let before = try fingerprint(root)
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try ItemStore.openPersonalWorkgroup(root: root, accounts: accounts)
            try store!.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(try store!.get(first.itemID), tombstone)
                XCTAssertEqual(try store!.history(first.itemID), [tombstone, updated, first])
                let retry = try store!.commit(request)
                XCTAssertTrue(retry.wasReplayed)
                XCTAssertEqual(retry.revision, first)
                XCTAssertTrue(try store!.candidates().isEmpty)
            }
            XCTAssertEqual(try fingerprint(root), before)
            store = nil
        }
    }

    func testCrossOriginExactRetryAndConservativeCollision() throws {
        try fixture { root, accounts in
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("old request")], operationID: "retained-operation"
            )
            let prior = try raw(
                operation: request.operationID, intent: JSON.encode(request).base64EncodedString())
            try save(prior, root: root)
            let before = try fingerprint(root)
            let store = try open(root, accounts, .selectedContent(policy()))
            try store.withAccess(forUID: accounts.alice) {
                let replay = try store.commit(request)
                XCTAssertTrue(replay.wasReplayed)
                XCTAssertEqual(replay.revision, prior)
            }
            XCTAssertEqual(try fingerprint(root), before)
        }
        try fixture { root, accounts in
            for _ in 0..<2 { try save(raw(operation: "collision"), root: root) }
            let store = try open(root, accounts, .selectedContent(policy()))
            let before = try fingerprint(root)
            try store.withAccess(forUID: accounts.alice) {
                assertCode("operationMismatch") { _ = try create(store, operation: "collision") }
            }
            XCTAssertEqual(try fingerprint(root), before)
        }
    }

    func testCurrentACLRevocationAndLocalPolicySurviveRebuild() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            let first = try store!.withAccess(forUID: accounts.alice) { try create(store!).revision }
            // A later item's catalogue/derived writes must not invalidate this item's state.
            let other = try store!.withAccess(forUID: accounts.alice) {
                try create(store!, operation: "other-create", subject: "other searchable").revision
            }
            let updatedOther = try store!.withAccess(forUID: accounts.alice) {
                try store!.commit(
                    .init(
                        action: .revise, itemID: other.itemID,
                        expectedRevisionID: other.revisionID,
                        changes: ["subject": .text("other searchable updated")],
                        operationID: "other-edit")
                ).revision
            }
            try store!.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store!.get(first.itemID), first)
                XCTAssertEqual(try store!.history(first.itemID), [first])
                XCTAssertEqual(try store!.get(other.itemID), updatedOther)
                XCTAssertEqual(try store!.candidates(text: "searchable"), [updatedOther])
            }
            let privateHead = try store!.withAccess(forUID: accounts.alice) {
                try store!.commit(
                    .init(
                        action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                        changes: ["permissions": permissions(0o600)], operationID: "revoke")
                ).revision
            }
            try store!.withAccess(forUID: accounts.bob) {
                assertCode("forbidden") { _ = try store!.get(first.itemID, revisionID: first.revisionID) }
                assertCode("forbidden") { _ = try store!.history(first.itemID) }
                XCTAssertEqual(try store!.get(other.itemID), updatedOther)
                XCTAssertEqual(try store!.candidates(text: "searchable"), [updatedOther])
            }
            assertCode("personalConfigurationRequired") {
                _ = try store!.configureAccess(policy(), operationID: "old-route")
            }
            try store!.configurePersonalAccess(policy(["alice"]))
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try open(root, accounts, .existing)
            assertCode("forbidden") {
                try store!.withAccess(forUID: accounts.bob) { _ = try store!.get(first.itemID) }
            }
            try store!.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(try store!.history(first.itemID), [privateHead, first])
            }
            store = nil
        }
    }

    func testPublicationFaultBoundariesRecoverAndReplayExactlyOnce() throws {
        for phase in 0..<3 {
            try fixture { root, accounts in
                var store: ItemStore? = try open(root, accounts, .fresh(policy()))
                let fault: () throws -> Void = {
                    throw TractandaError("fixtureFault", "Injected process boundary")
                }
                if phase == 0 { store!.beforeCanonicalPublicationForTesting = fault }
                if phase == 1 { store!.beforeIndexUpdate = fault }
                if phase == 2 { store!.beforeCheckpointClear = fault }
                let request = CommitRequest(
                    classID: "Item",
                    changes: ["subject": .text("one canonical edit"), "permissions": permissions()],
                    operationID: "fault-edit")
                var published: Revision?
                if phase == 0 {
                    assertCode("fixtureFault") {
                        _ = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
                    }
                    XCTAssertTrue(try fingerprint(root).isEmpty)
                } else {
                    let result = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
                    published = result.revision
                    XCTAssertFalse(result.warnings.isEmpty)
                }
                store = nil
                store = try open(root, accounts, .existing)
                try store!.withAccess(forUID: accounts.alice) {
                    let result = try store!.commit(request)
                    XCTAssertEqual(result.wasReplayed, phase != 0)
                    if let published { XCTAssertEqual(result.revision, published) }
                    XCTAssertEqual(try store!.history(result.revision.itemID).count, 1)
                    XCTAssertEqual(try store!.candidates().count, 1)
                }
                store = nil
            }
        }
    }

    func testUncertainDurablePublicationIsNotAcknowledgedAndExactRetryRecoversOnce() throws {
        for phase in 0..<2 {
            try fixture { root, accounts in
                var store: ItemStore? = try open(root, accounts, .fresh(policy()))
                if phase == 0 {
                    store!.publishResultOverrideForTesting = 1
                } else {
                    store!.beforePersonalDurableAcknowledgementForTesting = {
                        throw TractandaError("fixtureFault", "Device flush failed after publication")
                    }
                }
                let request = CommitRequest(
                    classID: "Item", changes: ["subject": .text("uncertain"), "permissions": permissions()],
                    operationID: "durable-exact-retry")
                assertCode("uncertainCommit") {
                    _ = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
                }
                XCTAssertTrue(StoreCheckpoint.isDirty(root: root))
                XCTAssertFalse(store!.isCanonicalTrusted)
                let published = try fingerprint(root)
                XCTAssertEqual(published.count, 1)
                if phase == 0 {
                    store = nil
                    store = try open(root, accounts, .existing)
                } else {
                    // A transient barrier failure must recover on the next serial
                    // request without stopping/restarting the service.
                    store!.beforePersonalDurableAcknowledgementForTesting = nil
                }
                try store!.withAccess(forUID: accounts.alice) {
                    let replay = try store!.commit(request)
                    XCTAssertTrue(replay.wasReplayed)
                    XCTAssertTrue(replay.isIndexReady)
                    XCTAssertEqual(try store!.history(replay.revision.itemID).count, 1)
                    XCTAssertEqual(try store!.commit(request).revision, replay.revision)
                }
                XCTAssertEqual(try fingerprint(root), published)
                store = nil
            }
        }
    }

    func testCompatibleUpgradeUsesEstablishedFenceWithoutInventoryAndStartupStillChecksContent() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            _ = try store!.withAccess(forUID: accounts.alice) { try create(store!) }
            let row = try XCTUnwrap(store!.exportCatalogueForVerification().first)
            store = nil
            let markerURL = root.appendingPathComponent(CanonicalReaderRequirement.fileName)
            let marker = try Data(contentsOf: markerURL)
            let canonical = root.appendingPathComponent(row.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonical.path)
            try Data("corrupt canonical content".utf8).write(to: canonical)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: canonical.path)
            let requirement = try CanonicalReaderRequirement.withWriterLock(
                root: root, ownerUID: tractanda_uid()
            ) {
                try ItemStore.personalWorkgroupUpgradeRequirement(root: root, ownerUID: tractanda_uid())
            }
            XCTAssertEqual(requirement, try JSON.decode(CanonicalReaderRequirement.self, marker))
            XCTAssertEqual(try Data(contentsOf: markerURL), marker)
            XCTAssertThrowsError(try open(root, accounts, .existing))
            XCTAssertEqual(try Data(contentsOf: canonical), Data("corrupt canonical content".utf8))
        }
    }

    func testTransientPublicationRecoveryBacksOffAndRejectsUnauthorizedTrigger() throws {
        try fixture { root, accounts in
            let store = try open(root, accounts, .fresh(policy(["alice"])))
            var clock: Double = 100
            store.personalRecoveryClockForTesting = { clock }
            store.beforePersonalDurableAcknowledgementForTesting = {
                throw TractandaError("fixtureFault", "Uncertain device flush")
            }
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("backoff"), "permissions": permissions()],
                operationID: "backoff-exact-retry")
            assertCode("uncertainCommit") {
                _ = try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
            }
            store.beforePersonalDurableAcknowledgementForTesting = nil
            var attempts = 0
            store.beforeCanonicalDurabilitySync = {
                attempts += 1
                throw TractandaError("resourceLimit", "Temporary recovery capacity failure")
            }
            assertCode("forbidden") { try store.withAccess(forUID: accounts.bob) {} }
            XCTAssertEqual(attempts, 0)
            for _ in 0..<3 {
                assertCode("resourceLimit") {
                    _ = try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
                }
            }
            XCTAssertEqual(attempts, 1, "Repeated requests must not restart a failed recovery scan")
            clock += 31
            store.beforeCanonicalDurabilitySync = nil
            let replay = try store.withAccess(forUID: accounts.alice) { try store.commit(request) }
            XCTAssertTrue(replay.wasReplayed)
            XCTAssertTrue(store.isCanonicalTrusted)
            XCTAssertEqual(try store.history(replay.revision.itemID).count, 1)
        }
    }

    func testCanonicalCorruptionStopsAutomaticRetryUntilExplicitRepairAndReopen() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            store!.publishResultOverrideForTesting = 1
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("repair"), "permissions": permissions()],
                operationID: "repair-exact-retry")
            assertCode("uncertainCommit") {
                _ = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
            }
            let physicalRoot = store!.root
            let relative = try XCTUnwrap(fingerprint(physicalRoot).keys.first)
            let path = physicalRoot.appendingPathComponent(relative)
            let original = try Data(contentsOf: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try Data("corrupt canonical bytes".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            XCTAssertThrowsError(try store!.withAccess(forUID: accounts.alice) {})
            XCTAssertFalse(store!.isCanonicalTrusted)
            // Explicitly repair this private fixture, but the failed runtime still requires
            // reopen: a later poll must not decide that canonical corruption cured itself.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try original.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            XCTAssertThrowsError(try store!.withAccess(forUID: accounts.alice) {})
            store = nil
            store = try open(root, accounts, .existing)
            XCTAssertTrue(
                try store!.withAccess(forUID: accounts.alice) { try store!.commit(request).wasReplayed })
            store = nil
        }
    }

    func testCompatibleUpgradeRejectsMissingWeakenedUnknownCrossStoreAndWrongOwnerFences() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            XCTAssertTrue(store!.isCanonicalTrusted)
            store = nil
            let markerURL = root.appendingPathComponent(CanonicalReaderRequirement.fileName)
            let original = try Data(contentsOf: markerURL)
            let fence = try JSON.decode(CanonicalReaderRequirement.self, original)
            func checkDenied() throws {
                XCTAssertThrowsError(
                    try CanonicalReaderRequirement.withWriterLock(root: root, ownerUID: tractanda_uid()) {
                        try ItemStore.personalWorkgroupUpgradeRequirement(
                            root: root, ownerUID: tractanda_uid())
                    })
            }
            try FileManager.default.removeItem(at: markerURL)
            try checkDenied()
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            for invalid in [
                CanonicalReaderRequirement(
                    storeID: fence.storeID, minimumReaderLevel: 2, recordFormats: [1, 2]),
                .init(
                    storeID: fence.storeID, minimumReaderLevel: fence.minimumReaderLevel,
                    recordFormats: fence.recordFormats,
                    capabilities: fence.capabilities + ["unknown.future-format"]),
                .init(
                    storeID: try id(), minimumReaderLevel: fence.minimumReaderLevel,
                    recordFormats: fence.recordFormats, capabilities: fence.capabilities),
            ] {
                let bytes = try JSON.encode(invalid)
                try PrivateConfiguration.write(bytes, to: markerURL)
                try checkDenied()
                XCTAssertEqual(try Data(contentsOf: markerURL), bytes)
            }
            try PrivateConfiguration.write(original, to: markerURL)
            XCTAssertThrowsError(
                try ItemStore.personalWorkgroupUpgradeRequirement(root: root, ownerUID: tractanda_uid() + 1))
            XCTAssertEqual(try Data(contentsOf: markerURL), original)
        }
    }

    /// Starts a fresh XCTest process, then exits it without Store deinitialization after
    /// acknowledged revision/original/document writes. This proves process-crash recovery,
    /// not the behavior of physical storage under a real power cut.
    func testAcknowledgedOwnedContentSurvivesAbruptProcessExitAndDisposableIndexLoss() throws {
        let environmentKey = "TRACTANDA_PRIVATE_PERSONAL_CRASH_ROOT"
        if let path = ProcessInfo.processInfo.environment[environmentKey] {
            let root = URL(fileURLWithPath: path)
            let accounts = Accounts()
            let store = try open(root, accounts, .fresh(policy()))
            try store.withAccess(forUID: accounts.alice) {
                let item = try create(store, operation: "abrupt-create").revision
                let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
                let upload = try store.beginAttachment(
                    .init(
                        itemID: item.itemID, expectedRevisionID: item.revisionID,
                        operationID: "abrupt-original", filename: "crash.png", mediaType: "image/png",
                        byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes)))
                let uploadID = try XCTUnwrap(upload.uploadID)
                _ = try store.appendAttachment(uploadID: uploadID, offset: 0, data: bytes)
                let attached = try store.finishAttachment(uploadID: uploadID)
                XCTAssertTrue(attached.warnings.isEmpty)
                guard
                    case .prepared(let snapshot) = try store.prepareAttachmentDocument(
                        itemID: item.itemID, expectedRevisionID: attached.revision.revisionID,
                        attachmentID: upload.attachment.attachmentID,
                        operationID: "abrupt-document", identity: .init())
                else { throw TractandaError("fixture", "Expected document preparation") }
                _ = try store.finishAttachmentDocument(snapshot, pages: [page()])
                // No fixture cleanup/deinit is allowed to close SQLite or release writer locks.
                _exit(73)
            }
            XCTFail("The crash child did not reach its exit boundary")
            return
        }
        try fixture { root, accounts in
            let child = Process()
            var environment = ProcessInfo.processInfo.environment
            environment[environmentKey] = root.path
            child.environment = environment
            let selector =
                "TractandaCoreTests.PersonalWorkgroupStoreTests/testAcknowledgedOwnedContentSurvivesAbruptProcessExitAndDisposableIndexLoss"
            #if os(macOS)
                child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                child.arguments = ["xctest", "-XCTest", selector, Bundle(for: Self.self).bundleURL.path]
            #else
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = [selector]
            #endif
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .exit)
            XCTAssertEqual(child.terminationStatus, 73)
            guard child.terminationStatus == 73 else { return }
            let before = try fingerprint(root)
            XCTAssertEqual(before.keys.filter { $0.hasSuffix(".tractanda") }.count, 3)
            // A corrupt ordinary item database must be as disposable as a missing one.
            let index = root.appendingPathComponent("index/items.sqlite")
            try Data("not a database".utf8).write(to: index)
            var store: ItemStore? = try open(root, accounts, .existing)
            func verify() throws {
                try store!.withAccess(forUID: accounts.alice) {
                    let item = try XCTUnwrap(store!.candidates().first)
                    XCTAssertEqual(try store!.history(item.itemID).count, 3)
                    let attachment = try XCTUnwrap(AttachmentDescriptor.descriptors(in: item.fields).first)
                    XCTAssertEqual(
                        try store!.attachmentContent(
                            itemID: item.itemID, attachmentID: attachment.attachmentID
                        ).data,
                        Data([137, 80, 78, 71, 13, 10, 26, 10]))
                    XCTAssertEqual(
                        try store!.readAttachmentDocument(
                            itemID: item.itemID, attachmentID: attachment.attachmentID, pageNumber: 1
                        ).pages.first?.parsed.text, "ordinarydocumentneedle")
                    XCTAssertTrue(try create(store!, operation: "abrupt-create").wasReplayed)
                }
                XCTAssertEqual(try fingerprint(root), before)
            }
            try verify()
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try open(root, accounts, .existing)
            try verify()
            store = nil
        }
    }

    func testPendingActivationResumesWithFenceBeforeIdentityAndRejectsOldWriter() throws {
        try fixture { root, accounts in
            let descriptor = tractanda_lock(root.appendingPathComponent(".writer.lock").path)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            assertCode("fixtureFault") {
                _ = try PersonalWorkgroupProfile.prepare(root, opening: .fresh(policy()), accounts: accounts)
                { phase in
                    if phase == "readerFenced" {
                        throw TractandaError("fixtureFault", "Interrupted activation")
                    }
                }
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(".tractanda-store-identity.json").path))
            let pending = try XCTUnwrap(PersonalWorkgroupProfile.load(root, pending: true))
            let fence = try JSON.decode(
                CanonicalReaderRequirement.self,
                Data(contentsOf: root.appendingPathComponent(CanonicalReaderRequirement.fileName)))
            let old = CanonicalFormatSupport(readerLevel: 15, writerLevel: 15, read: [1, 2], write: [2])
            assertCode("incompatibleCanonicalReader") { try old.require(fence) }
            tractanda_unlock(descriptor)
            var store: ItemStore? = try open(root, accounts, .existing)
            XCTAssertEqual(store!.replicaID, pending.replicaID)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(PersonalWorkgroupProfile.pendingName).path))
            store = nil
            assertCode("personalProfileRequired") { _ = try ItemStore(root: root, accounts: accounts) }
            try write(Data("unsupported current peer".utf8), root: root, path: ".peer-configuration")
            assertCode("unsupportedPersonalPeers") { _ = try open(root, accounts, .existing) }
        }
    }

    func testNewOriginalAndSavedDocumentPublishReadSearchAndReopen() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            let item = try store!.withAccess(forUID: accounts.alice) { try create(store!).revision }
            let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
            let (saved, attachment) = try store!.withAccess(forUID: accounts.alice) {
                let upload = try store!.beginAttachment(
                    .init(
                        itemID: item.itemID, expectedRevisionID: item.revisionID,
                        operationID: "original", filename: "fixture.png", mediaType: "image/png",
                        byteCount: Int64(bytes.count),
                        sha256: AuthorityRecordCodec.sha256(bytes)))
                let attachment = upload.attachment
                let uploadID = try XCTUnwrap(upload.uploadID)
                _ = try store!.appendAttachment(uploadID: uploadID, offset: 0, data: bytes)
                let attached = try store!.finishAttachment(uploadID: uploadID).revision
                guard
                    case .prepared(let snapshot) = try store!.prepareAttachmentDocument(
                        itemID: item.itemID,
                        expectedRevisionID: attached.revisionID, attachmentID: attachment.attachmentID,
                        operationID: "saved-document", identity: .init())
                else { throw TractandaError("fixture", "Expected new document admission") }
                let receipt = try store!.finishAttachmentDocument(snapshot, pages: [page()])
                let saved = try store!.get(receipt.itemID)
                XCTAssertEqual(
                    try store!.attachmentContent(itemID: item.itemID, attachmentID: attachment.attachmentID)
                        .data, bytes)
                XCTAssertEqual(
                    try store!.readAttachmentDocument(
                        itemID: item.itemID,
                        attachmentID: attachment.attachmentID, pageNumber: 1
                    ).pages.first?.parsed.text, "ordinarydocumentneedle")
                XCTAssertEqual(try store!.candidates(text: "ordinarydocumentneedle"), [saved])
                return (saved, attachment)
            }
            let before = try fingerprint(root)
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try open(root, accounts, .existing)
            try store!.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store!.get(item.itemID), saved)
                XCTAssertEqual(try store!.candidates(text: "ordinarydocumentneedle"), [saved])
                XCTAssertEqual(
                    try store!.attachmentContent(itemID: item.itemID, attachmentID: attachment.attachmentID)
                        .data, bytes)
                XCTAssertEqual(
                    try store!.readAttachmentDocument(
                        itemID: item.itemID,
                        attachmentID: attachment.attachmentID, pageNumber: 1
                    ).pages.first?.parsed.text, "ordinarydocumentneedle")
            }
            XCTAssertEqual(try fingerprint(root), before)
            store = nil
        }
    }

    func testSelectedMergeHistoryOwnedDocumentAndOldPolicyItemRemainOrdinaryContent() throws {
        try fixture { root, accounts in
            let bytes = Data("original selected bytes".utf8)
            let attachment = try AttachmentDescriptor(
                attachmentID: id(), filename: "selected.pdf", mediaType: "application/pdf",
                byteCount: Int64(bytes.count), sha256: AuthorityRecordCodec.sha256(bytes))
            let base = try raw(subject: "base", extra: ["attachments": .list([attachment.itemValue])])
            let left = try raw(item: base.itemID, parents: [base.revisionID], second: 1, subject: "left")
            let right = try raw(item: base.itemID, parents: [base.revisionID], second: 2, subject: "right")
            let source = try AttachmentDocumentSource(
                itemID: base.itemID, revisionID: base.revisionID,
                attachmentID: attachment.attachmentID, sha256: attachment.sha256,
                byteCount: attachment.byteCount, mediaType: attachment.mediaType)
            let document = try AttachmentDocumentRepresentation(
                representationID: id(), attachmentID: attachment.attachmentID,
                source: source, extractedAt: "2026-10-24T10:00:00Z", identity: .init(),
                pages: [
                    page(1, text: "selectedfirstpage", pdf: true),
                    page(2, text: "selectedlatepage", pdf: true),
                ])
            let mergedDraft = try raw(
                item: base.itemID, parents: [left.revisionID, right.revisionID], second: 3, subject: "merged",
                extra: [
                    "attachments": .list([attachment.itemValue]),
                    "attachmentDocument": .list([document.itemValue]),
                ])
            let absentWitness = try AuthorityBinding(
                recordID: id(), sha256: String(repeating: "a", count: 64))
            var mergedFields = mergedDraft.fields
            mergedFields["revisionAncestry"] = try RevisionProvenance(
                kind: .automaticMerge, originReplicaID: id(),
                parents: [left.revisionID, right.revisionID].sorted(),
                writtenFields: [], unsetFields: [], frontier: [left.revisionID, right.revisionID].sorted(),
                mergeProfile: RevisionProvenance.authorityReconciliationProfile,
                authorityWitness: absentWitness
            ).itemValue
            let merged = try Revision(fields: mergedFields, formatVersion: 2)
            var oldPolicyFields = try raw(subject: "old policy remains content").fields
            oldPolicyFields["classID"] = .text(AccessConfiguration.classID)
            oldPolicyFields["accessConfiguration"] = policy(["admin"])
            oldPolicyFields.removeValue(forKey: "permissions")
            oldPolicyFields.removeValue(forKey: "revisionAncestry")
            let policySeed = try Revision(fields: oldPolicyFields)
            oldPolicyFields["revisionAncestry"] = try RevisionProvenance(
                kind: .authored, originReplicaID: id(), parents: [],
                writtenFields: RevisionMerge.semanticFields(policySeed).keys.sorted(), unsetFields: [],
                frontier: []
            ).itemValue
            let oldPolicy = try Revision(fields: oldPolicyFields, formatVersion: 2)
            for revision in [merged, right, oldPolicy, left, base] { try save(revision, root: root) }
            let payloadPath = "attachments/payloads/2026/10/24/11/01/\(attachment.attachmentID).payload"
            try write(bytes, root: root, path: payloadPath)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: root.appendingPathComponent(payloadPath).path)
            let original = try fingerprint(root)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent("authority").path))
            var store: ItemStore? = try open(root, accounts, .selectedContent(policy()))
            XCTAssertEqual(try fingerprint(root), original)
            try store!.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store!.get(base.itemID), merged)
                XCTAssertEqual(try store!.get(base.itemID).provenance?.authorityWitness, absentWitness)
                XCTAssertEqual(try store!.candidates(text: "selectedlatepage"), [merged])
                XCTAssertEqual(
                    try store!.readAttachmentDocument(
                        itemID: base.itemID,
                        attachmentID: attachment.attachmentID, pageNumber: 2
                    ).pages.first?.parsed.text, "selectedlatepage")
                XCTAssertEqual(
                    try store!.attachmentContent(itemID: base.itemID, attachmentID: attachment.attachmentID)
                        .data, bytes)
            }
            let next = try store!.withAccess(forUID: accounts.alice) {
                try store!.commit(
                    .init(
                        action: .revise, itemID: base.itemID, expectedRevisionID: merged.revisionID,
                        changes: ["subject": .text("after selected merge")], operationID: "new-after-merge")
                ).revision
            }
            XCTAssertEqual(try next.provenance?.parents, [merged.revisionID])
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try open(root, accounts, .existing)
            try store!.withAccess(forUID: accounts.bob) {
                XCTAssertEqual(try store!.history(base.itemID), [next, merged, right, left, base])
                XCTAssertEqual(try store!.candidates(text: "selectedlatepage"), [next])
            }
            let after = try fingerprint(root)
            for (path, digest) in original { XCTAssertEqual(after[path], digest) }
            store = nil
        }
    }

    func testNormalOpenRequiresExplicitSelectionAndSelectedDAGPreservesFiles() throws {
        try fixture { root, accounts in
            let base = try raw()
            let branches = [
                base, try raw(item: base.itemID, parents: [base.revisionID], second: 1),
                try raw(item: base.itemID, parents: [base.revisionID], second: 2),
            ]
            for revision in branches { try save(revision, root: root) }
            assertCode("uninitializedPersonalProfile") { _ = try open(root, accounts, .existing) }
            let store = try open(root, accounts, .selectedContent(policy()))
            let history = try store.history(base.itemID)
            XCTAssertTrue(Set(branches.map(\.revisionID)).isSubset(of: history.map(\.revisionID)))
            XCTAssertEqual(try store.get(base.itemID).fields["subject"], base.fields["subject"])
        }
    }

    func testUncertainLocalPolicyPublicationFailsClosedUntilReopen() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            let item = try store!.withAccess(forUID: accounts.alice) { try create(store!).revision }
            let before = try fingerprint(root)
            store!.afterPersonalPolicyPublicationForTesting = {
                throw TractandaError("fixtureFault", "Directory sync interrupted")
            }
            assertCode("fixtureFault") { try store!.configurePersonalAccess(policy(["alice"])) }
            XCTAssertFalse(store!.isCanonicalTrusted)
            XCTAssertThrowsError(try store!.candidates())
            XCTAssertThrowsError(try store!.get(item.itemID))
            assertCode("recoveryRequired") { try store!.rebuildIndex() }
            assertCode("recoveryRequired") { try store!.configurePersonalAccess(policy()) }
            store = nil
            store = try open(root, accounts, .existing)
            assertCode("forbidden") {
                try store!.withAccess(forUID: accounts.bob) { _ = try store!.get(item.itemID) }
            }
            try store!.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(try store!.get(item.itemID), item)
            }
            XCTAssertEqual(try fingerprint(root), before)
            store = nil
        }
    }

    func testExistingProfileRejectsChangedInitializationPolicyAndWeakenedFence() throws {
        try fixture { root, accounts in
            var store: ItemStore? = try open(root, accounts, .fresh(policy()))
            let identity = try CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid())
            store = nil
            assertCode("invalidPersonalProfile") { _ = try open(root, accounts, .fresh(policy(["alice"]))) }
            let weakened = CanonicalReaderRequirement(
                storeID: identity, minimumReaderLevel: 16, recordFormats: [1, 2], capabilities: [])
            try PrivateConfiguration.write(
                JSON.encode(weakened), to: root.appendingPathComponent(CanonicalReaderRequirement.fileName))
            assertCode("invalidPersonalProfile") { _ = try open(root, accounts, .existing) }
        }
    }

    func testPostOpenCapacityKeepsReadsAvailableAndRetainsPublishedEditForRecovery() throws {
        try fixture { root, accounts in
            let available = AvailableBytes()
            let indexLocation = root.appendingPathComponent("external-derived-index")
            var limits = PersonalRecoveryIndex.Limits()
            limits.maximumDerivedBytes = 2 * 1024 * 1024
            var store: ItemStore? = try ItemStore(
                personalRoot: root, indexDirectory: indexLocation, opening: .fresh(policy()),
                accounts: accounts,
                attachmentUploadPolicy: .init(minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes),
                indexAvailableBytes: { available.read(at: $0) }, recoveryLimits: limits)
            let first = try store!.withAccess(forUID: accounts.alice) { try create(store!).revision }
            let before = try fingerprint(root)
            available.set(0)
            try store!.withAccess(forUID: accounts.alice) {
                XCTAssertEqual(try store!.get(first.itemID), first)
                XCTAssertEqual(try store!.history(first.itemID), [first])
                XCTAssertEqual(try store!.candidates(text: "original"), [first])
                assertCode("resourceLimit") {
                    _ = try store!.commit(
                        .init(
                            action: .revise, itemID: first.itemID,
                            expectedRevisionID: first.revisionID,
                            changes: ["subject": .text("must not publish")], operationID: "low-space"))
                }
            }
            XCTAssertEqual(try fingerprint(root), before)
            XCTAssertEqual(
                available.observedDirectory()?.standardizedFileURL.resolvingSymlinksInPath(),
                indexLocation.standardizedFileURL.resolvingSymlinksInPath())
            available.set(64 * 1024 * 1024 * 1024)
            // This bounded field produces several derived FTS copies and crosses a tiny installed
            // index cap, while the complete source/stage fixture remains below32MiB. No disk filling.
            let request = CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["body": .text(String(repeating: "boundedword ", count: 120_000))],
                operationID: "bounded-cap")
            let result = try store!.withAccess(forUID: accounts.alice) { try store!.commit(request) }
            XCTAssertFalse(result.isIndexReady)
            XCTAssertFalse(result.warnings.isEmpty)
            XCTAssertFalse(store!.isCanonicalTrusted)
            let published = try fingerprint(root)
            XCTAssertEqual(published.count, before.count + 1)
            store = nil
            try FileManager.default.removeItem(at: indexLocation)
            store = try open(root, accounts, .existing, indexDirectory: indexLocation)
            try store!.withAccess(forUID: accounts.alice) {
                let replay = try store!.commit(request)
                XCTAssertTrue(replay.wasReplayed)
                XCTAssertEqual(replay.revision, result.revision)
                XCTAssertEqual(try store!.history(first.itemID).count, 2)
            }
            XCTAssertEqual(try fingerprint(root), published)
            store = nil
        }
    }
}
