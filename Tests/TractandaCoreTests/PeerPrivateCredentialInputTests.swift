import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PeerPrivateCredentialInputTests: XCTestCase {
    private func file(_ root: URL) throws -> URL {
        let binding = try PeerExchangeBinding(
            peerID: "test", storeID: id(), localReplicaID: id(), remoteReplicaID: id(),
            pairingID: id(), localIsInitiator: true, configurationDigest: String(repeating: "a", count: 64))
        let credential = try PeerCredential(binding: binding, secret: Array(repeating: 0x5a, count: 32))
        try PeerCredentialStore(
            files: DocumentContentFiles(
                root: root, ownerUID: tractanda_uid(),
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        ).stage(credential)
        return try PeerCredentialStore.path(
            peerID: binding.peerID, configurationDigest: binding.configurationDigest
        )
        .reduce(root) { $0.appendingPathComponent($1) }
    }
    private func id() throws -> String { try UUID.makeVersion1().uuidString.lowercased() }
    func testPrivateCapturePinsBytesRedactsAndPreservesStandardAliases() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "PeerPrivateCredentialInputTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try file(root)
        let original = try Data(contentsOf: path)
        let input = try PeerPrivateCredentialInput.capture(path: path.path)
        XCTAssertEqual(input.count, original.count)
        XCTAssertEqual(
            try PeerPrivateCredentialInput.capture(
                path: path.deletingLastPathComponent().path + "/./" + path.lastPathComponent
            ).count, original.count)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try Data(repeating: 1, count: original.count).write(to: path)
        XCTAssertEqual(
            input.withBytes { $0 }, original, "Later file writes do not change the captured request.")
        XCTAssertEqual(String(reflecting: input), "PeerPrivateCredentialInput(<redacted>)")
        XCTAssertEqual(Mirror(reflecting: input).children.count, 0)
        #if os(macOS)
            XCTAssertEqual(
                try PeerPrivateCredentialInput.checkedPath("/tmp/input.key"), "/private/tmp/input.key")
            XCTAssertEqual(
                try PeerPrivateCredentialInput.checkedPath("/var/tmp/input.key"), "/private/var/tmp/input.key"
            )
        #else
            XCTAssertEqual(try PeerPrivateCredentialInput.checkedPath("/tmp/input.key"), "/tmp/input.key")
            XCTAssertEqual(
                try PeerPrivateCredentialInput.checkedPath("/var/tmp/input.key"), "/var/tmp/input.key")
        #endif
    }
    func testPrivateCaptureRejectsLinksModesFIFOAndMalformedBytesWithoutEcho() throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "PeerPrivateCredentialInputTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try file(root)
        let original = try Data(contentsOf: source)
        func denied(_ path: URL) {
            XCTAssertThrowsError(try PeerPrivateCredentialInput.capture(path: path.path)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerCredentialInput")
                XCTAssertFalse(String(describing: $0).contains("ZZZZZZZZ"))
            }
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        denied(link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: source, to: link)
        denied(source)
        try FileManager.default.removeItem(at: link)
        let parentLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(
            at: parentLink, withDestinationURL: source.deletingLastPathComponent())
        denied(parentLink.appendingPathComponent(source.lastPathComponent))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        denied(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        for data in [Data(), Data(repeating: 0x5a, count: 36), Data(repeating: 0x5a, count: 4097)] {
            try data.write(to: source)
            denied(source)
        }
        try original.write(to: source)
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        denied(fifo)
        denied(root)
    }
    #if os(macOS)
        func testMode600WithExtendedACLIsRejected() throws {
            try AttachmentFixtureCapacity.requireFree()
            let root = try GuardedFixtureDirectory.create(
                prefix: "v", source: "PeerPrivateCredentialInputTests", test: name)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = try file(root)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow read", path.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertThrowsError(try PeerPrivateCredentialInput.capture(path: path.path)) {
                XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerCredentialInput")
            }
        }
    #endif
    func testBeginSchemaAndBinaryBoundsAreStrict() throws {
        let operation = try id()
        let origins = [try id()]
        let begin = try NativePeerCredentialRegistration.Begin(
            operationID: operation, permittedOrigins: origins, byteCount: 36)
        XCTAssertEqual(
            try NativePeerCredentialRegistration.Begin.parse(begin.encoded()).operationID, operation)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSON.encode(begin)) as? [String: Any])
        fields["uid"] = 0
        let forged =
            NativePeerCredentialRegistration.prefix + (try JSONSerialization.data(withJSONObject: fields))
        XCTAssertThrowsError(try NativePeerCredentialRegistration.Begin.parse(forged))
        XCTAssertThrowsError(
            try NativePeerCredentialRegistration.Begin(
                operationID: operation, permittedOrigins: origins, byteCount: 4097))
        XCTAssertThrowsError(
            try NativePeerCredentialRegistration.Begin(
                operationID: operation, permittedOrigins: origins + origins, byteCount: 36))
        XCTAssertThrowsError(
            try NativePeerCredentialRegistration.Begin.parse(Data(repeating: 0x5a, count: 16385)))
        XCTAssertThrowsError(try PeerPrivateCredentialInput(bytes: Data(repeating: 0, count: 4097)))
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        XCTAssertEqual(tractanda_private_receive_frame(-1, &pointer, &count, 4096, 1), -1)
        XCTAssertEqual(errno, ETIMEDOUT)
        XCTAssertNil(pointer)
    }
    func testNativeRegistrationRetainsCurrentContextImmutableBytesAndExplicitMissingFileSemantics() throws {
        let root = try GuardedFixtureDirectory.create(
            prefix: "v", source: "PeerPrivateCredentialInputTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PeerIntakeStoreTests.Fixture(directory: root)
        try f.bootstrap()
        let binding = try PeerExchangeBinding(
            peerID: f.context.peerID, storeID: f.storeID,
            localReplicaID: XCTUnwrap(f.receiver.replicaID), remoteReplicaID: f.origin, pairingID: id(),
            localIsInitiator: false, configurationDigest: f.context.configurationDigest)
        let value = try PeerCredential(binding: binding, secret: Array(repeating: 7, count: 32))
        let operation = try id()
        func register(_ credential: PeerCredential, token: String? = nil, operation: String? = nil) throws {
            try f.receiver.withAccess(forUID: f.receiver.ownerUID) {
                try f.receiver.registerNativePeerCredential(
                    credential, permittedOrigins: f.context.permittedOrigins,
                    expectedContextToken: token ?? f.receiver.nativeCredentialRegistrationContext(),
                    operationID: operation ?? id())
            }
        }
        let stale = try f.receiver.withAccess(forUID: f.receiver.ownerUID) {
            try f.receiver.nativeCredentialRegistrationContext()
        }
        try register(value, token: stale, operation: operation)
        XCTAssertThrowsError(try register(value, token: stale, operation: operation)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "operationReviewRequired")
        }
        // Immutable same-generation retry does not depend on operation ID equality.
        try register(value, operation: id())
        let other = try PeerCredential(binding: binding, secret: Array(repeating: 9, count: 32))
        XCTAssertThrowsError(try register(other, operation: operation)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "invalidPeerCredential")
        }
        let path = try PeerCredentialStore.path(
            peerID: binding.peerID, configurationDigest: binding.configurationDigest
        )
        .reduce(f.receiverRoot) { $0.appendingPathComponent($1) }
        try FileManager.default.removeItem(at: path)
        // Explicit missing-file admin registration preserves the existing API semantics.
        try register(other, operation: operation)
        try f.receiver.loadPeerCredential(peerID: binding.peerID).withTLSInput { _, bytes in
            XCTAssertEqual(bytes, Array(repeating: 9, count: 32))
        }
        let digest = AuthorityRecordCodec.sha256(Data("rotation-out-of-scope".utf8))
        let rotated = try PeerCredential(
            binding: .init(
                peerID: binding.peerID, storeID: binding.storeID,
                localReplicaID: binding.localReplicaID, remoteReplicaID: binding.remoteReplicaID,
                pairingID: id(), localIsInitiator: false, configurationDigest: digest),
            secret: Array(repeating: 3, count: 32))
        XCTAssertThrowsError(try register(rotated)) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "managedPeerLifecycleRequired")
        }
        let rotatedPath = try PeerCredentialStore.path(peerID: binding.peerID, configurationDigest: digest)
            .reduce(f.receiverRoot) { $0.appendingPathComponent($1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedPath.path))
        XCTAssertThrowsError(
            try f.receiver.registerNativePeerCredential(
                value, permittedOrigins: f.context.permittedOrigins,
                expectedContextToken: f.receiver.peerIntakeContextToken(), operationID: id()))
        try f.capacity()
    }
}
