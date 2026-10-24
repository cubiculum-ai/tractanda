import Foundation

/// One aggregate I/O allowance covers both structural inventory and reconstruction reads.
/// The lock also keeps the immutable provider's Sendable closure honest; no source bytes are retained.
final class RecoveryReadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var recordBytes: UInt64
    private var payloadBytes: UInt64
    private let maximumRecordBytes: UInt64
    private let maximumPayloadBytes: UInt64

    init(inventory: PersonalRecoveryInventory.Result, limits: PersonalRecoveryInventory.Limits) {
        recordBytes = inventory.recordBytesBudgeted
        payloadBytes = inventory.payloadBytesBudgeted
        maximumRecordBytes = limits.maximumTotalRecordBytes
        maximumPayloadBytes = limits.maximumTotalPayloadBytes
    }

    func record(_ bytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try charge(bytes, total: &recordBytes, maximum: maximumRecordBytes)
    }

    func payload(_ bytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try charge(bytes, total: &payloadBytes, maximum: maximumPayloadBytes)
    }

    private func charge(_ count: Int, total: inout UInt64, maximum: UInt64) throws {
        guard count >= 0, total <= maximum, UInt64(count) <= maximum - total else {
            throw TractandaError("resourceLimit", "Recovery reconstruction I/O budget exceeded.")
        }
        total += UInt64(count)
    }
}

/// Borrowed only during synchronous index construction while the selected root remains offline.
/// Each lookup was validated by inventory; the shared reader rechecks the actual closure bytes.
struct SelectedRecoveryPageProvider: PageCorpusPageProvider {
    let root: URL
    let rootDescriptor: Int32
    let ownerUID: UInt32
    let locations: [String: [PersonalRecoveryInventory.Location]]
    let budget: RecoveryReadBudget
    var check: @Sendable () throws -> Void = {}
    var activity: @Sendable () throws -> Void = {}

    func forEachPage(
        document: PageCorpusDocumentPlan, visit: (DocumentStoredPage) throws -> Void
    ) throws {
        try forEachEncodedPage(document: document) { page, _ in try visit(page) }
    }

    func forEachEncodedPage(
        document: PageCorpusDocumentPlan, visit: (DocumentStoredPage, Int) throws -> Void
    ) throws {
        guard let content = document.savedContent,
            let location = locations[content.contentID]?.first, location.source == 0
        else {
            throw TractandaError("documentIntegrity", "Selected document has no validated original locator.")
        }
        try DocumentContentStore.forEachRecoveryPage(
            document: document, path: location.path, root: root, rootDescriptor: rootDescriptor,
            ownerUID: ownerUID,
            readBudget: {
                try check()
                try budget.payload($0)
            },
            visit: { page, count in
                try activity()
                try visit(page, count)
            })
    }
}
