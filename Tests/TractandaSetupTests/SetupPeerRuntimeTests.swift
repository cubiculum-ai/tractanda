import CTractandaPlatform
import Foundation
import TractandaCore
import XCTest
@testable import TractandaSetup
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class SetupPeerRuntimeTests: XCTestCase {
    private func fixture(_ body: (URL, SetupEngine) throws -> Void) throws {
        let root = try GuardedFixtureDirectory.create(prefix: "u", source: "SetupPeerRuntimeTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = SetupRoots(platform: .macos, software: root.appendingPathComponent("software"),
            configuration: root.appendingPathComponent("configuration"), launchDefinitions: root.appendingPathComponent("jobs"),
            runtime: root.appendingPathComponent("run"), data: root.appendingPathComponent("data"),
            indexes: root.appendingPathComponent("indexes"), commands: root.appendingPathComponent("commands"))
        let engine = SetupEngine(roots: roots, runner: SetupTests.Runner(), rootCheck: { true }, trustedOwnership: false)
        try body(root, engine)
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var size: UInt64 = 0
        while let url = scan.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { size += UInt64(values.fileSize ?? 0) }
        }
        XCTAssertLessThanOrEqual(size, 1024 * 1024)
    }
    private func bytes(listen: Bool = false, sync: Bool = false) throws -> Data {
        try PeerRuntimeConfiguration(listen: listen ? .init(host: "127.0.0.1", port: 48730) : nil,
            synchronization: .init(enabled: sync, intervalSeconds: 300)).encoded()
    }
    private func receipt(_ root: URL, _ engine: SetupEngine) throws -> InstallationReceipt {
        try InstallationReceipt(options: .init(name: "preview", bundle: root), roots: engine.roots,
            owner: "owner", release: root.appendingPathComponent("release"), manifestSHA256: String(repeating: "a", count: 64))
    }

    func testCaptureNormalizesOnceAndRejectsSymlinkFIFOAndOversizedInput() throws {
        try fixture { root, engine in
            let input = root.appendingPathComponent("input.json")
            try Data("{ \"version\": 1 }".utf8).write(to: input)
            let captured = try engine.capturePeerConfiguration(input)
            XCTAssertEqual(captured, try bytes())
            try bytes(listen: true).write(to: input)
            try engine.publishPeerBytes(captured, replacing: nil, instance: "preview", uid: tractanda_uid())
            XCTAssertEqual(try Data(contentsOf: engine.peerConfigurationURL("preview")), captured)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
            XCTAssertThrowsError(try engine.capturePeerConfiguration(link))
            let fifo = root.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try engine.capturePeerConfiguration(fifo))
            try Data(repeating: 32, count: 64 * 1024 + 1).write(to: input)
            XCTAssertThrowsError(try engine.capturePeerConfiguration(input))
            try Data("{\"version\":1,\"privateKey\":\"forbidden\"}".utf8).write(to: input)
            XCTAssertThrowsError(try engine.capturePeerConfiguration(input))
        }
    }
    func testAtomicLeafCustodyDriftHardlinkSymlinkAndExactRemoval() throws {
        try fixture { root, engine in
            let first = try bytes(), next = try bytes(listen: true)
            let target = engine.peerConfigurationURL("preview")
            try engine.publishPeerBytes(first, replacing: nil, instance: "preview", uid: tractanda_uid())
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, tractanda_uid())
            XCTAssertThrowsError(try engine.publishPeerBytes(next, replacing: nil, instance: "preview", uid: tractanda_uid()))
            let link = root.appendingPathComponent("hardlink")
            XCTAssertEqual(linkat(AT_FDCWD, target.path, AT_FDCWD, link.path, 0), 0)
            XCTAssertThrowsError(try engine.publishPeerBytes(next, replacing: first, instance: "preview", uid: tractanda_uid()))
            try FileManager.default.removeItem(at: link)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            XCTAssertThrowsError(try engine.publishPeerBytes(next, replacing: first, instance: "preview", uid: tractanda_uid()))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try engine.publishPeerBytes(next, replacing: first, instance: "preview", uid: tractanda_uid())
            XCTAssertEqual(try Data(contentsOf: target), next)
            XCTAssertThrowsError(try engine.publishPeerBytes(nil, replacing: first, instance: "preview", uid: tractanda_uid()))
            try engine.publishPeerBytes(nil, replacing: next, instance: "preview", uid: tractanda_uid())
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: link)
            XCTAssertThrowsError(try engine.publishPeerBytes(first, replacing: nil, instance: "preview", uid: tractanda_uid()))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".peer-") })
        }
    }
    func testUnsafeParentsAndMutationACLAreRefusedWithoutAdoption() throws {
        try fixture { _, engine in
            let parent = engine.peerConfigurationURL("preview").deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: parent.path)
            XCTAssertThrowsError(try engine.publishPeerBytes(bytes(), replacing: nil, instance: "preview", uid: tractanda_uid()))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            #if os(macOS)
            let user = try SystemAccountDirectory().user(forUID: tractanda_uid()).name
            let result = try FoundationProcessRunner().run("/bin/chmod", ["+a", "user:\(user) allow add_file,delete_child", parent.path], environment: [:])
            guard result.status == 0 else {
                XCTFail("Owned directory ACL setup failed: " + String(result.output.prefix(512)))
                return
            }
            XCTAssertThrowsError(try engine.publishPeerBytes(bytes(), replacing: nil, instance: "preview", uid: tractanda_uid()))
            #endif
            XCTAssertFalse(FileManager.default.fileExists(atPath: engine.peerConfigurationURL("preview").path))
        }
    }
    func testDesiredStateRecoveryPreservesExactOldBytesAndRefusesDrift() throws {
        try fixture { root, engine in
            let old = try bytes(), replacement = try bytes(listen: true)
            var previous = try receipt(root, engine)
            previous.state = .active
            previous.peerRuntimeConfiguration = try .init(path: engine.peerConfigurationURL("preview").path, bytes: old)
            try engine.publishPeerBytes(old, replacing: nil, instance: "preview", uid: tractanda_uid())
            let options = SetupOptions(name: "preview", bundle: root, peerRuntime: .replace(root.appendingPathComponent("input")))
            let change = try engine.preparePeerTransition(previous: previous, options: options, captured: replacement, uid: tractanda_uid())
            var candidate = previous; candidate.state = .preparing
            candidate.peerRuntimeConfiguration = change.desired; candidate.peerRuntimePrevious = change.previous
            try engine.writeReceipt(candidate)
            let decoded = try XCTUnwrap(engine.readReceipt("preview"))
            XCTAssertEqual(decoded.peerRuntimePrevious?.bytes, old)
            try engine.publishPeerBytes(replacement, replacing: old, instance: "preview", uid: tractanda_uid())
            let retry = try engine.preparePeerTransition(previous: decoded, options: .init(name: "preview", bundle: root), captured: nil, uid: tractanda_uid())
            XCTAssertEqual(retry.bytes, replacement)
            XCTAssertThrowsError(try engine.preparePeerTransition(previous: decoded, options: .init(name: "preview", bundle: root, peerRuntime: .disable), captured: nil, uid: tractanda_uid()))
            try engine.restorePeerConfiguration(decoded, uid: tractanda_uid())
            XCTAssertEqual(try Data(contentsOf: engine.peerConfigurationURL("preview")), old)
            XCTAssertThrowsError(try engine.preparePeerTransition(previous: decoded, options: .init(name: "preview", bundle: root), captured: nil, uid: tractanda_uid()))
            _ = try engine.preparePeerTransition(previous: decoded, options: options, captured: replacement, uid: tractanda_uid())
            try Data("drift".utf8).write(to: engine.peerConfigurationURL("preview"))
            XCTAssertThrowsError(try engine.restorePeerConfiguration(decoded, uid: tractanda_uid()))
            XCTAssertEqual(try Data(contentsOf: engine.peerConfigurationURL("preview")), Data("drift".utf8))
        }
    }
    func testDisabledRecoveryAcceptsAlreadyRemovedLeafAndLegacyReceiptRemainsDisabled() throws {
        try fixture { root, engine in
            let old = try bytes()
            var candidate = try receipt(root, engine)
            candidate.peerRuntimeConfiguration = nil
            candidate.peerRuntimePrevious = .init(configuration: try .init(path: engine.peerConfigurationURL("preview").path, bytes: old), bytes: old)
            try engine.publishPeerBytes(old, replacing: nil, instance: "preview", uid: tractanda_uid())
            try engine.publishPeerBytes(nil, replacing: old, instance: "preview", uid: tractanda_uid())
            try engine.writeReceipt(candidate)
            let retry = try engine.preparePeerTransition(previous: candidate,
                options: .init(name: "preview", bundle: root), captured: nil, uid: tractanda_uid())
            XCTAssertNil(retry.desired); XCTAssertNil(retry.currentBytes)
            XCTAssertNoThrow(try engine.verifyPeerConfigurationForLoad(candidate))
            candidate.peerRuntimePrevious = nil; candidate.state = .active
            try engine.writeReceipt(candidate)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: engine.receiptURL("preview"))) as? [String: Any])
            object.removeValue(forKey: "peerRuntimeConfiguration"); object.removeValue(forKey: "peerRuntimePrevious")
            try JSONSerialization.data(withJSONObject: object).write(to: engine.receiptURL("preview"))
            XCTAssertNil(try engine.readReceipt("preview")?.peerRuntimeConfiguration)
        }
    }
    func testReadinessRequiresActualLoadedIdentityFlagsAndAvailableDisabledState() throws {
        try fixture { root, engine in
            var receipt = try receipt(root, engine)
            let disabled = try PeerOperatorRuntimeStatus(state: .disabled, synchronization: .init(state: .disabled))
            XCTAssertNoThrow(try engine.verifyPeerReadiness(receipt, status: disabled))
            XCTAssertThrowsError(try engine.verifyPeerReadiness(receipt, status: .unavailable))
            let configuration = try ManagedPeerConfiguration(path: engine.peerConfigurationURL("preview").path, bytes: bytes())
            receipt.peerRuntimeConfiguration = configuration
            func status(path: String? = nil, digest: String? = nil, listener: Bool = false, sync: Bool = false,
                syncState: PeerSynchronizationStatus.State = .disabled) throws -> PeerOperatorRuntimeStatus {
                try .init(state: .active, configurationPath: path ?? configuration.path,
                    settingsDigest: digest ?? configuration.settingsDigest, synchronizationEnabled: sync,
                    listenerConfigured: listener, synchronization: .init(state: syncState))
            }
            XCTAssertNoThrow(try engine.verifyPeerReadiness(receipt, status: status()))
            for wrong in [try status(path: root.appendingPathComponent("different").path), try status(digest: String(repeating: "f", count: 64)),
                try status(listener: true), try status(sync: true), try status(syncState: .unavailable), disabled] {
                XCTAssertThrowsError(try engine.verifyPeerReadiness(receipt, status: wrong))
            }
            receipt.peerRuntimeConfiguration = try .init(path: configuration.path, bytes: bytes(sync: true))
            let expected = try XCTUnwrap(receipt.peerRuntimeConfiguration)
            XCTAssertNoThrow(try engine.verifyPeerReadiness(receipt, status: .init(state: .active,
                configurationPath: expected.path, settingsDigest: expected.settingsDigest, synchronizationEnabled: true,
                listenerConfigured: false, synchronization: .init(state: .active, activeJobCount: 0, eligibleEdgeCount: 0))))
            let definition = try PropertyListSerialization.propertyList(from: engine.serviceDefinition(receipt), format: nil) as? [String: Any]
            let argv = try XCTUnwrap(definition?["ProgramArguments"] as? [String])
            XCTAssertEqual(Array(argv.suffix(2)), ["--peer-runtime-configuration", expected.path])
            XCTAssertFalse(argv.contains(String(decoding: try bytes(sync: true), as: UTF8.self)))
            XCTAssertThrowsError(try engine.start(.init(name: "preview", bundle: root, peerRuntime: .disable)))
        }
    }
}
