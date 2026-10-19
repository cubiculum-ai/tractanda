import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PeerIntakeResumeStoreTests: XCTestCase {
    typealias Fixture = PeerIntakeStoreTests.Fixture
    private func code(
        _ expected: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }
    private func assertBegin(
        _ bytes: Data, at path: URL, mode: UInt32 = 0o400,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let metadata = try FileMetadata.read(at: path)
        XCTAssertEqual(metadata.type, .regular, file: file, line: line)
        XCTAssertEqual(metadata.uid, tractanda_uid(), file: file, line: line)
        XCTAssertEqual(metadata.mode & 0o777, mode, file: file, line: line)
        XCTAssertTrue(try Data(contentsOf: path) == bytes, "Begin bytes differ", file: file, line: line)
    }
    private func restoreBegin(_ bytes: Data, at path: URL) throws {
        try bytes.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
    }
    private func stageRoot(
        _ packet: PeerIntakeStoreTests.Packet, fixture f: Fixture,
        context: PeerPackage.Context? = nil
    ) throws {
        let context = context ?? f.context!
        _ = try f.receiver.beginPeerIntake(context: context, manifestBytes: JSON.encode(packet.manifest))
        let root = try XCTUnwrap(packet.objects.first { $0.0.id == packet.manifest.root.id })
        _ = try f.receiver.appendPeerObject(
            context: context, packageID: packet.manifest.packageID, object: root.0, offset: 0, bytes: root.1)
    }
    func testKnownOriginalReuseKeepsHeldDispositionIndependentOfTransferAndApplication() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(uid: f.sourceAccounts.bob)
        let originals = try f.source.peerMetadataObjects(revisionID: next.revisionID)
        let original = try XCTUnwrap(originals.first { $0.0.id == next.revisionID })
        f.receiverAccounts.bobHasGroup = false
        let applied = try f.packet(originals)
        XCTAssertEqual(try f.send(applied).held, 1)
        let oldState = try f.receiver.inspectPeerIntake(
            context: f.context, packageID: applied.manifest.packageID)
        XCTAssertEqual(oldState.phase, .applied)
        XCTAssertFalse(oldState.recoveryRequired)

        let reuse = try f.packet([original])
        try stageRoot(reuse, fixture: f)
        let page = try f.receiver.resumePeerIntake(context: f.context, packageID: reuse.manifest.packageID)
        let item = try XCTUnwrap(page.objects.first { $0.descriptor.id == next.revisionID })
        XCTAssertEqual(page.state.phase, .staged)
        XCTAssertEqual(item.source, .knownOriginal)
        XCTAssertEqual(item.nextOffset, original.0.length)
        XCTAssertEqual(item.evaluation?.disposition, .held)
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.blockedOnIndex)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        XCTAssertFalse(try f.receiver.history(next.itemID).contains { $0.revisionID == next.revisionID })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.receiverRoot.appendingPathComponent(
                    "authority/intake/\(reuse.manifest.packageID)/objects/\(next.revisionID)"
                ).path))
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        let reopened = try f.receiver.resumePeerIntake(
            context: f.context, packageID: reuse.manifest.packageID)
        XCTAssertEqual(
            reopened.objects.first { $0.descriptor.id == next.revisionID }?.nextOffset, original.0.length)
        XCTAssertEqual(
            reopened.objects.first { $0.descriptor.id == next.revisionID }?.evaluation?.disposition, .held)
        try f.capacity()
    }
    func testFreshConfigurationAndImmutablePackageBindingPrecedeResumeInspection() throws {
        let f = try Fixture()
        try f.bootstrap()
        let original = try XCTUnwrap(
            f.source.peerMetadataObjects(revisionID: f.base.revisionID).first {
                $0.0.id == f.base.revisionID
            })
        let first = try f.packet([original])
        try stageRoot(first, fixture: f)
        let cursor = try XCTUnwrap(
            f.receiver.resumePeerIntake(
                context: f.context, packageID: first.manifest.packageID, limit: 1
            ).nextCursor)
        let old = f.context!
        let updated = try PeerPackage.Context(
            peerID: old.peerID, storeID: old.storeID,
            configurationDigest: AuthorityRecordCodec.sha256(Data("new current configuration".utf8)),
            permittedOrigins: old.permittedOrigins)
        try f.receiver.rotatePeerIntakeCredential(
            peerID: updated.peerID, replacement: updated, operationID: Fixture.id())
        code("peerConfigurationChanged") {
            _ = try f.receiver.resumePeerIntake(
                context: old, packageID: first.manifest.packageID, cursor: cursor)
        }
        code("peerConfigurationChanged") {
            _ = try f.receiver.inspectPeerIntake(context: updated, packageID: first.manifest.packageID)
        }
        let next = try f.packet([original])
        try stageRoot(next, fixture: f, context: updated)
        code("invalidPeerCursor") {
            _ = try f.receiver.resumePeerIntake(
                context: updated, packageID: next.manifest.packageID, cursor: cursor)
        }
        let page = try f.receiver.resumePeerIntake(context: updated, packageID: next.manifest.packageID)
        XCTAssertEqual(page.objects.first { $0.descriptor.id == original.0.id }?.source, .knownOriginal)
        let unknown = try PeerPackage.Context(
            peerID: "not-configured", storeID: old.storeID,
            configurationDigest: old.configurationDigest, permittedOrigins: old.permittedOrigins)
        code("untrustedPeer") {
            _ = try f.receiver.resumePeerIntake(context: unknown, packageID: next.manifest.packageID)
        }
        // Private journal tampering must not rebind a manifest to another folder or StoreID.
        let beginPath = f.receiverRoot.appendingPathComponent(
            "authority/intake/\(next.manifest.packageID)/begin.json")
        let originalBegin = try Data(contentsOf: beginPath)
        defer { try? restoreBegin(originalBegin, at: beginPath) }
        try assertBegin(originalBegin, at: beginPath)
        // Filesystem integrity must precede decoding even a valid Begin, while fresh peer
        // authorization must precede reading an unsafe private journal.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: beginPath.path)
        try assertBegin(originalBegin, at: beginPath, mode: 0o600)
        code("documentIntegrity") {
            _ = try f.receiver.inspectPeerIntake(context: updated, packageID: next.manifest.packageID)
        }
        code("documentIntegrity") {
            _ = try f.receiver.resumePeerIntake(context: updated, packageID: next.manifest.packageID)
        }
        for inspect in [true, false] {
            for (context, expected) in [(old, "peerConfigurationChanged"), (unknown, "untrustedPeer")] {
                code(expected) {
                    if inspect {
                        _ = try f.receiver.inspectPeerIntake(
                            context: context, packageID: next.manifest.packageID)
                    } else {
                        _ = try f.receiver.resumePeerIntake(
                            context: context, packageID: next.manifest.packageID)
                    }
                }
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: beginPath.path)
        for manifest in [
            PeerPackage.Manifest(packageID: try Fixture.id(), storeID: old.storeID, root: next.manifest.root),
            PeerPackage.Manifest(
                packageID: next.manifest.packageID, storeID: try Fixture.id(), root: next.manifest.root),
        ] {
            let tampered = try JSON.encode(PeerIntakeJournal.Begin(manifest: manifest, context: updated))
            try tampered.write(to: beginPath, options: .atomic)
            let atomicMode = try FileMetadata.read(at: beginPath).mode & 0o777
            // Bounded evidence of Foundation's actual replacement metadata; no paths or bytes.
            print("PeerIntakeResumeStoreTests atomic Begin mode=0\(String(atomicMode, radix: 8))")
            try assertBegin(tampered, at: beginPath, mode: atomicMode)
            if atomicMode != 0o400 {
                code("documentIntegrity") {
                    _ = try f.receiver.inspectPeerIntake(context: updated, packageID: next.manifest.packageID)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: beginPath.path)
            try assertBegin(tampered, at: beginPath, mode: 0o600)
            code("documentIntegrity") {
                _ = try f.receiver.inspectPeerIntake(context: updated, packageID: next.manifest.packageID)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: beginPath.path)
            try assertBegin(tampered, at: beginPath)
            code("invalidPeerPackage") {
                _ = try f.receiver.inspectPeerIntake(context: updated, packageID: next.manifest.packageID)
            }
            code("invalidPeerPackage") {
                _ = try f.receiver.resumePeerIntake(context: updated, packageID: next.manifest.packageID)
            }
        }
        try restoreBegin(originalBegin, at: beginPath)
        try assertBegin(originalBegin, at: beginPath)
        XCTAssertEqual(
            try f.receiver.inspectPeerIntake(context: updated, packageID: next.manifest.packageID).phase,
            .staged)
        XCTAssertEqual(
            try f.receiver.resumePeerIntake(context: updated, packageID: next.manifest.packageID).state.phase,
            .staged)
        try f.capacity()
    }
    func testSealedFailureRequiresRecoveryAndCancellationNeverInventsAppliedOrEligible() throws {
        let f = try Fixture()
        try f.bootstrap()
        let next = try f.edit(uid: f.sourceAccounts.bob)
        let packet = try f.packet(f.source.peerMetadataObjects(revisionID: next.revisionID))
        f.receiver.peerIntakeBoundaryForTesting = {
            if $0 == .sealed { throw TractandaError("injectedCrash", "seal") }
        }
        code("injectedCrash") { _ = try f.send(packet) }
        let state = try f.receiver.inspectPeerIntake(context: f.context, packageID: packet.manifest.packageID)
        XCTAssertEqual(state.phase, .sealed)
        XCTAssertTrue(state.recoveryRequired)
        let page = try f.receiver.resumePeerIntake(context: f.context, packageID: packet.manifest.packageID)
        XCTAssertTrue(page.state.recoveryRequired)
        XCTAssertTrue(page.objects.allSatisfy { $0.evaluation == nil })
        var checkpoints = 0
        code("cancelled") {
            _ = try f.receiver.resumePeerIntake(
                context: f.context, packageID: packet.manifest.packageID,
                progress: {
                    checkpoints += 1
                    if checkpoints > 2 { throw TractandaError("cancelled", "native checkpoint") }
                })
        }
        XCTAssertGreaterThan(checkpoints, 2)
        f.receiverAccounts.bobHasGroup = false
        f.receiver = nil
        f.receiver = try Fixture.open(f.receiverRoot, f.receiverAccounts)
        let recovered = try f.receiver.resumePeerIntake(
            context: f.context, packageID: packet.manifest.packageID)
        XCTAssertEqual(recovered.state.phase, .applied)
        XCTAssertFalse(recovered.state.recoveryRequired)
        XCTAssertEqual(
            recovered.objects.first { $0.descriptor.id == next.revisionID }?.evaluation?.disposition, .held)
        XCTAssertEqual(try f.receiver.get(f.base.itemID).revisionID, f.base.revisionID)
        try f.capacity()
    }
}
