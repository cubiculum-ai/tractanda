import CTractandaPlatform
import XCTest

@testable import TractandaCore

final class PersonalEnrollmentTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard uid == tractanda_uid() || uid == 54001 else {
                throw TractandaError("unresolvedPrincipal", "Fixture user missing")
            }
            return .init(
                uid: uid, name: uid == tractanda_uid() ? "admin" : "alice",
                primaryGroupName: "staff", groupIDs: [74001])
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "admin" { return try user(forUID: tractanda_uid()) }
            if name == "alice" { return try user(forUID: 54001) }
            throw TractandaError("unresolvedPrincipal", "Fixture user missing")
        }
        func groupID(named name: String) throws -> UInt32 { 74001 }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    private func fixture(
        _ body: (URL, ItemStore, PersonalEnrollmentRegistry, PersonalEnrollmentLocalAuthorization) throws ->
            Void
    ) throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "personal-enrollment-" + Identifier.make())
        try PrivateConfiguration.makeDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = PersonalRecoveryIndex.Limits()
        limits.maximumDerivedBytes = AttachmentFixtureCapacity.fixtureCapBytes
        let store = try ItemStore(
            personalRoot: root.appendingPathComponent("store"),
            opening: .fresh(
                .object([
                    "profile": .text(AccessConfiguration.profile),
                    "users": .list([.text("admin"), .text("alice")]),
                ])), accounts: Accounts(), recoveryLimits: limits)
        let authorization = try PersonalEnrollmentLocalAuthorization.authorize(
            store: store, forUID: tractanda_uid())
        let registry = PersonalEnrollmentRegistry(root: store.root, ownerUID: tractanda_uid())
        try body(store.root, store, registry, authorization)
    }
    private func issue(
        _ registry: PersonalEnrollmentRegistry, _ authorization: PersonalEnrollmentLocalAuthorization,
        now: Int64 = 10_000
    ) throws -> PersonalEnrollmentInvitation {
        try registry.issue(
            authorization: authorization, endpoints: [.init(host: "raven.fixture", port: 48732)], now: now)
    }
    private func claim(_ invitation: PersonalEnrollmentInvitation, target: String? = nil) throws
        -> PersonalEnrollmentClaim
    {
        .init(
            metadata: .init(
                operationID: invitation.metadata.operationID,
                targetReplicaID: try target ?? id(), targetHostname: "target.fixture",
                continuationPairingID: try id()),
            continuationSecret: try .init(bytes: [UInt8](repeating: 71, count: 32)))
    }
    private func assertCode(
        _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? TractandaError)?.code, code, file: file, line: line)
        }
    }

    func testPrivateInvitationRoundTripAndDiagnosticsRedactSecrets() throws {
        try fixture { _, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let code = try invitation.privateCode()
            let parsed = try PersonalEnrollmentInvitation.parsePrivateCode(code)
            XCTAssertEqual(parsed.metadata, invitation.metadata)
            XCTAssertTrue(try parsed.privateCode() == code, "Private invitation round trip differs.")
            XCTAssertEqual(String(describing: invitation), "PersonalEnrollmentInvitation(<redacted>)")
            XCTAssertEqual(String(reflecting: invitation), "PersonalEnrollmentInvitation(<redacted>)")
            XCTAssertEqual(invitation.customMirror.children.count, 0)
            XCTAssertEqual(invitation.secret.customMirror.children.count, 0)
            let ordinaryStatus = try JSON.encode(registry.status(authorization: authorization))
            XCTAssertFalse(String(decoding: ordinaryStatus, as: UTF8.self).contains(code))
            XCTAssertFalse(String(decoding: ordinaryStatus, as: UTF8.self).contains("secret"))
            let otherSecret = try PersonalEnrollmentSecret.generate()
            XCTAssertFalse(
                invitation.secret.withBytes { $0 } == otherSecret.withBytes { $0 },
                "Fresh private secrets must differ.")
        }
    }
    func testNoncanonicalClaimHostnameCannotConsumeSingleUseInvitation() throws {
        try fixture { _, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let claim = PersonalEnrollmentClaim(
                metadata: .init(
                    operationID: invitation.metadata.operationID,
                    targetReplicaID: try id(), targetHostname: "STASH.FIXTURE",
                    continuationPairingID: try id()),
                continuationSecret: try .generate())
            XCTAssertThrowsError(
                try registry.claim(
                    claim, authenticatedInvitation: invitation.metadata,
                    authorization: authorization, now: 10_001))
            XCTAssertNotNil(try registry.invitationCredential(now: 10_001))
            XCTAssertEqual(try registry.status(authorization: authorization)?.phase, .invitation)
        }
    }

    func testMalformedCodeUnknownFieldsAndNumericEndpointAreRejected() throws {
        try fixture { _, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            XCTAssertThrowsError(try PersonalEnrollmentInvitation.parsePrivateCode("123456"))
            XCTAssertThrowsError(
                try PersonalEnrollmentInvitation.parsePrivateCode(try invitation.privateCode() + "\n"))
            XCTAssertThrowsError(
                try PersonalEnrollmentInvitation.parsePrivateCode(String(repeating: "x", count: 13 * 1024)))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(invitation.metadata)) as? [String: Any])
            object["allowItems"] = true
            let header = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let count = UInt32(header.count)
            let encoded =
                Data([
                    UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255),
                    UInt8(count & 255),
                ])
                + header + invitation.secret.withBytes { Data($0) }
            XCTAssertThrowsError(
                try PersonalEnrollmentInvitation.parsePrivateCode(
                    "tractanda-pair-v1." + encoded.base64EncodedString()))
            XCTAssertThrowsError(
                try registry.issue(
                    authorization: authorization,
                    endpoints: [.init(host: "127.0.0.1", port: 48732)], now: 20_000))
        }
    }

    func testOnlyOneUnusedInvitationAndExpiredReplacementUsesFreshIdentities() throws {
        try fixture { _, _, registry, authorization in
            let first = try issue(registry, authorization)
            assertCode("enrollmentConflict") { _ = try issue(registry, authorization) }
            XCTAssertNotNil(try registry.invitationCredential(now: 10_599))
            XCTAssertNil(try registry.invitationCredential(now: 10_600))
            let second = try issue(registry, authorization, now: 10_600)
            XCTAssertNotEqual(first.metadata.operationID, second.metadata.operationID)
            XCTAssertNotEqual(first.metadata.bootstrapReplicaID, second.metadata.bootstrapReplicaID)
            XCTAssertFalse(
                first.secret.withBytes { $0 } == second.secret.withBytes { $0 },
                "Replacement secret must be fresh.")
        }
    }

    func testAtomicSingleClaimPersistsContinuationAndNeverReplaysInvitation() throws {
        try fixture { root, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let target = try claim(invitation)
            let accepted = try registry.claim(
                target, authenticatedInvitation: invitation.metadata,
                authorization: authorization, now: 10_001)
            XCTAssertEqual(accepted.phase, .claimed)
            XCTAssertEqual(accepted.claim, target.metadata)
            XCTAssertNil(try registry.invitationCredential(now: 10_002))
            // A lost reply/restart already has the target-generated continuation; TTL is only unused codes.
            let reopened = PersonalEnrollmentRegistry(root: root, ownerUID: tractanda_uid())
            let retained = try XCTUnwrap(reopened.continuationCredential())
            XCTAssertEqual(retained.metadata, target.metadata)
            XCTAssertTrue(
                retained.continuationSecret.withBytes { $0 } == target.continuationSecret.withBytes { $0 },
                "Exact private continuation must survive restart.")
            XCTAssertEqual(try reopened.status(authorization: authorization)?.phase, .claimed)
            assertCode("enrollmentConflict") {
                _ = try reopened.claim(
                    target, authenticatedInvitation: invitation.metadata, authorization: authorization,
                    now: 10_002)
            }
            let substituted = try claim(invitation)
            assertCode("enrollmentConflict") {
                _ = try reopened.claim(
                    substituted, authenticatedInvitation: invitation.metadata, authorization: authorization,
                    now: 20_000)
            }
            assertCode("enrollmentConflict") { _ = try issue(reopened, authorization, now: 20_000) }
        }
    }

    func testExpiredOrWrongOperationClaimCannotConsumeCurrentInvitation() throws {
        try fixture { _, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let target = try claim(invitation)
            assertCode("invitationExpired") {
                _ = try registry.claim(
                    target, authenticatedInvitation: invitation.metadata, authorization: authorization,
                    now: 10_600)
            }
            let invalid = PersonalEnrollmentClaim(
                metadata: .init(
                    operationID: try id(), targetReplicaID: try id(),
                    targetHostname: "target.fixture", continuationPairingID: try id()),
                continuationSecret: target.continuationSecret)
            XCTAssertThrowsError(
                try registry.claim(
                    invalid, authenticatedInvitation: invitation.metadata,
                    authorization: authorization, now: 10_001))
            XCTAssertEqual(try registry.status(authorization: authorization)?.phase, .invitation)
            XCTAssertNotNil(try registry.invitationCredential(now: 10_001))
        }
    }

    func testLocalAuthorizationRequiresActualCurrentAdministrator() throws {
        try fixture { _, store, _, _ in
            assertCode("forbidden") {
                _ = try PersonalEnrollmentLocalAuthorization.authorize(store: store, forUID: 54001)
            }
        }
    }

    func testStateCustodyRejectsModeAndHardlinkSubstitution() throws {
        try fixture { root, _, registry, authorization in
            _ = try issue(registry, authorization)
            let state = root.appendingPathComponent(".personal-enrollment/current.bin")
            let metadata = try FileMetadata.read(at: state)
            XCTAssertEqual(metadata.mode & 0o777, 0o600)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: state.path)
            XCTAssertThrowsError(try registry.status(authorization: authorization))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
            let alias = root.appendingPathComponent("aliased-secret")
            try FileManager.default.linkItem(at: state, to: alias)
            XCTAssertThrowsError(try registry.status(authorization: authorization))
            try FileManager.default.removeItem(at: alias)
            XCTAssertEqual(try registry.status(authorization: authorization)?.phase, .invitation)
        }
    }

    func testFinishingRemovesPrivateSecretAndAllowsAnotherCurrentOperation() throws {
        try fixture { root, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let oldBytes = try Data(
                contentsOf: root.appendingPathComponent(".personal-enrollment/current.bin"))
            try registry.finish(
                authorization: authorization, operationID: invitation.metadata.operationID, cancelled: true)
            XCTAssertNil(try registry.invitationCredential(now: 10_001))
            XCTAssertNil(try registry.continuationCredential())
            let newBytes = try Data(
                contentsOf: root.appendingPathComponent(".personal-enrollment/current.bin"))
            XCTAssertNil(newBytes.range(of: Data(oldBytes.suffix(32))))
            XCTAssertEqual(try registry.status(authorization: authorization)?.phase, .cancelled)
            XCTAssertNotEqual(
                try issue(registry, authorization).metadata.operationID, invitation.metadata.operationID)
        }
    }

    func testEnrollmentFailureAndExpiredCleanupDoNotGateOrdinaryStoreIdentity() throws {
        try fixture { root, store, registry, authorization in
            _ = try issue(registry, authorization)
            _ = try issue(registry, authorization, now: 20_000)
            _ = try issue(registry, authorization, now: 30_000)
            let operationDirectory = root.appendingPathComponent(".personal-enrollment")
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: operationDirectory.path), ["current.bin"])
            try Data([0, 0, 0, 0]).write(to: operationDirectory.appendingPathComponent("current.bin"))
            XCTAssertThrowsError(try registry.status(authorization: authorization))
            XCTAssertEqual(try store.personalSyncIdentity().storeID, authorization.identity.storeID)
        }
    }

    func testCompletionRequiresExactPersistedResultingMembershipAndCleansSecretAfterCommit() throws {
        try fixture { root, source, registry, authorization in
            let invitation = try issue(registry, authorization)
            let target = try ItemStore.createJoiningPersonalSyncReplica(
                root: root.deletingLastPathComponent().appendingPathComponent("joining"),
                storeID: authorization.identity.storeID,
                accessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text("admin")]),
                ]),
                accounts: Accounts())
            let targetIdentity = try target.personalSyncIdentity()
            XCTAssertTrue(target.isPersonalBaselinePending)
            let selectionID = try target.startPersonalBaseline(
                sourceReplicaID: authorization.identity.replicaID)
            assertCode("baselineNotReady") { try target.finishPersonalBaseline(selectionID: selectionID) }
            let targetClaim = try claim(invitation, target: targetIdentity.replicaID)
            _ = try registry.claim(
                targetClaim, authenticatedInvitation: invitation.metadata, authorization: authorization,
                now: 10_001)
            let configuration = try PersonalMembershipConfiguration(
                storeID: authorization.identity.storeID,
                configurationID: id(),
                members: [
                    .init(replicaID: authorization.identity.replicaID, hostname: "raven.fixture"),
                    .init(replicaID: targetIdentity.replicaID, hostname: "target.fixture"),
                ])
            try registry.stageMembershipProposal(authorization: authorization, configuration: configuration)
            assertCode("enrollmentConflict") {
                try registry.finish(
                    authorization: authorization, operationID: invitation.metadata.operationID,
                    cancelled: false)
            }
            assertCode("enrollmentConflict") {
                try registry.finish(
                    authorization: authorization, operationID: invitation.metadata.operationID,
                    cancelled: true)
            }
            let nonce = try id()
            let pairing = try id()
            let digest = try configuration.digest
            let pa = try source.preparePersonalMembershipChange(
                configuration: configuration, expectedDigest: nil, nonce: nonce)
            let pb = try target.preparePersonalMembershipChange(
                configuration: configuration, expectedDigest: nil, nonce: nonce)
            let a = try PeerExchangeBinding(
                peerID: "target", storeID: configuration.storeID,
                localReplicaID: authorization.identity.replicaID, remoteReplicaID: targetIdentity.replicaID,
                pairingID: pairing, localIsInitiator: true, configurationDigest: digest)
            let b = try PeerExchangeBinding(
                peerID: "source", storeID: configuration.storeID,
                localReplicaID: targetIdentity.replicaID, remoteReplicaID: authorization.identity.replicaID,
                pairingID: pairing, localIsInitiator: false, configurationDigest: digest)
            try source.registerPersonalPeerCredentials(
                [.init(binding: a, secret: [UInt8](repeating: 42, count: 32))], configuration: configuration)
            try target.registerPersonalPeerCredentials(
                [.init(binding: b, secret: [UInt8](repeating: 42, count: 32))], configuration: configuration)
            _ = try source.commitPersonalMembershipChange(
                preparation: pa,
                acknowledgements: [
                    .init(
                        binding: a, response: target.personalMembershipReady(session: b, preparation: pa),
                        control: .commitCompletion())
                ])
            _ = try target.commitPersonalMembershipChange(
                preparation: pb,
                acknowledgements: [
                    .init(
                        binding: b, response: source.personalMembershipReady(session: a, preparation: pb),
                        control: .commitCompletion())
                ])
            let jobGeneration = UUID()
            let first = try PersonalEnrollmentCompletedCut(
                binding: b, selectionID: selectionID,
                jobGeneration: jobGeneration, ordinal: 1, sourceCatalogueGeneration: "empty-source-fixture",
                cutRowID: 0)
            let rescan = try PersonalEnrollmentCompletedCut(
                binding: b, selectionID: selectionID,
                jobGeneration: jobGeneration, ordinal: 2, sourceCatalogueGeneration: "empty-source-fixture",
                cutRowID: 0)
            try target.finishPersonalBaseline(
                selectionID: selectionID, actorUID: tractanda_uid(),
                readiness: .observed(first: first, rescan: rescan))
            XCTAssertFalse(target.isPersonalBaselinePending)
            XCTAssertEqual(try PersonalWorkgroupProfile.load(target.root)?.initialization, "freshReplica")
            let resultingAuthorization = try PersonalEnrollmentLocalAuthorization.authorize(
                store: source, forUID: tractanda_uid())
            XCTAssertEqual(
                try registry.status(authorization: resultingAuthorization)?.resultingMembership, configuration
            )
            try registry.finish(
                authorization: resultingAuthorization, operationID: invitation.metadata.operationID,
                cancelled: false)
            XCTAssertEqual(try registry.status(authorization: resultingAuthorization)?.phase, .complete)
            XCTAssertNil(try registry.continuationCredential())
        }
    }

    func testMaximumMembershipFitsOperationalStateWithoutEnlargingInvitationEnvelope() throws {
        try fixture { root, _, registry, authorization in
            let invitation = try issue(registry, authorization)
            let target = try claim(invitation)
            var members = [
                try PersonalMember(replicaID: authorization.identity.replicaID, hostname: "raven.fixture"),
                try PersonalMember(replicaID: target.metadata.targetReplicaID, hostname: "target.fixture"),
            ]
            for index in 2..<256 {
                let hostname =
                    "n\(index)."
                    + Array(repeating: String(repeating: "a", count: 60), count: 4).joined(separator: ".")
                members.append(try .init(replicaID: id(), hostname: hostname))
            }
            let membership = try PersonalMembershipConfiguration(
                storeID: authorization.identity.storeID,
                configurationID: id(), members: members)
            let state = PersonalEnrollmentIssuerStatus(
                phase: .claimed, invitation: invitation.metadata,
                administrator: authorization.administrator, claim: target.metadata,
                resultingMembership: membership)
            let bytes = try PersonalEnrollmentPrivateCodec.encode(
                state, secret: target.continuationSecret,
                maximumHeaderBytes: PersonalEnrollmentPrivateCodec.operationHeaderBytes)
            XCTAssertGreaterThan(bytes.count, 16 * 1024)
            XCTAssertLessThan(bytes.count, PersonalEnrollmentPrivateCodec.operationHeaderBytes)
            let files = DocumentContentFiles(
                root: root, ownerUID: tractanda_uid(), minimumFreeBytes: 10 * 1024 * 1024 * 1024)
            try files.replacePersonalEnrollmentState(bytes, expected: files.readPersonalEnrollmentState())
            XCTAssertEqual(try registry.status(authorization: authorization)?.resultingMembership, membership)
            XCTAssertThrowsError(
                try PersonalEnrollmentPrivateCodec.encode(state, secret: target.continuationSecret))
        }
    }
    #if os(macOS)
        func testReadGrantACLOnEnrollmentSecretStateAndDirectoryIsRejected() throws {
            try fixture { root, store, registry, authorization in
                _ = try issue(registry, authorization)
                let directory = root.appendingPathComponent(".personal-enrollment")
                let file = directory.appendingPathComponent("current.bin")
                func chmod(_ arguments: [String]) throws {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0)
                }
                try chmod(["+a", "everyone allow read", file.path])
                XCTAssertThrowsError(try registry.status(authorization: authorization))
                XCTAssertEqual(try store.personalSyncIdentity().storeID, authorization.identity.storeID)
                try chmod(["-N", file.path])
                XCTAssertNotNil(try registry.status(authorization: authorization))
                try chmod(["+a", "everyone allow list,search", directory.path])
                XCTAssertThrowsError(try registry.status(authorization: authorization))
                try chmod(["-N", directory.path])
            }
        }
    #endif
}
