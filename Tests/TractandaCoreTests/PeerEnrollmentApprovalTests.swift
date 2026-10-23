import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class PeerEnrollmentApprovalTests: XCTestCase {
    final class Accounts: AccountDirectory, @unchecked Sendable {
        let human: UInt32 = 51001
        let contributor: UInt32 = 51003
        var contributorHasWriterGroup = true
        var administrator = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [71002])
            }
            if uid == contributor {
                return .init(
                    uid: uid, name: "contributor", primaryGroupName: "writers",
                    groupIDs: contributorHasWriterGroup ? [71003] : [])
            }
            if uid == human {
                return .init(
                    uid: uid, name: "human", primaryGroupName: "staff", groupIDs: administrator ? [71001] : []
                )
            }
            throw TractandaError("unresolvedPrincipal", "Unknown enrollment test user")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "daemon" { return try user(forUID: tractanda_uid()) }
            if name == "human" { return try user(forUID: human) }
            if name == "contributor" { return try user(forUID: contributor) }
            throw TractandaError("unresolvedPrincipal", "Unknown enrollment test user")
        }
        func groupID(named name: String) throws -> UInt32 {
            if ["staff", "admin", "sudo"].contains(name) { return 71001 }
            if name == "service" { return 71002 }
            if name == "writers" { return 71003 }
            throw TractandaError("unresolvedPrincipal", "Unknown enrollment test group")
        }
    }
    final class Fixture {
        let root: URL
        let sourceRoot: URL
        let targetRoot: URL
        let accounts = Accounts()
        var source: ItemStore!
        let request: PeerEnrollmentApproval.Request
        var uid: UInt32 { accounts.human }
        static func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
        static var policy: ItemValue {
            .object([
                "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
                "administration": .text("system"), "administratorGroup": .text("staff"),
            ])
        }
        init(capturedPolicySource: Bool = false, initialPolicy: ItemValue? = nil) throws {
            try AttachmentFixtureCapacity.requireFree()
            // One initialized tiny source and an empty prepared target estimate below16MiB.
            guard AttachmentFixtureCapacity.fixtureCapBytes >= 16 * 1024 * 1024 else {
                throw TractandaError("resourceLimit", "Enrollment fixture estimate exceeds its cap")
            }
            root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
                "tractanda-enrollment-approval-" + (try Self.id()))
            sourceRoot = root.appendingPathComponent("source")
            targetRoot = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(
                at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            if capturedPolicySource {
                // Established-peer fixture: capture its real existing policy through the accepted
                // development conversion transaction. Never forge imported policy eligibility.
                source = try ItemStore(root: sourceRoot, accounts: accounts, revisionProjectionEnabled: true)
                _ = try source.configureAccess(initialPolicy ?? Self.policy, operationID: Self.id())
                var limits = InitialAuthorityBootstrap.Limits()
                limits.maximumRecords = 16
                limits.maximumBytes = 1024 * 1024
                limits.maximumWork = 128
                let conversion = try source.prepareInitialAuthorityConversion(
                    operationID: Self.id(),
                    actorUID: accounts.human, limits: limits)
                source = nil  // Release the lifetime writer before the exact authority-aware reopen.
                source = try ItemStore(
                    root: sourceRoot, accounts: accounts, revisionProjectionEnabled: true,
                    authorityIntakeEnabled: true, firstSourceOperation: conversion)
                try source.finishInitialAuthority(conversion)
            } else {
                source = try ItemStore.initializeFresh(
                    root: sourceRoot, accounts: accounts,
                    initialAccessConfiguration: initialPolicy ?? Self.policy)
            }
            let storeID = try CanonicalReaderRequirement.storeIdentity(
                root: sourceRoot, ownerUID: tractanda_uid())
            let sourceID = try XCTUnwrap(
                ReplicaIdentity.load(root: sourceRoot, storeID: storeID, ownerUID: tractanda_uid())
            ).replicaID
            let preparation = try PeerEnrollment.prepareTarget(
                root: targetRoot, commonStoreID: storeID, sourceReplicaID: sourceID)
            let sourceContext = try PeerPackage.Context(
                peerID: "target", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("source-generation".utf8)),
                permittedOrigins: [preparation.targetReplicaID])
            let targetContext = try PeerPackage.Context(
                peerID: "source", storeID: storeID,
                configurationDigest: AuthorityRecordCodec.sha256(Data("target-generation".utf8)),
                permittedOrigins: [sourceID])
            let pairing = try Self.id()
            request = try .init(
                operationID: Self.id(), preparationBytes: JSON.encode(preparation),
                sourceContext: sourceContext, targetContext: targetContext,
                sourceCredential: .init(
                    binding: .init(
                        peerID: sourceContext.peerID, storeID: storeID,
                        localReplicaID: sourceID, remoteReplicaID: preparation.targetReplicaID,
                        pairingID: pairing,
                        localIsInitiator: true, configurationDigest: sourceContext.configurationDigest),
                    secret: Array(0..<32)),
                targetCredential: .init(
                    binding: .init(
                        peerID: targetContext.peerID, storeID: storeID,
                        localReplicaID: preparation.targetReplicaID, remoteReplicaID: sourceID,
                        pairingID: pairing,
                        localIsInitiator: false, configurationDigest: targetContext.configurationDigest),
                    secret: Array(0..<32)))
            try capacity()
        }
        deinit {
            source = nil
            try? FileManager.default.removeItem(at: root)
        }
        func capacity() throws {
            try AttachmentFixtureCapacity.requireFree(at: root)
            var bytes: UInt64 = 0
            let scan = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            while let url = scan.nextObject() as? URL {
                let metadata = try FileMetadata.read(at: url)
                if metadata.type == .regular {
                    guard
                        metadata.size <= AttachmentFixtureCapacity.fixtureCapBytes
                            - min(bytes, AttachmentFixtureCapacity.fixtureCapBytes)
                    else {
                        throw TractandaError("resourceLimit", "Enrollment fixture cap exceeded")
                    }
                    bytes += metadata.size
                }
            }
        }
        func begin() throws -> PeerEnrollmentApproval.Handle {
            try source.beginPeerEnrollment(request, forUID: uid)
        }
        func ready(_ handle: PeerEnrollmentApproval.Handle) throws -> PeerPackage.Manifest {
            for _ in 0..<1024 {
                try capacity()
                let status: PeerEnrollmentApproval.Status
                do {
                    status = try source.stepPeerEnrollment(
                        handle, forUID: uid,
                        window: .init(maximumUnits: 4, maximumEdges: 8))
                } catch let error as TractandaError where error.code == "enrollmentBaselineIncomplete" {
                    throw try baselineDiagnostic(handle, error: error)
                }
                if let manifest = status.manifest { return manifest }
            }
            throw TractandaError("testTimeout", "Tiny enrollment baseline did not close")
        }
        // Bounded fixture-only diagnostics: identities and reference field names, never content/keys.
        private func baselineDiagnostic(_ handle: PeerEnrollmentApproval.Handle, error: TractandaError) throws
            -> TractandaError
        {
            let first = try XCTUnwrap(InitialAuthorityBootstrap.load(root: sourceRoot))
            let initial = [
                "root": [first.rootID], "index": [first.indexID], "pages": first.pages.map(\.recordID),
            ]
            let text = String(describing: error)
            let missing = text.components(separatedBy: " (").last?.components(separatedBy: ")").first ?? ""
            var references: [[String: String]] = []
            var visited = 0
            if let files = FileManager.default.enumerator(
                at: sourceRoot.appendingPathComponent("authority/records"), includingPropertiesForKeys: nil)
            {
                while let file = files.nextObject() as? URL {
                    visited += 1
                    guard visited <= 256 else {
                        throw TractandaError("resourceLimit", "Tiny diagnostic traversal cap")
                    }
                    guard file.pathExtension == "authority" else { continue }
                    let metadata = try FileMetadata.read(at: file)
                    guard metadata.size <= UInt64(AuthorityRecord.maximumBytes) else { continue }
                    let record = try AuthorityRecordCodec.decode(Data(contentsOf: file)).record
                    var fields = record.parentAuthorityIDs.contains(missing) ? ["parentAuthorityIDs"] : []
                    for (field, value) in record.payload {
                        if try JSON.encode(value).range(of: Data(missing.utf8)) != nil {
                            fields.append(field)
                        }
                    }
                    if !fields.isEmpty {
                        references.append([
                            "recordID": record.recordID, "kind": record.kind.rawValue,
                            "fields": fields.sorted().joined(separator: ","),
                        ])
                    }
                }
            }
            let summary = ItemValue.object([
                "initial": .object(initial.mapValues { .list($0.map(ItemValue.text)) }),
                "references": .list(references.map { .object($0.mapValues(ItemValue.text)) }),
            ])
            return TractandaError(
                error.code,
                text + " fixture identities/reference fields: "
                    + String(decoding: try JSON.encode(summary), as: UTF8.self))
        }
        func commit(_ subject: String) throws -> Revision {
            try source.withAccess(forUID: uid) {
                try source.commit(
                    .init(classID: "Item", changes: ["subject": .text(subject)], operationID: subject)
                ).revision
            }
        }
        func reopen(removeIndex: Bool = false) throws {
            source = nil
            if removeIndex {
                try FileManager.default.removeItem(at: sourceRoot.appendingPathComponent("index"))
            }
            source = try ItemStore.openInitialized(root: sourceRoot, accounts: accounts)
            try capacity()
        }
        func keyPath() throws -> URL {
            try PeerCredentialStore.path(
                peerID: request.sourceContext.peerID,
                configurationDigest: request.sourceContext.configurationDigest
            ).reduce(sourceRoot) { $0.appendingPathComponent($1) }
        }
        func objects(_ handle: PeerEnrollmentApproval.Handle, manifest: PeerPackage.Manifest) throws
            -> [PeerPackage.Object]
        {
            var pending = [manifest.root]
            var seen: Set<String> = []
            var result: [PeerPackage.Object] = []
            while let object = pending.popLast() {
                if !seen.insert(object.id).inserted { continue }
                try capacity()
                let bytes = try source.readPeerEnrollment(handle, object: object, offset: 0, forUID: uid)
                    .bytes
                XCTAssertEqual(bytes.count, object.length)
                result.append(object)
                if object.kind == .index {
                    let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                    pending.append(contentsOf: page.objects + page.children)
                }
            }
            return result
        }
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected) }
    }
    func testPrivateStagingNeverConfiguresOrAuthenticatesUnapprovedPeer() throws {
        let f = try Fixture()
        let handle = try f.begin()
        let configuration = try AuthorityStore.configuration(
            root: f.sourceRoot, files: InitialAuthorityBootstrap.files(f.sourceRoot))
        XCTAssertEqual(configuration?.peers, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try f.keyPath().path))
        code("untrustedPeer") { _ = try f.source.loadPeerCredential(peerID: f.request.sourceContext.peerID) }
        code("untrustedPeer") {
            _ = try f.source.withPeerExchange(binding: f.request.sourceCredential.binding, progress: {}) {
                _, _ in true
            }
        }
        let manifest = try f.ready(handle)
        code("enrollmentReviewRequired") {
            _ = try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid)
        }
        XCTAssertEqual(
            try AuthorityStore.configuration(
                root: f.sourceRoot, files: InitialAuthorityBootstrap.files(f.sourceRoot))?.peers, [])
        XCTAssertThrowsError(try ItemStore.openInitialized(root: f.targetRoot, accounts: f.accounts))
    }
    func testExactRetryPreservesIdentitiesAndRejectsDifferentSecretOrPreparation() throws {
        let f = try Fixture()
        let first = try f.begin()
        let journal = f.sourceRoot.appendingPathComponent(
            PeerEnrollmentApproval.directory + "/" + first.operationID + "/request.json")
        let original = try Data(contentsOf: journal)
        let key = try Data(contentsOf: f.keyPath())
        XCTAssertEqual(try f.begin().operationID, first.operationID)
        XCTAssertEqual(try Data(contentsOf: journal), original)
        let changed = try PeerEnrollmentApproval.Request(
            operationID: first.operationID, preparationBytes: f.request.preparationBytes,
            sourceContext: f.request.sourceContext, targetContext: f.request.targetContext,
            sourceCredential: .init(
                binding: f.request.sourceCredential.binding, secret: Array(repeating: 9, count: 32)),
            targetCredential: .init(
                binding: f.request.targetCredential.binding, secret: Array(repeating: 9, count: 32)))
        code("enrollmentReviewRequired") { _ = try f.source.beginPeerEnrollment(changed, forUID: f.uid) }
        XCTAssertEqual(try Data(contentsOf: f.keyPath()), key)
        let preparation = try PeerEnrollmentApproval.preparation(f.request.preparationBytes)
        let wrong = PeerEnrollment.Preparation(
            formatVersion: 1, commonStoreID: preparation.commonStoreID,
            sourceReplicaID: preparation.sourceReplicaID, targetReplicaID: try Fixture.id(),
            operationID: preparation.operationID)
        let wrongRequest = try PeerEnrollmentApproval.Request(
            operationID: first.operationID, preparationBytes: JSON.encode(wrong),
            sourceContext: f.request.sourceContext, targetContext: f.request.targetContext,
            sourceCredential: f.request.sourceCredential, targetCredential: f.request.targetCredential)
        code("enrollmentReviewRequired") { _ = try f.source.beginPeerEnrollment(wrongRequest, forUID: f.uid) }
    }
    func testFiniteBaselineExcludesConcurrentLaterWritesAndRetainsPermanentBootstrap() throws {
        let f = try Fixture()
        let before = try f.commit("before")
        let handle = try f.begin()
        _ = try f.source.stepPeerEnrollment(handle, forUID: f.uid)
        let later = try f.commit("later")
        let manifest = try f.ready(handle)
        let accepted = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        XCTAssertEqual(accepted.phase, .accepted)
        let objects = try f.objects(handle, manifest: manifest)
        XCTAssertTrue(objects.contains { $0.id == before.revisionID })
        XCTAssertFalse(objects.contains { $0.id == later.revisionID })
        let pin = try XCTUnwrap(
            AuthorityStore.configuration(
                root: f.sourceRoot, files: InitialAuthorityBootstrap.files(f.sourceRoot))?.bootstrap)
        XCTAssertTrue(objects.contains { $0.id == pin.recordID })
        let approval = try AuthorityRecordCodec.decode(
            f.source.peerEnrollmentApprovalBytes(handle, forUID: f.uid))
        XCTAssertEqual(approval.record.kind, .enrollmentApproval)
        XCTAssertEqual(
            approval.record.payload["manifestDigest"],
            .text(AuthorityRecordCodec.sha256(try JSON.encode(manifest))))
        XCTAssertEqual(
            try CanonicalReaderRequirement.load(root: f.sourceRoot, ownerUID: tractanda_uid())?
                .minimumReaderLevel, 13)
    }
    func testRevokedAdministratorBeforeSealNeverAcceptsButAcceptedBookkeepingSurvivesDemotion() throws {
        let f = try Fixture()
        let handle = try f.begin()
        _ = try f.ready(handle)
        f.source.peerEnrollmentBoundaryForTesting = { phase in
            if phase == "beforeAcceptance" { f.accounts.administrator = false }
        }
        code("forbidden") { _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid) }
        code("enrollmentReviewRequired") { _ = try f.source.finishAcceptedPeerEnrollment(handle) }
        f.accounts.administrator = true
        f.source.peerEnrollmentBoundaryForTesting = { phase in
            if phase == "accepted" { throw TractandaError("injectedCrash", "After exact durable approval") }
        }
        code("injectedCrash") { _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid) }
        f.source.peerEnrollmentBoundaryForTesting = nil
        f.accounts.administrator = false
        XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).phase, .accepted)
        XCTAssertEqual(try f.source.acceptPeerEnrollment(handle, forUID: f.uid).phase, .accepted)
        try f.reopen(removeIndex: true)
        XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).phase, .accepted)
        code("forbidden") { _ = try f.source.peerEnrollmentApprovalBytes(handle, forUID: f.uid) }
    }
    func testAcceptedSealedBaselineSurvivesCanonicalOnlyIndexRebuild() throws {
        let f = try Fixture()
        let handle = try f.begin()
        let manifest = try f.ready(handle)
        let approval = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        let original = try f.source.readPeerEnrollment(
            handle, object: manifest.root, offset: 0, forUID: f.uid
        ).bytes
        let privateKey = try Data(contentsOf: f.keyPath())
        try f.reopen(removeIndex: true)
        XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).approval, approval.approval)
        XCTAssertEqual(
            try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid).bytes,
            original)
        XCTAssertEqual(try Data(contentsOf: f.keyPath()), privateKey)
        XCTAssertEqual(
            try AuthorityStore.configuration(
                root: f.sourceRoot, files: InitialAuthorityBootstrap.files(f.sourceRoot))?.peers, [])
        let first = try XCTUnwrap(InitialAuthorityBootstrap.load(root: f.sourceRoot))
        let bootstrap = try XCTUnwrap(f.objects(handle, manifest: manifest).first { $0.id == first.rootID })
        let baseline = try f.source.readPeerEnrollment(handle, object: bootstrap, offset: 0, forUID: f.uid)
            .bytes
        let seal = f.sourceRoot.appendingPathComponent("authority/intake/" + first.packageID + "/sealed.json")
        let originalSeal = try Data(contentsOf: seal)
        let sealedPublication = try JSON.decode(PeerIntakeJournal.Publication.self, originalSeal)
        let sourceID = f.request.sourceCredential.binding.localReplicaID
        XCTAssertEqual(
            sealedPublication.context.configurationDigest,
            AuthorityRecordCodec.sha256(Data(("local:" + sourceID).utf8)))
        XCTAssertEqual(sealedPublication.contextToken, try InitialAuthorityBootstrap.digest(first))
        // An accepted approval does not replace missing or tampered canonical receipt proof.
        try FileManager.default.removeItem(at: seal)
        XCTAssertThrowsError(
            try f.source.readPeerEnrollment(handle, object: bootstrap, offset: 0, forUID: f.uid))
        try originalSeal.write(to: seal)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: seal.path)
        XCTAssertEqual(
            try f.source.readPeerEnrollment(handle, object: bootstrap, offset: 0, forUID: f.uid).bytes,
            baseline)
        let sealBytes = try Data(contentsOf: seal)
        let oldSeal = try JSON.decode(PeerIntakeJournal.Publication.self, sealBytes)
        let changedSeal = PeerIntakeJournal.Publication(
            packageID: oldSeal.packageID, manifestDigest: oldSeal.manifestDigest,
            context: oldSeal.context, contextToken: "forged-initial-token",
            arrivalMinute: oldSeal.arrivalMinute)
        try FileManager.default.removeItem(at: seal)
        try JSON.encode(changedSeal).write(to: seal)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: seal.path)
        XCTAssertThrowsError(
            try f.source.readPeerEnrollment(handle, object: bootstrap, offset: 0, forUID: f.uid))
        try FileManager.default.removeItem(at: seal)
        try sealBytes.write(to: seal)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: seal.path)
        XCTAssertEqual(
            try f.source.readPeerEnrollment(handle, object: bootstrap, offset: 0, forUID: f.uid).bytes,
            baseline)
    }
    func testUnfinishedEpochLossNeedsReviewAndDoesNotBlockOrdinaryService() throws {
        let f = try Fixture()
        let handle = try f.begin()
        _ = try f.source.stepPeerEnrollment(handle, forUID: f.uid)
        try f.reopen(removeIndex: true)
        code("peerExportChanged") { _ = try f.source.stepPeerEnrollment(handle, forUID: f.uid) }
        _ = try f.commit("unrelated-write")
        code("enrollmentReviewRequired") { _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid) }
        XCTAssertEqual(try f.begin().operationID, handle.operationID)
    }
    func testMissingOrChangedPrivateKeyCannotBeRecreatedByRetryOrRead() throws {
        let f = try Fixture()
        let handle = try f.begin()
        let manifest = try f.ready(handle)
        _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        let path = try f.keyPath()
        let original = try Data(contentsOf: path)
        var changed = original
        changed[changed.count - 1] ^= 1
        try FileManager.default.removeItem(at: path)
        try changed.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        code("enrollmentReviewRequired") { _ = try f.begin() }
        code("enrollmentReviewRequired") {
            _ = try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid)
        }
        try FileManager.default.removeItem(at: path)
        code("invalidPeerCredential") { _ = try f.begin() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testReplacingBothKeysWithSameNewSecretCannotChangePrivateOperationWitness() throws {
        let f = try Fixture()
        let handle = try f.begin()
        let remotePath = try PeerCredentialStore.path(
            peerID: f.request.targetContext.peerID,
            configurationDigest: f.request.targetContext.configurationDigest
        ).reduce(
            f.sourceRoot.appendingPathComponent(
                PeerEnrollmentApproval.directory + "/" + handle.operationID + "/remote")
        ) {
            $0.appendingPathComponent($1)
        }
        for path in [try f.keyPath(), remotePath] {
            var bytes = try Data(contentsOf: path)
            bytes.replaceSubrange((bytes.count - 32)..<bytes.count, with: repeatElement(UInt8(77), count: 32))
            try FileManager.default.removeItem(at: path)
            try bytes.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        }
        code("enrollmentReviewRequired") { _ = try f.source.stepPeerEnrollment(handle, forUID: f.uid) }
        code("enrollmentReviewRequired") { _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid) }
    }
    func testPrivateAcceptedMarkerCannotAuthorizeUnsealedApproval() throws {
        let f = try Fixture()
        let handle = try f.begin()
        let manifest = try f.ready(handle)
        let path = [PeerEnrollmentApproval.directory, handle.operationID, "accepted.json"]
        try InitialAuthorityBootstrap.files(f.sourceRoot).writeImmutable(
            Data("{}".utf8), path: path, maximumBytes: 4096)
        code("enrollmentReviewRequired") {
            _ = try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid)
        }
    }
    func testAcceptedApprovalCannotBypassCredentialRevocationOrTargetDisposal() throws {
        for dispose in [false, true] {
            let f = try Fixture()
            let handle = try f.begin()
            let manifest = try f.ready(handle)
            _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
            try f.source.withAccess(forUID: f.uid) {
                // Exercise the existing lifecycle boundary only in this isolated fixture.
                try f.source.configurePeerIntake(peers: [f.request.sourceContext])
                try f.source.removePeerIntake(
                    peerID: f.request.sourceContext.peerID,
                    retiredOriginIDs: dispose ? f.request.sourceContext.permittedOrigins : [],
                    operationID: Fixture.id())
            }
            XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).phase, .accepted)
            XCTAssertNotNil(
                try f.source.peerOriginMembership(f.request.sourceCredential.binding.remoteReplicaID),
                "Channel revocation and node disposal do not erase historical admission")
            code("enrollmentReviewRequired") {
                _ = try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid)
            }
            try f.reopen(removeIndex: true)
            XCTAssertEqual(try f.source.finishAcceptedPeerEnrollment(handle).phase, .accepted)
            XCTAssertNotNil(
                try f.source.peerOriginMembership(f.request.sourceCredential.binding.remoteReplicaID),
                "Channel revocation and node disposal do not erase historical admission")
            code("enrollmentReviewRequired") {
                _ = try f.source.readPeerEnrollment(handle, object: manifest.root, offset: 0, forUID: f.uid)
            }
        }
    }
    func testTamperedCanonicalApprovalSealCannotCompleteOrReplay() throws {
        let f = try Fixture()
        let handle = try f.begin()
        _ = try f.ready(handle)
        _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid)
        let journal = PeerEnrollmentApproval.Journal(
            files: InitialAuthorityBootstrap.files(f.sourceRoot), operationID: handle.operationID)
        let operation = try XCTUnwrap(journal.read(PeerEnrollmentApproval.Operation.self, "request.json"))
        let seal = f.sourceRoot.appendingPathComponent(
            "authority/intake/" + operation.publicationID + "/sealed.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: seal)) as! [String: Any]
        value["contextToken"] = "forged-bookkeeping"
        let bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.removeItem(at: seal)
        try bytes.write(to: seal)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: seal.path)
        code("invalidPeerPackage") { _ = try f.source.finishAcceptedPeerEnrollment(handle) }
        f.source = nil
        try FileManager.default.removeItem(at: f.sourceRoot.appendingPathComponent("index"))
        XCTAssertThrowsError(try ItemStore.openInitialized(root: f.sourceRoot, accounts: f.accounts))
    }
    func testOwnerBaselinePreservesImportedHeldHistoryWithoutPromotingIt() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let held = try f.edit(uid: f.sourceAccounts.bob)
        f.receiverAccounts.bobHasGroup = false
        let originals = try f.source.peerMetadataObjects(revisionID: held.revisionID)
        XCTAssertEqual(try f.send(f.packet(originals)).held, 1)
        let sourceID = try XCTUnwrap(
            ReplicaIdentity.load(root: f.receiverRoot, storeID: f.storeID, ownerUID: tractanda_uid())
        ).replicaID
        let target = f.directory.appendingPathComponent("enrollment-target")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let preparation = try PeerEnrollment.prepareTarget(
            root: target, commonStoreID: f.storeID, sourceReplicaID: sourceID)
        let local = try PeerPackage.Context(
            peerID: "new-target", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("new-local".utf8)),
            permittedOrigins: [preparation.targetReplicaID])
        let remote = try PeerPackage.Context(
            peerID: "new-source", storeID: f.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("new-remote".utf8)),
            permittedOrigins: [sourceID, f.origin].sorted())
        let pairing = try Fixture.id()
        let request = try PeerEnrollmentApproval.Request(
            operationID: Fixture.id(), preparationBytes: JSON.encode(preparation),
            sourceContext: local, targetContext: remote,
            sourceCredential: .init(
                binding: .init(
                    peerID: local.peerID, storeID: f.storeID, localReplicaID: sourceID,
                    remoteReplicaID: preparation.targetReplicaID, pairingID: pairing, localIsInitiator: true,
                    configurationDigest: local.configurationDigest), secret: Array(repeating: 23, count: 32)),
            targetCredential: .init(
                binding: .init(
                    peerID: remote.peerID, storeID: f.storeID,
                    localReplicaID: preparation.targetReplicaID, remoteReplicaID: sourceID,
                    pairingID: pairing,
                    localIsInitiator: false, configurationDigest: remote.configurationDigest),
                secret: Array(repeating: 23, count: 32)))
        let handle = try f.receiver.beginPeerEnrollment(request, forUID: tractanda_uid())
        var manifest: PeerPackage.Manifest?
        for _ in 0..<1024 {
            try f.capacity()
            manifest = try f.receiver.stepPeerEnrollment(handle, forUID: tractanda_uid()).manifest
            if manifest != nil { break }
        }
        _ = try XCTUnwrap(manifest)
        _ = try f.receiver.acceptPeerEnrollment(handle, forUID: tractanda_uid())
        var pending = [try XCTUnwrap(manifest).root]
        var seen: Set<String> = []
        while let object = pending.popLast() {
            if !seen.insert(object.id).inserted { continue }
            try f.capacity()
            let bytes = try f.receiver.readPeerEnrollment(
                handle, object: object, offset: 0, forUID: tractanda_uid()
            ).bytes
            if object.kind == .index {
                let page = try PeerPackage.decode(PeerPackage.Page.self, bytes)
                pending.append(contentsOf: page.objects + page.children)
            }
        }
        XCTAssertTrue(seen.contains(held.revisionID))
        XCTAssertTrue(seen.contains(f.base.revisionID))
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        var cursor: PeerInventory.Cursor?
        var dispositions: [AuthorityStore.Disposition?] = []
        let boundary = try f.receiver.capturePeerInventory(context: f.context)
        repeat {
            let page = try f.receiver.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor)
            dispositions += page.entries.filter { $0.descriptor.id == held.revisionID }.map(\.disposition)
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertFalse(dispositions.isEmpty)
        XCTAssertTrue(dispositions.allSatisfy { $0 == .held })
    }
    func testNoninitialModernWithoutAuthoredEvidenceCannotSealExport() throws {
        let f = try PeerIntakeStoreTests.Fixture()
        try f.bootstrap()
        let modern = try f.edit(subject: "not initial and no transferred A")
        let itemOnly = try f.source.peerMetadataObjects(revisionID: modern.revisionID).filter {
            $0.0.kind == .item
        }
        _ = try f.send(f.packet(itemOnly))
        let boundary = try f.receiver.capturePeerInventory(context: f.context)
        var cursor: PeerInventory.Cursor?
        var selected: PeerInventory.Entry?
        repeat {
            let page = try f.receiver.peerInventoryPage(
                context: f.context, boundary: boundary, cursor: cursor)
            selected = selected ?? page.entries.first { $0.descriptor.id == modern.revisionID }
            cursor = page.nextCursor
        } while cursor != nil
        let handle = try f.receiver.beginPeerExport(
            context: f.context, planID: Fixture.id(), packageID: Fixture.id(), boundary: boundary)
        _ = try f.receiver.selectPeerExport(
            context: f.context, handle: handle, entries: [XCTUnwrap(selected)], finish: true)
        for _ in 0..<128 {
            try f.capacity()
            let status = try f.receiver.stepPeerExport(context: f.context, handle: handle)
            XCTAssertNil(
                status.manifest, "Modern history outside the initial cut still needs exact authored evidence")
            if status.missing > 0 { return }
        }
        XCTFail("Untransferred modern authored evidence must be reported as missing")
    }
    func testPolicyChangeFencesUnacceptedOperation() throws {
        let f = try Fixture()
        let handle = try f.begin()
        _ = try f.ready(handle)
        _ = try f.source.withAccess(forUID: f.uid) {
            try f.source.configureAccess(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("human")]), "groups": .list([.text("staff")]),
                    "administration": .text("system"), "administratorGroup": .text("staff"),
                ]), operationID: "changed-policy")
        }
        code("enrollmentReviewRequired") { _ = try f.source.acceptPeerEnrollment(handle, forUID: f.uid) }
        code("enrollmentReviewRequired") { _ = try f.source.stepPeerEnrollment(handle, forUID: f.uid) }
    }
}
