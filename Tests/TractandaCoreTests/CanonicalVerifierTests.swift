import XCTest

@testable import TractandaCore

final class CanonicalVerifierTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-verifier-\(Identifier.make())")
    }

    func testDetectsMissingReplacedAndMetadataChangedRecords() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let first = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "first"))
            .revision
        let second = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "second"))
            .revision
        let third = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "third"))
            .revision
        let (snapshot, _) = try store.verificationSnapshot()
        let firstURL = root.appendingPathComponent(
            try XCTUnwrap(snapshot.rows.first { $0.revisionID == first.revisionID }).path)
        try FileManager.default.removeItem(at: firstURL)
        let secondRow = try XCTUnwrap(snapshot.rows.first { $0.revisionID == second.revisionID })
        let secondURL = root.appendingPathComponent(secondRow.path)
        var bytes = try Data(contentsOf: secondURL)
        bytes[0] ^= 0xff
        try FileManager.default.removeItem(at: secondURL)
        try bytes.write(to: secondURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secondURL.path)
        let currentSnapshot = try store.verificationSnapshot().0
        let thirdURL = root.appendingPathComponent(
            try XCTUnwrap(
                currentSnapshot.rows.first {
                    $0.revisionID == third.revisionID
                }
            ).path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: thirdURL.path)
        let findings = await CanonicalVerifier.scan(snapshot)
        XCTAssertTrue(findings.contains { $0.kind == .missing && $0.revisionID == first.revisionID })
        XCTAssertTrue(findings.contains { $0.kind == .changed && $0.revisionID == second.revisionID })
        XCTAssertTrue(findings.contains { $0.kind == .unsafe && $0.revisionID == third.revisionID })
    }

    func testLegalStagingNameAndConcurrentCommitDoNotRaiseFalseAlarm() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        _ = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "before")).revision
        let (snapshot, generation) = try store.verificationSnapshot()
        let parent = root.appendingPathComponent(try XCTUnwrap(snapshot.rows.first?.path))
            .deletingLastPathComponent()
        let staging = parent.appendingPathComponent("\(UUID().uuidString).tractanda.Abc123")
        XCTAssertTrue(CanonicalVerifier.isLegalStagingName(staging.lastPathComponent))
        try Data("staging".utf8).write(to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        let findings = await CanonicalVerifier.scan(snapshot)
        _ = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "after")).revision
        try store.applyVerification(findings, scannedGeneration: generation)
        XCTAssertEqual(store.canonicalVerificationStatus["state"] as? String, "clean")
    }

    func testConfirmedMissingRecordBlocksReadsUntilExplicitRebuild() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ItemStore(root: root)
        let item = try store.commit(CommitRequest(classID: "Item", changes: [:], operationID: "item"))
            .revision
        let (snapshot, generation) = try store.verificationSnapshot()
        let path = try XCTUnwrap(snapshot.rows.first?.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try store.applyVerification(
            [
                .init(
                    kind: .missing, path: path, revisionID: item.revisionID,
                    detail: "missing")
            ], scannedGeneration: generation)
        XCTAssertEqual(store.canonicalVerificationStatus["state"] as? String, "inconsistent")
        XCTAssertThrowsError(try store.get(item.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "recoveryRequired")
        }
        let service = ItemService(store: store)
        let request: [String: Any] = [
            "using": [ItemService.capability, "urn:ietf:params:jmap:core"],
            "methodCalls": [
                [
                    "TractandaItem/commit",
                    [
                        "classID": "Item", "changes": ["subject": "blocked"], "operationID": "blocked-write",
                    ], "write",
                ]
            ],
        ]
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: service.handle(
                    try JSONSerialization.data(withJSONObject: request), peerUID: store.ownerUID))
                as? [String: Any])
        let calls = try XCTUnwrap(response["methodResponses"] as? [[Any]])
        let failure = try XCTUnwrap(calls.first?[1] as? [String: Any])
        XCTAssertEqual(failure["type"] as? String, "recoveryRequired")
        try store.rebuildIndex()
        XCTAssertThrowsError(try store.get(item.itemID)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "notFound")
        }
    }

    func testCoordinatorVerificationDrainsOnCleanShutdown() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = try await ServiceCoordinator(opening: root)
        await coordinator.startCanonicalVerification(every: .seconds(3600))
        await coordinator.close()
        let reopened = try ItemStore(root: root)
        _ = reopened
    }

    func testDeviceRenumberDoesNotInvalidateCanonicalSnapshot() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ItemStore? = try ItemStore(root: root)
        let first = try XCTUnwrap(store).commit(
            CommitRequest(
                classID: "Item", changes: [:], operationID: "device-first")
        ).revision
        _ = try XCTUnwrap(store).commit(
            CommitRequest(
                action: .revise, itemID: first.itemID, expectedRevisionID: first.revisionID,
                changes: ["subject": .text("second")], operationID: "device-second"))
        let snapshot = try XCTUnwrap(store).verificationSnapshot().0
        let findings = await CanonicalVerifier.scan(snapshot) { url in
            let value = try FileMetadata.read(at: url)
            return FileMetadata(
                mode: value.mode, uid: value.uid, gid: value.gid, size: value.size,
                inode: value.inode, device: value.device &+ 1,
                modificationSeconds: value.modificationSeconds,
                modificationNanoseconds: value.modificationNanoseconds)
        }
        XCTAssertTrue(findings.isEmpty)
        store = nil
        store = try ItemStore(root: root)
        XCTAssertEqual(store?.startupRecovery["mode"], "checkpoint")
    }
}
