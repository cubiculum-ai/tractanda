import CTractandaPlatform
import Foundation
import Synchronization
import XCTest

@testable import TractandaCore

final class CurrentPublicationWaitTests: XCTestCase {
    func testCancelledWaitAfterDurablePublicationFinishesAndExactRetryRevealsOneRevision() async throws {
        try AttachmentFixtureCapacity.requireFree()
        let root = try GuardedFixtureDirectory.create(
            prefix: "publication-cancel-", source: #filePath, test: #function)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("store")
        do { _ = try ItemStore.initializeFresh(root: storeRoot) }
        let coordinator = try await ServiceCoordinator(opening: storeRoot)
        let entered = expectation(description: "Actual durable publication reached acknowledgement")
        let release = DispatchSemaphore(value: 0)
        let observed = Mutex(false)
        do {
            try await coordinator.setPersonalDurableAcknowledgementHookForTesting {
                let first = observed.withLock { value in
                    let first = !value
                    value = true
                    return first
                }
                if first {
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw TractandaError("testFixture", "Durable acknowledgement gate was not released")
                    }
                }
            }
            let uid = tractanda_uid()
            let client = NativeAsyncClientContext { try await coordinator.handle($0, forUID: uid) }
            let request = CommitRequest(
                classID: "Item", changes: ["subject": .text("durable despite cancelled waiter")],
                operationID: "cancel-after-durable-publication")
            let bytes = try JSON.encode(request)
            let pending = Task {
                try await client.send(method: "TractandaItem/commit", arguments: bytes, callID: "write")
            }
            await fulfillment(of: [entered], timeout: 3)
            XCTAssertTrue(observed.withLock { $0 })
            pending.cancel()
            release.signal()
            // Cancellation may close this waiter; it cannot undo a begun durable publication.
            _ = await pending.result
            try await coordinator.setPersonalDurableAcknowledgementHookForTesting(nil)
            let replay = try await client.send(
                method: "TractandaItem/commit", arguments: bytes, callID: "write")
            let receipt = try JSON.decode(
                MutationReceipt.self,
                NativeMethodResult.unwrap(replay, method: "TractandaItem/commit", callID: "write"))
            XCTAssertEqual(receipt.operationID, request.operationID)
            XCTAssertTrue(receipt.wasReplayed)
            await coordinator.close()
            do {
                let reopened = try ItemStore.openInitialized(root: storeRoot)
                let history = try reopened.history(receipt.itemID)
                XCTAssertEqual(history.count, 1)
                XCTAssertEqual(history.first?.revisionID, receipt.revisionID)
                XCTAssertEqual(history.first?.fields["subject"], .text("durable despite cancelled waiter"))
                let retry = try reopened.commit(request)
                XCTAssertTrue(retry.wasReplayed)
                XCTAssertEqual(retry.revision.revisionID, receipt.revisionID)
            }
        } catch {
            release.signal()
            await coordinator.close()
            throw error
        }
    }
}
