import Crypto
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class AttachmentDownloadTests: XCTestCase {
    private var root: URL!
    private var stage: URL { root.appendingPathComponent("stage") }
    private var output: URL { root.appendingPathComponent("original") }
    private var payload: URL { stage.appendingPathComponent("payload") }
    private let storeID = "11111111-1111-1111-8111-111111111111"
    private let bytes = Data((0..<524_301).map { UInt8($0 % 251) })
    private var policy: AttachmentDownloadPolicy {
        AttachmentDownloadPolicy(
            maximumStagedBytes: 8 * 1024 * 1024,
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
    }
    override func setUpWithError() throws {
        try AttachmentFixtureCapacity.requireFree()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tractanda-download-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func binding(_ data: Data? = nil, store: String? = nil) -> DownloadBinding {
        let data = data ?? bytes
        return DownloadBinding(
            storeID: store ?? storeID, objectIdentity: Data("pinned revision/principal".utf8),
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            destination: output.standardizedFileURL.path)
    }
    private func download(
        data: Data? = nil, source: DownloadBinding? = nil,
        hooks: ResumableByteDownload.Hooks = .init(), authorization: () throws -> Void = {},
        offsets: (Int64) -> Void = { _ in }
    ) throws {
        let data = data ?? bytes
        let source = source ?? binding(data)
        try ResumableByteDownload.run(
            binding: source, stage: stage, destination: output, policy: policy, hooks: hooks,
            authorize: authorization,
            read: { offset, limit in
                XCTAssertLessThanOrEqual(limit, 262_144)
                offsets(offset)
                return .init(
                    storeID: source.storeID, offset: offset,
                    data: data.subdata(in: Int(offset)..<min(Int(offset) + limit, data.count)))
            })
    }
    private func interrupt() throws {
        XCTAssertThrowsError(
            try download(
                hooks: .init(afterCheckpoint: { _ in throw TractandaError("disconnected", "Test interruption")
                }))
        ) { XCTAssertEqual(($0 as? TractandaError)?.code, "disconnected") }
        XCTAssertEqual(try Data(contentsOf: payload).count, 262_144)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    private func code(_ expected: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as? TractandaError)?.code, expected, "\($0)") }
    }
    func testInterruptedTransferResumesAtDurableOffsetAndDropsOwnedTail() throws {
        try interrupt()
        let file = try FileHandle(forWritingTo: payload)
        try file.seekToEnd()
        try file.write(contentsOf: Data("uncheckpointed".utf8))
        try file.close()
        var offsets: [Int64] = []
        try download(offsets: { offsets.append($0) })
        XCTAssertEqual(offsets, [262_144, 524_288])
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(try Data(contentsOf: payload), bytes)
    }
    func testCorruptPrefixIsPreservedAndNeverPublished() throws {
        try interrupt()
        let file = try FileHandle(forWritingTo: payload)
        try file.write(contentsOf: Data([255]))
        try file.close()
        code("downloadIntegrity") { try download() }
        XCTAssertEqual(try Data(contentsOf: payload).first, 255)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testShortPayloadAndDifferentStoreCannotResume() throws {
        try interrupt()
        code("downloadBinding") {
            try download(source: binding(store: "22222222-2222-1222-8222-222222222222"))
        }
        let file = try FileHandle(forWritingTo: payload)
        try file.truncate(atOffset: 17)
        try file.close()
        code("downloadIntegrity") { try download() }
        XCTAssertEqual(try Data(contentsOf: payload).count, 17)
    }
    func testCompleteRetriesAndPrepublicationRecheckAuthorization() throws {
        var checks = 0
        code("forbidden") {
            try download(authorization: {
                checks += 1
                if checks == 2 { throw TractandaError("forbidden", "Revoked before publication") }
            })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try download(offsets: { _ in XCTFail("Complete stage must not refetch bytes") })
        code("forbidden") {
            try download(authorization: { throw TractandaError("forbidden", "Revoked after publication") })
        }
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
    func testPostpublicationCrashIsRecoverableWithoutNetworkBytes() throws {
        code("crashed") {
            try download(
                hooks: .init(afterPublication: { throw TractandaError("crashed", "After hard link") }))
        }
        try download(offsets: { _ in XCTFail("Published retry must not refetch bytes") })
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
    func testCapacityUncertaintyRefusalAndQuotaFailBeforeFixtureWrites() throws {
        code("resourceLimit") {
            try download(
                hooks: .init(availableBytes: { throw TractandaError("resourceLimit", "Unknown capacity") }))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        code("resourceLimit") { try download(hooks: .init(availableBytes: { 0 })) }
        var quota = policy
        quota.maximumStagedBytes = 24 * 1024
        code("resourceLimit") {
            try ResumableByteDownload.run(
                binding: binding(), stage: stage, destination: output, policy: quota,
                authorize: {},
                read: { _, _ in
                    XCTFail("Quota must precede fetch")
                    fatalError()
                })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testZeroByteOriginalAndUnrelatedDestinationCollision() throws {
        try download(data: Data(), offsets: { _ in XCTFail("Empty original requires no data reads") })
        XCTAssertEqual(try Data(contentsOf: output), Data())
        try FileManager.default.removeItem(at: output)
        try Data("unrelated".utf8).write(to: output)
        code("downloadCollision") { try download(data: Data()) }
        XCTAssertEqual(try Data(contentsOf: output), Data("unrelated".utf8))
    }
    func testStageSymlinkUnknownFilesAndCompetingOwnerAreRejected() throws {
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: actual)
        XCTAssertThrowsError(try download())
        try FileManager.default.removeItem(at: stage)
        var checked = false
        try download(
            hooks: .init(afterCheckpoint: { _ in
                if !checked {
                    checked = true
                    self.code("downloadBusy") { try self.download() }
                }
            }))
        let unknown = stage.appendingPathComponent("unknown")
        try Data([1]).write(to: unknown)
        code("downloadIntegrity") { try download() }
        XCTAssertEqual(try Data(contentsOf: unknown), Data([1]))
    }
    func testWrongStoreContinuationAndWrongFinalDigestNeverPublish() throws {
        code("downloadIntegrity") {
            try ResumableByteDownload.run(
                binding: binding(), stage: stage, destination: output, policy: policy, authorize: {},
                read: { offset, _ in .init(storeID: Identifier.make(), offset: offset, data: Data([1])) })
        }
        let wrong = Data(repeating: 255, count: bytes.count)
        code("downloadIntegrity") { try download(data: wrong, source: binding()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRetainedFileTamperingDuringRunningTransferIsNotPublished() throws {
        var changed = false
        code("downloadIntegrity") {
            try download(
                hooks: .init(afterCheckpoint: { _ in
                    if !changed {
                        changed = true
                        let file = try FileHandle(forWritingTo: self.payload)
                        try file.write(contentsOf: Data([255]))
                        try file.close()
                    }
                }))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testInitializationCrashNeverPublishesHalfInitializedStage() throws {
        code("crashed") {
            try download(
                hooks: .init(beforeInitializationPublication: {
                    throw TractandaError("crashed", "Initializer")
                }))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        let retained = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".download-init-") }
        XCTAssertEqual(retained.count, 1)
        try download()
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained[0].path))
    }
    func testPayloadPathReplacementDuringAuthorizationCannotPublishUnverifiedBytes() throws {
        var checks = 0
        let retained = stage.appendingPathComponent("verified-retained")
        code("downloadIntegrity") {
            try download(authorization: {
                checks += 1
                if checks == 2 {
                    try FileManager.default.moveItem(at: self.payload, to: retained)
                    try Data("unverified replacement".utf8).write(to: self.payload)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: self.payload.path)
                }
            })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: retained), bytes)
        XCTAssertEqual(try Data(contentsOf: payload), Data("unverified replacement".utf8))
    }
    func testCrashBeforeCheckpointRenameValidatesOldPrefixAndRecoversReservedTemporary() throws {
        code("crashed") {
            try download(
                hooks: .init(beforeCheckpointRename: { _ in
                    throw TractandaError("crashed", "Checkpoint rename")
                }))
        }
        let temporary = stage.appendingPathComponent("checkpoint.next")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        // Also exercise a partial checkpoint write, as SIGKILL may interrupt the write itself.
        let file = try FileHandle(forWritingTo: temporary)
        try file.truncate(atOffset: 7)
        try file.close()
        var offsets: [Int64] = []
        try download(offsets: { offsets.append($0) })
        XCTAssertEqual(offsets.first, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
}
