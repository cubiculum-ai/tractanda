import CTractandaPlatform
import Foundation
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private final class EnrollmentGrowth {
    let path: String
    var succeeded = false
    init(_ path: String) { self.path = path }
}
private func growEnrollmentArtifact(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    let value = Unmanaged<EnrollmentGrowth>.fromOpaque(raw).takeUnretainedValue()
    let fd = open(value.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    if fd >= 0 {
        var byte: UInt8 = 1
        value.succeeded = write(fd, &byte, 1) == 1
        _ = close(fd)
    }
    errno = ENOENT  // An unrelated stale errno must never turn changed bytes into absence.
}

final class PeerEnrollmentArtifactTests: XCTestCase {
    private func root() throws -> URL {
        try AttachmentFixtureCapacity.requireFree()
        return try GuardedFixtureDirectory.create(
            prefix: "e", source: "PeerEnrollmentArtifactTests", test: name)
    }
    private func directory(_ parent: URL, _ name: String) throws -> URL {
        let result = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }
    func testPrivatePublicationPinsParentAndRejectsChangedNameEvenWithEqualBytes() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try directory(root, "parent")
        let moved = root.appendingPathComponent("moved")
        let output = parent.appendingPathComponent("pair")
        let data = Data(repeating: 7, count: 64)
        try PeerEnrollmentFiles.writeExact(data, path: output.path, maximum: 128)
        XCTAssertThrowsError(
            try PeerEnrollmentFiles.writeExact(
                data, path: output.path, maximum: 128,
                afterParentOpenForTesting: {
                    try FileManager.default.moveItem(at: parent, to: moved)
                    _ = try self.directory(root, "parent")
                    try data.write(to: output)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o400], ofItemAtPath: output.path)
                }))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("pair")), data)
        XCTAssertEqual(try Data(contentsOf: output), data)
        try PeerEnrollmentFiles.writeExact(data, path: output.path, maximum: 128)
        XCTAssertThrowsError(
            try PeerEnrollmentFiles.writeExact(Data(repeating: 8, count: 64), path: output.path, maximum: 128)
        )
        XCTAssertEqual(try Data(contentsOf: output), data)
    }
    func testOnlyActualFinalOpenAbsenceIsMissingAndGrowthIsAnError() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(
            try PeerEnrollmentFiles.readPrivate(root.appendingPathComponent("absent").path, maximum: 128))
        XCTAssertThrowsError(
            try PeerEnrollmentFiles.readPrivate(
                root.appendingPathComponent("absent-parent/file").path, maximum: 128))
        let path = root.appendingPathComponent("changing")
        try Data(repeating: 0x5a, count: 36).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let growth = EnrollmentGrowth(path.path)
        var pointer: UnsafeMutableRawPointer?
        var count: UInt32 = 0
        let result = withExtendedLifetime(growth) {
            path.path.withCString {
                tractanda_capture_private_artifact_for_testing(
                    $0, &pointer, &count, 128,
                    growEnrollmentArtifact, Unmanaged.passUnretained(growth).toOpaque())
            }
        }
        let observedErrno = errno
        XCTAssertTrue(growth.succeeded)
        XCTAssertEqual(result, -1)
        XCTAssertEqual(observedErrno, EAGAIN)
        XCTAssertNil(pointer)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try PeerEnrollmentFiles.readPrivate(path.path, maximum: 128)?.count, 37)
    }
    func testAtomicPairExactRetryConflictAndLostAcknowledgmentRetainOneContainer() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try directory(root, "target")
        let prep = try PeerEnrollment.prepareTarget(
            root: target,
            commonStoreID: UUID.makeVersion1().uuidString.lowercased(),
            sourceReplicaID: UUID.makeVersion1().uuidString.lowercased())
        let preparation = root.appendingPathComponent("preparation.json")
        try JSON.encode(prep).write(to: preparation)
        let pair = root.appendingPathComponent("pair.private")
        let first = try NativePeerEnrollment.createPair(
            preparationPath: preparation.path, outputPath: pair.path,
            sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true)
        let bytes = try Data(contentsOf: pair)
        let input = try PeerEnrollmentPairInput.capture(path: pair.path)
        XCTAssertEqual(input.count, bytes.count)
        XCTAssertLessThanOrEqual(bytes.count, 12344)
        XCTAssertEqual(Mirror(reflecting: input).children.count, 0)
        XCTAssertEqual(String(reflecting: input), "PeerEnrollmentPairInput(<redacted>)")
        XCTAssertEqual(
            try NativePeerEnrollment.createPair(
                preparationPath: preparation.path, outputPath: pair.path,
                sourcePeerID: "target", targetPeerID: "source", sourceIsInitiator: true), first)
        XCTAssertEqual(try Data(contentsOf: pair), bytes)
        XCTAssertThrowsError(
            try NativePeerEnrollment.createPair(
                preparationPath: preparation.path, outputPath: pair.path,
                sourcePeerID: "different", targetPeerID: "source", sourceIsInitiator: true))
        let lost = root.appendingPathComponent("lost.private")
        struct Lost: Error {}
        XCTAssertThrowsError(
            try PeerEnrollmentFiles.writeExact(
                bytes, path: lost.path, maximum: 12344,
                afterPublicationForTesting: { throw Lost() }))
        try PeerEnrollmentFiles.writeExact(bytes, path: lost.path, maximum: 12344)
        XCTAssertEqual(try Data(contentsOf: lost), bytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
                $0.hasPrefix(".peer-artifact-")
            }, [])
        let metadata = try FileMetadata.read(at: pair)
        XCTAssertEqual(metadata.type, .regular)
        XCTAssertEqual(metadata.mode & 0o777, 0o400)
    }
}
