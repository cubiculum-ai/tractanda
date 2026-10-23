import CSQLite
import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class AtomicAuthorityActivationTests: XCTestCase {
    private var legacy14: CanonicalFormatSupport {
        let capabilities = CanonicalFormatSupport.current.capabilities.filter {
            $0 != AtomicAuthorityFormat.profile
        }
        return .init(
            readerLevel: 14, writerLevel: 14, read: [1, 2], write: [2],
            capabilities: capabilities, writeCapabilities: capabilities)
    }
    private func canonical(_ root: URL) throws -> [String: String] {
        let ignored: Set<String> = [
            "index/items.sqlite", "index/items.sqlite-wal", "index/items.sqlite-shm",
            "index/items.sqlite-journal",
        ]
        var result: [String: String] = [:]
        for case let file as URL in try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        {
            let metadata = try FileMetadata.read(at: file)
            guard metadata.type == .regular else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if ignored.contains(relative) { continue }
            if relative.hasPrefix("index/rebuild-"), !relative.dropFirst(6).contains("/") {
                var name = String(relative.dropFirst("index/rebuild-".count))
                for suffix in ["-wal", "-shm", "-journal"] where name.hasSuffix(suffix) {
                    name.removeLast(suffix.count)
                    break
                }
                if name.hasSuffix(".sqlite"), UUID(uuidString: String(name.dropLast(7))) != nil { continue }
            }
            result[relative] = AuthorityRecordCodec.sha256(try Data(contentsOf: file))
        }
        return result
    }
    private func transitionRequired(
        _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(
                ($0 as? TractandaError)?.code, "atomicAuthorityTransitionRequired", file: file, line: line)
        }
    }

    func
        testEstablished14CheckpointOpensReadOnlyWithoutCanonicalWritesThenExplicitActivationAllowsExactRequest()
        throws
    {
        let f = try AtomicAuthorityStoreFixture(support: legacy14)
        let existing = try f.source.commit(
            .init(
                classID: "Item", changes: ["subject": .text("legacy content")],
                operationID: "activation-existing"))
        XCTAssertTrue(existing.isIndexReady, existing.warnings.joined(separator: "\n"))
        let storeID = f.storeID
        let replicaID = f.source.replicaID
        f.source = nil
        // A real old schema20 checkpoint predates these additive atomic-only tables/views.
        // Drop only empty new objects directly in this isolated derived fixture, preserving
        // its original graph/checkpoint rows, then require ordinary opening to install them.
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(f.sourceRoot.appendingPathComponent("index/items.sqlite").path, &database), SQLITE_OK
        )
        defer { if let database { sqlite3_close(database) } }
        for sql in [
            "DROP VIEW authority_control_facts", "DROP VIEW authority_control_outcomes",
            "DROP TABLE authority_atomic_accepted", "DROP TABLE authority_atomic_outcome",
            "DROP TABLE authority_control_support",
        ] {
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        database = nil
        let before = try canonical(f.sourceRoot)
        f.source = try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        XCTAssertEqual(try f.source.get(existing.revision.itemID), existing.revision)
        XCTAssertTrue(
            try f.source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("legacy content")],
                    operationID: "activation-existing")
            ).wasReplayed)
        let request = CommitRequest(
            classID: "Item", changes: ["subject": .text("after explicit activation")],
            operationID: "activation-same-request")
        transitionRequired { _ = try f.source.commit(request) }
        transitionRequired { try f.source.configurePeerIntake(peers: []) }
        transitionRequired { try f.source.rebuildIndex() }
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        XCTAssertEqual(try canonical(f.sourceRoot), before)
        f.source = nil
        try AtomicAuthorityStoreFixture.transition(f.sourceRoot)
        f.source = try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        let created = try f.source.commit(request)
        XCTAssertTrue(created.isIndexReady, created.warnings.joined(separator: "\n"))
        XCTAssertFalse(created.wasReplayed)
        XCTAssertTrue(try f.source.commit(request).wasReplayed)
        XCTAssertEqual(f.source.replicaID, replicaID)
        XCTAssertEqual(
            try CanonicalReaderRequirement.storeIdentity(root: f.sourceRoot, ownerUID: tractanda_uid()),
            storeID)
        XCTAssertEqual(try f.source.get(existing.revision.itemID), existing.revision)
        try f.capacity()
    }

    func testMissing14CheckpointReportsActivationRequiredWithoutCanonicalRecovery() throws {
        let f = try AtomicAuthorityStoreFixture(support: legacy14)
        f.source = nil
        for name in ["items.sqlite", "items.sqlite-wal", "items.sqlite-shm", "items.sqlite-journal"] {
            let path = f.sourceRoot.appendingPathComponent("index").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
        let before = try canonical(f.sourceRoot)
        transitionRequired {
            _ = try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        }
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        XCTAssertEqual(try canonical(f.sourceRoot), before)
        try f.capacity()
    }

    func testNamed15FreshFactoryStartsWithAtomicHeadAndOldReaderRefusesItsRequirement() throws {
        let f = try AtomicAuthorityStoreFixture(support: AtomicAuthorityCompatibility.support)
        let requirement = try XCTUnwrap(
            CanonicalReaderRequirement.load(root: f.sourceRoot, ownerUID: tractanda_uid()))
        XCTAssertEqual(requirement.minimumReaderLevel, 15)
        XCTAssertTrue(requirement.capabilities.contains(AtomicAuthorityFormat.profile))
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let head = try XCTUnwrap(index.authorityControlHead(originID: XCTUnwrap(f.source.replicaID)))
        XCTAssertTrue(try index.isAcceptedAtomicControl(head))
        XCTAssertTrue(try index.authorityKindPage(kind: "controlCommit", limit: 1).isEmpty)
        index.close()
        let result = try f.source.commit(
            .init(classID: "Item", changes: ["subject": .text("fresh15 write")], operationID: "fresh15-write")
        )
        XCTAssertTrue(result.isIndexReady, result.warnings.joined(separator: "\n"))
        let revised = try f.source.commit(
            .init(
                action: .revise, itemID: result.revision.itemID,
                expectedRevisionID: result.revision.revisionID,
                changes: ["subject": .text("fresh15 revised")],
                operationID: "fresh15-revise"))
        XCTAssertTrue(revised.isIndexReady, revised.warnings.joined(separator: "\n"))
        XCTAssertFalse(StoreCheckpoint.isDirty(root: f.sourceRoot))
        f.source = nil
        XCTAssertThrowsError(
            try ItemStore(
                root: f.sourceRoot, accounts: f.sourceAccounts,
                revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil,
                canonicalFormatSupport: legacy14)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "incompatibleCanonicalReader")
        }
        f.source = try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.sourceAccounts)
        XCTAssertEqual(try f.source.get(result.revision.itemID), revised.revision)
        try f.capacity()
    }
    func testFreshPolicyHandoffDoesNotInventServiceOwnerAdmissionForBackgroundGenesis() throws {
        let f = try PeerEnrollmentApprovalTests.Fixture()
        let origin = try XCTUnwrap(f.source.replicaID)
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let head = try XCTUnwrap(index.authorityControlHead(originID: origin))
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: head.recordID))
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.request.sourceContext.storeID)
        let accepted = try XCTUnwrap(
            coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: head))
        XCTAssertEqual(accepted.receipt.context.validationPurpose, .backgroundSourceCut)
        XCTAssertEqual(accepted.receipt.context.requestPrincipal, "replica:" + origin)
        XCTAssertEqual(try coordinator.logicalControlHeader(head, index: index).actor, "replica:" + origin)
        index.close()
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: tractanda_uid()) {
                try f.source.requirePeerCredentialAdministrator()
            }
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        let before = try canonical(f.sourceRoot)
        try f.reopen(removeIndex: true)
        XCTAssertEqual(try canonical(f.sourceRoot), before)
        XCTAssertThrowsError(
            try f.source.withAccess(forUID: tractanda_uid()) {
                try f.source.requirePeerCredentialAdministrator()
            }
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "forbidden")
        }
        try f.source.withAccess(forUID: f.uid) { try f.source.requirePeerCredentialAdministrator() }
        try f.capacity()
    }

    func testBackgroundPurposeCannotReclassifyAnAuthoredAcceptedRootOnColdReplay() throws {
        let f = try AtomicAuthorityStoreFixture()
        let authored = try f.source.commit(
            .init(
                classID: "Item", changes: ["subject": .text("ordinary authored")],
                operationID: "purpose-role-guard"))
        XCTAssertTrue(authored.isIndexReady, authored.warnings.joined(separator: "\n"))
        let origin = try XCTUnwrap(f.source.replicaID)
        let index = try ItemIndex(
            path: f.sourceRoot.appendingPathComponent("index/items.sqlite").path, create: false)
        let head = try XCTUnwrap(
            index.localAuthorityAcceptanceControl(revisionID: authored.revision.revisionID))
        let raw = try XCTUnwrap(index.retainedAuthorityObject(id: head.recordID))
        let coordinator = PeerIntakeCoordinator(
            root: f.sourceRoot, ownerUID: tractanda_uid(), storeID: f.storeID)
        let original = try XCTUnwrap(
            coordinator.journal.atomicAcceptance(packageID: raw.packageID, root: head)
        ).receipt
        XCTAssertEqual(original.context.validationPurpose, .authenticatedRequest)
        let changed = try AtomicAuthorityAcceptance.Receipt(
            storeID: original.storeID, receiverReplicaID: original.receiverReplicaID, root: original.root,
            packageID: original.packageID, manifestSHA256: original.manifestSHA256,
            validationContextSHA256: original.validationContextSHA256,
            context: .init(
                configuration: original.context.configuration, authorities: original.context.authorities,
                authorityCount: original.context.authorityCount, requestPrincipal: "replica:" + origin,
                validationPurpose: .backgroundSourceCut))
        index.close()
        f.source = nil
        let receipt = f.sourceRoot.appendingPathComponent(
            "authority/intake/\(raw.packageID)/atomic-accepted/\(head.recordID).json")
        // Deliberate isolated canonical tamper: no production record or permission is changed.
        XCTAssertEqual(chmod(receipt.path, 0o600), 0)
        try JSON.encode(changed).write(to: receipt)
        XCTAssertEqual(chmod(receipt.path, 0o400), 0)
        for name in ["items.sqlite", "items.sqlite-wal", "items.sqlite-shm", "items.sqlite-journal"] {
            let file = f.sourceRoot.appendingPathComponent("index").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        XCTAssertThrowsError(try AtomicAuthorityStoreFixture.open(f.sourceRoot, accounts: f.sourceAccounts)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidAtomicAuthority")
        }
        try f.capacity()
    }

    func testDefault15BootstraplessAuthorityCannotPublishLegacyOrAcceptOrdinaryPeerIntake() throws {
        let f = try AtomicAuthorityStoreFixture()
        let root = f.directory.appendingPathComponent("bootstrapless")
        var store: ItemStore? = try ItemStore(
            root: root, accounts: f.sourceAccounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true, firstSourceOperation: nil)
        defer { store = nil }
        let context = try PeerPackage.Context(
            peerID: "unadmitted",
            storeID: CanonicalReaderRequirement.storeIdentity(root: root, ownerUID: tractanda_uid()),
            configurationDigest: String(repeating: "a", count: 64),
            permittedOrigins: [UUID.makeVersion1().uuidString.lowercased()])
        try store!.configurePeerIntake(peers: [context])
        let before = try canonical(root)
        XCTAssertThrowsError(
            try store!.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("must not become legacy")],
                    operationID: "no-legacy-fallback"))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "authorityBootstrapRequired")
        }
        XCTAssertThrowsError(
            try store!.beginPeerIntake(context: context, manifestBytes: Data("unparsed".utf8))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "authorityBootstrapRequired")
        }
        XCTAssertTrue(try store!.exportCatalogueForVerification().isEmpty)
        XCTAssertFalse(StoreCheckpoint.isDirty(root: root))
        XCTAssertEqual(try canonical(root), before)
        try f.capacity()
    }

}
