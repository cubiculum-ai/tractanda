import CTractandaPlatform
import Crypto
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

final class SetupLayout17IntegrationTests: XCTestCase {
    /// Installer transaction fixture: service manager and external converter are mocked. The
    /// separate genuine16.2-binary fixture qualifies real conversion and new Core reopening.
    final class Fixture {
        let base: SetupPackageLifecycleTests.Fixture
        let root: URL
        let store: URL
        let candidate: URL
        let original: SetupPackageCompatibility
        let incoming: SetupPackageCompatibility
        let originalRequirement: CanonicalReaderRequirement
        let originalHash: String
        let storeID: String
        let replicaID: String
        let clustered: Bool
        var failure: String?
        var migrations = 0
        init(clustered: Bool) throws {
            self.clustered = clustered
            root = try GuardedFixtureDirectory.create(
                prefix: "layout17-setup-", source: #filePath, test: #function)
            base = try .init(root: root.standardizedFileURL)
            try base.configureFresh()
            try base.install()
            store = base.engine.roots.data.appendingPathComponent("a")
            candidate = root.appendingPathComponent("candidate")
            let profile =
                try JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf:
                            store.appendingPathComponent(".tractanda-personal-profile.json")))
                as! [String: Any]
            storeID = profile["storeID"] as! String
            replicaID = profile["replicaID"] as! String
            if clustered {
                let membership = try PersonalMembershipConfiguration(
                    storeID: storeID,
                    configurationID: UUID.makeVersion1().uuidString.lowercased(),
                    members: [
                        .init(replicaID: replicaID, hostname: "one.fixture"),
                        .init(
                            replicaID: UUID.makeVersion1().uuidString.lowercased(), hostname: "two.fixture"),
                    ])
                try Self.privateWrite(
                    JSON.encode(membership), store.appendingPathComponent(".personal-membership.json"))
            }
            let current = try XCTUnwrap(
                CanonicalReaderRequirement.load(root: store, ownerUID: tractanda_uid()))
            originalRequirement = .init(
                storeID: storeID, minimumReaderLevel: 18,
                recordFormats: current.recordFormats,
                capabilities: current.capabilities.filter {
                    !["tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1"].contains($0)
                })
            let oldBytes = try JSON.encode(originalRequirement)
            originalHash = Self.digest(oldBytes)
            try Self.privateWrite(oldBytes, store.appendingPathComponent("canonical-reader.json"))
            try FileManager.default.removeItem(at: store.appendingPathComponent("canonical-layout.json"))
            let prior = try JSON.decode(BundleManifest.self, Data(contentsOf: base.manifestURL))
            let currentSupport = CanonicalFormatSupport.current
            let oldSupport = CanonicalFormatSupport(
                readerLevel: 18, writerLevel: 18, read: currentSupport.read,
                write: currentSupport.write,
                capabilities: currentSupport.capabilities.filter {
                    !["tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1"].contains($0)
                },
                writeCapabilities: currentSupport.writeCapabilities.filter {
                    !["tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1"].contains($0)
                })
            let oldManifest = BundleManifest(
                version: "0.1.0-poc.16.2", platform: "linux", arch: prior.arch,
                files: prior.files, canonicalFormats: oldSupport)
            let oldManifestBytes = try JSON.encode(oldManifest)
            try oldManifestBytes.write(to: base.manifestURL)
            original = .init(
                manifestSHA256: Self.digest(oldManifestBytes), version: oldManifest.version,
                arch: oldManifest.arch, canonicalFormats: oldSupport)
            var receipt = try XCTUnwrap(base.engine.readReceipt("a"))
            receipt.manifestSHA256 = original.manifestSHA256
            receipt.releases = [receipt.release: original.manifestSHA256]
            try base.engine.writeReceipt(receipt)
            var state = try SetupPackageState(original: original, instances: [])
            state.incoming = original
            state.observed = original
            state.phase = .committed
            try base.engine.writePackageState(state)
            try FileManager.default.copyItem(at: base.engine.packagePayload, to: candidate)
            let helper = Data("fixture converter executable".utf8)
            try helper.write(to: candidate.appendingPathComponent("bin/tractanda-layout17"))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: candidate.appendingPathComponent("bin/tractanda-layout17").path)
            let manifest = BundleManifest(
                version: "0.1.0-poc.17", platform: "linux", arch: prior.arch,
                files: prior.files + [
                    .init(
                        path: "bin/tractanda-layout17", sha256: Self.digest(helper),
                        size: UInt64(helper.count), mode: 0o755)
                ],
                canonicalFormats: .current)
            let bytes = try JSON.encode(manifest)
            try bytes.write(to: candidate.appendingPathComponent("bundle-manifest.json"))
            incoming = .init(
                manifestSHA256: Self.digest(bytes), version: manifest.version, arch: manifest.arch,
                canonicalFormats: .current, upgrade: .coordinatedMaintenance)
            base.runner.layout17Call = { [unowned self] args in
                if args.first == "inspect" { return try self.inspect() }
                let journal = self.base.engine.layout17JournalDirectory
                XCTAssertTrue(args.contains(journal.path))
                let mode =
                    try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions]
                    as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o700)
                self.migrations += 1
                if self.failure == "beforeFence" { return .init(status: 1, output: "injected before fence") }
                try self.fenceAndJournal()
                if self.failure == "afterFence" { return .init(status: 1, output: "injected after reader20") }
                try Self.privateWrite(
                    JSON.encode([
                        "profile": "tractanda.physical-layout.v1",
                        "layout": "flat-items-visible-attachments.v1", "recordEncoding": "message-v1",
                    ]), self.store.appendingPathComponent("canonical-layout.json"))
                try FileManager.default.removeItem(
                    at: self.store.appendingPathComponent("canonical-layout.pending.json"))
                return .init(status: 0)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        static func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        static func privateWrite(_ bytes: Data, _ target: URL) throws {
            try bytes.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        func inspect() throws -> ProcessResult {
            var value: [String: Any] = [
                "profile": "tractanda.layout17-inspection.v1", "storeID": storeID,
                "replicaID": replicaID, "readerRequirementSHA256": originalHash,
                "minimumReaderLevel": try CanonicalReaderRequirement.load(
                    root: store, ownerUID: tractanda_uid())!.minimumReaderLevel,
                "clustered": clustered,
            ]
            if clustered {
                value["memberCount"] = 2
                value["membershipDigest"] = Self.digest(
                    try Data(contentsOf: store.appendingPathComponent(".personal-membership.json")))
            }
            return .init(
                status: 0,
                output: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        func fenceAndJournal() throws {
            let raised = CanonicalReaderRequirement(
                storeID: storeID, minimumReaderLevel: 20,
                recordFormats: originalRequirement.recordFormats,
                capabilities: (originalRequirement.capabilities + [
                    "tractanda.physical-layout.flat-items.v1", "tractanda.message-items.v1",
                ]).sorted())
            try Self.privateWrite(JSON.encode(raised), store.appendingPathComponent("canonical-reader.json"))
            try Self.privateWrite(
                Data("{}".utf8), store.appendingPathComponent("canonical-layout.pending.json"))
            try base.engine.writeProtected(
                JSON.encode([
                    "profile": "tractanda.layout17-journal.v1", "storeID": storeID,
                    "replicaID": replicaID, "originalRequirementSHA256": originalHash,
                ]),
                to: base.engine.layout17JournalDirectory.appendingPathComponent(
                    "layout17-" + storeID + "-" + replicaID + ".json"), mode: 0o600)
        }
        func prepare() throws { _ = try base.engine.prepareLayout17(instance: "a", bundle: candidate) }
        func preflight() throws {
            let descriptor = root.appendingPathComponent("preflight.json")
            try base.engine.writeProtected(incoming.encoded(), to: descriptor, mode: 0o600)
            _ = try base.engine.packageLifecycle(
                .init(action: .preflight, descriptor: descriptor, instance: nil, candidateBundle: candidate))
        }
        func unpack() throws {
            // Model the genuine old-helper stop-only boundary and protected actual-descriptor binding.
            _ = try base.hook(.prermUpgrade)
            var state = try XCTUnwrap(base.engine.readPackageState())
            state.incoming = incoming
            state.phase = .awaitingUnpack
            try base.engine.writePackageState(state)
            try FileManager.default.removeItem(at: base.engine.packagePayload)
            try FileManager.default.copyItem(at: candidate, to: base.engine.packagePayload)
        }
        func configure() throws { _ = try base.hook(.configure, incoming) }
    }

    func testUnpreparedClusterRefusesBeforeAnyServiceStopOrPackageMutation() throws {
        let f = try Fixture(clustered: true)
        let calls = f.base.runner.calls.count
        let state = try f.base.engine.readPackageState()
        XCTAssertThrowsError(try f.preflight())
        XCTAssertEqual(try f.base.engine.readPackageState(), state)
        XCTAssertFalse(
            f.base.runner.calls.dropFirst(calls).contains { $0.contains("disable") || $0.contains("stop") })
        XCTAssertFalse(f.base.runner.running.isEmpty)
        XCTAssertEqual(f.migrations, 0)
    }
    func testPreparedClusterSurvivesIntentBeforeStopAndRemainsHeldUntilExplicitComplete() throws {
        let f = try Fixture(clustered: true)
        try f.prepare()
        XCTAssertTrue(f.base.runner.running.isEmpty)
        XCTAssertTrue(f.base.runner.enabled.isEmpty)
        let intent = try XCTUnwrap(f.base.engine.readLayout17Intent("a"))
        // Re-running the exact phase1 operation after its durable intent/stop boundary is safe.
        try f.prepare()
        XCTAssertEqual(try f.base.engine.readLayout17Intent("a"), intent)
        try f.preflight()
        try f.unpack()
        try f.configure()
        XCTAssertEqual(f.migrations, 1)
        XCTAssertTrue(f.base.runner.running.isEmpty)
        XCTAssertTrue(f.base.runner.enabled.isEmpty)
        XCTAssertThrowsError(try f.base.engine.packageRuntimeGuard("a"))
        XCTAssertThrowsError(try f.base.engine.start(f.base.options()))
        _ = try f.base.engine.completeLayout17(instance: "a")
        XCTAssertNil(try f.base.engine.readLayout17Intent("a"))
        XCTAssertFalse(f.base.runner.running.isEmpty)
        // Crash/retry after intent consumption does not require a permanent completion ledger.
        _ = try f.base.engine.completeLayout17(instance: "a")
        XCTAssertEqual(f.migrations, 1)
    }
    func testCommitted17ReinstallPreservesServiceIntentWithoutMigration() throws {
        for clustered in [false, true] {
            let f = try Fixture(clustered: clustered)
            if clustered { try f.prepare() } else { try f.preflight() }
            try f.unpack()
            try f.configure()
            let running = f.base.runner.running
            let enabled = f.base.runner.enabled
            let hold = try f.base.engine.readLayout17Intent("a")
            XCTAssertEqual(hold != nil, clustered)
            XCTAssertEqual(running.isEmpty, clustered)

            let otherArtifact = SetupPackageCompatibility(
                manifestSHA256: String(repeating: "a", count: 64),
                version: f.incoming.version, arch: f.incoming.arch, canonicalFormats: .current,
                upgrade: .coordinatedMaintenance)
            let otherSemantics = SetupPackageCompatibility(
                manifestSHA256: f.incoming.manifestSHA256,
                version: f.incoming.version, arch: f.incoming.arch, canonicalFormats: .current,
                semanticProfile: "different-semantic-profile", upgrade: .coordinatedMaintenance)
            let relabeledArtifact = SetupPackageCompatibility(
                manifestSHA256: otherArtifact.manifestSHA256,
                version: f.incoming.version, arch: f.incoming.arch, canonicalFormats: .current)
            for declaration in [otherArtifact, otherSemantics, relabeledArtifact] {
                XCTAssertThrowsError(try f.base.hook(.preinst, declaration))
                XCTAssertEqual(try f.base.engine.readPackageState()?.phase, .committed)
                XCTAssertEqual(f.base.runner.running, running)
                XCTAssertEqual(f.base.runner.enabled, enabled)
            }

            _ = try f.base.hook(.preinst, f.incoming)
            XCTAssertEqual(try f.base.engine.readPackageState()?.phase, .awaitingUnpack)
            XCTAssertTrue(f.base.runner.running.isEmpty)
            try f.configure()
            XCTAssertEqual(try f.base.engine.readPackageState()?.phase, .committed)
            XCTAssertEqual(try f.base.engine.readLayout17Intent("a"), hold)
            XCTAssertEqual(f.base.runner.running, running)
            XCTAssertEqual(f.base.runner.enabled, enabled)
            XCTAssertEqual(f.migrations, 1)
            if clustered {
                XCTAssertThrowsError(try f.base.engine.packageRuntimeGuard("a"))
                _ = try f.base.engine.completeLayout17(instance: "a")
                XCTAssertFalse(f.base.runner.running.isEmpty)
            }
        }
    }

    func testCompletionStartFailureAndConsumedIntentRestartRemainRecoverable() throws {
        let f = try Fixture(clustered: true)
        try f.prepare()
        try f.unpack()
        try f.configure()
        f.base.failReadiness = true
        XCTAssertThrowsError(try f.base.engine.completeLayout17(instance: "a"))
        XCTAssertNotNil(try f.base.engine.readLayout17Intent("a"))
        XCTAssertTrue(f.base.runner.running.isEmpty)
        f.base.failReadiness = false
        _ = try f.base.engine.completeLayout17(instance: "a")
        XCTAssertNil(try f.base.engine.readLayout17Intent("a"))
        XCTAssertFalse(f.base.runner.running.isEmpty)
        XCTAssertEqual(f.migrations, 1)
    }
    func testActual17PayloadResumesAfterReader20FailureWithoutOldReaderRollback() throws {
        let f = try Fixture(clustered: true)
        try f.prepare()
        try f.unpack()
        f.failure = "afterFence"
        XCTAssertThrowsError(try f.configure())
        let raised = try XCTUnwrap(CanonicalReaderRequirement.load(root: f.store, ownerUID: tractanda_uid()))
        XCTAssertEqual(raised.minimumReaderLevel, 20)
        XCTAssertThrowsError(try f.original.canonicalFormats.require(raised))
        XCTAssertTrue(f.base.runner.running.isEmpty)
        XCTAssertEqual(try f.base.engine.readPackageState()?.original, f.original)
        f.failure = nil
        try f.configure()
        XCTAssertEqual(f.migrations, 2)
        XCTAssertEqual(try f.base.engine.readPackageState()?.phase, .committed)
        XCTAssertTrue(f.base.runner.running.isEmpty)
    }
    func testStandaloneStoppedServiceAndBootIntentArePreserved() throws {
        let f = try Fixture(clustered: false)
        f.base.runner.running.removeAll()
        let enabled = f.base.runner.enabled
        try f.preflight()
        try f.unpack()
        try f.configure()
        XCTAssertEqual(f.migrations, 1)
        XCTAssertTrue(f.base.runner.running.isEmpty)
        XCTAssertEqual(f.base.runner.enabled, enabled)
        XCTAssertNil(try f.base.engine.readLayout17Intent("a"))
    }
    func testFinite17ConfigureDoesNotPromoteOrReadRetiredStore() throws {
        let f = try Fixture(clustered: false)
        try f.preflight()
        try f.unpack()
        // A retained removed receipt is operational inventory, not permission to re-adopt its
        // data. Model that stopped transaction metadata without creating any retired data root.
        var retired = try InstallationReceipt(
            options: f.base.options("retired"), roots: f.base.engine.roots,
            owner: NSUserName(), release: f.base.engine.packagePayload,
            manifestSHA256: f.original.manifestSHA256)
        retired.state = .removed
        try f.base.engine.writeReceipt(retired)
        var state = try XCTUnwrap(f.base.engine.readPackageState())
        state.instances.append(
            .init(
                name: "retired", originalManifestSHA256: f.original.manifestSHA256,
                wasRunning: false, wasEnabled: false, embeddingWasRunning: false,
                authenticationWasRunning: false))
        try f.base.engine.writePackageState(state)
        try f.configure()
        XCTAssertEqual(f.migrations, 1)
        XCTAssertEqual(try f.base.engine.readReceipt("retired"), retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.indexDirectory))
    }
    func testBeforeFenceFailureLeavesOldFormatReadableAndNoAutomaticRestart() throws {
        let f = try Fixture(clustered: false)
        try f.preflight()
        try f.unpack()
        f.failure = "beforeFence"
        XCTAssertThrowsError(try f.configure())
        let retained = try XCTUnwrap(
            CanonicalReaderRequirement.load(root: f.store, ownerUID: tractanda_uid()))
        XCTAssertEqual(retained.minimumReaderLevel, 18)
        XCTAssertNoThrow(try f.original.canonicalFormats.require(retained))
        XCTAssertTrue(f.base.runner.running.isEmpty)
        f.failure = nil
        try f.configure()
        XCTAssertFalse(f.base.runner.running.isEmpty)
    }
    func testActivationFailureAfterCompletionDoesNotReapplyOldMigrationSnapshot() throws {
        let f = try Fixture(clustered: false)
        try f.preflight()
        try f.unpack()
        f.base.failReadiness = true
        XCTAssertThrowsError(try f.configure())
        XCTAssertEqual(f.migrations, 1)
        let accounts = SystemAccountDirectory()
        var store: ItemStore? = try .openPersonalWorkgroup(root: f.store, accounts: accounts)
        let revision = try store!.withAccess(forUID: tractanda_uid()) {
            try store!.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("post-migration ordinary edit")],
                    operationID: "later-write"))
        }.revision
        store = nil
        f.base.failReadiness = false
        try f.configure()
        XCTAssertEqual(f.migrations, 1)
        store = try .openPersonalWorkgroup(root: f.store, accounts: accounts)
        XCTAssertEqual(
            try store!.withAccess(forUID: tractanda_uid()) { try store!.get(revision.itemID) }, revision)
        store = nil
    }
}
