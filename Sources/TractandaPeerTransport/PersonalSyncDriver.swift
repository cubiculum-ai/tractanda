import Foundation
import TractandaCore

package typealias PersonalChunkObserver = @Sendable (PersonalObjectDescriptor, Int64) async throws -> Void

package struct PersonalSyncReport: Codable, Sendable {
    package var revisions = 0
    package var transferredBytes: Int64 = 0
    package var outcomes: [String: Int] = [:]
}

/// Each authenticated endpoint pulls its remote's finite catalogue cut. Missing ancestry
/// is walked once with disposable disk frames, independent of UUID/catalogue order.
package enum PersonalSyncDriver {
    package static func pull(
        connection: PersonalPeerConnection, coordinator: ServiceCoordinator,
        binding: PeerExchangeBinding, afterChunkForTesting: PersonalChunkObserver? = nil
    ) async throws -> PersonalSyncReport {
        var report = PersonalSyncReport()
        var snapshot: String?
        var cursor = try await coordinator.personalPeerLoadCursor(binding)
        var cutRowID: Int64 = 0
        var cutGeneration: String?
        let work = try await coordinator.personalPeerCreateWork(binding)
        do {
            var offset = 0
            while true {
                try Task.checkCancellation()
                var fields: [String: ItemValue] = ["offset": .integer(Int64(offset)), "limit": .integer(128)]
                if let snapshot {
                    fields["snapshotID"] = .text(snapshot)
                } else {
                    fields["afterRowID"] = .integer(cursor.consumedRowID)
                    if let generation = cursor.remoteGenerationID {
                        fields["knownGeneration"] = .text(generation)
                    }
                }
                let page: PersonalInventoryPage = try await remote(connection, "inventory", fields)
                if snapshot == nil {
                    cutRowID = page.cutRowID
                    cutGeneration = page.generationID
                    if cursor.remoteGenerationID == page.generationID, cursor.consumedRowID <= page.cutRowID {
                        offset = Int(exactly: cursor.consumedRowID) ?? 0
                    } else {
                        offset = 0
                    }
                }
                guard !page.generationID.isEmpty, page.generationID.utf8.count <= 200,
                    page.cutRowID >= 0, page.generationID == cutGeneration, page.cutRowID == cutRowID,
                    page.entries.count <= 128, snapshot == nil || snapshot == page.snapshotID,
                    page.complete == (page.nextOffset == nil),
                    page.complete || (page.nextOffset.map { $0 > offset && Int64($0) <= cutRowID } ?? false),
                    page.complete || !page.entries.isEmpty
                else { throw invalid() }
                snapshot = page.snapshotID
                for descriptor in page.entries {
                    try descriptor.validate()
                    guard descriptor.kind == .revision else { throw invalid() }
                    _ = try await coordinator.personalPeerWork(work, .push(.init(descriptor: descriptor)))
                    try await transfer(
                        work, connection: connection, coordinator: coordinator,
                        binding: binding, report: &report, afterChunkForTesting: afterChunkForTesting)
                }
                if page.complete { break }
                offset = page.nextOffset!
            }
            if let snapshot {
                _ = try await connection.request(
                    .init("personal.inventory.close", ["snapshotID": .text(snapshot)])
                ).get()
            }
            cursor.remoteGenerationID = cutGeneration
            cursor.consumedRowID = cutRowID
            try await coordinator.personalPeerSaveCursor(cursor, binding: binding)
            _ = try await coordinator.personalPeerWork(work, .close)
            return report
        } catch {
            _ = try? await coordinator.personalPeerWork(work, .close)
            if let snapshot, connection.isActive {
                _ = try? await connection.request(
                    .init("personal.inventory.close", ["snapshotID": .text(snapshot)])
                ).get()
            }
            throw error
        }
    }

    private static func transfer(
        _ work: PersonalDependencyWorkStack, connection: PersonalPeerConnection,
        coordinator: ServiceCoordinator, binding: PeerExchangeBinding,
        report: inout PersonalSyncReport, afterChunkForTesting: PersonalChunkObserver?
    ) async throws {
        while var frame = try await coordinator.personalPeerWork(work, .peek) {
            try Task.checkCancellation()
            let descriptor = frame.descriptor
            let encoded = try JSON.encode(descriptor)
            switch frame.phase {
            case .bytes:
                let progress: PersonalObjectProgress = try await local(
                    coordinator, binding, "prepare", ["descriptor": .bytes(encoded)])
                guard progress.nextOffset >= 0, progress.nextOffset <= descriptor.byteCount,
                    !progress.complete || progress.nextOffset == descriptor.byteCount
                else { throw invalid() }
                var offset = progress.nextOffset
                while !progress.complete, offset < descriptor.byteCount {
                    try Task.checkCancellation()
                    let count = Int(min(256 * 1024, descriptor.byteCount - offset))
                    let bytes = try await connection.request(
                        .init(
                            "personal.read",
                            [
                                "descriptor": .bytes(encoded), "offset": .integer(offset),
                                "limit": .integer(Int64(count)),
                            ])
                    ).get()
                    guard bytes.count == count else { throw invalid() }
                    let next: PersonalObjectProgress = try await local(
                        coordinator, binding, "append",
                        [
                            "descriptor": .bytes(encoded), "offset": .integer(offset), "bytes": .bytes(bytes),
                        ])
                    // A concurrent idempotent publisher may have finished this exact object.
                    guard
                        next.nextOffset == offset + Int64(count)
                            || (next.complete && next.nextOffset == descriptor.byteCount)
                    else { throw invalid() }
                    offset = next.nextOffset
                    guard report.transferredBytes <= Int64.max - Int64(count) else { throw invalid() }
                    report.transferredBytes += Int64(count)
                    try await afterChunkForTesting?(descriptor, offset)
                }
                frame.phase = .finish
                _ = try await coordinator.personalPeerWork(work, .replace(frame))
            case .dependencies:
                // One dependency per frame step keeps the working set constant even for a
                // very deep reverse-ordered chain; the cursor survives each nested visit.
                let page: PersonalDependencyPage = try await remote(
                    connection, "dependencies",
                    [
                        "descriptor": .bytes(encoded), "offset": .integer(Int64(frame.dependencyOffset)),
                        "limit": .integer(1),
                    ])
                guard page.entries.count <= 1, page.complete == (page.nextOffset == nil),
                    page.complete || page.nextOffset == frame.dependencyOffset + page.entries.count,
                    page.complete || !page.entries.isEmpty
                else { throw invalid() }
                if page.complete { frame.phase = .bytes } else { frame.dependencyOffset = page.nextOffset! }
                _ = try await coordinator.personalPeerWork(work, .replace(frame))
                if let dependency = page.entries.first {
                    try dependency.validate()
                    if dependency.kind == .revision {
                        guard descriptor.kind == .revision,
                            descriptor.parentRevisionIDs.contains(dependency.id)
                        else { throw invalid() }
                        let progress: PersonalObjectProgress = try await local(
                            coordinator, binding, "prepare",
                            [
                                "descriptor": .bytes(JSON.encode(dependency))
                            ])
                        if progress.knownRevision { continue }
                    }
                    _ = try await coordinator.personalPeerWork(work, .push(.init(descriptor: dependency)))
                }
            case .finish:
                let finished: PersonalObjectProgress = try await local(
                    coordinator, binding, "finish", ["descriptor": .bytes(encoded)])
                guard finished.complete, finished.nextOffset == descriptor.byteCount else { throw invalid() }
                if descriptor.kind == .revision {
                    let result: PersonalApplyResult = try await local(
                        coordinator, binding, "apply", ["descriptor": .bytes(encoded)])
                    guard result.revisionID == descriptor.id, result.itemID == descriptor.itemID else {
                        throw invalid()
                    }
                    guard report.revisions < Int.max else { throw invalid() }
                    report.revisions += 1
                    report.outcomes[result.status.rawValue, default: 0] += 1
                }
                _ = try await coordinator.personalPeerWork(work, .pop)
            }
        }
    }
    private static func remote<T: Decodable>(
        _ connection: PersonalPeerConnection, _ operation: String, _ fields: [String: ItemValue]
    ) async throws -> T {
        try JSON.decode(T.self, await connection.request(.init("personal." + operation, fields)).get())
    }
    private static func local<T: Decodable>(
        _ coordinator: ServiceCoordinator, _ binding: PeerExchangeBinding,
        _ operation: String, _ fields: [String: ItemValue]
    ) async throws -> T {
        try JSON.decode(
            T.self,
            await coordinator.personalPeerRequest(binding, request: .init("personal." + operation, fields)))
    }
    private static func invalid() -> TractandaError {
        TractandaError(
            "invalidPeerResponse",
            "Personal synchronization response differs from its finite cut or immutable descriptor.")
    }
}
