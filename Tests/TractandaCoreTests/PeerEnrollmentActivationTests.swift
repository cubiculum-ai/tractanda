import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

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
        init(
            withAttachment: Bool = false, sourcePolicy: ItemValue? = nil,
            basePermissions: ItemValue? = nil
        ) throws {
            // Real fresh profilev2, not a converted/importer-special fixture.
            source = try Source(initialPolicy: sourcePolicy)
            let base: Revision
            if let basePermissions {
                let fixture = source
                base = try fixture.source.withAccess(forUID: fixture.uid) {
                    try fixture.source.commit(
                        .init(
                            classID: "Item",
                            changes: [
                                "subject": .text("actual prepared target baseline"),
                                "permissions": basePermissions,
                            ], operationID: "actual prepared target baseline")
                    ).revision
                }
            } else {
                base = try source.commit("actual prepared target baseline")
            }
            if withAttachment {
                let fixture = source
                revision = try fixture.source.withAccess(forUID: fixture.uid) {
                    let data = Data("tiny approved attachment original".utf8)
                    let result = try fixture.source.beginAttachment(
                        .init(
                            itemID: base.itemID, expectedRevisionID: base.revisionID,
                            operationID: "attach-before-enrollment", filename: "tiny.txt",
                            mediaType: "text/plain",
                            byteCount: Int64(data.count), sha256: AuthorityRecordCodec.sha256(data)))
                    let uploadID = try XCTUnwrap(result.uploadID)
                    _ = try fixture.source.appendAttachment(uploadID: uploadID, offset: 0, data: data)
                    return try fixture.source.finishAttachment(uploadID: uploadID).revision
                }
            } else {
                revision = base
            }
            handle = try source.begin()
            _ = try source.ready(handle)
            let accepted = try source.source.acceptPeerEnrollment(handle, forUID: source.uid)
            material = try source.source.peerEnrollmentActivationMaterial(handle, forUID: source.uid)
            let bootstrap = try AuthorityRecord.list(
                AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
            pin = try .init(
                sourceReplicaID: PeerEnrollmentApproval.preparation(material.preparationBytes)
                    .sourceReplicaID,
                bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)),
                approval: XCTUnwrap(accepted.approval))
            try source.capacity()
        }
        deinit {
            session?.close()
            target = nil
        }
        func open(progress: ((String) throws -> Void)? = nil) throws {
            session = try PeerEnrollmentActivation.open(
                root: source.targetRoot, material: material,
                pin: pin, accounts: source.accounts, progress: progress)
        }
        func transfer(omitAttachments: Bool = false) throws {
            let session = try XCTUnwrap(session)
            var cursor: PeerPackage.ResumeCursor?
            var work = 0
            repeat {
                try source.capacity()
                let page = try session.resume(
                    packageID: material.baseline.packageID, cursor: cursor, limit: 4)
                for object in page.objects
                where !object.verifiedComplete && !(omitAttachments && object.descriptor.kind == .attachment)
                {
                    var offset = object.nextOffset
                    while offset < object.descriptor.length {
                        work += 1
                        guard work <= 4096 else {
                            throw TractandaError("resourceLimit", "Tiny provisioning transfer work cap")
                        }
                        let chunk = try source.source.readPeerEnrollment(
                            handle, object: object.descriptor,
                            offset: offset, forUID: source.uid)
                        _ = try session.append(
                            packageID: material.baseline.packageID, object: object.descriptor,
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
        func closeSession() {
            session?.close()
            session = nil
        }
        func reopen(cold: Bool = false) throws {
            closeSession()
            target = nil
            if cold {
                try FileManager.default.removeItem(at: source.targetRoot.appendingPathComponent("index"))
            }
            target = try ItemStore.openInitialized(root: source.targetRoot, accounts: source.accounts)
        }
        func targetFiles() -> DocumentContentFiles { InitialAuthorityBootstrap.files(source.targetRoot) }
        func assertPending(file: StaticString = #filePath, line: UInt = #line) {
            // Initialized-root preflight must reject pending state even while its private owner holds the lock.

            XCTAssertThrowsError(
                try ItemStore.requireInitializedRoot(source.targetRoot), file: file, line: line)
        }
    }
    final class CompletionAccounts: AccountDirectory, @unchecked Sendable {
        let base: PeerEnrollmentApprovalTests.Accounts
        let otherUID: UInt32 = 51002
        var renamedAuthor = false
        init(_ base: PeerEnrollmentApprovalTests.Accounts) { self.base = base }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == otherUID {
                return .init(uid: uid, name: "other-admin", primaryGroupName: "staff", groupIDs: [71001])
            }
            let account = try base.user(forUID: uid)
            if uid == base.human, renamedAuthor {
                return .init(
                    uid: uid, name: "renamed-human", primaryGroupName: account.primaryGroupName,
                    groupIDs: account.groupIDs)
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
    private func code(
        _ expected: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, expected, file: file, line: line)
        }
    }

    /// Run explicitly as root: ordinary same-UID fixtures cannot reproduce Setup's custody check.
    func testPrivilegedPreparedReplicaValidationHonorsDaemonCustody() throws {
        guard getuid() == 0, geteuid() == 0 else {
            throw XCTSkip("Requires an isolated root invocation to verify real cross-UID custody.")
        }
        let daemon = try XCTUnwrap(getpwnam("daemon"))
        let owner = daemon.pointee.pw_uid
        let group = daemon.pointee.pw_gid
        XCTAssertNotEqual(owner, 0)
        let f = try Fixture()
        try f.open()
        try f.transfer()
        _ = try f.finish()
        f.closeSession()
        let root = f.source.targetRoot
        let manager = FileManager.default
        let paths = try XCTUnwrap(
            manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]))
        for case let path as URL in paths {
            XCTAssertFalse(try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
            XCTAssertEqual(chown(path.path, owner, group), 0)
        }
        XCTAssertEqual(chown(root.path, owner, group), 0)
        let preparation = try PeerEnrollmentApproval.preparation(f.material.preparationBytes)
        func verify() throws {
            try ItemStore.verifyPreparedReplicaIdentity(
                root: root, ownerUID: owner, expectedStoreID: preparation.commonStoreID,
                expectedReplicaID: preparation.targetReplicaID)
        }
        let identity = root.appendingPathComponent(".tractanda-store-identity.json")
        let original = try Data(contentsOf: identity)
        XCTAssertEqual(try FileMetadata.read(at: identity).uid, owner)
        XCTAssertEqual(try FileMetadata.read(at: identity).mode & 0o777, 0o600)
        XCTAssertNoThrow(try verify())
        // Correct root custody alone must not admit an identity file owned by the caller instead.
        XCTAssertEqual(chown(identity.path, 0, 0), 0)
        XCTAssertThrowsError(try verify())
        XCTAssertEqual(chown(identity.path, owner, group), 0)
        for mode: mode_t in [0o400, 0o640, 0o644, 0o660] {
            XCTAssertEqual(chmod(identity.path, mode), 0)
            XCTAssertThrowsError(try verify())
        }
        XCTAssertEqual(chmod(identity.path, 0o600), 0)
        let retained = root.appendingPathComponent("identity-retained-for-custody-test")
        try manager.moveItem(at: identity, to: retained)
        try manager.createSymbolicLink(at: identity, withDestinationURL: retained)
        XCTAssertThrowsError(try verify())
        try manager.removeItem(at: identity)
        try manager.moveItem(at: retained, to: identity)
        try manager.linkItem(at: identity, to: retained)
        XCTAssertThrowsError(try verify())
        try manager.removeItem(at: retained)
        var substituted = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        substituted["storeID"] = try Source.id()
        try JSONSerialization.data(withJSONObject: substituted).write(to: identity)
        XCTAssertThrowsError(try verify())
        try original.write(to: identity)
        XCTAssertNoThrow(try verify())
        XCTAssertEqual(try Data(contentsOf: identity), original)
    }

}
