import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import TractandaCore
@testable import TractandaPeerTransport
@testable import TractandaServer

private final class PeerSocketCloseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func mark() {
        lock.lock()
        closed = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

private actor PeerLeasePause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    func wait(_ entered: XCTestExpectation) async {
        guard !used else { return }
        used = true
        await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

final class PeerSyncRuntimeTests: XCTestCase {
    private func fixture() throws -> PeerServiceFixture {
        try PeerFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(prefix: "s", source: "PeerSyncRuntimeTests", test: name)
        return try PeerServiceFixture(root: root)
    }
    private func coordinator(_ root: URL, _ accounts: PeerServiceFixture.Accounts) async throws
        -> ServiceCoordinator
    {
        try await ServiceCoordinator(
            opening: root, embeddingProviderForTesting: nil,
            requireInitializedStore: true, makeAccountDirectory: { accounts })
    }
    private func admit(_ lease: PeerLogicalExchange.Lease) async throws {
        let control = try PeerExchangeControl(maximumSeconds: 5)
        let declaration = try await lease.advanceCompatibility(.declare, control: control)
        let acknowledgement = try await lease.advanceCompatibility(.accept(declaration), control: control)
        _ = try await lease.advanceCompatibility(.acknowledge(acknowledgement), control: control)
    }
    private func execute(_ lease: PeerLogicalExchange.Lease, _ request: PeerExchangeRequest) async throws
        -> Data
    {
        try await lease.execute(JSON.encode(request), control: PeerExchangeControl(maximumSeconds: 5))
    }

    private func canonicalFacts(_ root: URL) throws -> [String: String] {
        var facts: [String: String] = [:]
        var bytes = 0
        for directory in ["items", "authority/records"] {
            guard
                let scan = FileManager.default.enumerator(
                    at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in scan where ["tractanda", "authority"].contains(file.pathExtension) {
                let metadata = try FileMetadata.read(at: file)
                guard facts.count < 256, metadata.size <= UInt64(8 * 1024 * 1024 - bytes) else {
                    throw TractandaError("resourceLimit", "Tiny canonical facts estimate exceeded.")
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
                facts[id] = kind + ":" + AuthorityRecordCodec.sha256(raw)
            }
        }
        return facts
    }

}
