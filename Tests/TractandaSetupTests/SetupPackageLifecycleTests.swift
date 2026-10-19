import Crypto
import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaSetup

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Real tiny canonical stores; package payload replacement, privilege and systemd are mocked.
/// These tests do not establish native Linux installation or bundled model inference parity.
final class SetupPackageLifecycleTests: XCTestCase {
    final class Runner: SetupProcessRunning, @unchecked Sendable {
        let definitions: URL
        var running = Set<String>()
        var enabled = Set<String>()
        var calls: [[String]] = []
        var failDisable: String?
        var foreignUnit: String?
        var bootstraps = 0
        init(_ definitions: URL) { self.definitions = definitions }
        func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws
            -> ProcessResult
        {
            calls.append([executable] + arguments)
            if let index = arguments.firstIndex(of: "--bootstrap-store") {
                bootstraps += 1
                try StoreBootstrap.initialize(
                    store: URL(fileURLWithPath: arguments[index + 1]),
                    indexDirectory: URL(fileURLWithPath: arguments[index + 2]),
                    owner: arguments[index + 3], instance: arguments[index + 4])
            }
            guard executable == "/usr/bin/systemctl", let action = arguments.first else {
                return ProcessResult(status: 0)
            }
            if action == "daemon-reload" { return ProcessResult(status: 0) }
            if action == "list-units" || action == "list-unit-files" {
                return ProcessResult(status: 0, output: foreignUnit.map { $0 + " loaded\n" } ?? "")
            }
            let unit = arguments.last!
            if action == "show" {
                let unit = arguments[1]
                let definition = definitions.appendingPathComponent(unit)
                let exists = FileManager.default.fileExists(atPath: definition.path)
                return ProcessResult(
                    status: exists ? 0 : 1,
                    output: "LoadState=" + (exists ? "loaded" : "not-found")
                        + "\nActiveState=" + (running.contains(unit) ? "active" : "inactive")
                        + "\nFragmentPath=" + (exists ? definition.path : "")
                        + "\nDropInPaths=\nNeedDaemonReload=no\nMainPID="
                        + (running.contains(unit) ? "4242" : "0")
                        + "\nUnitFileState=" + (enabled.contains(unit) ? "enabled" : "disabled") + "\n")
            }
            if action == "disable", failDisable == unit {
                return ProcessResult(status: 1, output: "fixture stop refusal")
            }
            switch action {
            case "enable": enabled.insert(unit)
            case "start": running.insert(unit)
            case "stop": running.remove(unit)
            case "disable":
                running.remove(unit)
                enabled.remove(unit)
            default: throw SetupError("Unexpected mocked systemctl command.")
            }
            return ProcessResult(status: 0)
        }
    }

    final class Fixture {
        let engine: SetupEngine
        let runner: Runner
        let root: URL
        var failReadiness = false
        var ownerLive = true
        var ownerTicks: UInt64 = 1
        var denyAuthentication = false
        init(root: URL) throws {
            self.root = root
            let roots = SetupRoots(
                platform: .linux, software: root.appendingPathComponent("p"),
                configuration: root.appendingPathComponent("c"),
                launchDefinitions: root.appendingPathComponent("u"),
                runtime: root.appendingPathComponent("r"),
                data: root.appendingPathComponent("d"), indexes: root.appendingPathComponent("i"),
                commands: root.appendingPathComponent("b"))
            runner = Runner(roots.launchDefinitions)
            engine = SetupEngine(
                roots: roots, runner: runner, rootCheck: { true }, trustedOwnership: false,
                peerStatusCall: { _, _ in
                    try .init(state: .disabled, synchronization: .init(state: .disabled))
                }, readinessCheck: { _, _, _ in })
            engine.packageOwnerIdentity = { [unowned self] in
                SetupPackageOwner(
                    pid: getpid(), startTicks: self.ownerTicks, bootID: "00000000-0000-4000-8000-000000000001"
                )
            }
            engine.packageOwnerIsLive = { [unowned self] owner in
                self.ownerLive && owner.startTicks == self.ownerTicks
            }
            engine.packageAuthenticationReadiness = { [unowned self] _ in
                if self.failReadiness { throw SetupError("fixture authentication readiness failure") }
            }
            engine.packageStartPolicy = { [unowned self] unit in
                !(self.denyAuthentication && unit.contains("-authentication-"))
            }
            var files: [BundleManifest.File] = []
            for path in [
                "bin/tractanda", "bin/tractanda-setup", "bin/tractanda-tui", "bin/tractanda-mcp",
                "bin/tractanda-auth-helper", "lib/runtime", "templates/example", "docs/example",
                "licenses/example", "bin/Tractanda_TractandaWeb.resources/Kanban.html",
            ] {
                let url = engine.packagePayload.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = Data("tiny package fixture".utf8)
                try bytes.write(to: url)
                let mode: UInt16 = path.hasPrefix("bin/tractanda") ? 0o755 : 0o644
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
                files.append(
                    .init(path: path, sha256: Self.digest(bytes), size: UInt64(bytes.count), mode: mode))
            }
            #if arch(arm64)
                let arch = "arm64"
            #else
                let arch = "x86_64"
            #endif
            let manifest = BundleManifest(
                version: "0.1.0-poc.15", platform: "linux", arch: arch,
                files: files, canonicalFormats: .current)
            try JSONEncoder().encode(manifest).write(to: manifestURL)
        }
        static func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        var manifestURL: URL { engine.packagePayload.appendingPathComponent("bundle-manifest.json") }
        func options(_ name: String = "a", selection: SetupOptions.StoreSelection = .unconfigured)
            -> SetupOptions
        {
            SetupOptions(
                name: name, owner: NSUserName(), bundle: engine.packagePayload, storeSelection: selection)
        }
        @discardableResult
        func hook(_ action: SetupPackageArguments.Action, _ declaration: SetupPackageCompatibility? = nil)
            throws -> String
        {
            let descriptor = root.appendingPathComponent("descriptor.json")
            if let declaration {
                try engine.writeProtected(declaration.encoded() + Data([10]), to: descriptor, mode: 0o600)
            }
            return try engine.packageLifecycle(
                .init(action: action, descriptor: declaration == nil ? nil : descriptor, instance: nil))
        }
        func configureFresh() throws {
            _ = try hook(.configure, engine.installedPackageCompatibility())
        }
        func install(_ name: String = "a") throws {
            try engine.install(options(name, selection: .standalone))
        }
        /// A data-only package descriptor is available before mocked dpkg overwrites the manifest.
        func next(_ version: String) throws -> (SetupPackageCompatibility, Data) {
            let old = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))
            let manifest = BundleManifest(
                version: version, platform: old.platform, arch: old.arch,
                files: old.files, canonicalFormats: old.canonicalFormats)
            let bytes = try JSONEncoder().encode(manifest)
            return (
                .init(
                    manifestSHA256: Self.digest(bytes), version: version, arch: old.arch,
                    canonicalFormats: try XCTUnwrap(old.canonicalFormats)), bytes
            )
        }
        func canonicalBytes(_ name: String = "a") throws -> [String: Data] {
            let store = engine.roots.data.appendingPathComponent(name)
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(at: store, includingPropertiesForKeys: [.isRegularFileKey]))
            var files: [String: Data] = [:]
            var total = 0
            while let url = scan.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let bytes = try Data(contentsOf: url)
                    total += bytes.count
                    guard total <= 16 * 1024 * 1024 else {
                        throw SetupError("Tiny canonical fixture exceeded its budget.")
                    }
                    files[String(url.path.dropFirst(store.path.count))] = bytes
                }
            }
            return files
        }

        func requireTinyCapacity() throws {
            var info = statvfs()
            guard statvfs(root.path, &info) == 0, info.f_frsize > 0,
                UInt64(info.f_bavail) >= (10 * 1024 * 1024 * 1024 + 16 * 1024 * 1024) / UInt64(info.f_frsize)
            else { throw SetupError("Cannot preserve the tiny enrollment fixture's genuine reserve.") }
            let scan = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
            var count = 0
            var bytes = 0
            while let url = scan.nextObject() as? URL {
                count += 1
                guard count <= 4096 else { throw SetupError("Tiny fixture exceeded its file budget.") }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
                guard bytes <= 16 * 1024 * 1024 else {
                    throw SetupError("Tiny fixture exceeded its byte budget.")
                }
            }
        }

        struct Enrollment {
            let source: ItemStore
            let sourceRoot: URL
            let preparation: PeerEnrollment.Preparation
            let request: PeerEnrollmentApproval.Request
        }
        /// Existing real fresh-source / accepted-target APIs, with no fake activation marker.
        func preparedTarget(activate: Bool) throws -> Enrollment {
            try requireTinyCapacity()
            let accounts = SystemAccountDirectory()
            let account = try accounts.user(forUID: getuid())
            let sourceRoot = root.appendingPathComponent("source")
            let target = engine.roots.data.appendingPathComponent("a")
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let source = try ItemStore.initializeFresh(
                root: sourceRoot, accounts: accounts,
                initialAccessConfiguration: .object([
                    "profile": .text(AccessConfiguration.profile), "users": .list([.text(account.name)]),
                    "administration": .text("system"), "administratorGroup": .text(account.primaryGroupName),
                ]))
            let storeID = try CanonicalReaderRequirement.storeIdentity(root: sourceRoot, ownerUID: getuid())
            let sourceID = try XCTUnwrap(source.replicaID)
            let prep = try PeerEnrollment.prepareTarget(
                root: target, commonStoreID: storeID, sourceReplicaID: sourceID)
            let outbound = try PeerPackage.Context(
                peerID: "target", storeID: storeID,
                configurationDigest: Fixture.digest(Data("source generation".utf8)),
                permittedOrigins: [prep.targetReplicaID])
            let inbound = try PeerPackage.Context(
                peerID: "source", storeID: storeID,
                configurationDigest: Fixture.digest(Data("target generation".utf8)),
                permittedOrigins: [sourceID])
            let pairing = try UUID.makeVersion1().uuidString.lowercased()
            let request = try PeerEnrollmentApproval.Request(
                operationID: UUID.makeVersion1().uuidString.lowercased(),
                preparationBytes: JSON.encode(prep), sourceContext: outbound, targetContext: inbound,
                sourceCredential: .init(
                    binding: .init(
                        peerID: outbound.peerID, storeID: storeID,
                        localReplicaID: sourceID, remoteReplicaID: prep.targetReplicaID, pairingID: pairing,
                        localIsInitiator: true, configurationDigest: outbound.configurationDigest),
                    secret: Array(0..<32)),
                targetCredential: .init(
                    binding: .init(
                        peerID: inbound.peerID, storeID: storeID,
                        localReplicaID: prep.targetReplicaID, remoteReplicaID: sourceID, pairingID: pairing,
                        localIsInitiator: false, configurationDigest: inbound.configurationDigest),
                    secret: Array(0..<32)))
            let result = Enrollment(
                source: source, sourceRoot: sourceRoot, preparation: prep, request: request)
            guard activate else { return result }
            let handle = try source.beginPeerEnrollment(request, forUID: getuid())
            var ready = false
            for _ in 0..<256 {
                try requireTinyCapacity()
                if try source.stepPeerEnrollment(
                    handle, forUID: getuid(),
                    window: .init(maximumUnits: 16, maximumEdges: 64)
                ).manifest != nil {
                    ready = true
                    break
                }
            }
            guard ready else { throw SetupError("Tiny source baseline did not close.") }
            let accepted = try source.acceptPeerEnrollment(handle, forUID: getuid())
            let material = try source.peerEnrollmentActivationMaterial(handle, forUID: getuid())
            let bootstrap = try AuthorityRecord.list(
                AuthorityRecordCodec.decode(material.proof.approvalBytes).record.payload["bootstrap"])
            let pin = try PeerEnrollmentActivation.Pin(
                sourceReplicaID: sourceID,
                bootstrap: AuthorityBinding(value: XCTUnwrap(bootstrap.first)),
                approval: XCTUnwrap(accepted.approval))
            let session = try PeerEnrollmentActivation.open(
                root: target, material: material, pin: pin, accounts: accounts)
            defer { session.close() }
            var cursor: PeerPackage.ResumeCursor?
            var work = 0
            repeat {
                try requireTinyCapacity()
                let page = try session.resume(
                    packageID: material.baseline.packageID, cursor: cursor, limit: 4)
                for object in page.objects where !object.verifiedComplete {
                    var offset = object.nextOffset
                    while offset < object.descriptor.length {
                        work += 1
                        guard work <= 4096 else {
                            throw SetupError("Tiny enrollment exceeded its work bound.")
                        }
                        let chunk = try source.readPeerEnrollment(
                            handle, object: object.descriptor, offset: offset, forUID: getuid())
                        _ = try session.append(
                            packageID: material.baseline.packageID, object: object.descriptor,
                            offset: offset, bytes: chunk.bytes)
                        offset += chunk.bytes.count
                    }
                }
                if !page.blockedOnIndex { cursor = page.nextCursor }
                if !page.blockedOnIndex && cursor == nil { break }
            } while work <= 4096
            _ = try session.finish()
            try source.registerAcceptedPeerEnrollment(handle, forUID: getuid())
            return result
        }

        func verifyAdoptionAsFixtureCustodian() {
            engine.packagePreparedVerification = { receipt, storeID, replicaID in
                try ItemStore.verifyPreparedReplicaForSetup(
                    root: URL(fileURLWithPath: receipt.store),
                    indexDirectory: URL(fileURLWithPath: receipt.indexDirectory),
                    expectedStoreID: storeID, expectedReplicaID: replicaID)
            }
        }

        /// Real canonical retirement/control intake; no forged disposed flag or replacement ID.
        func disposePreparedTarget(_ enrollment: Enrollment) throws {
            let prep = enrollment.preparation
            let targetRoot = engine.roots.data.appendingPathComponent("a")
            try enrollment.source.withAccess(forUID: getuid()) {
                try enrollment.source.removePeerIntake(
                    peerID: enrollment.request.sourceContext.peerID,
                    retiredOriginIDs: [prep.targetReplicaID],
                    operationID: UUID.makeVersion1().uuidString.lowercased())
            }
            let target = try ItemStore.openInitialized(root: targetRoot)
            var objects: [(PeerPackage.Object, Data)] = []
            let files = try XCTUnwrap(
                FileManager.default.enumerator(at: enrollment.sourceRoot, includingPropertiesForKeys: nil))
            for case let file as URL in files {
                let authority = file.pathExtension == "authority"
                guard authority || file.pathExtension == "tractanda" && file.path.contains("/items/") else {
                    continue
                }
                try requireTinyCapacity()
                let bytes = try Data(contentsOf: file)
                let id =
                    authority
                    ? try AuthorityRecordCodec.decode(bytes).record.recordID
                    : try RecordCodec.decode(bytes).revisionID
                objects.append(
                    (
                        .init(
                            kind: authority ? .authority : .item, id: id, length: bytes.count,
                            sha256: Fixture.digest(bytes)), bytes
                    ))
            }
            let page = try JSON.encode(PeerPackage.Page(objects: objects.map(\.0), children: []))
            let index = PeerPackage.Object(
                kind: .index, id: try UUID.makeVersion1().uuidString.lowercased(),
                length: page.count, sha256: Fixture.digest(page))
            let manifest = PeerPackage.Manifest(
                packageID: try UUID.makeVersion1().uuidString.lowercased(),
                storeID: prep.commonStoreID, root: index)
            let context = enrollment.request.targetContext
            _ = try target.beginPeerIntake(context: context, manifestBytes: JSON.encode(manifest))
            for (object, bytes) in [(index, page)] + objects {
                for offset in stride(from: 0, to: bytes.count, by: object.chunkBytes) {
                    _ = try target.appendPeerObject(
                        context: context, packageID: manifest.packageID, object: object,
                        offset: offset,
                        bytes: Data(bytes[offset..<min(bytes.count, offset + object.chunkBytes)]))
                }
            }
            _ = try target.commitPeerIntake(
                context: context, packageID: manifest.packageID,
                expectedContextToken: target.peerIntakeContextToken())
            XCTAssertThrowsError(try target.peerRuntimeMaterial()) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "localReplicaRetired")
            }
        }
    }

    private var root: URL?
    private func fixture() throws -> Fixture {
        let root = try GuardedFixtureDirectory.create(
            prefix: "pkg", source: "SetupPackageLifecycleTests", test: name)
        self.root = root
        return try Fixture(root: root)
    }
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testFreshPackageConfigureNeverSelectsInitializesOrStartsAStore() throws {
        let f = try fixture()
        try f.configureFresh()
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
        XCTAssertEqual(try f.engine.readPackageState()?.instances, [])
        XCTAssertEqual(f.runner.bootstraps, 0)
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertFalse(f.engine.exists(f.engine.roots.data))
        XCTAssertThrowsError(try f.engine.install(f.options()))
        try f.install()
        XCTAssertEqual(f.runner.bootstraps, 1)
        XCTAssertEqual(try f.engine.readReceipt("a")?.state, .active)
    }

    func testOldPrermAndRepeatedPreinstRetainOriginalRunningIntentAndBlockStarts() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let (incoming, _) = try f.next("0.1.0-poc.16")
        _ = try f.hook(.prermUpgrade)
        _ = try f.hook(.prermUpgrade)
        _ = try f.hook(.preinst, incoming)
        _ = try f.hook(.preinst, incoming)
        let state = try XCTUnwrap(f.engine.readPackageState())
        XCTAssertEqual(state.phase, .awaitingUnpack)
        XCTAssertTrue(try XCTUnwrap(state.instances.first).wasRunning)
        XCTAssertTrue(try XCTUnwrap(state.instances.first).wasEnabled)
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertTrue(f.runner.enabled.isEmpty)
        XCTAssertThrowsError(try f.engine.packageRuntimeGuard("a"))
        XCTAssertThrowsError(try f.engine.start(f.options()))
        XCTAssertThrowsError(try f.engine.install(f.options(), upgrade: true))
    }

    func testCompatibleConfigureRestartsAutomaticallyAndRetryDoesNotRecaptureIntent() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let before = try f.canonicalBytes()
        let (incoming, bytes) = try f.next("0.1.0-poc.16")
        _ = try f.hook(.prermUpgrade)
        _ = try f.hook(.preinst, incoming)
        try bytes.write(to: f.manifestURL)  // Mock dpkg unpack, never a Setup payload copy.
        XCTAssertTrue(try f.hook(.configure, incoming).contains("1 verified restart"))
        try f.engine.packageRuntimeGuard("a")
        let starts = f.runner.calls.filter { $0.dropFirst().first == "start" }.count
        _ = try f.hook(.configure, incoming)
        XCTAssertEqual(f.runner.calls.filter { $0.dropFirst().first == "start" }.count, starts)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
        XCTAssertEqual(try f.engine.readReceipt("a")?.manifestSHA256, incoming.manifestSHA256)
        XCTAssertEqual(try f.canonicalBytes(), before)
        XCTAssertEqual(f.runner.bootstraps, 1)
    }

    func testPartialAllInstanceStopFailureRetainsPendingStateAndOriginalPayload() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install("a")
        try f.install("b")
        let digest = try f.engine.sha256(f.manifestURL)
        f.runner.failDisable = f.engine.serviceBackend.name("b")
        XCTAssertThrowsError(try f.hook(.prermUpgrade))
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .failed)
        XCTAssertEqual(try f.engine.readPackageState()?.instances.count, 2)
        XCTAssertFalse(f.runner.running.contains(f.engine.serviceBackend.name("a")))
        XCTAssertTrue(f.runner.running.contains(f.engine.serviceBackend.name("b")))
        XCTAssertEqual(try f.engine.sha256(f.manifestURL), digest)
        XCTAssertThrowsError(try f.engine.packageRuntimeGuard("b"))
        f.runner.failDisable = nil
        _ = try f.hook(.prermUpgrade)
        XCTAssertTrue(f.runner.running.isEmpty)
    }

    func testFailedConfigureKeepsActualProgramAndOlderDebReinstallUsesOriginalIntent() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let originalBytes = try Data(contentsOf: f.manifestURL)
        let original = try f.engine.installedPackageCompatibility()
        let before = try f.canonicalBytes()
        let (incoming, bytes) = try f.next("0.1.0-poc.16")
        _ = try f.hook(.prermUpgrade)
        _ = try f.hook(.preinst, incoming)
        try bytes.write(to: f.manifestURL)
        f.failReadiness = true
        XCTAssertThrowsError(try f.hook(.configure, incoming))
        XCTAssertEqual(try Data(contentsOf: f.manifestURL), bytes)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .failed)
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertTrue(f.runner.enabled.isEmpty)
        XCTAssertThrowsError(try f.engine.packageRuntimeGuard("a"))
        _ = try f.hook(.preinst, original)
        try originalBytes.write(to: f.manifestURL)
        f.failReadiness = false
        _ = try f.hook(.configure, original)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
        XCTAssertTrue(f.runner.running.contains(f.engine.serviceBackend.name("a")))
        XCTAssertEqual(try f.canonicalBytes(), before)
        XCTAssertEqual(f.runner.bootstraps, 1)
    }

    func testRejectedIncomingRetainsObservedFailedPayloadForSubsequentRecovery() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let original = try f.engine.installedPackageCompatibility()
        let (incoming, bytes) = try f.next("0.1.0-poc.16")
        _ = try f.hook(.preinst, incoming)
        try bytes.write(to: f.manifestURL)
        f.failReadiness = true
        XCTAssertThrowsError(try f.hook(.configure, incoming))
        let rejected = SetupPackageCompatibility(
            manifestSHA256: String(repeating: "b", count: 64),
            version: "1.0.0", arch: incoming.arch, canonicalFormats: .legacy)
        XCTAssertThrowsError(try f.hook(.preinst, rejected))
        let state = try XCTUnwrap(f.engine.readPackageState())
        XCTAssertEqual(state.observed?.manifestSHA256, incoming.manifestSHA256)
        XCTAssertEqual(state.incoming, rejected)
        XCTAssertEqual(try f.engine.sha256(f.manifestURL), incoming.manifestSHA256)
        _ = try f.hook(.preinst, original)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .awaitingUnpack)
    }

    func testDeadConfigureOwnerDeniesLaterStartAndRetryRetainsCapturedIntent() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let incoming = try f.engine.installedPackageCompatibility()
        var state = try f.engine.preparePackageUpgrade(incoming: incoming)
        state.phase = .configuring
        state.owner = try f.engine.packageOwnerIdentity()
        state.startupPermitted = ["a"]
        try f.engine.writePackageState(state)
        try f.engine.packageRuntimeGuard("a")
        // The guard does not stop an already-running daemon after SIGKILL; it rejects new starts.
        f.ownerLive = false
        XCTAssertThrowsError(try f.engine.packageRuntimeGuard("a"))
        f.ownerLive = true
        f.ownerTicks = 2  // New configure operation; the persisted owner's birth remains stale.
        _ = try f.hook(.configure, incoming)
        XCTAssertTrue(f.runner.running.contains(f.engine.serviceBackend.name("a")))
        XCTAssertTrue(try XCTUnwrap(f.engine.readPackageState()?.instances.first).wasRunning)
    }

    func testPolicyDeniedAuthenticationLeavesInstanceStoppedWithoutClaimingReadiness() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let (incoming, bytes) = try f.next("0.1.0-poc.16")
        _ = try f.hook(.preinst, incoming)
        try bytes.write(to: f.manifestURL)
        f.denyAuthentication = true
        let result = try f.hook(.configure, incoming)
        XCTAssertTrue(result.contains("1 stopped by policy"))
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
        XCTAssertEqual(try f.engine.readReceipt("a")?.state, .active)
        XCTAssertEqual(f.runner.bootstraps, 1)
    }

    func testPackageRemovalPreservesProgramAndCanonicalBytesAndReinstallDoesNotBootstrap() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let before = try f.canonicalBytes()
        let incoming = try f.engine.installedPackageCompatibility()
        _ = try f.hook(.remove)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .removed)
        XCTAssertEqual(try f.engine.readReceipt("a")?.state, .removed)
        XCTAssertTrue(f.engine.exists(f.manifestURL))  // Only dpkg removes package-owned files.
        XCTAssertEqual(try f.canonicalBytes(), before)
        XCTAssertTrue(f.runner.running.isEmpty)
        _ = try f.hook(.preinst, incoming)
        _ = try f.hook(.configure, incoming)
        XCTAssertEqual(try f.engine.readReceipt("a")?.state, .active)
        XCTAssertEqual(f.runner.bootstraps, 1)
        XCTAssertEqual(try f.canonicalBytes(), before)
    }

    func testPreparedAdoptionVerifierRejectsStandaloneStoreWithoutChangingIdentity() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let receipt = try XCTUnwrap(f.engine.readReceipt("a"))
        let before = try f.canonicalBytes()
        XCTAssertThrowsError(
            try ItemStore.verifyPreparedReplicaForSetup(
                root: URL(fileURLWithPath: receipt.store),
                indexDirectory: URL(fileURLWithPath: receipt.indexDirectory),
                expectedStoreID: "00000000-0000-1000-8000-000000000001",
                expectedReplicaID: "00000000-0000-1000-8000-000000000002"))
        XCTAssertEqual(try f.canonicalBytes(), before)
    }

    func testUnownedManagedUnitBlocksPackageConfigurationAndOverwriteAdmission() throws {
        let f = try fixture()
        f.runner.foreignUnit = "tractanda-server-foreign.service"
        XCTAssertThrowsError(try f.configureFresh())
        XCTAssertNil(try f.engine.readPackageState())
        f.runner.foreignUnit = nil
        try f.configureFresh()
        try f.install()
        f.runner.foreignUnit = "tractanda-server-foreign.service"
        XCTAssertThrowsError(try f.hook(.prermUpgrade))
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
    }

    func testOlderDebCannotReplaceFailedPayloadWhenActualCanonicalFloorHasAdvanced() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let current = try f.engine.installedPackageCompatibility()
        let receipt = try XCTUnwrap(f.engine.readReceipt("a"))
        let store = URL(fileURLWithPath: receipt.store)
        let before = try XCTUnwrap(CanonicalReaderRequirement.load(root: store, ownerUID: getuid()))
        XCTAssertLessThan(before.minimumReaderLevel, 12)
        let olderSupport = CanonicalFormatSupport(
            readerLevel: before.minimumReaderLevel, writerLevel: before.minimumReaderLevel,
            read: before.recordFormats, write: before.recordFormats,
            capabilities: before.capabilities, writeCapabilities: before.capabilities)
        XCTAssertNoThrow(try olderSupport.require(before))
        let oldManifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: f.manifestURL))
        let previousManifest = BundleManifest(
            version: "0.1.0-poc.14", platform: "linux", arch: current.arch,
            files: oldManifest.files, canonicalFormats: olderSupport)
        let older = SetupPackageCompatibility(
            manifestSHA256: Fixture.digest(try JSONEncoder().encode(previousManifest)),
            version: previousManifest.version, arch: current.arch, canonicalFormats: olderSupport)
        let captured = try f.engine.preparePackageUpgrade(incoming: current)
        // Explicit failed-after-unpack recovery fixture: original reader was admitted at the real
        // captured floor, actual bytes now support current, and the original running intent survives.
        var failed = try SetupPackageState(original: older, instances: captured.instances)
        failed.incoming = current
        failed.observed = current
        failed.phase = .failed
        try f.engine.writePackageState(failed)
        try CanonicalReaderRequirement.withWriterLock(root: store, ownerUID: getuid()) {
            try CanonicalReaderRequirement.beforeEnrollmentApprovalPublication(
                root: store, ownerUID: getuid())
        }
        let raised = try XCTUnwrap(CanonicalReaderRequirement.load(root: store, ownerUID: getuid()))
        XCTAssertEqual(raised.minimumReaderLevel, 12)
        XCTAssertThrowsError(try olderSupport.require(raised))
        let canonical = try f.canonicalBytes()
        XCTAssertThrowsError(try f.hook(.preinst, older))
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .failed)
        XCTAssertEqual(try f.engine.readPackageState()?.observed, current)
        XCTAssertEqual(try f.engine.sha256(f.manifestURL), current.manifestSHA256)
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertEqual(try f.canonicalBytes(), canonical)
    }

    func testDifferingSupportRoleRunningOrBootIntentIsRejectedBeforeAnyMutation() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let auth = f.engine.serviceBackend.name("a", role: .authentication)
        for runningDiffers in [true, false] {
            if runningDiffers { f.runner.running.remove(auth) } else { f.runner.enabled.remove(auth) }
            let before = try Data(contentsOf: f.engine.packageStateURL)
            let calls = f.runner.calls.count
            XCTAssertThrowsError(try f.hook(.prermUpgrade))
            XCTAssertEqual(try Data(contentsOf: f.engine.packageStateURL), before)
            XCTAssertFalse(f.runner.calls.dropFirst(calls).contains { $0.dropFirst().first == "disable" })
            f.runner.running.insert(auth)
            f.runner.enabled.insert(auth)
        }
    }

    func testInterruptedOwnedDefinitionPublicationReconcilesDesiredBytesAndRetries() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let incoming = try f.engine.installedPackageCompatibility()
        _ = try f.hook(.preinst, incoming)
        var receipt = try XCTUnwrap(f.engine.readReceipt("a"))
        let file = f.engine.definitionURL("a")
        let desired = try Data(contentsOf: file) + Data("# owned desired definition\n".utf8)
        f.engine.packageDefinitionMutation = { _, _, _ in
            throw SetupError("fixture interrupted after owned write")
        }
        XCTAssertThrowsError(try f.engine.publishPackageDefinition(desired, role: .server, receipt: &receipt))
        let interrupted = try XCTUnwrap(f.engine.readReceipt("a"))
        XCTAssertNotNil(interrupted.packageDefinitions?["server"])
        XCTAssertEqual(try Data(contentsOf: file), desired)
        XCTAssertNotEqual(interrupted.definitionSHA256, Fixture.digest(desired))
        f.engine.packageDefinitionMutation = nil
        _ = try f.hook(.configure, incoming)
        XCTAssertNil(try f.engine.readReceipt("a")?.packageDefinitions)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .committed)
        XCTAssertTrue(f.runner.running.contains(f.engine.serviceBackend.name("a")))
    }

    func testInterruptedDefinitionRecoveryRejectsForeignBytesAndUnintendedAbsence() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let incoming = try f.engine.installedPackageCompatibility()
        _ = try f.hook(.preinst, incoming)
        var receipt = try XCTUnwrap(f.engine.readReceipt("a"))
        let file = f.engine.definitionURL("a")
        let desired = try Data(contentsOf: file) + Data("# desired\n".utf8)
        f.engine.packageDefinitionMutation = { _, _, _ in throw SetupError("fixture write interruption") }
        XCTAssertThrowsError(try f.engine.publishPackageDefinition(desired, role: .server, receipt: &receipt))
        f.engine.packageDefinitionMutation = nil
        try Data("foreign definition\n".utf8).write(to: file)
        XCTAssertThrowsError(try f.hook(.configure, incoming))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "foreign definition\n")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try f.hook(.configure, incoming))
        XCTAssertNotNil(try f.engine.readReceipt("a")?.packageDefinitions?["server"])
        try desired.write(to: file)
        _ = try f.hook(.configure, incoming)
        XCTAssertNil(try f.engine.readReceipt("a")?.packageDefinitions)
    }

    func testInterruptedOwnedRemovalAcceptsOnlyIntendedAbsenceThenCompletesOnRetry() throws {
        let f = try fixture()
        try f.configureFresh()
        try f.install()
        let canonical = try f.canonicalBytes()
        f.engine.packageDefinitionMutation = { _, role, removing in
            if role == .server && removing { throw SetupError("fixture interrupted after owned removal") }
        }
        XCTAssertThrowsError(try f.hook(.remove))
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .failed)
        XCTAssertNotNil(try f.engine.readReceipt("a")?.packageDefinitions?["server"])
        XCTAssertFalse(f.engine.exists(f.engine.definitionURL("a")))
        let foreign = Data("foreign recreation\n".utf8)
        try foreign.write(to: f.engine.definitionURL("a"))
        XCTAssertThrowsError(try f.hook(.remove))
        XCTAssertEqual(try Data(contentsOf: f.engine.definitionURL("a")), foreign)
        try FileManager.default.removeItem(at: f.engine.definitionURL("a"))
        f.engine.packageDefinitionMutation = nil
        _ = try f.hook(.remove)
        XCTAssertEqual(try f.engine.readPackageState()?.phase, .removed)
        XCTAssertEqual(try f.engine.readReceipt("a")?.state, .removed)
        XCTAssertNil(try f.engine.readReceipt("a")?.packageDefinitions)
        XCTAssertTrue(f.runner.running.isEmpty)
        XCTAssertEqual(try f.canonicalBytes(), canonical)
    }

    func testActivatedPreparedAdoptionValidatesRealAuthorityAndPreservesIdentityKeysAndPolicy() throws {
        let f = try fixture()
        try f.configureFresh()
        let enrollment = try f.preparedTarget(activate: true)
        f.verifyAdoptionAsFixtureCustodian()
        let prep = enrollment.preparation
        let target = f.engine.roots.data.appendingPathComponent("a")
        let key = try PeerCredentialStore.path(
            peerID: enrollment.request.targetContext.peerID,
            configurationDigest: enrollment.request.targetContext.configurationDigest
        ).joined(separator: "/")
        let paths = [
            ReplicaIdentity.name, ".tractanda-store-identity.json", PeerEnrollment.intentName,
            PeerEnrollmentActivation.directory + "/request.json",
            PeerEnrollmentActivation.directory + "/activated.json", key,
        ]
        let preserved = try paths.map { try Data(contentsOf: target.appendingPathComponent($0)) }
        let sequence = try AuthorityStore.configurationSequence(root: target)
        let configuration = try AuthorityStore.configuration(
            root: target,
            files: DocumentContentFiles(root: target, ownerUID: getuid(), minimumFreeBytes: 0))
        let wrong = try UUID.makeVersion1().uuidString.lowercased()
        for pins in [(wrong, prep.targetReplicaID), (prep.commonStoreID, wrong)] {
            XCTAssertThrowsError(
                try f.engine.install(f.options(selection: .prepared(storeID: pins.0, replicaID: pins.1))))
            XCTAssertNil(try f.engine.readReceipt("a"))
        }
        try f.engine.install(
            f.options(selection: .prepared(storeID: prep.commonStoreID, replicaID: prep.targetReplicaID)))
        XCTAssertEqual(f.runner.bootstraps, 0)
        let receipt = try XCTUnwrap(f.engine.readReceipt("a"))
        XCTAssertEqual(receipt.state, .active)
        XCTAssertEqual(receipt.preparedStoreID, prep.commonStoreID)
        XCTAssertEqual(receipt.preparedReplicaID, prep.targetReplicaID)
        try f.engine.packageRuntimeGuard("a")
        for (path, bytes) in zip(paths, preserved) {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(path)), bytes)
        }
        XCTAssertEqual(try AuthorityStore.configurationSequence(root: target), sequence)
        XCTAssertEqual(
            try AuthorityStore.configuration(
                root: target,
                files: DocumentContentFiles(root: target, ownerUID: getuid(), minimumFreeBytes: 0)),
            configuration)
        try f.requireTinyCapacity()
    }

    func testPreparedAdoptionRejectsPendingTargetWithoutBootstrapOrIdentityReplacement() throws {
        let f = try fixture()
        try f.configureFresh()
        let enrollment = try f.preparedTarget(activate: false)
        f.verifyAdoptionAsFixtureCustodian()
        let before = try f.canonicalBytes()
        let prep = enrollment.preparation
        XCTAssertThrowsError(
            try f.engine.install(
                f.options(selection: .prepared(storeID: prep.commonStoreID, replicaID: prep.targetReplicaID)))
        )
        XCTAssertEqual(try f.canonicalBytes(), before)
        XCTAssertNil(try f.engine.readReceipt("a"))
        XCTAssertEqual(f.runner.bootstraps, 0)
        XCTAssertTrue(f.runner.running.isEmpty)
    }

    func testPreparedAdoptionRejectsLostActivationProofWithoutRepairingIt() throws {
        let f = try fixture()
        try f.configureFresh()
        let enrollment = try f.preparedTarget(activate: true)
        f.verifyAdoptionAsFixtureCustodian()
        let prep = enrollment.preparation
        let proof = f.engine.roots.data.appendingPathComponent("a").appendingPathComponent(
            PeerEnrollmentActivation.directory + "/activated.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proof.path)
        let invalid = Data("{}".utf8)
        try invalid.write(to: proof)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: proof.path)
        XCTAssertThrowsError(
            try f.engine.install(
                f.options(selection: .prepared(storeID: prep.commonStoreID, replicaID: prep.targetReplicaID)))
        )
        XCTAssertEqual(try Data(contentsOf: proof), invalid)
        XCTAssertNil(try f.engine.readReceipt("a"))
        XCTAssertEqual(f.runner.bootstraps, 0)
    }

    func testPreparedAdoptionRejectsActualCanonicalTargetDisposalAndPreservesEvidence() throws {
        let f = try fixture()
        try f.configureFresh()
        let enrollment = try f.preparedTarget(activate: true)
        try f.disposePreparedTarget(enrollment)
        f.verifyAdoptionAsFixtureCustodian()
        let before = try f.canonicalBytes()
        let prep = enrollment.preparation
        XCTAssertThrowsError(
            try f.engine.install(
                f.options(selection: .prepared(storeID: prep.commonStoreID, replicaID: prep.targetReplicaID)))
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "localReplicaRetired")
        }
        XCTAssertEqual(f.runner.bootstraps, 0)
        XCTAssertNil(try f.engine.readReceipt("a"))
        XCTAssertEqual(try f.canonicalBytes(), before)
    }
}
