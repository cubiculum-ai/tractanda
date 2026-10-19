import CTractandaPlatform
import Foundation
import XCTest
@testable import TractandaCore

final class PeerEnrollmentActivationTests: XCTestCase {
    typealias Source = PeerEnrollmentApprovalTests.Fixture
    final class Fixture {
        let source: Source
        let handle: PeerEnrollmentApproval.Handle
        let revision: Revision
        let material: PeerEnrollmentActivation.Material
        let pin: PeerEnrollmentActivation.Pin
        var session: PeerEnrollmentActivation.Session?
        var target: ItemStore?
        init(withAttachment: Bool = false) throws {
            source = try Source() // Real fresh profilev2, not a converted/importer-special fixture.
            let base = try source.commit("actual prepared target baseline")
            if withAttachment {
                let fixture = source
                revision = try fixture.source.withAccess(forUID: fixture.uid) {
                    let data = Data("tiny approved attachment original".utf8)
                    let result = try fixture.source.beginAttachment(.init(itemID: base.itemID, expectedRevisionID: base.revisionID,
                        operationID: "attach-before-enrollment", filename: "tiny.txt", mediaType: "text/plain",
                        byteCount: Int64(data.count), sha256: AuthorityRecordCodec.sha256(data)))
                    let uploadID = try XCTUnwrap(result.uploadID)
                    _ = try fixture.source.appendAttachment(uploadID: uploadID, offset: 0, data: data)
                    return try fixture.source.finishAttachment(uploadID: uploadID).revision
                }
            } else { revision = base }
            handle = try source.begin()
            _ = try source.ready(handle)
            let accepted = try source.source.acceptPeerEnrollment(handle, forUID: source.uid)
            material = try source.source.peerEnrollmentActivationMaterial(handle, forUID: source.uid)
            let bootstrap = try AuthorityRecord.list(AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
            pin = try .init(sourceReplicaID: PeerEnrollmentApproval.preparation(material.preparationBytes).sourceReplicaID,
                bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)), approval: XCTUnwrap(accepted.approval))
            try source.capacity()
        }
        deinit { session?.close(); target = nil }
        func open(progress: ((String) throws -> Void)? = nil) throws {
            session = try PeerEnrollmentActivation.open(root: source.targetRoot, material: material,
                pin: pin, accounts: source.accounts, progress: progress)
        }
        func transfer(omitAttachments: Bool = false) throws {
            let session = try XCTUnwrap(session)
            var cursor: PeerPackage.ResumeCursor?, work = 0
            repeat {
                try source.capacity()
                let page = try session.resume(packageID: material.baseline.packageID, cursor: cursor, limit: 4)
                for object in page.objects where !object.verifiedComplete && !(omitAttachments && object.descriptor.kind == .attachment) {
                    var offset = object.nextOffset
                    while offset < object.descriptor.length {
                        work += 1
                        guard work <= 4096 else { throw TractandaError("resourceLimit", "Tiny provisioning transfer work cap") }
                        let chunk = try source.source.readPeerEnrollment(handle, object: object.descriptor,
                            offset: offset, forUID: source.uid)
                        _ = try session.append(packageID: material.baseline.packageID, object: object.descriptor,
                            offset: offset, bytes: chunk.bytes)
                        offset += chunk.bytes.count
                    }
                }
                // An incomplete index deliberately blocks its continuation until the exact page arrives.
                if !page.blockedOnIndex { cursor = page.nextCursor }
                if !page.blockedOnIndex && cursor == nil { break }
            } while work <= 4096
        }
        func finish() throws -> PeerEnrollmentActivation.Receipt { try XCTUnwrap(session).finish() }
        func closeSession() { session?.close(); session = nil }
        func reopen(cold: Bool = false) throws {
            closeSession(); target = nil
            if cold { try FileManager.default.removeItem(at: source.targetRoot.appendingPathComponent("index")) }
            target = try ItemStore.openInitialized(root: source.targetRoot, accounts: source.accounts)
        }
        func targetFiles() -> DocumentContentFiles { InitialAuthorityBootstrap.files(source.targetRoot) }
        func assertPending(file: StaticString = #filePath, line: UInt = #line) {
            // Initialized-root preflight must reject pending state even while its private owner holds the lock.
            XCTAssertThrowsError(try ItemStore.requireInitializedRoot(source.targetRoot), file: file, line: line)
        }
    }
    final class CompletionAccounts: AccountDirectory, @unchecked Sendable {
        let base: PeerEnrollmentApprovalTests.Accounts
        let otherUID: UInt32 = 51002
        var renamedAuthor = false
        init(_ base: PeerEnrollmentApprovalTests.Accounts) { self.base = base }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == otherUID { return .init(uid: uid, name: "other-admin", primaryGroupName: "staff", groupIDs: [71001]) }
            let account = try base.user(forUID: uid)
            if uid == base.human, renamedAuthor {
                return .init(uid: uid, name: "renamed-human", primaryGroupName: account.primaryGroupName, groupIDs: account.groupIDs)
            }
            return account
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "other-admin" { return try user(forUID: otherUID) }
            if name == "renamed-human" { return try user(forUID: base.human) }
            return try base.user(named: name)
        }
        func groupID(named name: String) throws -> UInt32 { try base.groupID(named: name) }
    }
    private func code(_ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    func testActualPreparedTargetActivatesRegistersReopensAndRebuilds() throws {
        let f = try Fixture()
        f.assertPending()
        try f.open(); try f.transfer()
        let receipt = try f.finish()
        XCTAssertEqual(receipt.approval, f.pin.approval)
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid)
        XCTAssertEqual(try f.source.source.loadPeerCredential(peerID: f.material.sourceContext.peerID).commitment,
            try f.source.request.sourceCredential.commitment)
        XCTAssertFalse(try CanonicalReaderRequirement.load(root: f.source.sourceRoot, ownerUID: tractanda_uid())!
            .capabilities.contains(PeerEnrollmentActivation.targetCapability))
        XCTAssertTrue(try CanonicalReaderRequirement.load(root: f.source.targetRoot, ownerUID: tractanda_uid())!
            .capabilities.contains(PeerEnrollmentActivation.targetCapability))
        // Only the operation's own registration transition is normalized for the already sealed finite export.
        _ = try f.source.source.readPeerEnrollment(f.handle, object: f.material.baseline.root, offset: 0, forUID: f.source.uid)
        XCTAssertEqual(try f.finish(), receipt)
        try f.reopen(cold: true)
        XCTAssertEqual(try f.target!.withAccess(forUID: f.source.uid) { try f.target!.get(f.revision.itemID) }, f.revision)
        XCTAssertEqual(try f.target!.loadPeerCredential(peerID: f.material.targetContext.peerID).commitment,
            try f.source.request.targetCredential.commitment)
        XCTAssertEqual(try ReplicaIdentity.load(root: f.source.targetRoot,
            storeID: f.material.targetContext.storeID, ownerUID: tractanda_uid())?.replicaID,
            try PeerEnrollmentApproval.preparation(f.material.preparationBytes).targetReplicaID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.targetRoot.appendingPathComponent(PeerEnrollment.intentName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.targetRoot.appendingPathComponent(InitialAuthorityBootstrap.receiptName).path))
        XCTAssertEqual(try CanonicalReaderRequirement.load(root: f.source.targetRoot, ownerUID: tractanda_uid())?.minimumReaderLevel, 14)
        try f.source.reopen(removeIndex: true)
        XCTAssertEqual(try f.source.source.loadPeerCredential(peerID: f.material.sourceContext.peerID).commitment,
            try f.source.request.sourceCredential.commitment)
    }
    func testCompletedCanonicalTargetCopiesToNewDirectoryWithExactIdentityKeysAndReceipt() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); f.closeSession()
        let original = f.source.targetRoot
        let restoredRoot = f.source.root.appendingPathComponent("restored-complete-target")
        let keyPath = try PeerCredentialStore.path(peerID: f.material.targetContext.peerID,
            configurationDigest: f.material.targetContext.configurationDigest)
        let preserved = [PeerEnrollment.intentName, ReplicaIdentity.name, ".tractanda-store-identity.json",
            PeerEnrollmentActivation.directory + "/request.json", PeerEnrollmentActivation.directory + "/activated.json",
            keyPath.joined(separator: "/")]
        let bytes = try preserved.map { try Data(contentsOf: original.appendingPathComponent($0)) }
        try FileManager.default.copyItem(at: original, to: restoredRoot)
        XCTAssertNotEqual(try FileMetadata.read(at: original).inode, try FileMetadata.read(at: restoredRoot).inode)
        try FileManager.default.removeItem(at: restoredRoot.appendingPathComponent("index"))
        var restored: ItemStore? = try ItemStore.openInitialized(root: restoredRoot, accounts: f.source.accounts)
        defer { restored = nil }
        XCTAssertEqual(try restored!.withAccess(forUID: f.source.uid) { try restored!.get(f.revision.itemID) }, f.revision)
        XCTAssertEqual(try restored!.loadPeerCredential(peerID: f.material.targetContext.peerID).privateBytesDigest,
            f.material.targetPrivateBytesDigest)
        for (path, data) in zip(preserved, bytes) {
            XCTAssertEqual(try Data(contentsOf: restoredRoot.appendingPathComponent(path)), data)
        }
        try f.source.capacity()
    }
    func testWarmCheckpointActivationValidationSkipsUserBaselineTraversalButExplicitRebuildReadsIt() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); try f.reopen()
        // Establish the ordinary final configuration's canonical checkpoint, then open it normally.
        try f.target!.rebuildIndex()
        try f.reopen()
        XCTAssertEqual(f.target!.startupRecovery["mode"], "checkpoint")
        // Scoped to the activation validator; bounded policy proof and Unit1 receipt replay
        // can legitimately hydrate other originals independently of this full traversal.
        XCTAssertEqual(f.target!.targetEnrollmentBaselineTraversalReadsForTesting.count, 0)
        XCTAssertNil(f.target!.targetEnrollmentBaselineTraversalReadsForTesting.lastOriginalID)
        try f.target!.rebuildIndex()
        XCTAssertGreaterThan(f.target!.targetEnrollmentBaselineTraversalReadsForTesting.count, 0)
        XCTAssertEqual(f.target!.targetEnrollmentBaselineTraversalReadsForTesting.lastOriginalID, f.revision.revisionID)
    }
    func testPendingAndInterruptedPinKeepOrdinaryOpeningClosed() throws {
        let f = try Fixture()
        try f.open(progress: { if $0 == "bootstrapPinned" { throw TractandaError("testInterruption", "pin boundary") } })
        f.assertPending()
        code("missingDependencies") { _ = try f.finish() }
        try f.transfer()
        code("testInterruption") { _ = try f.finish() }
        f.closeSession(); f.assertPending()
        // The real daemon lost administrator rights at pin; exact completion still proceeds.
        try f.open()
        _ = try f.finish()
        try f.reopen()
        code("forbidden") {
            _ = try f.target!.withAccess(forUID: tractanda_uid()) { try f.target!.get(f.revision.itemID) }
        }
        XCTAssertEqual(try f.target!.withAccess(forUID: f.source.uid) { try f.target!.get(f.revision.itemID) }, f.revision)
    }
    func testPreparedTargetCannotExposeUnattendedRuntimeCredentialsBeforeActivation() throws {
        let f = try Fixture()
        let record = try PeerEnrollmentActivation.makeRecord(f.material, pin: f.pin)
        let pending = try ItemStore(root: f.source.targetRoot, accounts: f.source.accounts,
            revisionProjectionEnabled: true, authorityIntakeEnabled: true,
            firstSourceOperation: nil,
            targetProvisioning: .init(record: record, credential: f.material.targetCredential))
        code("enrollmentActivationRequired") { _ = try pending.peerRuntimeMaterial() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.targetRoot.appendingPathComponent(
            PeerEnrollmentActivation.directory + "/activated.json").path))
        try f.source.capacity()
    }
    func testInterruptedConfigurationCommitIsExactRecoverableCompletion() throws {
        let f = try Fixture()
        try f.open(progress: { if $0 == "configurationCommitted" { throw TractandaError("testInterruption", "config boundary") } })
        try f.transfer()
        code("testInterruption") { _ = try f.finish() }
        f.closeSession(); f.assertPending()
        let before = try AuthorityStore.configurationSequence(root: f.source.targetRoot)
        try f.open(); _ = try f.finish()
        XCTAssertEqual(try AuthorityStore.configurationSequence(root: f.source.targetRoot), before)
        try f.reopen(cold: true)
    }
    func testIndependentApprovalPinAndSourceIdentitySubstitutionFailBeforeIdentity() throws {
        let f = try Fixture()
        let bad = PeerEnrollmentActivation.Pin(sourceReplicaID: try Source.id(), bootstrap: f.pin.bootstrap, approval: f.pin.approval)
        XCTAssertThrowsError(try PeerEnrollmentActivation.open(root: f.source.targetRoot, material: f.material, pin: bad, accounts: f.source.accounts))
        let wrongHash = try AuthorityBinding(recordID: f.pin.approval.recordID, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try PeerEnrollmentActivation.open(root: f.source.targetRoot, material: f.material,
            pin: .init(sourceReplicaID: f.pin.sourceReplicaID, bootstrap: f.pin.bootstrap, approval: wrongHash), accounts: f.source.accounts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.targetRoot.appendingPathComponent(ReplicaIdentity.name).path))
        f.assertPending()
    }
    func testTargetSecretChangedRetryAndMissingEstablishedSecretFailClosed() throws {
        let f = try Fixture(); try f.open(); f.closeSession()
        let changed = PeerEnrollmentActivation.Material(preparationBytes: f.material.preparationBytes, baseline: f.material.baseline,
            proof: f.material.proof, sourceContext: f.material.sourceContext, targetContext: f.material.targetContext,
            targetCredential: try .init(binding: f.material.targetCredential.binding, secret: Array(repeating: 9, count: 32)),
            targetPrivateBytesDigest: f.material.targetPrivateBytesDigest)
        XCTAssertThrowsError(try PeerEnrollmentActivation.open(root: f.source.targetRoot, material: changed, pin: f.pin, accounts: f.source.accounts))
        let path = try PeerCredentialStore.path(peerID: f.material.targetContext.peerID,
            configurationDigest: f.material.targetContext.configurationDigest).reduce(f.source.targetRoot) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try f.open())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        f.assertPending()
    }
    func testEstablishedTargetIdentityCannotBeRegeneratedOrSubstituted() throws {
        let f = try Fixture(); try f.open(); f.closeSession()
        let prep = try PeerEnrollmentApproval.preparation(f.material.preparationBytes)
        let path = f.source.targetRoot.appendingPathComponent(ReplicaIdentity.name)
        let changed = ReplicaIdentity.Record(formatVersion: 1, storeID: prep.commonStoreID, replicaID: try Source.id())
        try PrivateConfiguration.write(JSON.encode(changed), to: path)
        XCTAssertThrowsError(try f.open())
        XCTAssertEqual(try JSON.decode(ReplicaIdentity.Record.self, Data(contentsOf: path)), changed)
        f.assertPending()
    }
    func testSourceRegistrationRequiresOriginalFullPrivateBytes() throws {
        let f = try Fixture(), path = try f.source.keyPath()
        var bytes = try Data(contentsOf: path)
        bytes[bytes.count - 1] ^= 1 // Valid same public metadata, different PSK generation bytes.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try bytes.write(to: path)
        XCTAssertThrowsError(try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid))
        XCTAssertEqual(try AuthorityStore.configuration(root: f.source.sourceRoot,
            files: InitialAuthorityBootstrap.files(f.source.sourceRoot))?.peers, [])
    }
    func testWrongManifestAndUnlistedObjectCannotExpandFiniteIntake() throws {
        let f = try Fixture(); try f.open()
        let bytes = Data("unapproved".utf8)
        let object = PeerPackage.Object(kind: .authority, id: try Source.id(), length: bytes.count, sha256: AuthorityRecordCodec.sha256(bytes))
        XCTAssertThrowsError(try f.session!.append(packageID: try Source.id(), object: object, offset: 0, bytes: bytes))
        XCTAssertThrowsError(try f.session!.append(packageID: f.material.baseline.packageID, object: object, offset: 0, bytes: bytes))
        f.assertPending()
    }
    func testIncompleteAttachmentPayloadKeepsTargetClosedUntilExactOriginalArrives() throws {
        let f = try Fixture(withAttachment: true); try f.open()
        try f.transfer(omitAttachments: true)
        code("missingDependencies") { _ = try f.finish() }
        f.assertPending()
        try f.transfer(); _ = try f.finish(); try f.reopen(cold: true)
        // Cold receipt replay initially has an eligible parent before catalogue promotion.
        // Its attachment child must be deferred, then re-evaluated against accepted history.
        let parentID = try XCTUnwrap(f.revision.supersedes)
        let sourceParent = try f.source.source.withAccess(forUID: f.source.uid) {
            try f.source.source.get(f.revision.itemID, revisionID: parentID)
        }
        try f.target!.withAccess(forUID: f.source.uid) {
            let parent = try f.target!.get(f.revision.itemID, revisionID: parentID)
            let child = try f.target!.get(f.revision.itemID)
            XCTAssertEqual(parent.fields, sourceParent.fields)
            XCTAssertEqual(child.revisionID, f.revision.revisionID)
            XCTAssertEqual(child.supersedes, parent.revisionID)
            XCTAssertEqual(child.fields, f.revision.fields)
            XCTAssertEqual(try f.target!.listAttachments(itemID: f.revision.itemID).attachments.count, 1)
        }
    }
    func testMissingCanonicalApprovalSealFailsColdRecovery() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); f.closeSession()
        try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(
            "authority/intake/" + f.material.proof.manifest.packageID + "/sealed.json"))
        try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try f.reopen())
    }
    func testMissingPreparationDoesNotTurnActivatedTargetIntoOrdinaryUnsealedStore() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); f.closeSession()
        try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollment.intentName))
        XCTAssertThrowsError(try f.reopen())
    }
    func testLostPreparationAndRequestKeepWarmAndColdOpeningClosed() throws {
        for cold in [false, true] {
            let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); f.closeSession()
            try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollment.intentName))
            try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollmentActivation.directory + "/request.json"))
            if cold { try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent("index")) }
            code("enrollmentActivationRequired") { _ = try ItemStore.openInitialized(root: f.source.targetRoot, accounts: f.source.accounts) }
        }
    }
    func testLostWholeActivationDirectoryAndPreparationKeepWarmAndColdOpeningClosed() throws {
        for cold in [false, true] {
            let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); f.closeSession()
            try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollment.intentName))
            try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollmentActivation.directory))
            XCTAssertTrue(try CanonicalReaderRequirement.load(root: f.source.targetRoot, ownerUID: tractanda_uid())!
                .capabilities.contains(PeerEnrollmentActivation.targetCapability))
            if cold { try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent("index")) }
            code("enrollmentActivationRequired") { _ = try ItemStore.openInitialized(root: f.source.targetRoot, accounts: f.source.accounts) }
        }
    }
    func testUnsafeActivationArtifactPresenceCannotRemoveGate() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.source.targetRoot.appendingPathComponent(PeerEnrollment.intentName))
        let artifact = f.source.targetRoot.appendingPathComponent(PeerEnrollmentActivation.directory)
        try Data("malformed private activation directory".utf8).write(to: artifact)
        code("enrollmentActivationRequired") { try ItemStore.requireInitializedRoot(f.source.targetRoot) }
        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: f.source.sourceRoot)
        code("enrollmentActivationRequired") { try ItemStore.requireInitializedRoot(f.source.targetRoot) }
    }
    func testDistinctCurrentGlobalAdministratorCompletesOnlyTheAcceptedOperation() throws {
        let f = try Fixture(), accounts = CompletionAccounts(f.source.accounts)
        f.source.source = nil
        f.source.source = try ItemStore.openInitialized(root: f.source.sourceRoot, accounts: accounts)
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: accounts.otherUID)
        XCTAssertEqual(try f.source.source.loadPeerCredential(peerID: f.material.sourceContext.peerID).commitment,
            try f.source.request.sourceCredential.commitment)
        XCTAssertThrowsError(try f.source.source.registerAcceptedPeerEnrollment(.init(operationID: Source.id()), forUID: accounts.otherUID))
    }
    func testOriginalAuthorCompletionRejectsNumericUIDRemappedToAnotherName() throws {
        let f = try Fixture(), accounts = CompletionAccounts(f.source.accounts)
        f.source.accounts.administrator = false
        accounts.renamedAuthor = true
        f.source.source = nil
        f.source.source = try ItemStore.openInitialized(root: f.source.sourceRoot, accounts: accounts)
        code("enrollmentActivationRequired") { try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid) }
    }
    func testSourceRegistrationInterruptedAfterCommitRetainsExactBaseline() throws {
        let f = try Fixture()
        f.source.source.peerEnrollmentBoundaryForTesting = { if $0 == "registrationCommitted" { throw TractandaError("testInterruption", "source commit boundary") } }
        code("testInterruption") { try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid) }
        try f.source.reopen()
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid)
        _ = try f.source.source.readPeerEnrollment(f.handle, object: f.material.baseline.root, offset: 0, forUID: f.source.uid)
    }
    func testSourceRegistrationHistoricalCompletionSurvivesAuthorDemotionButDoesNotAuthorizeNewExport() throws {
        let f = try Fixture()
        f.source.accounts.administrator = false
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid)
        XCTAssertThrowsError(try f.source.source.peerEnrollmentActivationMaterial(f.handle, forUID: f.source.uid))
        XCTAssertThrowsError(try f.source.source.readPeerEnrollment(f.handle, object: f.material.baseline.root, offset: 0, forUID: f.source.uid))
    }
    func testUnrelatedConfigurationChangeStillFencesRegisteredBaselineAndCompletion() throws {
        let f = try Fixture()
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid)
        let extra = try PeerPackage.Context(peerID: "unrelated", storeID: f.material.sourceContext.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("unrelated context".utf8)),
            permittedOrigins: [Source.id()])
        try f.source.source.withAccess(forUID: f.source.uid) {
            try f.source.source.configurePeerIntake(peers: [f.material.sourceContext, extra])
        }
        XCTAssertThrowsError(try f.source.source.readPeerEnrollment(f.handle,
            object: f.material.baseline.root, offset: 0, forUID: f.source.uid))
        XCTAssertThrowsError(try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid))
    }
    func testTargetLaterDisposesSourceWithoutErasingHistoricalActivation() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); try f.reopen()
        try f.target!.withAccess(forUID: f.source.uid) {
            try f.target!.removePeerIntake(peerID: f.material.targetContext.peerID,
                retiredOriginIDs: [f.pin.sourceReplicaID], operationID: Source.id())
        }
        XCTAssertThrowsError(try f.target!.loadPeerCredential(peerID: f.material.targetContext.peerID))
        try f.reopen(cold: true)
        XCTAssertThrowsError(try f.target!.loadPeerCredential(peerID: f.material.targetContext.peerID))
        let targetID = try PeerEnrollmentApproval.preparation(f.material.preparationBytes).targetReplicaID
        XCTAssertEqual(try f.target!.peerOriginMembership(targetID), f.pin.approval)
    }
    func testSourceDisposedOrRevokedPairingCannotBeReadmittedByAcceptedOperation() throws {
        let f = try Fixture()
        try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid)
        let target = try PeerEnrollmentApproval.preparation(f.material.preparationBytes).targetReplicaID
        try f.source.source.withAccess(forUID: f.source.uid) {
            try f.source.source.removePeerIntake(peerID: f.material.sourceContext.peerID,
                retiredOriginIDs: [target], operationID: Source.id())
        }
        XCTAssertThrowsError(try f.source.source.registerAcceptedPeerEnrollment(f.handle, forUID: f.source.uid))
        XCTAssertEqual(try f.source.source.peerOriginMembership(target), f.pin.approval)
        try f.source.reopen(removeIndex: true)
        XCTAssertThrowsError(try f.source.source.loadPeerCredential(peerID: f.material.sourceContext.peerID))
    }
    func testTargetRotationPreservesActivationAndMembershipWithoutOriginalSecret() throws {
        let f = try Fixture(); try f.open(); try f.transfer(); _ = try f.finish(); try f.reopen()
        let old = f.material.targetContext
        let context = try PeerPackage.Context(peerID: old.peerID, storeID: old.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("new target generation".utf8)), permittedOrigins: old.permittedOrigins)
        let b = f.material.targetCredential.binding
        let key = try PeerCredential(binding: .init(peerID: context.peerID, storeID: b.storeID,
            localReplicaID: b.localReplicaID, remoteReplicaID: b.remoteReplicaID,
            pairingID: Source.id(), localIsInitiator: b.localIsInitiator, configurationDigest: context.configurationDigest),
            secret: Array(repeating: 7, count: 32))
        try f.target!.withAccess(forUID: f.source.uid) {
            try f.target!.registerPeerCredential(key, context: context,
                expectedContextToken: f.target!.peerIntakeContextToken(), operationID: Source.id())
        }
        let oldPath = try PeerCredentialStore.path(peerID: old.peerID, configurationDigest: old.configurationDigest)
            .reduce(f.source.targetRoot) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: oldPath)
        try f.reopen(cold: true)
        XCTAssertEqual(try f.target!.loadPeerCredential(peerID: old.peerID).commitment, try key.commitment)
        XCTAssertEqual(try f.target!.peerOriginMembership(b.localReplicaID), f.pin.approval)
    }
}
