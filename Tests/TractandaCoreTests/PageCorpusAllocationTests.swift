import Foundation
import Synchronization
import XCTest

@testable import TractandaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class PageCorpusAllocationTests: XCTestCase {
    private func entry(
        _ inode: UInt64, kind: PageCorpusAllocationEntry.Kind = .regular,
        logical: Int64 = 1024, blocks: Int64? = 128
    ) -> PageCorpusAllocationEntry {
        PageCorpusAllocationEntry(
            kind: kind, device: 1, inode: inode, logicalBytes: logical, allocatedBlocks: blocks)
    }
    private func root() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
        // Tiny canary/link fixture <64KiB; still require complete16MiB cap and genuine10GiB reserve.
        try PageCorpusSpoolPolicy(maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
            .check(at: parent, additionalBytes: 16 * 1024 * 1024)
        let root = parent.appendingPathComponent("corpus-allocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    func testExtentPreallocationAndDirectoryOverheadRejectWhileLogicalLengthsFit() throws {
        var ledger = PageCorpusAllocation.Ledger()
        try ledger.include(entry(1, kind: .directory, logical: 65536))
        try ledger.include(entry(2, logical: 4096))  // Database preallocated to64KiB.
        try ledger.include(entry(3, logical: 512))  // Receipt uses another64KiB extent.
        XCTAssertEqual(ledger.usage.logicalBytes, 4608)
        XCTAssertEqual(ledger.usage.allocatedBytes, 3 * 65536)
        XCTAssertThrowsError(
            try PageCorpusAllocation.check(
                ledger.usage, maximumBytes: 128 * 1024, additionalBytes: 0, allocationUnit: 65536)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
    }
    func testProspectiveGrowthRoundsAndSparseLogicalLengthRemainsSeparate() throws {
        XCTAssertEqual(try PageCorpusAllocation.rounded(1, allocationUnit: 65536), 65536)
        XCTAssertEqual(try PageCorpusAllocation.rounded(65536, allocationUnit: 65536), 65536)
        XCTAssertEqual(try PageCorpusAllocation.rounded(0, allocationUnit: 65536), 0)
        var ledger = PageCorpusAllocation.Ledger()
        try ledger.include(entry(1, kind: .directory, logical: 4096, blocks: 8))
        // Mock sparse logical file, no allocation.
        try ledger.include(entry(2, logical: 1024 * 1024, blocks: 0))
        XCTAssertEqual(ledger.usage.logicalBytes, 1024 * 1024)
        XCTAssertEqual(ledger.usage.allocatedBytes, 4096)
        XCTAssertThrowsError(
            try PageCorpusAllocation.check(
                ledger.usage, maximumBytes: 128 * 1024, additionalBytes: 0, allocationUnit: 4096))
        XCTAssertEqual(
            try PageCorpusAllocation.check(
                ledger.usage, maximumBytes: 2 * 1024 * 1024, additionalBytes: 1, allocationUnit: 65536), 65536
        )
    }
    func testHardlinkInodeDedupAndUnknownOverflowFailClosed() throws {
        var ledger = PageCorpusAllocation.Ledger()
        let file = entry(2)
        try ledger.include(file)
        try ledger.include(file)
        XCTAssertEqual(ledger.usage.inodeCount, 1)
        XCTAssertEqual(ledger.usage.allocatedBytes, 65536)
        XCTAssertThrowsError(try ledger.include(entry(3, blocks: nil)))
        XCTAssertThrowsError(try ledger.include(entry(3, blocks: -1)))
        XCTAssertThrowsError(try ledger.include(entry(3, blocks: .max)))
        XCTAssertThrowsError(try ledger.include(entry(2, logical: 2000)))
        XCTAssertThrowsError(try ledger.include(entry(3, kind: .symbolicLink, blocks: 0)))
        XCTAssertThrowsError(try PageCorpusAllocation.rounded(.max, allocationUnit: 65536))
        XCTAssertThrowsError(try PageCorpusAllocation.rounded(1, allocationUnit: 0))
    }
    func testMaximumRecordHintRemainsReservationWithoutBecomingOperatorCharge() throws {
        let hint: Int64 = 16 * 1024 * 1024
        let usage = PageCorpusAllocationUsage(logicalBytes: 1024, allocatedBytes: 1024, inodeCount: 1)
        XCTAssertEqual(
            try PageCorpusAllocation.check(
                usage, maximumBytes: 128 * 1024, additionalBytes: 1024, allocationUnit: hint), hint)
        let policy = try PageCorpusSpoolPolicy(
            maximumBytes: 128 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(try policy.reservation(additionalBytes: 1024, allocationUnit: hint), hint)
        let needed = UInt64(policy.minimumFreeBytes + hint)
        XCTAssertThrowsError(try policy.checkAvailable(needed - 1, reservedGrowth: hint))
        XCTAssertNoThrow(try policy.checkAvailable(needed, reservedGrowth: hint))
        XCTAssertThrowsError(try policy.reservation(additionalBytes: 128 * 1024 + 1, allocationUnit: hint))
        XCTAssertThrowsError(try policy.reservation(additionalBytes: 1, allocationUnit: 0))
    }
    func testBoundedEstimateAndActualOverageKeepIndependentPhysicalAndLogicalLimits() throws {
        let cap: Int64 = 128 * 1024
        for usage in [
            PageCorpusAllocationUsage(logicalBytes: 1024, allocatedBytes: cap - 100, inodeCount: 1),
            PageCorpusAllocationUsage(logicalBytes: cap - 100, allocatedBytes: 1024, inodeCount: 1),
        ] {
            XCTAssertThrowsError(
                try PageCorpusAllocation.check(
                    usage, maximumBytes: cap, additionalBytes: 101, allocationUnit: 16 * 1024 * 1024))
        }
        for usage in [
            PageCorpusAllocationUsage(logicalBytes: 1024, allocatedBytes: cap + 1, inodeCount: 1),
            PageCorpusAllocationUsage(logicalBytes: cap + 1, allocatedBytes: 1024, inodeCount: 1),
        ] {
            XCTAssertThrowsError(
                try PageCorpusAllocation.check(
                    usage, maximumBytes: cap, additionalBytes: 0, allocationUnit: 16 * 1024 * 1024))
        }
    }
    func testSharedStagingStillReceivesTheFullRoundedFilesystemReservation() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let unit = try PageCorpusAllocation.allocationUnit(at: root)
        let rounded = try PageCorpusAllocation.rounded(1024, allocationUnit: unit)
        let observed = Mutex<Int64>(-1)
        let policy = try PageCorpusSpoolPolicy(
            maximumBytes: 128 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024,
            availableBytes: { UInt64(10 * 1024 * 1024 * 1024 + rounded) },
            stagingBoundary: { _, growth in observed.withLock { $0 = growth } })
        try policy.check(at: root, additionalBytes: 1024)
        XCTAssertEqual(observed.withLock { $0 }, rounded)
    }
    func testPostWriteLogicalOverageDiscardsOnlyTheOwnedStageBeforePublication() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = root.appendingPathComponent("canary")
        try Data("retain".utf8).write(to: canary)
        let fields: [String: ItemValue] = [
            "itemID": .text(try UUID.makeVersion1().uuidString.lowercased()),
            "revisionID": .text(try UUID.makeVersion1().uuidString.lowercased()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()), "actor": .text("fixture"),
            "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
            "body": .text("tiny body"),
        ]
        let input = try PageCorpusInput(
            storeID: UUID.makeVersion1().uuidString.lowercased(), revision: Revision(fields: fields))
        struct Provider: PageCorpusPageProvider {
            func forEachPage(document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void)
                throws
            {}
        }
        let injected = Mutex(false)
        let policy = try PageCorpusSpoolPolicy(
            maximumBytes: 256 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024,
            stagingBoundary: { directory, growth in
                guard directory != root, growth == 0,
                    injected.withLock({ value in
                        if value { return false }
                        value = true
                        return true
                    })
                else { return }
                // A real bounded post-write sidecar, not a disk-fill or sparse-size heuristic.
                guard
                    FileManager.default.createFile(
                        atPath: directory.appendingPathComponent("owned-sidecar").path,
                        contents: Data(repeating: 0, count: 257 * 1024),
                        attributes: [.posixPermissions: 0o600])
                else { throw TractandaError("fixture", "Cannot create owned sidecar") }
            })
        XCTAssertThrowsError(
            try PageCorpusProjection.prepare(input: input, provider: Provider(), root: root, policy: policy)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertTrue(injected.withLock { $0 })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), ["canary"])
        XCTAssertEqual(try Data(contentsOf: canary), Data("retain".utf8))
    }
    func testDescriptorRelativeScanCountsOwnedAuxiliariesAndDoesNotFollowSymlinks() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(
            at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = stage.appendingPathComponent("projection.sqlite")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let before = try PageCorpusAllocation.usage(at: stage)
        XCTAssertEqual(before.logicalBytes, 3)
        try FileManager.default.linkItem(at: file, to: stage.appendingPathComponent("same-inode-auxiliary"))
        let linked = try PageCorpusAllocation.usage(at: stage)
        XCTAssertEqual(linked.inodeCount, before.inodeCount)
        XCTAssertEqual(linked.logicalBytes, before.logicalBytes)
        let aux = stage.appendingPathComponent("unexpected-owned-sidecar")
        try Data([4]).write(to: aux)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aux.path)
        XCTAssertEqual(try PageCorpusAllocation.usage(at: stage).logicalBytes, 4)
        let canary = root.appendingPathComponent("canary")
        try Data("untouched".utf8).write(to: canary)
        try FileManager.default.createSymbolicLink(
            at: stage.appendingPathComponent("foreign-link"), withDestinationURL: canary)
        XCTAssertThrowsError(try PageCorpusAllocation.usage(at: stage))
        XCTAssertEqual(try Data(contentsOf: canary), Data("untouched".utf8))
        XCTAssertGreaterThan(try PageCorpusAllocation.allocationUnit(at: stage), 0)
    }
    func testCancellationDiscardsOnlyNewPhysicalSpoolAndPreservesCanary() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = root.appendingPathComponent("canary")
        try Data("retain".utf8).write(to: canary)
        let fields: [String: ItemValue] = [
            "itemID": .text(try UUID.makeVersion1().uuidString.lowercased()),
            "revisionID": .text(try UUID.makeVersion1().uuidString.lowercased()), "classID": .text("Item"),
            "schemaVersion": .integer(1), "createdAt": .date(Timestamp.now()),
            "modifiedAt": .date(Timestamp.now()),
            "actor": .text("fixture"), "operationID": .text("fixture"), "requestIdentity": .text("fixture"),
            "body": .text("tiny body"),
        ]
        let input = try PageCorpusInput(
            storeID: UUID.makeVersion1().uuidString.lowercased(), revision: Revision(fields: fields))
        struct Provider: PageCorpusPageProvider {
            func forEachPage(document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void)
                throws
            {
                throw TractandaError("fixture", "No documents expected")
            }
        }
        var boundaries = 0
        XCTAssertThrowsError(
            try PageCorpusProjection.prepare(
                input: input, provider: Provider(), root: root,
                policy: PageCorpusSpoolPolicy(
                    maximumBytes: 16 * 1024 * 1024, minimumFreeBytes: 10 * 1024 * 1024 * 1024),
                boundary: {
                    boundaries += 1
                    if boundaries > 1 { throw CancellationError() }
                }))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(
                \.lastPathComponent), ["canary"])
        XCTAssertEqual(try Data(contentsOf: canary), Data("retain".utf8))
    }
}
