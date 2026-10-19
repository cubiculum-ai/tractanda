import Foundation
import TractandaCore

package struct PeerSyncLimits: Sendable {
    package var maximumRequests = 128
    package var maximumBytes = 8 * 1024 * 1024
    package var maximumPages = 32
    package var maximumChunks = 16
    package var maximumSeconds: Double = 20
    package init() {}
    package func validate() throws {
        guard (8...512).contains(maximumRequests),
            (4 * 1024 * 1024...16 * 1024 * 1024).contains(maximumBytes),
            (1...128).contains(maximumPages), (1...64).contains(maximumChunks),
            maximumSeconds.isFinite, maximumSeconds > 0, maximumSeconds <= 60
        else {
            throw TractandaError("resourceLimit", "Invalid finite synchronization limits.")
        }
    }
}

/// One paired edge's two sequential directions. No Store owner or transaction spans an await.
/// Persisted references resume existing journals; connection cursors stay bounded in memory.
package actor PeerSyncDriver {
    package struct Report: Sendable {
        /// Complete means both captured finite cuts finished, not a cluster-wide fixed point.
        package enum Status: String, Sendable {
            case complete, yielded, held, missing, rejected, repairRequired, unsupported
        }
        package var status: Status = .complete
        package var sessionRollovers = 0
        package var packagesCreated = 0
        package var packagesCommitted = 0
        package var pages = 0
        package var chunks = 0
        package var encodedBytes = 0
        mutating func note(_ value: Status) {
            let order: [Status] = [
                .complete, .yielded, .held, .rejected, .missing, .unsupported, .repairRequired,
            ]
            if order.firstIndex(of: value)! > order.firstIndex(of: status)! { status = value }
        }
    }
    private enum Direction: Int, CaseIterable { case outbound, inbound }
    private struct InventoryPage {
        let descriptors: [PeerSyncDescriptor]
        let complete: Bool
    }
    private struct ResumeObject {
        let descriptor: PeerSyncDescriptor
        let offset: Int
        let verified: Bool
    }
    private struct ResumePage {
        let objects: [ResumeObject]
        let complete: Bool
        let blocked: Bool
    }
    private struct Chunk {
        let descriptor: PeerSyncDescriptor
        let offset: Int
        let bytes: Data
    }
    private struct Flow {
        var inventoryStarted = false
        var inventoryRound = UUID().uuidString.lowercased()
        var inventoryOrdinal: Int64 = 0
        var resumeRound = UUID().uuidString.lowercased()
        var resumeOrdinal: Int64 = 0
        var page: InventoryPage?
        var compared: [PeerSyncDescriptor]?
        var comparisonOffset = 0
        var missingIDs: [String] = []
        var deferredDescriptors: [PeerSyncDescriptor] = []
        var finished = false
        var activePackage: String?
        var exportOpen = false
        var phase: String?
        var remainingSelection: Set<String>?
        var manifest: Data?
        var intakeBegun = false
        var resumeStarted = false
        var resumePage: ResumePage?
        var objectIndex = 0
        var objectOffset: Int?
        var chunk: Chunk?
        var readyToCommit = false
        var chunkCharged = false
        var retryStamp: String?
        var retryFinished = true
        var retryAfter = ""
        var retryPackages: [String] = []
        var retryPageComplete = false
        var blockedStamp: String?
        var blockedStatus: Report.Status?
        mutating func resetTransfer(_ id: String?) {
            activePackage = id
            exportOpen = false
            phase = nil
            remainingSelection = nil
            manifest = nil
            intakeBegun = false
            resumeStarted = false
            resumePage = nil
            resumeRound = UUID().uuidString.lowercased()
            resumeOrdinal = 0
            objectIndex = 0
            objectOffset = nil
            chunk = nil
            chunkCharged = false
            readyToCommit = false
        }
    }
    private struct Budget {
        let limits: PeerSyncLimits
        let deadline: Double
        var requests = 0
        var report = Report()
        mutating func request(_ encoded: Int, responseMaximum: Int) throws {
            try check()
            guard requests < limits.maximumRequests,
                encoded + responseMaximum <= limits.maximumBytes - report.encodedBytes
            else { throw Self.yield() }
            requests += 1
            report.encodedBytes += encoded
        }
        mutating func page() throws {
            try check()
            guard report.pages < limits.maximumPages else { throw Self.yield() }
            report.pages += 1
        }
        mutating func chunk() throws {
            try check()
            guard report.chunks < limits.maximumChunks else { throw Self.yield() }
            report.chunks += 1
        }
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Self.yield() }
        }
        static func yield() -> TractandaError {
            TractandaError("peerSyncYield", "Finite job window exhausted.")
        }
    }
    private let coordinator: ServiceCoordinator
    private let binding: PeerExchangeBinding
    private let limits: PeerSyncLimits
    private var local: PeerLogicalExchange.Lease?
    private var localContext: PeerLogicalExchange?
    private var remoteContextID: String?
    private var stopped = false
    private var connection: PeerExchangeConnection?
    private var flows = [Flow(), Flow()]
    private var startDirection = Direction.outbound
    private var busy = false
    private var lastCreatedRoots: (direction: String, roots: [String])?
    package func createdRootsForTesting() -> (direction: String, roots: [String])? { lastCreatedRoots }

    package init(
        coordinator: ServiceCoordinator, binding: PeerExchangeBinding, limits: PeerSyncLimits = .init()
    ) throws {
        try limits.validate()
        self.coordinator = coordinator
        self.binding = binding
        self.limits = limits
    }
    /// Explicit future operator action may retry a blocked observation after authorized repair.
    package func retry() { for index in flows.indices { flows[index].blockedStamp = nil } }

    package func run(connection supplied: PeerExchangeConnection) async throws -> Report {
        guard !busy else { throw TractandaError("serviceBusy", "One job already owns this paired edge.") }
        busy = true
        defer { busy = false }
        guard !stopped else { throw TractandaError("serviceClosed", "Synchronization driver is closed.") }
        let reconnected = connection !== supplied
        var budget = Budget(
            limits: limits, deadline: ProcessInfo.processInfo.systemUptime + limits.maximumSeconds)
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(limits.maximumSeconds))
                _ = supplied.close()
            } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            do {
                if localContext == nil {
                    let snapshot = try await coordinator.loadPeerRuntimeSnapshot()
                    localContext = try await PeerLogicalExchange(
                        coordinator: coordinator, binding: binding, snapshot: snapshot)
                }
                if reconnected || local == nil {
                    await local?.detach()
                    guard let context = localContext else {
                        throw TractandaError("serviceClosed", "No local synchronization context.")
                    }
                    let lease = try await context.attach(close: {})
                    local = lease
                    // No self-declaration/ack: adopt the actual ready connection's Core-minted
                    // evidence and revocable physical lifetime within this finite job budget.
                    try await supplied.admitLocalContinuation(
                        lease, expectedBinding: binding, control: control(budget))
                }
                guard let local else {
                    throw TractandaError("serviceClosed", "No local synchronization gateway.")
                }
                // Publish the new physical owner only after its fresh admission handoff.
                connection = supplied
                if reconnected {
                    let hello = try await call(remote: true, .init("syncContext"), budget: &budget)
                    let identity = try text(hello["contextID"])
                    guard UUID(uuidString: identity) != nil else { throw malformed() }
                    if remoteContextID != identity {
                        // Process restart/rebuild/security invalidation explicitly rescans. Exact
                        // durable plan/package references reopen instead of allocating duplicates.
                        for index in flows.indices { flows[index] = Flow() }
                    }
                    remoteContextID = identity
                }
                var work = try await local.syncWork(control: control(budget))
                let left = try await call(remote: false, .init("syncEpoch"), budget: &budget)
                let right = try await call(remote: true, .init("syncEpoch"), budget: &budget)
                let stamp =
                    try text(left["epoch"]) + ":" + text(left["security"]) + ":"
                    + text(right["epoch"]) + ":" + text(right["security"])
                if flows.allSatisfy(\.finished) {
                    for index in flows.indices {
                        flows[index].inventoryStarted = false
                        flows[index].page = nil
                        flows[index].finished = false
                        flows[index].inventoryRound = UUID().uuidString.lowercased()
                        flows[index].inventoryOrdinal = 0
                        flows[index].resetTransfer(nil)
                    }
                }
                let directions: [Direction] =
                    startDirection == .outbound ? [.outbound, .inbound] : [.inbound, .outbound]
                startDirection = startDirection == .outbound ? .inbound : .outbound
                for direction in directions {
                    var flow = flows[direction.rawValue]
                    flow.chunkCharged = false
                    defer { flows[direction.rawValue] = flow }
                    if flow.blockedStamp == stamp, let status = flow.blockedStatus {
                        budget.report.note(status)
                        continue
                    }
                    flow.blockedStamp = nil
                    flow.blockedStatus = nil
                    do {
                        if transfer(direction, work) == nil {
                            try await retryPending(direction, stamp: stamp, flow: &flow, budget: &budget)
                        }
                        try await directionStep(direction, flow: &flow, work: &work, budget: &budget)
                    } catch let error as TractandaError where error.code == "peerSyncYield" {
                        budget.report.note(.yielded)
                        return budget.report
                    } catch let error as TractandaError
                        where ["peerPayloadVerifying", "peerVerificationBusy"].contains(error.code)
                    {
                        budget.report.note(.yielded)
                        return budget.report
                    } catch let error as TractandaError
                        where error.code == "peerExportChanged"
                        && transfer(direction, work)?.manifestDigest == nil
                    {
                        // Unsealed disposable work may be invalidated by rebuild. Keep canonical journals,
                        // forget only the locator, and compare current inventory before allocating anew.
                        setTransfer(nil, direction, &work)
                        work = try await local.syncWork(work, control: control(budget))
                        flow = Flow()
                        budget.report.note(.yielded)
                        return budget.report
                    } catch let error as TractandaError
                        where [
                            "peerRepairRequired", "peerSyncWorkInvalid", "peerObjectCollision",
                            "invalidPeerPackage", "invalidPeerExport", "peerOriginAdmissionInvalid",
                            "documentIntegrity",
                        ].contains(error.code)
                    {
                        flow.blockedStamp = stamp
                        flow.blockedStatus = .repairRequired
                        budget.report.note(.repairRequired)
                    }
                    if let status = flow.blockedStatus {
                        flow.blockedStamp = stamp
                        budget.report.note(status)
                    }
                }
                return budget.report
            } catch let error as TractandaError where error.code == "peerSessionExhausted" {
                _ = try? await supplied.close().get()
                budget.report.sessionRollovers += 1
                budget.report.note(.yielded)
                return budget.report
            } catch {
                if ProcessInfo.processInfo.systemUptime >= budget.deadline, !Task.isCancelled {
                    _ = try? await supplied.close().get()
                    budget.report.note(.yielded)
                    return budget.report
                }
                throw error
            }
        } onCancel: {
            _ = supplied.close()
        }
    }

    package func close() async {
        stopped = true
        if let connection { _ = try? await connection.close().get() }
        connection = nil
        local = nil
        await localContext?.invalidate()
        localContext = nil
        flows = [Flow(), Flow()]
    }
    private func control(_ budget: Budget) throws -> PeerExchangeControl {
        try budget.check()
        return try PeerExchangeControl(
            maximumSeconds: min(30, budget.deadline - ProcessInfo.processInfo.systemUptime))
    }
    private func call(remote: Bool, _ request: PeerExchangeRequest, budget: inout Budget) async throws
        -> [String: ItemValue]
    {
        let encoded = try JSON.encode(request)
        try budget.request(
            encoded.count, responseMaximum: request.operation == "exportRead" ? 2 * 1024 * 1024 : 128 * 1024)
        let bytes: Data
        if remote {
            guard let connection else { throw TractandaError("serviceClosed", "No peer connection.") }
            bytes = try await connection.request(request).get()
        } else {
            guard let local else { throw TractandaError("serviceClosed", "No local gateway.") }
            bytes = try await local.execute(encoded, control: control(budget))
        }
        budget.report.encodedBytes += bytes.count
        try budget.check()
        guard bytes.count <= (request.operation == "exportRead" ? 2 * 1024 * 1024 : 128 * 1024) else {
            throw TractandaError("resourceLimit", "Synchronization response window exceeded.")
        }
        return try JSON.decode([String: ItemValue].self, bytes)
    }
    private func text(_ value: ItemValue?) throws -> String {
        guard case .text(let result) = value, result.utf8.count <= 256 else { throw malformed() }
        return result
    }
    private func list(_ value: ItemValue?, maximum: Int = 128) throws -> [ItemValue] {
        guard case .list(let result) = value, result.count <= maximum else { throw malformed() }
        return result
    }
    private func bool(_ value: ItemValue?) throws -> Bool {
        guard case .boolean(let result) = value else { throw malformed() }
        return result
    }
    private func integer(_ value: ItemValue?) throws -> Int {
        guard case .integer(let result) = value, let encoded = Int(exactly: result), encoded >= 0 else {
            throw malformed()
        }
        return encoded
    }
    private func malformed() -> TractandaError {
        TractandaError("invalidPeerResponse", "Synchronization response framing differs.")
    }
    private func transfer(_ direction: Direction, _ work: PeerSyncWork) -> PeerSyncWork.Transfer? {
        direction == .outbound ? work.outbound : work.inbound
    }
    private func setTransfer(
        _ value: PeerSyncWork.Transfer?, _ direction: Direction, _ work: inout PeerSyncWork
    ) {
        if direction == .outbound { work.outbound = value } else { work.inbound = value }
    }
    private func save(_ work: inout PeerSyncWork, budget: Budget) async throws {
        guard let local else { throw malformed() }
        work = try await local.syncWork(work, control: control(budget))
    }
    private func inventory(_ sender: Bool, flow: inout Flow, budget: inout Budget) async throws {
        try budget.page()
        let output = try await call(
            remote: sender,
            .init(
                "syncInventory",
                [
                    "round": .text(flow.inventoryRound), "ordinal": .integer(flow.inventoryOrdinal),
                ]), budget: &budget)
        flow.inventoryOrdinal += 1
        flow.inventoryStarted = true
        var entries: [PeerSyncDescriptor] = []
        var seen: [String: ItemValue] = [:]
        for value in try list(output["entries"]) {
            guard let raw = value.map?["descriptor"] else { throw malformed() }
            let descriptor = try PeerSyncDescriptor(raw)
            guard ["item", "authority"].contains(descriptor.kind) else { throw malformed() }
            if let old = seen[descriptor.id] {
                guard old == descriptor.value else { throw malformed() }
            } else {
                seen[descriptor.id] = descriptor.value
                entries.append(descriptor)
            }
        }
        flow.page = InventoryPage(descriptors: entries, complete: try bool(output["complete"]))
        flow.compared = entries
        flow.comparisonOffset = 0
        flow.missingIDs = []
        flow.deferredDescriptors = []
    }

    private func directionStep(
        _ direction: Direction, flow: inout Flow, work: inout PeerSyncWork,
        budget: inout Budget
    ) async throws {
        let sender = direction == .inbound
        let receiver = !sender
        while !flow.finished {
            try budget.check()
            if transfer(direction, work) == nil {
                if flow.page == nil { try await inventory(sender, flow: &flow, budget: &budget) }
                guard let page = flow.page else { throw malformed() }
                if flow.compared == nil { flow.compared = page.descriptors }
                let descriptors = flow.compared!
                if descriptors.isEmpty {
                    flow.compared = nil
                    if page.complete {
                        flow.finished = true
                        return
                    }
                    flow.page = nil
                    continue
                }
                let answer = try await call(
                    remote: receiver,
                    .init(
                        "needsTransfer",
                        [
                            "descriptors": .list(descriptors.map(\.value)),
                            "after": .integer(Int64(flow.comparisonOffset)),
                        ]), budget: &budget)
                let states = try list(answer["objects"])
                let next = try integer(answer["nextOffset"])
                guard next == flow.comparisonOffset + states.count, next <= descriptors.count,
                    try bool(answer["complete"]) == (next == descriptors.count),
                    !states.isEmpty || next == descriptors.count
                else { throw malformed() }
                for (offset, value) in states.enumerated() {
                    guard let fields = value.map, let raw = fields["descriptor"] else { throw malformed() }
                    let descriptor = try PeerSyncDescriptor(raw)
                    guard descriptors[flow.comparisonOffset + offset].value == descriptor.value else {
                        throw malformed()
                    }
                    switch try text(fields["state"]) {
                    case "knownComplete": break
                    case "missingOrIncomplete": flow.missingIDs.append(descriptor.id)
                    case "deferred": flow.deferredDescriptors.append(descriptor)
                    case "repairRequired":
                        flow.blockedStatus = .repairRequired
                        return
                    default: throw malformed()
                    }
                }
                flow.comparisonOffset = next
                if next < descriptors.count { continue }
                if flow.missingIDs.isEmpty {
                    if !flow.deferredDescriptors.isEmpty {
                        flow.compared = flow.deferredDescriptors
                        flow.deferredDescriptors = []
                        flow.comparisonOffset = 0
                        throw Budget.yield()
                    }
                    flow.compared = nil
                    flow.comparisonOffset = 0
                    if page.complete {
                        flow.finished = true
                        return
                    }
                    flow.page = nil
                    continue
                }
                let created = try PeerSyncWork.transfer(roots: flow.missingIDs)
                lastCreatedRoots = (direction == .outbound ? "outbound" : "inbound", created.roots)
                setTransfer(created, direction, &work)
                try await save(&work, budget: budget)  // Actual IDs are durable BEFORE exportBegin.
                budget.report.packagesCreated += 1
            }
            guard var pending = transfer(direction, work) else { throw malformed() }
            if flow.activePackage != pending.packageID { flow.resetTransfer(pending.packageID) }
            if flow.missingIDs == pending.roots {
                flow.compared = flow.deferredDescriptors
                flow.deferredDescriptors = []
                flow.comparisonOffset = 0
                flow.missingIDs = []
            }
            let identity: [String: ItemValue] = [
                "planID": .text(pending.planID), "packageID": .text(pending.packageID),
            ]
            if !flow.exportOpen {
                let exists = try await call(remote: sender, .init("exportExists", identity), budget: &budget)
                let status: [String: ItemValue]
                if try bool(exists["exists"]) {
                    status = try await call(remote: sender, .init("exportReopen", identity), budget: &budget)
                } else {
                    guard pending.manifestDigest == nil else {
                        throw TractandaError(
                            "peerRepairRequired", "Acknowledged sealed export journal is missing.")
                    }
                    // This window may have crashed after locator publication but before exportBegin.
                    if flow.page == nil { try await inventory(sender, flow: &flow, budget: &budget) }
                    status = try await call(remote: sender, .init("exportBegin", identity), budget: &budget)
                }
                try acceptStatus(status, pending: &pending, flow: &flow)
                setTransfer(pending, direction, &work)
                flow.exportOpen = true
                if pending.manifestDigest != nil { try await save(&work, budget: budget) }
            }
            if flow.manifest == nil {
                if flow.phase == "selecting" {
                    if flow.remainingSelection == nil { flow.remainingSelection = Set(pending.roots) }
                    if flow.page == nil { try await inventory(sender, flow: &flow, budget: &budget) }
                    guard let page = flow.page, var remaining = flow.remainingSelection else {
                        throw malformed()
                    }
                    let selected = page.descriptors.map(\.id).filter { remaining.contains($0) }
                    for selectedID in selected {
                        remaining.remove(selectedID)
                    }
                    if !selected.isEmpty || remaining.isEmpty {
                        let status = try await call(
                            remote: sender,
                            .init(
                                "exportSelect",
                                [
                                    "ids": .list(selected.map(ItemValue.text)),
                                    "finish": .boolean(remaining.isEmpty),
                                ]), budget: &budget)
                        try acceptStatus(status, pending: &pending, flow: &flow)
                        setTransfer(pending, direction, &work)
                    }
                    flow.remainingSelection = remaining
                    if !remaining.isEmpty {
                        guard !page.complete else {
                            throw TractandaError(
                                "peerExportChanged", "Selected current roots are no longer enumerable.")
                        }
                        flow.page = nil
                        continue
                    }
                }
                if flow.manifest == nil {
                    let status = try await call(remote: sender, .init("exportStep"), budget: &budget)
                    try acceptStatus(status, pending: &pending, flow: &flow)
                    setTransfer(pending, direction, &work)
                    if pending.manifestDigest != nil { try await save(&work, budget: budget) }
                    if flow.blockedStatus != nil { return }
                    continue
                }
            }
            guard let manifest = flow.manifest else { throw malformed() }
            if !flow.intakeBegun {
                _ = try await call(
                    remote: receiver, .init("begin", ["manifest": .bytes(manifest)]), budget: &budget)
                flow.intakeBegun = true
            }
            if flow.readyToCommit {
                try await commit(
                    direction, receiver: receiver, pending: pending, flow: &flow, work: &work, budget: &budget
                )
                continue
            }
            if flow.resumePage == nil {
                try budget.page()
                let request = PeerExchangeRequest(
                    "syncResume",
                    [
                        "packageID": .text(pending.packageID),
                        "round": .text(flow.resumeRound), "ordinal": .integer(flow.resumeOrdinal),
                    ])
                let output = try await call(remote: receiver, request, budget: &budget)
                flow.resumeOrdinal += 1
                flow.resumeStarted = true
                guard try text(output["packageID"]) == pending.packageID,
                    try text(output["manifestDigest"]) == pending.manifestDigest
                else { throw malformed() }
                let objects = try list(output["objects"]).map { value -> ResumeObject in
                    guard let fields = value.map, let raw = fields["descriptor"] else { throw malformed() }
                    let descriptor = try PeerSyncDescriptor(raw)
                    let offset = try integer(fields["nextOffset"])
                    guard offset <= descriptor.length else { throw malformed() }
                    return ResumeObject(
                        descriptor: descriptor, offset: offset, verified: try bool(fields["verifiedComplete"])
                    )
                }
                flow.resumePage = ResumePage(
                    objects: objects, complete: try bool(output["complete"]),
                    blocked: try bool(output["blockedOnIndex"]))
                flow.objectIndex = 0
                flow.objectOffset = nil
            }
            guard let page = flow.resumePage else { throw malformed() }
            while flow.objectIndex < page.objects.count {
                let object = page.objects[flow.objectIndex]
                let descriptor = object.descriptor
                if object.verified {
                    flow.objectIndex += 1
                    flow.objectOffset = nil
                    continue
                }
                let offset = flow.objectOffset ?? object.offset
                if offset == descriptor.length && descriptor.length > 0 {
                    flow.objectIndex += 1
                    flow.objectOffset = nil
                    continue
                }
                if !flow.chunkCharged {
                    try budget.chunk()
                    flow.chunkCharged = true
                }
                if flow.chunk == nil {
                    let response = try await call(
                        remote: sender,
                        .init(
                            "exportRead",
                            [
                                "descriptor": descriptor.value, "offset": .integer(Int64(offset)),
                            ]), budget: &budget)
                    guard let raw = response["descriptor"],
                        try PeerSyncDescriptor(raw).value == descriptor.value,
                        try integer(response["offset"]) == offset, case .bytes(let data) = response["bytes"],
                        data.count == min(descriptor.chunkBytes, descriptor.length - offset)
                    else { throw malformed() }
                    flow.chunk = Chunk(descriptor: descriptor, offset: offset, bytes: data)
                }
                guard let chunk = flow.chunk else { throw malformed() }
                _ = try await call(
                    remote: receiver,
                    .init(
                        "append",
                        [
                            "packageID": .text(pending.packageID),
                            "descriptor": chunk.descriptor.value, "offset": .integer(Int64(chunk.offset)),
                            "bytes": .bytes(chunk.bytes),
                        ]), budget: &budget)
                flow.chunk = nil
                flow.chunkCharged = false
                flow.objectOffset = offset + chunk.bytes.count  // Only after acknowledged exact append.
                if flow.objectOffset == descriptor.length {
                    flow.objectIndex += 1
                    flow.objectOffset = nil
                }
            }
            flow.resumePage = nil
            if !page.complete || page.blocked { continue }
            flow.readyToCommit = true
            try await commit(
                direction, receiver: receiver, pending: pending, flow: &flow, work: &work, budget: &budget)
        }
    }
    private func commit(
        _ direction: Direction, receiver: Bool, pending: PeerSyncWork.Transfer,
        flow: inout Flow, work: inout PeerSyncWork, budget: inout Budget
    ) async throws {
        let result = try await call(
            remote: receiver, .init("commit", ["packageID": .text(pending.packageID)]), budget: &budget)
        guard try text(result["packageID"]) == pending.packageID else { throw malformed() }
        let missing = try integer(result["missing"])
        let held = try integer(result["held"])
        let rejected = try integer(result["rejected"])
        _ = try integer(result["stored"])
        _ = try integer(result["accepted"])
        let outcome = missing > 0 ? "missing" : rejected > 0 ? "rejected" : held > 0 ? "held" : "accepted"
        let completion = try PeerSyncWork.Completion(pending, outcome: outcome)
        if direction == .outbound {
            work.completedOutbound = completion
        } else {
            work.completedInbound = completion
        }
        budget.report.packagesCommitted += 1
        if missing > 0 { budget.report.note(.missing) }
        setTransfer(nil, direction, &work)
        try await save(&work, budget: budget)
        flow.resetTransfer(nil)
        // Recompare the current page, including deferred availability, before advancing it.
        if held > 0 { budget.report.note(.held) }
        if rejected > 0 { budget.report.note(.rejected) }
    }
    /// Retry at most one exact sealed pending receipt per direction/job. Derived discovery is
    /// reconstructed from canonical intake journals after index loss; held bytes do not block scans.
    private func retryPending(
        _ direction: Direction, stamp: String, flow: inout Flow,
        budget: inout Budget
    ) async throws {
        let receiver = direction == .outbound
        if flow.retryFinished {
            guard flow.retryStamp != stamp else { return }
            flow.retryStamp = stamp
            flow.retryFinished = false
            flow.retryAfter = ""
            flow.retryPackages = []
            flow.retryPageComplete = false
        }
        if flow.retryPackages.isEmpty {
            try budget.page()
            let page = try await call(
                remote: receiver, .init("pendingIntakes", ["afterID": .text(flow.retryAfter)]),
                budget: &budget)
            flow.retryPackages = try list(page["packages"], maximum: 16).map { try text($0) }
            flow.retryAfter = try text(page["afterID"])
            flow.retryPageComplete = try bool(page["complete"])
        }
        if let package = flow.retryPackages.first {
            let result = try await call(
                remote: receiver, .init("commit", ["packageID": .text(package)]), budget: &budget)
            guard try text(result["packageID"]) == package else { throw malformed() }
            if try integer(result["held"]) > 0 { budget.report.note(.held) }
            if try integer(result["missing"]) > 0 { budget.report.note(.missing) }
            if try integer(result["rejected"]) > 0 { budget.report.note(.rejected) }
            flow.retryPackages.removeFirst()
        }
        if flow.retryPackages.isEmpty, flow.retryPageComplete { flow.retryFinished = true }
    }
    private func acceptStatus(
        _ status: [String: ItemValue], pending: inout PeerSyncWork.Transfer,
        flow: inout Flow
    ) throws {
        flow.phase = try text(status["phase"])
        guard ["selecting", "closure", "leaves", "indexes", "sealed"].contains(flow.phase!) else {
            throw malformed()
        }
        if case .bytes(let manifest) = status["manifest"] {
            let digest = try PeerSyncWork.manifestDigest(
                manifest, packageID: pending.packageID, storeID: binding.storeID)
            guard pending.manifestDigest == nil || pending.manifestDigest == digest else {
                throw TractandaError("peerObjectCollision", "Resumed sealed manifest differs.")
            }
            pending.manifestDigest = digest
            flow.manifest = manifest
        } else {
            guard pending.manifestDigest == nil, flow.phase != "sealed" else {
                throw TractandaError("peerRepairRequired", "Sealed export lost its manifest.")
            }
            if try integer(status["unsupported"]) > 0 {
                flow.blockedStatus = .unsupported
            } else if try integer(status["missing"]) > 0 {
                flow.blockedStatus = .missing
            }
        }
    }
}
