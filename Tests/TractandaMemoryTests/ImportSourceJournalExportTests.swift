import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaMemory

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class ImportSourceJournalExportTests: XCTestCase {
    func testJournalReopenRetiresOnlyUnpublishedAtomicStaging() throws {
        let fixture = try MemoryImportFixture()
        let state = try ImportJournalState(
            plan: fixture.plan([fixture.record("note", body: "bounded source")]),
            binding: fixture.transport.binding())
        let journal = try fixture.journal()
        try journal.save(state)
        let staged = journal.directory.appendingPathComponent(".import-state-" + UUID().uuidString)
        try Data("unfinished private write".utf8).write(to: staged)
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        XCTAssertEqual(try journal.load(), state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let unexpected = journal.directory.appendingPathComponent("unexpected.json")
        try Data("unrecognized evidence".utf8).write(to: unexpected)
        XCTAssertEqual(chmod(unexpected.path, 0o600), 0)
        XCTAssertThrowsError(try journal.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: unexpected.path))
    }

    func testPerRecordJournalWritesScaleLinearlyAndNeverRewriteSelectedPlan() throws {
        var measurements: [Int64] = []
        for count in [1, 8] {
            let fixture = try MemoryImportFixture()
            let records = try (0..<count).map {
                try fixture.record("note-\($0)", body: String(repeating: "x", count: 8192))
            }
            let state = try ImportJournalState(
                plan: fixture.plan(records), binding: fixture.transport.binding())
            let journal = try fixture.journal()
            try journal.save(state)
            let planFile = journal.directory.appendingPathComponent("plan.json")
            let originalPlan = try Data(contentsOf: planFile)
            for record in records {
                var progress = state.records[record.sourceID]!
                for step in 0..<4 {
                    progress.events = [
                        ImportDiagnostic(
                            "fixture-progress", "checkpoint \(step)", severity: .information,
                            sourceID: record.sourceID)
                    ]
                    try journal.saveRecord(sourceID: record.sourceID, progress: progress)
                }
            }
            XCTAssertEqual(journal.planWritesForTesting, 1)
            XCTAssertEqual(journal.recordWritesForTesting, 5 * count)
            XCTAssertEqual(try Data(contentsOf: planFile), originalPlan)
            let loaded = try journal.load()
            XCTAssertEqual(loaded.planSHA256, state.planSHA256)
            XCTAssertTrue(loaded.records.values.allSatisfy({ $0.events.first?.message == "checkpoint 3" }))
            measurements.append(journal.bytesWrittenForTesting)
        }
        XCTAssertLessThan(
            measurements[1], measurements[0] * 9,
            "Eight records may write about eight times the payload, never a plan-sized rewrite per other record."
        )
    }

    func testNativeItemAndOriginalExportsHonorCallerReserve() throws {
        let fixture = try MemoryImportFixture()
        let report = try fixture.engine.apply(
            fixture.plan([fixture.record("note", body: "source bytes")]), journal: fixture.journal())
        let id = try XCTUnwrap(report.outcomes.first?.itemID)
        let revision = try fixture.store.get(id)
        let original = try XCTUnwrap(AttachmentDescriptor.descriptors(in: revision.fields).first)
        let itemDestination = fixture.root.appendingPathComponent("unpublished-item")
        XCTAssertThrowsError(
            try ItemDirectoryExport.export(
                client: fixture.client, itemID: id, destination: itemDestination, minimumFreeBytes: .max)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDestination.path))
        let originalDestination = fixture.root.appendingPathComponent("unpublished-original")
        XCTAssertThrowsError(
            try AttachmentFiles.export(
                client: fixture.client, itemID: id, attachmentID: original.attachmentID,
                destination: originalDestination, revisionID: revision.revisionID, minimumFreeBytes: .max)
        ) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalDestination.path))
    }

    func testSecureSourcesRejectEscapesSymlinksChangesAndAggregateBudget() throws {
        let fixture = try MemoryImportFixture()
        let record = try fixture.record("note", body: "source")
        let files = try ImportSourceFiles(root: fixture.source, limits: fixture.limits)
        XCTAssertEqual(try files.list(), ["note.md"])
        XCTAssertEqual(try files.read(relativePath: "note.md", maximumBytes: 64), Data("source".utf8))
        XCTAssertEqual(try files.original(relativePath: "note.md").sha256, record.original.sha256)
        for path in ["../note.md", "/etc/passwd", "nested/../note.md", "./note.md", "nested//note.md"] {
            XCTAssertThrowsError(try files.open(relativePath: path))
        }
        let held = try files.open(relativePath: "note.md")
        try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("note.md"))
        XCTAssertThrowsError(try held.verifyUnchanged())
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("symlink"), withDestinationURL: fixture.root)
        XCTAssertThrowsError(try files.open(relativePath: "symlink/outside"))
        XCTAssertThrowsError(try files.list())
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("symlink"))
        let small = ImportLimits(maximumOriginalBytes: 3, minimumFreeBytes: fixture.limits.minimumFreeBytes)
        XCTAssertThrowsError(try ImportSourceFiles(root: fixture.source, limits: small).list())
        XCTAssertThrowsError(try files.read(relativePath: "note.md", maximumBytes: 2))
    }

    func testSourceChangedSincePreviewAndForbiddenProjectionProduceZeroMutations() throws {
        let fixture = try MemoryImportFixture()
        let record = try fixture.record("note", body: "source")
        let plan = fixture.plan([record])
        try Data("replaced".utf8).write(to: fixture.source.appendingPathComponent("note.md"))
        XCTAssertThrowsError(try fixture.engine.apply(plan, journal: fixture.journal()))
        XCTAssertEqual(fixture.transport.commits, 0)
        var invalid = record
        invalid.projection["permissions"] = .object([:])
        XCTAssertThrowsError(try fixture.plan([invalid]).validate())
        invalid.projection.removeValue(forKey: "permissions")
        invalid.projection["importState"] = .text("complete")
        XCTAssertThrowsError(try fixture.plan([invalid]).validate())
        invalid = record
        invalid.original.mediaType = "text//markdown"
        XCTAssertThrowsError(try fixture.plan([invalid]).validate())
        invalid = record
        invalid.projection["body"] = .integer(1)
        XCTAssertThrowsError(try fixture.plan([invalid]).validate())
        invalid = record
        invalid.metadata[""] = .text("invalid native key retained only in original")
        XCTAssertThrowsError(try fixture.plan([invalid]).validate())
    }

    func testJournalLeasePrivateFilesAndExactPendingPayloadValidation() throws {
        let fixture = try MemoryImportFixture()
        let plan = fixture.plan([try fixture.record("note", body: "source")])
        let journal = try fixture.journal("lease")
        var state = try ImportJournalState(plan: plan, binding: fixture.transport.binding())
        try journal.save(state)
        XCTAssertEqual(try journal.load(), state)
        XCTAssertThrowsError(try ImportJournal(directory: journal.directory, limits: fixture.limits))
        var progress = ImportRecordProgress()
        progress.pendingCommit = CommitRequest(
            classID: "Item", changes: ["body": .text("source")], operationID: "exact")
        progress.pendingCommitBytes = Data("different bytes".utf8)
        state.records["note"] = progress
        XCTAssertThrowsError(try journal.save(state))
        let file = journal.directory.appendingPathComponent("state.json")
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try journal.load())
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: fixture.source.appendingPathComponent("note.md"))
        XCTAssertThrowsError(try journal.load())
        XCTAssertEqual(chmod(fixture.source.path, 0o755), 0)
        XCTAssertThrowsError(try ImportJournal(directory: fixture.source))
    }

    func testReadableExportKeepsOriginalEvidenceNativeFieldsAndLinksWithoutOverwrite() throws {
        let fixture = try MemoryImportFixture()
        let source = "---\nunknown: exact source data\n---\nOriginal body\n"
        let record = try fixture.record(
            "note", body: source,
            links: [ImportLink(originalTarget: "missing.md", targetSourceID: "missing", kind: .missing)],
            metadata: ["unknownExtension": .object(["claim": .text("not authority")])])
        let plan = fixture.plan([record])
        let imported = try fixture.engine.apply(plan, journal: fixture.journal())
        let id = try XCTUnwrap(imported.outcomes.first?.itemID)
        _ = try fixture.revise(id, ["body": .text("Locally edited readable memory")])
        let output = fixture.root.appendingPathComponent("export", isDirectory: true)
        let report = try ImportBundleExport.export(
            client: fixture.client, namespace: plan.namespace, destination: output,
            endpoint: "fixture-local-peer", limits: fixture.limits)
        XCTAssertEqual(report.outcomes.first?.itemID, id)
        let manifest = try JSON.decode(
            ImportExportManifest.self, Data(contentsOf: output.appendingPathComponent("manifest.json")))
        let entry = try XCTUnwrap(manifest.entries.first)
        XCTAssertEqual(entry.sourceID, "note")
        XCTAssertEqual(entry.originalSHA256, record.original.sha256)
        let originalID = try XCTUnwrap(entry.originalAttachmentID)
        let original = output.appendingPathComponent(entry.nativeDirectory + "/" + originalID + ".original")
        XCTAssertEqual(try Data(contentsOf: original), Data(source.utf8))
        let readable = try String(
            contentsOf: output.appendingPathComponent(entry.readablePath), encoding: .utf8)
        XCTAssertTrue(readable.contains("Locally edited readable memory"))
        let native = try JSON.decode(
            Revision.self,
            Data(contentsOf: output.appendingPathComponent(entry.nativeDirectory + "/revision.json")))
        XCTAssertEqual(
            native.fields["importMetadata"]?.map?["unknownExtension"],
            .object(["claim": .text("not authority")]))
        XCTAssertEqual(
            native.fields["importLinks"]?.array?.first?.map?["originalTarget"]?.string, "missing.md")
        XCTAssertTrue(
            manifest.diagnostics.contains(where: {
                $0.code == "okfExportBoundary" && $0.severity == .unsupported
            }))
        let originalManifest = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(
            try ImportBundleExport.export(
                client: fixture.client, namespace: plan.namespace, destination: output,
                endpoint: "fixture-local-peer", limits: fixture.limits))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("manifest.json")), originalManifest)
    }
}
