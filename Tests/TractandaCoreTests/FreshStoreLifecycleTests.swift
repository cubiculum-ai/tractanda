import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

final class FreshStoreLifecycleTests: XCTestCase {
    final class Accounts: AccountDirectory, @unchecked Sendable {
        let owner: UInt32 = 51001
        var actorAvailable = true
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            if uid == tractanda_uid() {
                guard actorAvailable else {
                    throw TractandaError("unresolvedPrincipal", "Creator was removed")
                }
                return .init(uid: uid, name: "daemon", primaryGroupName: "service", groupIDs: [71002])
            }
            if uid == owner {
                return .init(uid: uid, name: "human", primaryGroupName: "staff", groupIDs: [71001])
            }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func user(named name: String) throws -> AccountIdentity {
            if name == "daemon" { return try user(forUID: tractanda_uid()) }
            if name == "human" { return try user(forUID: owner) }
            throw TractandaError("unresolvedPrincipal", "Unknown fixture user")
        }
        func groupID(named name: String) throws -> UInt32 {
            switch name {
            case "admin", "sudo", "staff": return 71001
            case "service": return 71002
            default: throw TractandaError("unresolvedPrincipal", "Unknown fixture group")
            }
        }
    }
    private var policy: ItemValue {
        .object([
            "profile": .text(AccessConfiguration.profile), "users": .list([.text("human")]),
            "groups": .list([]), "administration": .text("system"), "administratorGroup": .text("admin"),
        ])
    }
    private func directory() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        let root = (try GuardedFixtureDirectory.parent()).appendingPathComponent(
            "tractanda-fresh-lifecycle-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return root
    }
    private func start(
        _ root: URL, operation: String, accounts: Accounts,
        progress: ((String) throws -> Void)? = nil
    ) throws -> ItemStore {
        try ItemStore.createInitialized(
            root: root, accounts: accounts,
            initialAccessConfiguration: policy, actorUID: tractanda_uid(), operationID: operation,
            initializationKey: "handoff", progress: progress)
    }
    private func assertInitialPackages(_ root: URL, applied: Bool) throws {
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
        for package in [try XCTUnwrap(request.foundingPolicy).original.packageID]
            + request.pages.map(\.packageID) + [request.packageID]
        {
            let path = root.appendingPathComponent("authority/intake/" + package)
            let marker = path.appendingPathComponent("applied.json")
            if applied {
                XCTAssertEqual(
                    try Data(contentsOf: marker),
                    try Data(contentsOf: path.appendingPathComponent("sealed.json")))
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }
    }
    func testFreshCreationRejectsSymlinkLeafWithoutWritingTarget() throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try ItemStore.initializeFresh(
                root: link, accounts: Accounts(),
                initialAccessConfiguration: policy))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testServiceCreatorHandsOffToHumanAndCannotAdministerAfterCompletion() throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("store")
        let accounts = Accounts()
        let store = try ItemStore.initializeFresh(
            root: root, accounts: accounts,
            initialAccessConfiguration: policy, initializationKey: "setup:fixture")
        try assertInitialPackages(root, applied: true)
        XCTAssertThrowsError(
            try store.withAccess(forUID: tractanda_uid()) { try store.requireAdministrator() })
        _ = try store.withAccess(forUID: accounts.owner) {
            try store.commit(
                .init(classID: "Item", changes: ["subject": .text("human")], operationID: "human-write"))
        }
        XCTAssertThrowsError(
            try store.withAccess(forUID: tractanda_uid()) {
                try store.configureAccess(
                    .object(["profile": .text(AccessConfiguration.profile)]), operationID: "daemon-escalation"
                )
            })
    }
    func testRestartBeforeAndAfterAcceptedHandoffOnlyCompletesExactOperation() throws {
        for boundary in [
            "beforeFoundingPolicy", "afterFoundingPolicy", "afterInitialCapture", "beforePolicy", "beforePin",
            "beforePinAcceptance", "afterPin", "beforeComplete",
        ] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let accounts = Accounts()
            let operation = try UUID.makeVersion1().uuidString.lowercased()
            XCTAssertThrowsError(
                try start(root, operation: operation, accounts: accounts) {
                    if $0 == boundary { throw CancellationError() }
                })
            try assertInitialPackages(root, applied: boundary == "beforeComplete")
            let receipt = try Data(
                contentsOf: root.appendingPathComponent(InitialAuthorityBootstrap.receiptName))
            let identity = try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name))
            let configuration = try AuthorityStore.configuration(
                root: root, files: InitialAuthorityBootstrap.files(root))
            XCTAssertThrowsError(try ItemStore.openInitialized(root: root, accounts: accounts))
            XCTAssertThrowsError(
                try ItemStore.initializeFresh(
                    root: root, accounts: accounts,
                    initialAccessConfiguration: policy, initializationKey: "other-request"))
            var resumed: ItemStore? = try start(root, operation: operation, accounts: accounts)
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent(InitialAuthorityBootstrap.receiptName)),
                receipt)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name)), identity)
            if let originalPin = configuration?.bootstrap {
                XCTAssertEqual(
                    try AuthorityStore.configuration(
                        root: root, files: InitialAuthorityBootstrap.files(root))?.bootstrap,
                    originalPin)
            }
            try assertInitialPackages(root, applied: true)
            XCTAssertThrowsError(
                try resumed!.withAccess(forUID: tractanda_uid()) { try resumed!.requireAdministrator() })
            resumed = nil
            let opened = try ItemStore.openInitialized(root: root, accounts: accounts)
            XCTAssertEqual(try opened.withAccess(forUID: accounts.owner) { try opened.candidates().count }, 1)
        }
    }
    func testCreatorResolutionRevokedBeforePolicyAcceptanceCannotPinOrComplete() throws {
        for boundary in ["beforePolicy", "beforePinAcceptance"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let accounts = Accounts()
            let operation = try UUID.makeVersion1().uuidString.lowercased()
            XCTAssertThrowsError(
                try start(root, operation: operation, accounts: accounts) {
                    if $0 == boundary { accounts.actorAvailable = false }
                })
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
            let founding = try XCTUnwrap(request.foundingPolicy)
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent(founding.original.path)), founding.bytes)
            XCTAssertNil(
                try AuthorityStore.configuration(root: root, files: InitialAuthorityBootstrap.files(root))?
                    .bootstrap)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(InitialAuthorityBootstrap.completeName).path))
            XCTAssertThrowsError(try start(root, operation: operation, accounts: accounts))
            accounts.actorAvailable = true
            let store = try start(root, operation: operation, accounts: accounts)
            XCTAssertThrowsError(
                try store.withAccess(forUID: tractanda_uid()) { try store.requireAdministrator() })
        }
    }
    func testAcceptedPinCompletesAfterCreatorDisappearsWithoutRestoringRights() throws {
        for boundary in ["afterPin", "beforeComplete"] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let accounts = Accounts()
            let operation = try UUID.makeVersion1().uuidString.lowercased()
            XCTAssertThrowsError(
                try start(root, operation: operation, accounts: accounts) {
                    if $0 == boundary { throw CancellationError() }
                })
            let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
            let before = try Data(
                contentsOf: root.appendingPathComponent(InitialAuthorityBootstrap.receiptName))
            let identity = try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name))
            accounts.actorAvailable = false
            var store: ItemStore? = try start(root, operation: operation, accounts: accounts)
            XCTAssertTrue(try InitialAuthorityBootstrap.completed(root: root, request: request))
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent(InitialAuthorityBootstrap.receiptName)),
                before)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ReplicaIdentity.name)), identity)
            try assertInitialPackages(root, applied: true)
            XCTAssertThrowsError(
                try store!.withAccess(forUID: tractanda_uid()) { try store!.requireAdministrator() })
            store = nil
            try FileManager.default.removeItem(at: root.appendingPathComponent("index"))
            store = try ItemStore.openInitialized(root: root, accounts: accounts)
            try store!.withAccess(forUID: accounts.owner) {
                try store!.requireAdministrator()
                XCTAssertEqual(try store!.candidates().count, 1)
            }
        }
    }
    func testChangedCurrentPolicyAfterAcceptedHandoffCannotCompleteEarlierOperation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = Accounts()
        let operation = try UUID.makeVersion1().uuidString.lowercased()
        XCTAssertThrowsError(
            try start(root, operation: operation, accounts: accounts) {
                if $0 == "afterPin" { throw CancellationError() }
            })
        let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
        do {
            let store = try ItemStore(
                root: root, accounts: accounts, revisionProjectionEnabled: true,
                authorityIntakeEnabled: true, firstSourceOperation: request)
            _ = try store.withAccess(forUID: accounts.owner) {
                try store.configureAccess(policy, operationID: "a-different-accepted-operation")
            }
        }
        XCTAssertThrowsError(try start(root, operation: operation, accounts: accounts))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(InitialAuthorityBootstrap.completeName).path))
        XCTAssertThrowsError(try ItemStore.openInitialized(root: root, accounts: accounts))
    }
    func testAcceptedHandoffRejectsMissingOrChangedCanonicalProof() throws {
        for corruption in [
            "pin", "identity", "seal", "capture", "history", "page", "root", "framing", "policy",
        ] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let accounts = Accounts()
            let operation = try UUID.makeVersion1().uuidString.lowercased()
            XCTAssertThrowsError(
                try start(root, operation: operation, accounts: accounts) {
                    if $0 == "beforeComplete" { throw CancellationError() }
                })
            switch corruption {
            case "pin":
                let files = InitialAuthorityBootstrap.files(root)
                let old = try XCTUnwrap(AuthorityStore.configuration(root: root, files: files))
                let pin = try XCTUnwrap(old.bootstrap)
                try AuthorityStore.writeConfiguration(
                    .init(
                        profile: old.profile, peers: old.peers,
                        bootstrap: .init(recordID: pin.recordID, sha256: pin.sha256, actor: "changed"),
                        lifecycle: old.lifecycle, credentialBindings: old.credentialBindings), root: root,
                    files: files)
            case "identity":
                try FileManager.default.removeItem(at: root.appendingPathComponent(ReplicaIdentity.name))
            case "capture":
                try FileManager.default.removeItem(
                    at: root.appendingPathComponent(".authority-initial-capture.json"))
            case "history":
                let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
                let founding = try XCTUnwrap(request.foundingPolicy)
                try FileManager.default.removeItem(
                    at: root.appendingPathComponent(
                        "authority/initial-history/" + founding.original.revisionID))
            case "policy":
                let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
                let founding = try XCTUnwrap(request.foundingPolicy)
                try FileManager.default.removeItem(at: root.appendingPathComponent(founding.original.path))
            case "page", "root", "framing":
                let request = try XCTUnwrap(InitialAuthorityBootstrap.load(root: root))
                if corruption == "framing" {
                    try FileManager.default.removeItem(
                        at: root.appendingPathComponent(
                            "authority/intake/" + request.packageID + "/objects/" + request.framingID + "/0"))
                    break
                }
                let id = corruption == "page" ? request.pages[0].recordID : request.rootID
                let paths = try FileManager.default.subpathsOfDirectory(
                    atPath: root.appendingPathComponent("authority").path)
                let matches = paths.filter {
                    $0.hasSuffix("/" + id + ".authority") || $0.hasSuffix("/" + id + ".index")
                }
                XCTAssertEqual(matches.count, 1)
                for path in matches {
                    try FileManager.default.removeItem(at: root.appendingPathComponent("authority/" + path))
                }
            default:
                let paths = try FileManager.default.subpathsOfDirectory(
                    atPath: root.appendingPathComponent("authority").path)
                let seals = paths.filter { $0.hasSuffix("/sealed.json") }
                XCTAssertFalse(seals.isEmpty)
                for seal in seals {
                    try FileManager.default.removeItem(at: root.appendingPathComponent("authority/" + seal))
                }
            }
            XCTAssertThrowsError(try start(root, operation: operation, accounts: accounts), corruption)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(InitialAuthorityBootstrap.completeName).path))
        }
    }
    func testStrictCoordinatorOpensInitializedStoreAndRejectsMissingLegacyPendingAndUnsafeRoots() async throws
    {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let accounts = Accounts()
        let initialized = parent.appendingPathComponent("initialized")
        do {
            _ = try ItemStore.initializeFresh(
                root: initialized, accounts: accounts,
                initialAccessConfiguration: policy, initializationKey: "coordinator")
        }
        let coordinator = try await ServiceCoordinator(
            opening: initialized, makeAccountDirectory: { accounts })
        let identity = try await coordinator.accountIdentity(forUID: accounts.owner)
        XCTAssertEqual(identity.name, "human")
        await coordinator.close()
        try FileManager.default.removeItem(at: initialized.appendingPathComponent("index"))
        do { _ = try ItemStore.openInitialized(root: initialized, accounts: accounts) }
        let missing = parent.appendingPathComponent("missing")
        let legacy = parent.appendingPathComponent("legacy")
        do { _ = try ItemStore(root: legacy) }
        let pending = parent.appendingPathComponent("pending")
        XCTAssertThrowsError(
            try start(pending, operation: UUID.makeVersion1().uuidString.lowercased(), accounts: accounts) {
                if $0 == "beforePolicy" { throw CancellationError() }
            })
        let unsafe = parent.appendingPathComponent("unsafe")
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: initialized)
        for root in [missing, legacy, pending, unsafe] {
            do {
                let unexpected = try await ServiceCoordinator(
                    opening: root, makeAccountDirectory: { accounts })
                await unexpected.close()
                XCTFail("Strict coordinator adopted \(root.lastPathComponent)")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("authority").path))
    }
}
