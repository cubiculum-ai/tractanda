import Foundation
import XCTest
@testable import TractandaCore

final class PeerVerificationParkingTests: XCTestCase {
    func testEightOfflineHashOwnersDoNotBlockNinthAndReopenedProgressFinishes() throws {
        let root = try GuardedFixtureDirectory.create(prefix: "p", source: "PeerVerificationParkingTests", test: name)
        defer { try? FileManager.default.removeItem(at: root) }
        try AttachmentFixtureCapacity.requireFree(at: root)
        let files = DocumentContentFiles(root: root, ownerUID: getuid(),
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        let payloads = try AttachmentPayloadStore(root: root, ownerUID: getuid(),
            reserveBytes: AttachmentFixtureCapacity.reserveBytes)
        let quota = try StagingByteQuota(root: root, ownerUID: getuid(), maximumBytes: 32 * 1024 * 1024)
        let original = try PeerOriginalTransfer(root: root, ownerUID: getuid(), payloads: payloads,
            quota: quota, reserveBytes: AttachmentFixtureCapacity.reserveBytes)
        let contentID = try UUID.makeVersion1().uuidString.lowercased()
        let base = ["documents", "content", contentID]
        try files.ensurePrivateDirectory(base)
        let bytes = Data((0..<(192 * 1024)).map { UInt8($0 % 251) })
        try files.ensurePrivateDirectory(base + ["pages", "0"])
        let largePath = base + ["pages", "0", "2.json"]
        try files.writeImmutable(bytes, path: largePath, maximumBytes: 256 * 1024)
        let object = PeerPackage.Object(kind: .document, id: contentID, length: bytes.count,
            sha256: AuthorityRecordCodec.sha256(bytes), part: .init(role: .page, level: 0, ordinal: 2))
        let owners = (0..<9).map { _ in UUID().uuidString.lowercased() }
        var offsets: [Int64] = []
        func verify(_ owner: String) throws -> Bool {
            do { return try original.withLogicalVerificationOwner(owner + ":comparison") {
                let real = try files.peerDocumentPartFile(path: largePath, maximumBytes: 256 * 1024)
                let file = PeerOriginalFile(metadata: real.metadata, descriptors: [], read: { offset, count in
                    offsets.append(offset)
                    return try real.read(offset: offset, count: count)
                }, validate: real.check)
                return try original.verifyDocumentPart(file: file, key: "fixed-large", object: object,
                    proofPrefix: nil, whole: true, budget: .init(bytes: 64 * 1024))
            } } catch let error as TractandaError where error.code == "peerPayloadVerifying" { return false }
        }
        for owner in owners.prefix(8) { XCTAssertFalse(try verify(owner)) }
        let parked = original.verificationCountsForTesting()
        XCTAssertEqual(parked.parked, 8)
        XCTAssertEqual(parked.active, 0)
        // A separate healthy object can finish while every other owner is disconnected.
        let small = Data("healthy ninth".utf8)
        try files.ensurePrivateDirectory(base + ["pages", "0"])
        let path = base + ["pages", "0", "1.json"]
        try files.writeImmutable(small, path: path, maximumBytes: 4096)
        let descriptor = PeerPackage.Object(kind: .document, id: contentID, length: small.count,
            sha256: AuthorityRecordCodec.sha256(small), part: .init(role: .page, level: 0, ordinal: 1))
        XCTAssertTrue(try original.withLogicalVerificationOwner(owners[8] + ":comparison") {
            try original.verifyDocumentPart(file: files.peerDocumentPartFile(path: path, maximumBytes: 4096),
                key: "healthy-small", object: descriptor, proofPrefix: nil, whole: true,
                budget: .init(bytes: 64 * 1024))
        })
        offsets = []
        XCTAssertFalse(try verify(owners[0]))
        XCTAssertTrue(try verify(owners[0]))
        XCTAssertEqual(offsets, [64 * 1024, 128 * 1024], "Fair yields reopen at retained hash offsets.")
        XCTAssertTrue(try verify(owners[1]), "Another owner consumes the completed current-process certificate.")
        XCTAssertTrue(try original.withLogicalVerificationOwner(owners[1] + ":comparison") {
            try original.verifyDocumentPart(file: files.peerDocumentPartFile(path: path, maximumBytes: 4096),
                key: "second-new-certificate", object: descriptor, proofPrefix: nil, whole: true,
                budget: .init(bytes: 64 * 1024))
        }, "A completed shared certificate must release the owner's matching parked slot.")
        for owner in owners { original.releaseLogicalVerification(owner) }
        XCTAssertEqual(original.verificationCountsForTesting().parked, 0)
        try AttachmentFixtureCapacity.requireFree(at: root)
    }
}
