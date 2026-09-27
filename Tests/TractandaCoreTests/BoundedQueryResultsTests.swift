import XCTest

@testable import TractandaCore

final class BoundedQueryResultsTests: XCTestCase {
    private struct Row: Equatable {
        let key: Int
        let id: Int
        var bytes: Int { 8 }
    }

    private func before(_ lhs: Row, _ rhs: Row, reverse: Bool = false) -> Bool {
        if lhs.key != rhs.key { return reverse ? lhs.key > rhs.key : lhs.key < rhs.key }
        return lhs.id < rhs.id
    }

    func testTopKDeepPageMatchesFullSortOracleAndBoundsRetainedWindow() throws {
        let input = (0..<37).map { Row(key: $0 % 5, id: $0) }
        let expected = input.sorted { before($0, $1) }
        var accumulator = try BoundedQueryResults(
            strategy: .orderedWindow(position: 24, limit: 6), maximumRetainedBytes: 240,
            estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1) }
        )
        for row in input { try accumulator.append(row) }
        XCTAssertEqual(accumulator.retainedCount, 30)
        XCTAssertEqual(accumulator.retainedByteCount, 240)
        let page = try accumulator.finish()
        XCTAssertEqual(page.elements, Array(expected[24..<30]))
        XCTAssertEqual(page.totalCount, input.count)
    }

    func testReverseOrderAndTiesAreDeterministic() throws {
        let input = [Row(key: 2, id: 5), Row(key: 1, id: 3), Row(key: 2, id: 1), Row(key: 3, id: 4)]
        var accumulator = try BoundedQueryResults(
            strategy: .orderedWindow(position: 1, limit: 2), maximumRetainedBytes: 64,
            estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1, reverse: true) }
        )
        for row in input { try accumulator.append(row) }
        let expected = input.sorted { before($0, $1, reverse: true) }
        XCTAssertEqual(try accumulator.finish().elements, Array(expected[1..<3]))
    }

    func testAlreadyOrderedDeepStreamRetainsOnlyPageButCountsAll() throws {
        var accumulator = try BoundedQueryResults(
            strategy: .orderedStream(position: 90, limit: 4), maximumRetainedBytes: 32,
            estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1) }
        )
        for index in 0..<100 { try accumulator.append(Row(key: index, id: index)) }
        XCTAssertEqual(accumulator.retainedCount, 4)
        XCTAssertEqual(accumulator.retainedByteCount, 32)
        let page = try accumulator.finish()
        XCTAssertEqual(page.elements.map(\.id), [90, 91, 92, 93])
        XCTAssertEqual(page.totalCount, 100)
    }

    func testExactCustomSortOverbudgetFailsWithoutPartialPageOrCount() throws {
        var accumulator = try BoundedQueryResults(
            strategy: .exact(position: 0, limit: 2, maximumCandidates: 3, maximumBytes: 24),
            maximumRetainedBytes: 24, estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1) }
        )
        try accumulator.append(Row(key: 1, id: 1))
        try accumulator.append(Row(key: 2, id: 2))
        try accumulator.append(Row(key: 3, id: 3))
        XCTAssertThrowsError(try accumulator.append(Row(key: 4, id: 4))) {
            XCTAssertEqual(($0 as? TractandaError)?.code, "resourceLimit")
        }
        XCTAssertThrowsError(try accumulator.finish())
        XCTAssertEqual(accumulator.retainedCount, 0)
        XCTAssertEqual(accumulator.retainedByteCount, 0)
    }

    func testByteCapAndOrderedWindowRetainedEntryCap() throws {
        var byteLimited = try BoundedQueryResults(
            strategy: .orderedStream(position: 0, limit: 3), maximumRetainedBytes: 16,
            estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1) }
        )
        try byteLimited.append(Row(key: 0, id: 0))
        try byteLimited.append(Row(key: 1, id: 1))
        XCTAssertThrowsError(try byteLimited.append(Row(key: 2, id: 2)))
        XCTAssertThrowsError(try byteLimited.finish())
        XCTAssertEqual(byteLimited.retainedCount, 0)

        var entryLimited = try BoundedQueryResults(
            strategy: .orderedStream(position: 5, limit: 2), maximumRetainedBytes: 16,
            estimateBytes: \.bytes, isOrderedBefore: { self.before($0, $1) }
        )
        for index in 0..<20 { try entryLimited.append(Row(key: index, id: index)) }
        XCTAssertEqual(entryLimited.retainedCount, 2)
        XCTAssertEqual(entryLimited.retainedByteCount, 16)
    }

    func testCancellationPreventsResultAndClearsRetainedValues() throws {
        var cancelled = false
        var accumulator = try BoundedQueryResults(
            strategy: .exact(position: 0, limit: 5, maximumCandidates: 10, maximumBytes: 80),
            maximumRetainedBytes: 80, estimateBytes: \.bytes,
            isOrderedBefore: { self.before($0, $1) }, isCancelled: { cancelled }
        )
        try accumulator.append(Row(key: 0, id: 0))
        cancelled = true
        XCTAssertThrowsError(try accumulator.append(Row(key: 1, id: 1))) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try accumulator.finish())
        XCTAssertEqual(accumulator.retainedCount, 0)
    }

    func testEmptyAndLastPageTotalsAreExact() throws {
        var empty = try BoundedQueryResults<Int>(
            strategy: .orderedWindow(position: 0, limit: 3), maximumRetainedBytes: 0,
            estimateBytes: { _ in 0 }, isOrderedBefore: { (a: Int, b: Int) in a < b }
        )
        XCTAssertEqual(try empty.finish().totalCount, 0)

        var last = try BoundedQueryResults(
            strategy: .exact(position: 2, limit: 5, maximumCandidates: 4, maximumBytes: 32),
            maximumRetainedBytes: 32, estimateBytes: { _ in 8 },
            isOrderedBefore: { (a: Int, b: Int) in a < b }
        )
        for value in [4, 1, 3, 2] { try last.append(value) }
        let result = try last.finish()
        XCTAssertEqual(result.elements, [3, 4])
        XCTAssertEqual(result.totalCount, 4)
    }
}
