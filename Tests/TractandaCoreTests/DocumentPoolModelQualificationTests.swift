import Foundation
import XCTest

@testable import TractandaCore

/// Explicit private qualification only. Ordinary test runs never load a real model.
final class DocumentPoolModelQualificationTests: XCTestCase {
    func testPinnedModelPoolABAEqualsFreshAndUnloadReloads() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TRACTANDA_DOCLING_POOL_QUALIFICATION"] == "1" else {
            throw XCTSkip(
                "Set the explicit pool qualification flag and synthetic fixture inputs to run real inference")
        }
        func input(_ key: String) throws -> URL {
            let path = try XCTUnwrap(env[key], "Missing explicit qualification input \(key)")
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw TractandaError("invalidConfiguration", "Qualification paths must be absolute")
            }
            return URL(fileURLWithPath: path)
        }
        let executable = try input("TRACTANDA_DOCLING_CONVERTER")
        let model = try input("TRACTANDA_DOCLING_MODEL_DIRECTORY")
        let fixtureA = try input("TRACTANDA_DOCLING_FIXTURE_A")
        let fixtureB = try input("TRACTANDA_DOCLING_FIXTURE_B")
        let report = try input("TRACTANDA_DOCLING_POOL_REPORT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path), "Report must be new")
        try AttachmentFixtureCapacity.requireFree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "docling-model-pool-" + Identifier.make())
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFixtureCapacity.makeStore(root: root.appendingPathComponent("store"))
        let executableSHA = try DocumentProcess.executableSHA256(executable.path)
        let config = DocumentConverterConfiguration(
            executablePath: executable.path, modelDirectory: model.path,
            scratchDirectory: root.appendingPathComponent("scratch").path)
        let configID = String(repeating: "c", count: 64)
        func document(_ url: URL, label: String) throws -> DocumentJobMaterialWork {
            let bytes = try Data(contentsOf: url)
            guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024,
                ["pdf", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
            else {
                throw TractandaError(
                    "invalidFixture", "Use bounded synthetic PDF/PNG/JPEG qualification fixtures")
            }
            let media =
                url.pathExtension.lowercased() == "pdf"
                ? "application/pdf"
                : url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            let item = try store.commit(CommitRequest(classID: "Item", operationID: label)).revision
            let upload = try store.beginAttachment(
                AttachmentUploadRequest(
                    itemID: item.itemID, expectedRevisionID: item.revisionID,
                    operationID: label + "-original",
                    filename: url.lastPathComponent, mediaType: media, byteCount: Int64(bytes.count),
                    sha256: PageCorpusInput.digest(bytes)))
            let id = try XCTUnwrap(upload.uploadID)
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + 65_536)
                _ = try store.appendAttachment(
                    uploadID: id, offset: Int64(offset), data: bytes.subdata(in: offset..<end))
                offset = end
            }
            let attached = try store.finishAttachment(uploadID: id).revision
            let job = try store.startDocumentJob(
                DocumentJobStart(
                    itemID: attached.itemID, expectedRevisionID: attached.revisionID,
                    attachmentID: upload.attachment.attachmentID, operationID: label + "-job"),
                identity: .init(), configurationSHA256: configID)
            let claimed = try store.claimDocumentJob(job.jobID, configurationSHA256: configID)
            return try store.documentJobMaterialWork(
                job.jobID,
                generation: claimed.checkpoint.generation, configurationSHA256: configID)
        }
        let a = try document(fixtureA, label: "synthetic-A")
        let b = try document(fixtureB, label: "synthetic-B")
        XCTAssertNotEqual(a.intent.source.sha256, b.intent.source.sha256)
        let files = DocumentContentFiles(
            root: store.root, ownerUID: store.ownerUID,
            minimumFreeBytes: AttachmentFixtureCapacity.reserveBytes)
        struct Sample {
            let pid: Int32
            let binding: NativeDocumentBinding
            let wasLoaded: Bool
            let phases: [String: Int]
            let page: AttachmentDocumentPage
        }
        func sample(_ work: DocumentJobMaterialWork, pool: DocumentWorkerPool?) throws -> Sample {
            let original = try work.verifyOriginal(cancellation: .init())
            let session = try DocumentNativeSession(
                intent: work.intent, original: original,
                configuration: config, expectedExecutableSHA256: executableSHA, files: files,
                root: store.root,
                budgets: DocumentWorkerBudgets(), cancellation: .init(), pool: pool)
            var phases: [String: Int] = [:]
            let stored = try session.convert(1) { phase, _, _ in phases[phase, default: 0] += 1 }
            let page = try XCTUnwrap(stored.page, "Qualification requires a successful parsed first page")
            try session.close()
            return Sample(
                pid: session.workerPID, binding: session.binding,
                wasLoaded: session.modelWasLoadedAtInspection, phases: phases, page: page)
        }
        let pool = try DocumentWorkerPool(idleSeconds: 60)
        do {
            let pooled = [try sample(a, pool: pool), try sample(b, pool: pool), try sample(a, pool: pool)]
            XCTAssertEqual(Set(pooled.map(\.pid)).count, 1)
            XCTAssertEqual(pooled.map(\.wasLoaded), [false, true, true])
            XCTAssertEqual(pooled.map { $0.phases["modelLoad", default: 0] }, [1, 0, 0])
            XCTAssertEqual(Set(pooled.map { $0.binding.sessionID }).count, 3)
            XCTAssertNotEqual(pooled[0].binding.source, pooled[1].binding.source)
            XCTAssertEqual(pooled[0].binding.source, pooled[2].binding.source)
            _ = try await pool.unload()
            let stopped = await pool.status()
            XCTAssertFalse(stopped.workerRunning)
            let reloaded = try sample(a, pool: pool)
            XCTAssertNotEqual(reloaded.pid, pooled[0].pid)
            XCTAssertFalse(reloaded.wasLoaded)
            XCTAssertEqual(reloaded.phases["modelLoad"], 1)
            await pool.shutdown()
            let freshA = try sample(a, pool: nil)
            let freshB = try sample(b, pool: nil)
            XCTAssertEqual(pooled[0].page, freshA.page)
            XCTAssertEqual(pooled[1].page, freshB.page)
            XCTAssertEqual(pooled[2].page, freshA.page)
            XCTAssertEqual(reloaded.page, freshA.page)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            func encoded(_ sample: Sample) throws -> [String: Any] {
                [
                    "workerPID": sample.pid, "jobID": sample.binding.jobID,
                    "sessionID": sample.binding.sessionID,
                    "source": try JSONSerialization.jsonObject(with: encoder.encode(sample.binding.source)),
                    "modelWasLoadedAtInspection": sample.wasLoaded, "phases": sample.phases,
                    "parsedPage": try JSONSerialization.jsonObject(with: encoder.encode(sample.page)),
                ]
            }
            let evidence: [String: Any] = [
                "profile": "tractanda.docling-pool-model-qualification.v1",
                "executableSHA256": executableSHA,
                "converterIdentity": try JSONSerialization.jsonObject(
                    with: encoder.encode(DocumentConverterIdentity())),
                "fixtureASHA256": a.intent.source.sha256, "fixtureBSHA256": b.intent.source.sha256,
                "pooledABA": try pooled.map(encoded), "afterExplicitUnload": try encoded(reloaded),
                "freshA": try encoded(freshA), "freshB": try encoded(freshB),
                "parsedParity": pooled[0].page == freshA.page && pooled[1].page == freshB.page
                    && pooled[2].page == freshA.page && reloaded.page == freshA.page,
            ]
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
                .write(to: report, options: .withoutOverwriting)
        } catch {
            await pool.shutdown()
            throw error
        }
    }
}
