import Foundation

/// Accumulates an exact query result while bounding the Swift values retained in memory.
/// The comparator must implement the complete deterministic order, including item ID ties.
public struct BoundedQueryResults<Element> {
    public struct Page {
        public let elements: [Element]
        public let totalCount: Int
    }

    public enum Strategy {
        /// Consume an already ordered stream, skipping the prefix and retaining only the page.
        case orderedStream(position: Int, limit: Int)
        /// Retain only the first `position + limit` values in the supplied order.
        case orderedWindow(position: Int, limit: Int)
        /// Retain every value, failing before exceeding either cap.
        case exact(position: Int, limit: Int, maximumCandidates: Int, maximumBytes: Int)
    }

    private let strategy: Strategy
    private let maximumRetainedBytes: Int
    private let compare: (Element, Element) -> Bool
    private let estimateBytes: (Element) -> Int
    private let isCancelled: () -> Bool
    private var retained: [(element: Element, bytes: Int)] = []
    private var retainedBytes = 0
    private var totalCount = 0
    private var failure: Error?
    private var finished = false

    public init(
        strategy: Strategy,
        maximumRetainedBytes: Int,
        estimateBytes: @escaping (Element) -> Int,
        isOrderedBefore: @escaping (Element, Element) -> Bool,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) throws {
        guard maximumRetainedBytes >= 0 else {
            throw TractandaError("invalidArguments", "The retained-byte limit must be nonnegative.")
        }
        switch strategy {
        case .orderedStream(let position, let limit):
            guard position >= 0, limit >= 0 else {
                throw TractandaError("invalidArguments", "Query position and limit must be nonnegative.")
            }
        case .orderedWindow(let position, let limit):
            guard position >= 0, limit >= 0 else {
                throw TractandaError("invalidArguments", "Query position and limit must be nonnegative.")
            }
            let (window, overflow) = position.addingReportingOverflow(limit)
            guard !overflow else {
                throw TractandaError("resourceLimit", "The requested query window is too large.")
            }
            _ = window
        case .exact(let position, let limit, let maximumCandidates, let maximumBytes):
            guard position >= 0, limit >= 0, maximumCandidates >= 0, maximumBytes >= 0 else {
                throw TractandaError("invalidArguments", "Exact-result limits must be nonnegative.")
            }
            let (_, overflow) = position.addingReportingOverflow(limit)
            guard !overflow else {
                throw TractandaError("resourceLimit", "The requested query window is too large.")
            }
            guard maximumBytes <= maximumRetainedBytes else {
                throw TractandaError(
                    "invalidArguments", "The exact-result byte limit exceeds the retained-byte limit.")
            }
        }
        self.strategy = strategy
        self.maximumRetainedBytes = maximumRetainedBytes
        self.estimateBytes = estimateBytes
        self.compare = isOrderedBefore
        self.isCancelled = isCancelled
    }

    public var retainedCount: Int { retained.count }
    public var retainedByteCount: Int { retainedBytes }

    public mutating func append(_ element: Element) throws {
        guard failure == nil, !finished else {
            throw TractandaError(
                "invalidArguments", "The query accumulator is no longer accepting candidates.")
        }
        do {
            try checkCancellation()
            let (nextCount, countOverflow) = totalCount.addingReportingOverflow(1)
            guard !countOverflow else {
                throw TractandaError("resourceLimit", "The exact query result count overflowed.")
            }
            let bytes = estimateBytes(element)
            guard bytes >= 0 else {
                throw TractandaError("invalidArguments", "The candidate byte estimate must be nonnegative.")
            }
            totalCount = nextCount
            switch strategy {
            case .orderedStream(let position, let limit):
                if totalCount > position, retained.count < limit {
                    try appendRetained(element, bytes: bytes)
                }
            case .orderedWindow(let position, let limit):
                let window = limit == 0 ? 0 : position + limit
                guard window > 0 else { return }
                try insertIntoWindow(element, bytes: bytes, capacity: window)
            case .exact(_, _, let maximumCandidates, let maximumBytes):
                guard retained.count < maximumCandidates else {
                    throw resourceLimit("Exact query candidates exceed the configured limit.")
                }
                guard bytes <= maximumBytes - retainedBytes else {
                    throw resourceLimit("Exact query candidates exceed the configured byte limit.")
                }
                retained.append((element, bytes))
                retainedBytes += bytes
            }
        } catch {
            failure = error
            retained.removeAll(keepingCapacity: false)
            retainedBytes = 0
            throw error
        }
    }

    public mutating func finish() throws -> Page {
        guard !finished else {
            throw TractandaError("invalidArguments", "The query accumulator has already been finished.")
        }
        finished = true
        if let failure { throw failure }
        do {
            try checkCancellation()
            let page: [Element]
            switch strategy {
            case .orderedStream:
                page = retained.map(\.element)
            case .orderedWindow(let position, let limit):
                page =
                    position >= retained.count
                    ? [] : Array(retained[position..<min(retained.count, position + limit)]).map(\.element)
            case .exact(let position, let limit, let maximumCandidates, let maximumBytes):
                guard retained.count <= maximumCandidates, retainedBytes <= maximumBytes else {
                    throw resourceLimit("Exact query result exceeded its configured limit.")
                }
                retained.sort { compare($0.element, $1.element) }
                page =
                    position >= retained.count
                    ? []
                    : Array(retained[position..<min(retained.count, position + limit)]).map(\.element)
            }
            return Page(elements: page, totalCount: totalCount)
        } catch {
            failure = error
            retained.removeAll(keepingCapacity: false)
            retainedBytes = 0
            throw error
        }
    }

    private mutating func insertIntoWindow(_ element: Element, bytes: Int, capacity: Int) throws {
        var low = 0
        var high = retained.count
        while low < high {
            let middle = low + (high - low) / 2
            if compare(retained[middle].element, element) { low = middle + 1 } else { high = middle }
        }
        if low >= capacity { return }
        let evictedBytes = retained.count == capacity ? retained[capacity - 1].bytes : 0
        let (baseBytes, subtractionOverflow) = retainedBytes.subtractingReportingOverflow(evictedBytes)
        let (nextBytes, additionOverflow) = baseBytes.addingReportingOverflow(bytes)
        guard !subtractionOverflow, !additionOverflow, nextBytes <= maximumRetainedBytes else {
            throw resourceLimit("The retained query window exceeds its byte limit.")
        }
        retained.insert((element, bytes), at: low)
        if retained.count > capacity { retained.removeLast() }
        retainedBytes = nextBytes
    }

    private mutating func appendRetained(_ element: Element, bytes: Int) throws {
        let (nextBytes, overflow) = retainedBytes.addingReportingOverflow(bytes)
        guard !overflow, nextBytes <= maximumRetainedBytes else {
            throw resourceLimit("The retained query result exceeds its byte limit.")
        }
        retained.append((element, bytes))
        retainedBytes = nextBytes
    }

    private func checkCancellation() throws {
        if isCancelled() { throw CancellationError() }
    }

    private func resourceLimit(_ message: String) -> TractandaError {
        TractandaError("resourceLimit", message)
    }
}
