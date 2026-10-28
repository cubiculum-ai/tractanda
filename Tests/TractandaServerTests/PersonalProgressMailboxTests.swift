import Foundation
import XCTest

@testable import TractandaCore
@testable import TractandaServer

private actor ProgressMailboxGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var values: [PersonalPullProgress] = []
    func receive(_ value: PersonalPullProgress, entered: XCTestExpectation, complete: XCTestExpectation) async
    {
        values.append(value)
        if values.count == 1 {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        } else {
            complete.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func captured() -> [PersonalPullProgress] { values }
}

final class PersonalProgressMailboxTests: XCTestCase {
    func testBoundedMailboxCoalescesActualCountersWithoutQueuingEveryEvent() async throws {
        let first = expectation(description: "first actual update held")
        let last = expectation(description: "coalesced latest update")
        let gate = ProgressMailboxGate()
        let mailbox = PersonalProgressMailbox { value in
            await gate.receive(value, entered: first, complete: last)
        }
        mailbox.publish(try .init(phase: .transferring, transferredBytes: 1))
        await fulfillment(of: [first], timeout: 5)
        for bytes in 2...10_000 {
            mailbox.publish(try .init(phase: .transferring, transferredBytes: Int64(bytes)))
        }
        await gate.release()
        await fulfillment(of: [last], timeout: 5)
        let values = await gate.captured()
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.last?.transferredBytes, 10_000)
        XCTAssertNil(values.last?.lastProgressAt, "The mailbox must never fabricate an activity timestamp")
    }
}
