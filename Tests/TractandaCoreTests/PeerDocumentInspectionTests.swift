import Foundation
import XCTest

@testable import TractandaCore

final class PeerDocumentInspectionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let contents: DocumentContentStore
        let reference: DocumentContentReference
    }

    private func fixture(pageCount: Int = 3) throws -> Fixture {
        let root = try GuardedFixtureDirectory.create(
            prefix: "i", source: "PeerDocumentInspectionTests", test: name)
        do {
            let estimatedBytes = UInt64(pageCount) * 4096 + 64 * 1024
            guard estimatedBytes < AttachmentFixtureCapacity.fixtureCapBytes else {
                throw TractandaError("resourceLimit", "Peer inspection fixture exceeds its 32 MiB cap.")
            }
            try AttachmentFixtureCapacity.requireFree(at: root)
            let id = try UUID.makeVersion1().uuidString.lowercased()
            let source = try AttachmentDocumentSource(
                itemID: id, revisionID: id, attachmentID: id,
                sha256: String(repeating: "a", count: 64), byteCount: 128,
                mediaType: "application/pdf")
            let contents = DocumentContentStore(
                root: root, ownerUID: getuid(),
                minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
            let writer = try contents.begin(
                source: source, identity: .init(), maximumWriteBytes: 1024 * 1024)
            for number in 1...pageCount {
                try AttachmentFixtureCapacity.requireFree(at: root)
                try writer.append(
                    DocumentStoredPage(
                        pageNumber: Int64(number), sourceSHA256: source.sha256,
                        status: "failed", failureCode: "syntheticFixture"))
            }
            return Fixture(root: root, contents: contents, reference: try writer.publish())
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func inspectToCompletion(
        _ inspection: DocumentContentFiles.PeerTreeInspection,
        callback: ([String], PeerOriginalFile) throws -> Void = { _, _ in }
    ) throws {
        var resumes = 0
        while !inspection.complete {
            do {
                _ = try inspection.step(
                    budget: PeerOriginalReadBudget(bytes: 1024 * 1024, maximumSteps: 1),
                    synchronize: false, inspect: callback)
            } catch let error as TractandaError where error.code == "peerPayloadVerifying" {
                resumes += 1
            }
            XCTAssertLessThan(resumes, 64, "Tiny saved tree should finish in bounded one-step windows")
        }
    }

    func testPeerInspectionCompletesAcrossOneStepWindowsAndVisitsEachPartOnce() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let inspection = try f.contents.beginPeerInspection(base: f.contents.directory(f.reference.contentID))
        var visits: [[String]: Int] = [:]

        try inspectToCompletion(inspection) { path, file in
            XCTAssertGreaterThan(file.metadata.size, 0)
            visits[path, default: 0] += 1
        }

        XCTAssertTrue(inspection.complete)
        XCTAssertEqual(inspection.count, Int64(visits.count))
        XCTAssertEqual(visits.values.reduce(0, +), visits.count)
        XCTAssertGreaterThanOrEqual(inspection.count, Int64(f.reference.pageCount + 2))
    }

    func testPeerInspectionCallbackCancellationPreservesContinuationAndStablePartCount() throws {
        let f = try fixture(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let base = try f.contents.directory(f.reference.contentID)
        let inspection = try f.contents.beginPeerInspection(base: base)
        var visits: [[String]: Int] = [:]
        var cancelled = false
        XCTAssertThrowsError(
            try inspection.step(
                budget: PeerOriginalReadBudget(
                    bytes: 1024 * 1024, maximumSteps: 32,
                    onStep: {
                        if !cancelled && !visits.isEmpty {
                            cancelled = true
                            throw TractandaError("injectedCancellation", "Stop this inspection window.")
                        }
                    }), synchronize: false,
                inspect: { path, _ in visits[path, default: 0] += 1 }))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(visits.isEmpty, "Cancellation follows a completed file callback")
        XCTAssertEqual(visits.values.reduce(0, +), visits.count)

        try inspectToCompletion(inspection) { path, _ in visits[path, default: 0] += 1 }
        XCTAssertTrue(inspection.complete)
        XCTAssertEqual(visits.values.reduce(0, +), visits.count)
        XCTAssertEqual(inspection.count, Int64(visits.count))

        let fresh = try f.contents.beginPeerInspection(base: base)
        try inspectToCompletion(fresh)
        XCTAssertTrue(fresh.complete)
        XCTAssertEqual(fresh.count, inspection.count)
    }
    func testParkedInspectionKeepsNoDescriptorsAcrossFairWindowsAndRejectsReplacement() throws {
        let f = try fixture(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let base = try f.contents.directory(f.reference.contentID)
        let inspection = try f.contents.beginPeerInspection(base: base, parkable: true)
        var visits: [[String]: Int] = [:]
        var windows = 0
        while !inspection.complete {
            windows += 1
            XCTAssertLessThan(windows, 128)
            do {
                _ = try inspection.step(
                    budget: .init(bytes: 64 * 1024, maximumSteps: 8),
                    synchronize: false,
                    inspect: { path, file in
                        try file.check()
                        visits[path, default: 0] += 1
                    })
            } catch let error as TractandaError where error.code == "peerPayloadVerifying" {}
            XCTAssertFalse(inspection.retainsDirectoryDescriptors)
            XCTAssertLessThanOrEqual(inspection.retainedByteCount, 48 * 1024)
        }
        XCTAssertGreaterThan(windows, 1)
        XCTAssertEqual(visits.values.reduce(0, +), visits.count)
        XCTAssertEqual(inspection.count, Int64(visits.count))
        let stale = try f.contents.beginPeerInspection(base: base, parkable: true)
        let tree = base.reduce(f.root) { $0.appendingPathComponent($1) }
        let moved = tree.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: tree, to: moved)
        try FileManager.default.createDirectory(
            at: tree, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try stale.step(budget: .init(), synchronize: false, inspect: { _, _ in }))
        XCTAssertFalse(stale.retainsDirectoryDescriptors)
    }

}
