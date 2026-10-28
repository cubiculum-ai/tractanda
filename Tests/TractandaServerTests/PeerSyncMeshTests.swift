import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

@MainActor
final class PeerSyncMeshTests: XCTestCase {
    @MainActor private final class Harness {
        let fixture: PeerSyncMeshFixture
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var services: [String: ServiceCoordinator] = [:]
        var responders: [String: PeerServiceRuntime] = [:]
        var listeners: [String: DaemonListener] = [:]
        var connectors: [String: PeerServiceRuntime] = [:]
        var drivers: [String: PeerSyncDriver] = [:]
        private var closed = false
        let next = ["a": "b", "b": "c", "c": "a"]
        init(_ fixture: PeerSyncMeshFixture) async throws {
            self.fixture = fixture
            fixture.releaseWriters()
            do {
                for node in ["a", "b", "c"] {
                    let accounts = try fixture.accountDirectory(for: node)
                    let service = try await ServiceCoordinator(
                        opening: XCTUnwrap(fixture.roots[node]),
                        embeddingProviderForTesting: nil, requireInitializedStore: true,
                        makeAccountDirectory: { accounts })
                    services[node] = service
                    let runtime = try PeerServiceRuntime(
                        configuration: .init(), coordinator: service, group: group)
                    responders[node] = runtime
                    await runtime.refreshNow()
                    await runtime.activate()
                    listeners[node] = try await DaemonListeners.peer(
                        group: group, host: "127.0.0.1", port: 0,
                        initialize: { runtime.install(on: $0) })
                }
                for node in ["a", "b", "c"] {
                    let destination = next[node]!
                    let port = try XCTUnwrap(listeners[destination]?.port)
                    let configuration = try PeerRuntimeConfiguration(peers: [
                        .init(alias: destination, host: "127.0.0.1", port: port)
                    ])
                    var transport = PeerConnectionLimits()
                    transport.connectSeconds = 0.5
                    transport.handshakeSeconds = 3
                    transport.exchange.maximumRequests = 16
                    transport.exchange.sessionSeconds = 20
                    let connector = try PeerServiceRuntime(
                        configuration: configuration, coordinator: services[node]!,
                        group: group, limits: transport)
                    await connector.activate()
                    connectors[node] = connector
                    var limits = PeerSyncLimits()
                    limits.maximumRequests = 24
                    limits.maximumPages = 4
                    limits.maximumChunks = 1
                    limits.maximumSeconds = 10
                    drivers[node] = try PeerSyncDriver(
                        coordinator: services[node]!,
                        binding: XCTUnwrap(fixture.bindings[node + "-" + destination]), limits: limits)
                }
            } catch {
                await close()
                throw error
            }
        }
        func close() async {
            guard !closed else { return }
            closed = true
            for driver in drivers.values { await driver.close() }
            drivers = [:]
            for runtime in connectors.values { await runtime.close() }
            connectors = [:]
            for listener in listeners.values { try? await listener.close() }
            listeners = [:]
            for runtime in responders.values { await runtime.close() }
            responders = [:]
            for service in services.values { await service.close() }
            services = [:]
            try? await group.shutdownGracefully()
        }
        func call(_ node: String, _ method: String, _ arguments: [String: Any]) async throws -> Data {
            let response = try await nativeFixtureResponse(
                XCTUnwrap(services[node]), forUID: fixture.accountDirectory(for: node).human,
                method: method, arguments: JSONSerialization.data(withJSONObject: arguments), callID: "mesh")
            return try NativeMethodResult.unwrap(response, method: method, callID: "mesh")
        }
        func current(_ node: String, _ itemID: String) async throws -> Revision? {
            let result = try JSON.decode(
                JMAPItemGetResponse.self, await call(node, "TractandaItem/get", ["ids": [itemID]]))
            return try result.list.first?.canonicalRevision()
        }
        func commit(_ node: String, _ request: CommitRequest) async throws -> Revision {
            let arguments = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSON.encode(request)) as? [String: Any])
            let receipt = try JSON.decode(
                MutationReceipt.self, await call(node, "TractandaItem/commit", arguments))
            let pinned = try await call(
                node, "TractandaRevision/get", ["ids": [receipt.revisionID]])
            let result = try JSON.decode(JMAPRevisionGetResponse.self, pinned)
            let revision = try XCTUnwrap(result.list.first).canonicalRevision()
            XCTAssertEqual(revision.itemID, receipt.itemID)
            XCTAssertEqual(revision.revisionID, receipt.revisionID)
            return revision
        }
        func round(_ nodes: [String] = ["a", "b", "c"]) async throws -> [PeerSyncDriver.Report] {
            var reports: [PeerSyncDriver.Report] = []
            for node in nodes {
                let report = try await connectors[node]!.synchronize(
                    peerID: next[node]!, driver: drivers[node]!)
                reports.append(report)
                // Real disconnects interrupt metadata, document parts and page acknowledgement.
                await connectors[node]!.closeSynchronizationConnection(peerID: next[node]!)
                try fixture.capacity()
            }
            return reports
        }
    }
    private func canonicalSnapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        var bytes = 0
        for directory in ["items", "authority/records"] {
            guard
                let scan = FileManager.default.enumerator(
                    at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in scan where ["tractanda", "authority"].contains(file.pathExtension) {
                let metadata = try FileMetadata.read(at: file)
                guard result.count < 256, metadata.size <= UInt64(8 * 1024 * 1024 - bytes) else {
                    throw TractandaError("resourceLimit", "Tiny mesh canonical facts cap")
                }
                let raw = try Data(contentsOf: file)
                bytes += raw.count
                let id: String
                let kind: String
                if file.pathExtension == "authority" {
                    let record = try AuthorityRecordCodec.decode(raw).record
                    id = record.recordID
                    kind = record.kind.rawValue
                } else {
                    id = try RecordCodec.decode(raw).revisionID
                    kind = "item"
                }
                result[id] = kind + ":" + AuthorityRecordCodec.sha256(raw)
            }
        }
        return result
    }
    private func documentParts(_ root: URL, reference: DocumentContentReference) throws -> [String: String] {
        let contents = DocumentContentStore(
            root: root, ownerUID: getuid(), minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes))
        let manifest = try contents.peerManifestBytes(reference, budget: .init())
        _ = try contents.validatePeerManifest(manifest, reference: reference)
        let base = try contents.directory(reference.contentID).reduce(root) { $0.appendingPathComponent($1) }
        var parts: [String: String] = [:]
        var bytes = 0
        let scan = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        for case let file as URL in scan {
            let metadata = try FileMetadata.read(at: file)
            guard metadata.type == .regular else { continue }
            guard parts.count < 64, metadata.size <= UInt64(min(2 * 1024 * 1024, 4 * 1024 * 1024 - bytes))
            else {
                throw TractandaError("resourceLimit", "Tiny document parts estimate exceeded")
            }
            let relative = try GuardedFixtureDirectory.relativePath(file, beneath: base)
                .split(separator: "/").map(String.init)
            _ = try PeerPackage.DocumentPart.from(relativePath: relative)
            let raw = try Data(contentsOf: file)
            bytes += raw.count
            parts[relative.joined(separator: "/")] = AuthorityRecordCodec.sha256(raw)
        }
        return parts
    }
    private func seedMetadata(_ fixture: PeerSyncMeshFixture) throws -> Revision {
        let source = try XCTUnwrap(fixture.a)
        let accounts = try fixture.accountDirectory(for: "a")
        let base = try source.withAccess(forUID: accounts.human) {
            try source.commit(
                .init(
                    classID: "Item", changes: ["subject": .text("seed"), "body": .text("base")],
                    operationID: PeerServiceFixture.id())
            ).revision
        }
        return base
    }
    private func seed(_ fixture: PeerSyncMeshFixture) throws -> (Revision, Revision) {
        let source = try XCTUnwrap(fixture.a)
        let accounts = try fixture.accountDirectory(for: "a")
        let base = try seedMetadata(fixture)
        let saved = try source.withAccess(forUID: accounts.human) { () throws -> Revision in
            let pdf = Data("%PDF-1.4\ntiny explicit test source\n".utf8)
            let upload = try source.beginAttachment(
                .init(
                    itemID: base.itemID, expectedRevisionID: base.revisionID,
                    operationID: PeerServiceFixture.id(), filename: "tiny.pdf", mediaType: "application/pdf",
                    byteCount: Int64(pdf.count), sha256: AuthorityRecordCodec.sha256(pdf)))
            let uploadID = try XCTUnwrap(upload.uploadID)
            _ = try source.appendAttachment(uploadID: uploadID, offset: 0, data: pdf)
            let attached = try source.finishAttachment(uploadID: uploadID).revision
            guard
                case .prepared(let snapshot) = try source.prepareAttachmentDocument(
                    itemID: attached.itemID,
                    expectedRevisionID: attached.revisionID, attachmentID: upload.attachment.attachmentID,
                    operationID: PeerServiceFixture.id(), identity: .init())
            else { throw TractandaError("fixture", "Document snapshot missing") }
            let writer = try DocumentContentStore(
                root: fixture.roots["a"]!, ownerUID: getuid(),
                minimumFreeBytes: Int64(PeerFixtureCapacity.reserveBytes)
            ).begin(
                source: snapshot.source,
                identity: .init(), maximumWriteBytes: 1024 * 1024)
            for page in 1...5 {
                try fixture.capacity()
                try writer.append(
                    .init(
                        pageNumber: Int64(page), sourceSHA256: snapshot.source.sha256,
                        status: "failed", failureCode: "tiny-fixture"))
            }
            let prepared = try writer.preparePublication()
            let corpus = try source.prepareAttachmentDocumentCorpus(snapshot, prepared: prepared)
            let result = try source.finishAttachmentDocument(snapshot, prepared: prepared, corpus: corpus)
            return try source.get(result.itemID)
        }
        return (base, saved)
    }
    func testThreeNodesCycleOfflineConcurrentMetadataWritersAndColdIndexRecoveryQuiesce() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(prefix: "h", source: "PeerSyncMeshTests", test: name)
        let fixture = try PeerSyncMeshFixture(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try seedMetadata(fixture)
        let saved = base
        var harness = try await Harness(fixture)
        defer { await harness.close() }
        var initialComplete = false
        var yielded = false
        var initialEdges = Set<Int>()
        for _ in 0..<256 {
            let beforeCuts = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            let reports = try await harness.round()
            yielded = yielded || reports.contains { $0.status == .yielded }
            let currents = try await [
                harness.current("a", base.itemID), harness.current("b", base.itemID),
                harness.current("c", base.itemID),
            ]
            let cuts = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            if cuts != beforeCuts {
                initialEdges.removeAll()
            } else {
                for (index, report) in reports.enumerated() where report.status == .complete {
                    initialEdges.insert(index)
                }
            }
            if currents.allSatisfy({ $0?.revisionID == saved.revisionID }), initialEdges.count == 3,
                cuts[0] == cuts[1], cuts[1] == cuts[2]
            {
                initialComplete = true
                break
            }
        }
        XCTAssertTrue(initialComplete)
        XCTAssertTrue(yielded)
        // Close C's actual TCP endpoint. An owned background B job must fail once, back off,
        // and release its child/job slot while all replicas remain independently writable.
        let offlinePort = try XCTUnwrap(harness.listeners["c"]?.port)
        try await harness.listeners["c"]?.close()
        harness.listeners.removeValue(forKey: "c")
        await harness.drivers["b"]?.close()
        harness.drivers.removeValue(forKey: "b")
        let offlineConfiguration = try PeerRuntimeConfiguration(
            peers: [.init(alias: "c", host: "127.0.0.1", port: offlinePort)],
            synchronization: .init(enabled: true))
        let automatic = try PeerSyncRuntime(
            configuration: offlineConfiguration, coordinator: harness.services["b"]!,
            network: harness.connectors["b"]!)
        defer { await automatic.close() }
        await automatic.activate()
        await automatic.tick(now: 0)
        var backedOff = false
        for _ in 0..<200 {
            if let state = await automatic.schedulingForTesting(peerID: "c"), state.failures == 1 {
                XCTAssertGreaterThanOrEqual(state.next, 4)
                XCTAssertLessThanOrEqual(state.next, 6)
                backedOff = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(backedOff)
        let activeAfterFailure = await automatic.activeJobsForTesting()
        XCTAssertEqual(activeAfterFailure, 0)
        let observed = await automatic.maximumObservedJobs
        XCTAssertLessThanOrEqual(observed, 2)
        await automatic.tick(now: 1)
        let retryState = await automatic.schedulingForTesting(peerID: "c")
        XCTAssertEqual(retryState?.failures, 1, "A heartbeat before the backoff deadline must not redial.")
        await automatic.close()
        // Every independent replica may still author while C is unreachable to its peers.
        let a = try await harness.commit(
            "a",
            .init(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: saved.revisionID, changes: ["subject": .text("A writer")],
                operationID: PeerServiceFixture.id()))
        let b = try await harness.commit(
            "b",
            .init(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: saved.revisionID, changes: ["body": .text("B writer")],
                operationID: PeerServiceFixture.id()))
        let c = try await harness.commit(
            "c",
            .init(
                classID: "Item", changes: ["subject": .text("offline C writer")],
                operationID: PeerServiceFixture.id()))
        for _ in 0..<12 { _ = try await harness.round(["a"]) }
        let offline = try await harness.current("c", base.itemID)
        XCTAssertEqual(offline?.revisionID, saved.revisionID)
        let responderC = try XCTUnwrap(harness.responders["c"])
        harness.listeners["c"] = try await DaemonListeners.peer(
            group: harness.group, host: "127.0.0.1", port: offlinePort,
            initialize: { responderC.install(on: $0) })
        let resumedAutomatic = try PeerSyncRuntime(
            configuration: offlineConfiguration, coordinator: harness.services["b"]!,
            network: harness.connectors["b"]!)
        defer { await resumedAutomatic.close() }
        await resumedAutomatic.activate()
        await resumedAutomatic.tick(now: 0)
        var resumedBackgroundJob = false
        for _ in 0..<2000 {
            let reports = await resumedAutomatic.reportsForTesting()
            if let report = reports["c"] {
                XCTAssertTrue([PeerSyncDriver.Report.Status.complete, .yielded].contains(report.status))
                resumedBackgroundJob = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            resumedBackgroundJob,
            "The actual background owner must make a successful finite attempt after connectivity returns.")
        await resumedAutomatic.close()  // Finite checkpoints survive owned driver shutdown/recreation.
        var resumedLimits = PeerSyncLimits()
        resumedLimits.maximumRequests = 24
        resumedLimits.maximumPages = 4
        resumedLimits.maximumChunks = 1
        resumedLimits.maximumSeconds = 10
        harness.drivers["b"] = try PeerSyncDriver(
            coordinator: harness.services["b"]!,
            binding: XCTUnwrap(fixture.bindings["b-c"]), limits: resumedLimits)
        var converged = false
        var convergedEdges = Set<Int>()
        for _ in 0..<256 {
            let beforeCuts = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            let reports = try await harness.round()
            let currents = try await [
                harness.current("a", base.itemID), harness.current("b", base.itemID),
                harness.current("c", base.itemID),
            ]
            let extra = try await [
                harness.current("a", c.itemID), harness.current("b", c.itemID),
                harness.current("c", c.itemID),
            ]
            let cuts = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            if cuts != beforeCuts {
                convergedEdges.removeAll()
            } else {
                for (index, report) in reports.enumerated() where report.status == .complete {
                    convergedEdges.insert(index)
                }
            }
            if currents.allSatisfy({
                $0?.fields["subject"] == .text("A writer") && $0?.fields["body"] == .text("B writer")
            }),
                extra.allSatisfy({ $0?.revisionID == c.revisionID }), convergedEdges.count == 3,
                cuts[0] == cuts[1], cuts[1] == cuts[2]
            {
                for revision in currents {
                    XCTAssertEqual(
                        Set(try XCTUnwrap(revision?.provenance).frontier), Set([a.revisionID, b.revisionID]))
                }
                converged = true
                break
            }
        }
        XCTAssertTrue(converged)
        let before = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
        var quietComplete = false
        var quietCuts = [0, 0, 0]
        for _ in 0..<256 {
            let reports = try await harness.round()
            XCTAssertEqual(reports.reduce(0) { $0 + $1.packagesCreated }, 0)
            XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
            for (index, report) in reports.enumerated() where report.status == .complete {
                quietCuts[index] += 1
            }
            // One completion can finish a previously partial cut; the next proves a full fresh cut.
            if quietCuts.allSatisfy({ $0 >= 2 }) {
                quietComplete = true
                break
            }
        }
        XCTAssertTrue(
            quietComplete, "A full fresh finite cut must quiesce, not just its first four prefixes.")
        await harness.close()
        // Only derived C index is lost; canonical originals/private proofs/work refs survive.
        try FileManager.default.removeItem(at: fixture.roots["c"]!.appendingPathComponent("index"))
        harness = try await Harness(fixture)
        var recoveredComplete = false
        var recoveredEdges = Set<Int>()
        for _ in 0..<256 {
            let reports = try await harness.round()
            XCTAssertEqual(reports.reduce(0) { $0 + $1.packagesCreated }, 0)
            XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
            for (index, report) in reports.enumerated() where report.status == .complete {
                recoveredEdges.insert(index)
            }
            if recoveredEdges.count == 3 {
                recoveredComplete = true
                break
            }
        }
        XCTAssertTrue(recoveredComplete)
        let restored = try await harness.current("c", base.itemID)
        XCTAssertEqual(restored?.fields["subject"], .text("A writer"))
        XCTAssertEqual(restored?.fields["body"], .text("B writer"))
        XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
        try fixture.capacity()
    }
    func testThreeNodesRelayResumeAndMergeSavedDocumentReferencesThenRebuildQuiescently() async throws {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(prefix: "h", source: "PeerSyncMeshTests", test: name)
        let fixture = try PeerSyncMeshFixture(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let (base, saved) = try seed(fixture)
        let representation = try XCTUnwrap(
            AttachmentDocumentRepresentation.representations(in: saved.fields).first)
        let reference = try XCTUnwrap(representation.content)
        let sourceParts = try documentParts(fixture.roots["a"]!, reference: reference)
        XCTAssertGreaterThanOrEqual(sourceParts.count, 7)
        XCTAssertNotNil(saved.fields["attachments"])
        XCTAssertNotNil(saved.fields["attachmentDocument"])
        var harness = try await Harness(fixture)
        defer { await harness.close() }
        var delivered = false
        var yielded = false
        // C may receive this saved document only through B before its C→A connector is used.
        // Do not require an extra initial quiet epoch before the concurrent edit workload.
        for _ in 0..<256 {
            let reports = try await harness.round(["a", "b"])
            yielded = yielded || reports.contains { $0.status == .yielded }
            XCTAssertFalse(reports.contains { [.repairRequired, .unsupported].contains($0.status) })
            let currents = try await [
                harness.current("a", base.itemID), harness.current("b", base.itemID),
                harness.current("c", base.itemID),
            ]
            if currents.allSatisfy({ $0?.revisionID == saved.revisionID }) {
                delivered = true
                break
            }
        }
        XCTAssertTrue(delivered)
        XCTAssertTrue(yielded)
        for node in ["a", "b", "c"] {
            XCTAssertEqual(try documentParts(fixture.roots[node]!, reference: reference), sourceParts)
        }
        // Preserve the original cheap coupling: independent edits on the item owning the saved document.
        let a = try await harness.commit(
            "a",
            .init(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: saved.revisionID, changes: ["subject": .text("A document writer")],
                operationID: PeerServiceFixture.id()))
        let b = try await harness.commit(
            "b",
            .init(
                action: .revise, itemID: base.itemID,
                expectedRevisionID: saved.revisionID, changes: ["body": .text("B document writer")],
                operationID: PeerServiceFixture.id()))
        var converged = false
        var completedEdges = Set<Int>()
        for _ in 0..<256 {
            let prior = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            let reports = try await harness.round()
            let currents = try await [
                harness.current("a", base.itemID), harness.current("b", base.itemID),
                harness.current("c", base.itemID),
            ]
            let cuts = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
            if cuts != prior {
                completedEdges.removeAll()
            } else {
                for (index, report) in reports.enumerated() where report.status == .complete {
                    completedEdges.insert(index)
                }
            }
            if currents.allSatisfy({
                $0?.fields["subject"] == .text("A document writer")
                    && $0?.fields["body"] == .text("B document writer")
            }),
                completedEdges.count == 3, cuts[0] == cuts[1], cuts[1] == cuts[2]
            {
                for current in currents {
                    let value = try XCTUnwrap(current)
                    XCTAssertEqual(
                        Set(try XCTUnwrap(value.provenance).frontier), Set([a.revisionID, b.revisionID]))
                    XCTAssertEqual(value.fields["attachments"], saved.fields["attachments"])
                    XCTAssertEqual(value.fields["attachmentDocument"], saved.fields["attachmentDocument"])
                }
                converged = true
                break
            }
        }
        XCTAssertTrue(converged)
        for node in ["a", "b", "c"] {
            XCTAssertEqual(try documentParts(fixture.roots[node]!, reference: reference), sourceParts)
        }
        let before = try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }
        var quietCuts = [0, 0, 0]
        for _ in 0..<256 {
            let reports = try await harness.round()
            XCTAssertEqual(reports.reduce(0) { $0 + $1.packagesCreated }, 0)
            XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
            for (index, report) in reports.enumerated() where report.status == .complete {
                quietCuts[index] += 1
            }
            if quietCuts.allSatisfy({ $0 >= 2 }) { break }
        }
        XCTAssertTrue(quietCuts.allSatisfy({ $0 >= 2 }), "Every edge must finish a fresh zero-work cut.")
        await harness.close()
        try FileManager.default.removeItem(at: fixture.roots["c"]!.appendingPathComponent("index"))
        harness = try await Harness(fixture)
        var recoveredEdges = Set<Int>()
        for _ in 0..<256 {
            let reports = try await harness.round()
            XCTAssertEqual(reports.reduce(0) { $0 + $1.packagesCreated }, 0)
            XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
            for (index, report) in reports.enumerated() where report.status == .complete {
                recoveredEdges.insert(index)
            }
            if recoveredEdges.count == 3 { break }
        }
        XCTAssertEqual(recoveredEdges.count, 3)
        let restored = try await harness.current("c", base.itemID)
        XCTAssertEqual(restored?.fields["subject"], .text("A document writer"))
        XCTAssertEqual(restored?.fields["body"], .text("B document writer"))
        XCTAssertEqual(restored?.fields["attachments"], saved.fields["attachments"])
        XCTAssertEqual(restored?.fields["attachmentDocument"], saved.fields["attachmentDocument"])
        XCTAssertEqual(try documentParts(fixture.roots["c"]!, reference: reference), sourceParts)
        XCTAssertEqual(try ["a", "b", "c"].map { try canonicalSnapshot(fixture.roots[$0]!) }, before)
        try fixture.capacity()
    }
}
