import Foundation
import Synchronization
import TractandaClient
import TractandaCore

enum ItemSearchMode: String, Sendable {
    case text = "Text"
    case semantic = "Semantic"
}

struct ItemSearchHit: Decodable, Sendable, Equatable {
    let itemID: String
    let revisionID: String
    let passage: String
    let similarity: Double
}

struct ItemSearchResponse: Decodable, Sendable {
    let queryID: String
    let state: String
    let expiresAt: String
    let retryAfterMilliseconds: Int?
    let partialCoverage: Bool?
    let results: [ItemSearchHit]?
}

/// Only current, authorized revisions enter the report. Keep native ranking and the first passage
/// per item; an old passage must never be attached to a newer item revision.
struct ItemSearchPage: Sendable {
    let items: [TractandaCore.Revision]
    let hits: [String: ItemSearchHit]
    let unresolved: [TractandaCore.ItemUnresolvedState]
    let unhydratedIDs: [String]
    let partialCoverage: Bool
    let omitted: Int
    let currentState: String?

    init(
        response: ItemSearchResponse, current: [TractandaCore.Revision], currentState: String? = nil,
        unresolved: [TractandaCore.ItemUnresolvedState] = [], unhydratedIDs: [String] = []
    ) {
        self.currentState = currentState
        let byID = Dictionary(current.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        let unresolvedByID = Dictionary(
            unresolved.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var items: [TractandaCore.Revision] = []
        var hits: [String: ItemSearchHit] = [:]
        var omitted = 0
        for hit in (response.results ?? []).prefix(ItemSearchLoader.limit) {
            guard !seen.contains(hit.itemID) else { continue }
            if unresolvedByID[hit.itemID] != nil {
                seen.insert(hit.itemID)
                continue
            }
            guard let item = byID[hit.itemID], !item.isDeleted, item.revisionID == hit.revisionID,
                hit.similarity.isFinite
            else {
                omitted += 1
                continue
            }
            seen.insert(hit.itemID)
            items.append(item)
            hits[hit.itemID] = hit
        }
        self.items = items
        self.hits = hits
        self.unresolved = (response.results ?? []).compactMap { unresolvedByID[$0.itemID] }
        self.unhydratedIDs = unhydratedIDs
        partialCoverage = response.partialCoverage ?? false
        self.omitted = omitted
    }
}

/// Tasks own socket calls and retry delays. A checked mailbox rejects every old generation,
/// including a result already in flight when Escape or a replacement search cancels it.
struct ItemSearchLoader: Sendable {
    static let limit = 64
    enum Outcome: Sendable {
        case pending
        case checking
        case ready(ItemSearchPage)
        case failed(String)
        case unavailable(String)
        case expired
    }
    struct Delivery: Sendable {
        let generation: Int
        let outcome: Outcome
    }
    private struct State: Sendable {
        var generation = 0
        var task: Task<Void, Never>?
        var delivery: Delivery?
    }
    private final class Mailbox: Sendable {
        let state = Mutex(State())
        func invalidate() -> Int {
            state.withLock {
                $0.task?.cancel()
                $0.task = nil
                $0.delivery = nil
                $0.generation += 1
                return $0.generation
            }
        }
        func install(_ task: Task<Void, Never>, generation: Int) {
            state.withLock {
                if $0.generation == generation { $0.task = task } else { task.cancel() }
            }
        }
        func publish(_ outcome: Outcome, generation: Int) {
            state.withLock {
                guard $0.generation == generation else { return }
                $0.delivery = Delivery(generation: generation, outcome: outcome)
            }
        }
        func take() -> Delivery? {
            state.withLock { state in
                defer { state.delivery = nil }
                return state.delivery
            }
        }
    }
    private struct SearchRequest: Encodable, Sendable {
        let text: String
        let expression: String?
        let limit = ItemSearchLoader.limit
        let at: String
        let timeZone: String
    }
    private struct ResultsRequest: Encodable, Sendable { let queryID: String }
    private struct GetRequest: Encodable, Sendable { let ids: [String] }
    private struct GetResponse: Decodable, Sendable {
        let list: [TractandaCore.Revision]
        let notFound: [String]?
        let unresolved: [TractandaCore.ItemUnresolvedState]?
        let state: String?
        let remainingIDs: [String]?
        let oversizedIDs: [String]?
    }
    private let mailbox = Mailbox()
    private let client: TractandaClient.ItemClient

    init(client: TractandaClient.ItemClient) { self.client = client }
    init(connection: ServerConnection) {
        client = TractandaClient.ItemClient(transport: LocalItemTransport(connection: connection))
    }
    func cancel() { _ = mailbox.invalidate() }
    func hasDelivery() -> Bool { mailbox.state.withLock { $0.delivery != nil } }
    func take() -> Delivery? { mailbox.take() }

    @discardableResult
    func validate(_ page: ItemSearchPage) -> Int {
        let generation = mailbox.invalidate()
        let mailbox = mailbox
        let client = client
        mailbox.publish(.checking, generation: generation)
        let response = ItemSearchResponse(
            queryID: "", state: "ready", expiresAt: Timestamp.now(), retryAfterMilliseconds: nil,
            partialCoverage: page.partialCoverage,
            results: page.items.compactMap { page.hits[$0.itemID] })
        let task = Task.detached(priority: .userInitiated) {
            do {
                let refreshed = try await Self.fetchPage(
                    client: client, response: response,
                    expiry: Date().addingTimeInterval(300))
                mailbox.publish(.ready(refreshed), generation: generation)
            } catch is CancellationError {
            } catch {
                mailbox.publish(.failed(String(describing: error)), generation: generation)
            }
        }
        mailbox.install(task, generation: generation)
        return generation
    }

    private static func fetchPage(
        client: TractandaClient.ItemClient,
        response: ItemSearchResponse, expiry: Date
    ) async throws -> ItemSearchPage {
        var ids: [String] = []
        for hit in (response.results ?? []).prefix(Self.limit) where !ids.contains(hit.itemID) {
            ids.append(hit.itemID)
        }
        var remaining = ids
        var items: [TractandaCore.Revision] = []
        var unresolvedByID: [String: TractandaCore.ItemUnresolvedState] = [:]
        var unhydratedIDs = Set<String>()
        var state: String?
        var retainedBytes = 0
        var attempts = 0
        while !remaining.isEmpty, attempts < Self.limit {
            attempts += 1
            let current = try await client.call(
                "TractandaItem/get", arguments: GetRequest(ids: remaining),
                returning: GetResponse.self)
            try Task.checkCancellation()
            guard Date() < expiry else {
                throw TractandaCore.TractandaError("notFound", "Semantic query expired.")
            }
            if let prior = state, let next = current.state, prior != next {
                throw TractandaCore.TractandaError(
                    "stateChanged", "Items changed while fetching semantic results. Refresh search.")
            }
            state = current.state
            let unresolved = current.unresolved ?? []
            let remainingIDs = current.remainingIDs ?? []
            let oversizedIDs = current.oversizedIDs ?? []
            let classified =
                current.list.map(\.itemID) + (current.notFound ?? [])
                + unresolved.map(\.itemID) + remainingIDs + oversizedIDs
            guard Set(classified).count == classified.count, Set(classified) == Set(remaining) else {
                throw TractandaCore.TractandaError(
                    "protocolError", "Semantic item delivery omitted or repeated requested IDs.")
            }
            unresolvedByID.merge(
                Dictionary(uniqueKeysWithValues: unresolved.map { ($0.itemID, $0) })
            ) {
                _, newer in newer
            }
            unhydratedIDs.formUnion(remainingIDs)
            unhydratedIDs.formUnion(oversizedIDs)
            for item in current.list where ids.contains(item.itemID) {
                let bytes = try TractandaCore.JSON.encode(item).count
                if retainedBytes + bytes <= 16 * 1_024 * 1_024 {
                    items.append(item)
                    retainedBytes += bytes
                }
            }
            let next = remainingIDs.filter {
                remaining.contains($0) && !oversizedIDs.contains($0)
            }
            guard next.count < remaining.count else {
                unhydratedIDs.formUnion(remaining)
                break
            }
            remaining = next
        }
        return ItemSearchPage(
            response: response, current: items, currentState: state,
            unresolved: (response.results ?? []).compactMap { unresolvedByID[$0.itemID] },
            unhydratedIDs: Array(unhydratedIDs))
    }

    @discardableResult
    func start(text: String, expression: String) -> Int {
        let generation = mailbox.invalidate()
        let mailbox = mailbox
        let client = client
        mailbox.publish(.pending, generation: generation)
        let task = Task.detached(priority: .userInitiated) {
            do {
                var response = try await client.call(
                    "TractandaSemantic/search",
                    arguments: SearchRequest(
                        text: text, expression: expression.isEmpty ? nil : expression,
                        at: Timestamp.now(), timeZone: TimeZone.current.identifier),
                    returning: ItemSearchResponse.self)
                let queryID = response.queryID
                // A malformed or unexpectedly distant expiry cannot cause an endless client poll.
                guard let serverExpiry = Timestamp.parse(response.expiresAt) else {
                    throw TractandaCore.TractandaError("protocolError", "Invalid semantic query expiry.")
                }
                let expiry = min(serverExpiry, Date().addingTimeInterval(300))
                while response.state == "pending" {
                    guard Date() < expiry else {
                        mailbox.publish(.expired, generation: generation)
                        return
                    }
                    let delay = min(5_000, max(100, response.retryAfterMilliseconds ?? 500))
                    let remaining = max(0, expiry.timeIntervalSinceNow)
                    try await Task.sleep(nanoseconds: UInt64(min(Double(delay) / 1_000, remaining) * 1e9))
                    try Task.checkCancellation()
                    guard Date() < expiry else {
                        mailbox.publish(.expired, generation: generation)
                        return
                    }
                    response = try await client.call(
                        "TractandaSemantic/results", arguments: ResultsRequest(queryID: queryID),
                        returning: ItemSearchResponse.self)
                    guard response.queryID == queryID else {
                        throw TractandaCore.TractandaError(
                            "protocolError", "Unexpected semantic query result.")
                    }
                }
                guard response.state == "ready" else {
                    mailbox.publish(
                        .failed("Semantic query failed. Submit again or choose Text."), generation: generation
                    )
                    return
                }
                guard Date() < expiry else {
                    mailbox.publish(.expired, generation: generation)
                    return
                }
                let page = try await Self.fetchPage(client: client, response: response, expiry: expiry)
                mailbox.publish(.ready(page), generation: generation)
            } catch is CancellationError {
                // Cancellation leaves the previous context in charge of the screen.
            } catch {
                let code =
                    (error as? TractandaClient.TractandaError)?.code
                    ?? (error as? TractandaCore.TractandaError)?.code
                if code == "notFound" {
                    mailbox.publish(.expired, generation: generation)
                } else if ["semanticDisabled", "unknownMethod", "unknownCapability", "semanticUnavailable"]
                    .contains(code ?? "")
                {
                    mailbox.publish(.unavailable(String(describing: error)), generation: generation)
                } else {
                    mailbox.publish(.failed(String(describing: error)), generation: generation)
                }
            }
        }
        mailbox.install(task, generation: generation)
        return generation
    }
}
