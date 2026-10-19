import Foundation

/// A host-owned continuation, never a wire cursor or authorization grant. A socket lease
/// fences publication after every await. Ordinary socket rollover retains bounded typed state.
package actor PeerLogicalExchange {
    package struct Lease: Sendable {
        private let owner: PeerLogicalExchange
        private let id: UUID
        fileprivate init(_ owner: PeerLogicalExchange, _ id: UUID) {
            self.owner = owner
            self.id = id
        }
        package func compatibilityAdmission(
            lifetime: PeerCompatibilityLifetime,
            control: PeerExchangeControl
        ) async throws -> PeerCompatibilityAdmission {
            try await owner.compatibilityAdmission(lifetime: lifetime, lease: id, control: control)
        }
        package func adoptCompatibility(
            _ admission: PeerCompatibilityAdmission,
            expectedBinding: PeerExchangeBinding, control: PeerExchangeControl
        ) async throws {
            try await owner.adoptCompatibility(
                admission, expectedBinding: expectedBinding, lease: id, control: control)
        }
        package func advanceCompatibility(_ action: PeerCompatibilityAction, control: PeerExchangeControl)
            async throws -> Data
        {
            try await owner.advanceCompatibility(action, lease: id, control: control)
        }
        package func execute(_ request: Data, control: PeerExchangeControl) async throws -> Data {
            try await owner.execute(request, lease: id, control: control)
        }
        package func authorize(control: PeerExchangeControl) async throws {
            try await owner.authorize(id, control)
        }
        package func detach() async { await owner.detach(id) }
        package func syncWork(_ replacement: PeerSyncWork? = nil, control: PeerExchangeControl) async throws
            -> PeerSyncWork
        {
            try await owner.syncWork(replacement, lease: id, control: control)
        }
    }
    private struct Scan: Sendable {
        let round: UUID
        let ordinal: Int64
        let packageID: String?
        let before: PeerExchangeState
        let limit: Int
        let request: Data
        let response: Data
    }
    private let coordinator: ServiceCoordinator
    private let snapshot: PeerRuntimeSnapshot
    private let maximumScanEntries: Int
    private let contextID = UUID().uuidString.lowercased()
    private var state: PeerExchangeState
    private var inventory: Scan?
    private var resume: Scan?
    private var lease: UUID?
    private var closer: (@Sendable () async -> Void)?
    private var active: PeerExchangeControl?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    private var touched = ProcessInfo.processInfo.systemUptime

    package init(
        coordinator: ServiceCoordinator, binding: PeerExchangeBinding, snapshot: PeerRuntimeSnapshot,
        maximumScanEntries: Int = 128
    ) async throws {
        guard (1...128).contains(maximumScanEntries) else {
            throw TractandaError("resourceLimit", "Invalid logical scan window.")
        }
        self.coordinator = coordinator
        self.snapshot = snapshot
        self.maximumScanEntries = maximumScanEntries
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        var state = try await coordinator.openPeerExchange(binding, control: PeerExchangeControl())
        state.logicalOwner = contextID
        self.state = state
    }
    private func require(_ id: UUID) throws {
        guard !stopped, lease == id else {
            throw TractandaError("peerLeaseChanged", "Logical peer socket lease is no longer current.")
        }
    }
    package func attach(close: @escaping @Sendable () async -> Void) async throws -> Lease {
        guard !stopped else { throw TractandaError("serviceClosed", "Logical peer context is closed.") }
        let id = UUID()
        let previous = closer
        lease = id
        closer = close
        active?.cancel()
        await previous?()
        while active != nil {
            await withCheckedContinuation { waiters.append($0) }
            try require(id)
        }
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        try require(id)
        // Every physical lease must declare and acknowledge afresh.
        state.compatibility = PeerExchangeCompatibility()
        touched = ProcessInfo.processInfo.systemUptime
        return Lease(self, id)
    }
    private func detach(_ id: UUID) {
        guard lease == id else { return }
        lease = nil
        closer = nil
        active?.cancel()
    }
    package func invalidate() async {
        stopped = true
        lease = nil
        active?.cancel()
        let close = closer
        closer = nil
        await close?()
        while active != nil { await withCheckedContinuation { waiters.append($0) } }
        inventory = nil
        resume = nil
        await coordinator.releasePeerLogicalVerification(contextID)
    }
    /// Only genuine unattached idle contexts are reclaimable, never routine cap rollover.
    package func isIdle(before: Double) -> Bool { lease == nil && active == nil && touched < before }
    private func finish() {
        active = nil
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
    private func authorize(_ id: UUID, _ control: PeerExchangeControl) async throws {
        try require(id)
        try control.check()
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        try require(id)
        try control.check()
        try await coordinator.authorizePeerExchange(state, control: control)
        try require(id)
        try control.check()
        try state.compatibility.requireLifetime()
    }
    private func compatibilityAdmission(
        lifetime: PeerCompatibilityLifetime, lease id: UUID,
        control: PeerExchangeControl
    ) async throws -> PeerCompatibilityAdmission {
        try require(id)
        try control.check()
        try lifetime.check()
        guard active == nil, state.compatibility.lifetime == nil else {
            throw PeerExchangeCompatibility.invalid()
        }
        active = control
        defer { finish() }
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        try require(id)
        try control.check()
        try lifetime.check()
        var next = state
        next.compatibility.lifetime = lifetime
        try await coordinator.authorizePeerExchange(next, control: control)
        try require(id)
        try control.check()
        try lifetime.check()
        state = next
        return PeerCompatibilityAdmission(binding: state.binding, compatibility: state.compatibility)
    }
    private func adoptCompatibility(
        _ admission: PeerCompatibilityAdmission,
        expectedBinding: PeerExchangeBinding, lease id: UUID, control: PeerExchangeControl
    ) async throws {
        try require(id)
        try control.check()
        try admission.requireBinding(expectedBinding)
        guard active == nil else {
            throw TractandaError("serviceBusy", "A logical operation is already active.")
        }
        active = control
        defer { finish() }
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        try require(id)
        try control.check()
        try admission.checkLifetime()
        let next = try await coordinator.adoptPeerCompatibility(
            admission, expectedBinding: expectedBinding,
            state: state, control: control)
        try require(id)
        try control.check()
        try admission.checkLifetime()
        state = next  // Only compatibility changes; current logical cursors and work remain owned here.
    }
    private func advanceCompatibility(
        _ action: PeerCompatibilityAction, lease id: UUID,
        control: PeerExchangeControl
    ) async throws -> Data {
        try require(id)
        try control.check()
        guard active == nil else {
            throw TractandaError("serviceBusy", "A logical operation is already active.")
        }
        active = control
        defer { finish() }
        try await coordinator.validatePeerRuntimeSnapshot(snapshot)
        try require(id)
        try control.check()
        let step = try await coordinator.advancePeerCompatibility(action, state: state, control: control)
        try require(id)
        try control.check()
        state = step.state
        return step.response
    }
    private func syncWork(_ replacement: PeerSyncWork?, lease id: UUID, control: PeerExchangeControl)
        async throws -> PeerSyncWork
    {
        try require(id)
        guard active == nil else {
            throw TractandaError("serviceBusy", "A logical operation is already active.")
        }
        active = control
        defer { finish() }
        try await authorize(id, control)
        let work = try await coordinator.peerSyncWork(
            state: state, replacement: replacement, control: control)
        try await authorize(id, control)
        return work
    }
    private func execute(_ bytes: Data, lease id: UUID, control: PeerExchangeControl) async throws -> Data {
        try require(id)
        guard active == nil else {
            throw TractandaError("serviceBusy", "A logical operation is already active.")
        }
        active = control
        defer { finish() }
        return try await withTaskCancellationHandler {
            try await authorize(id, control)
            let request = try PeerPackage.decode(PeerExchangeRequest.self, bytes, maximum: 2 * 1024 * 1024)
            if request.operation == "syncContext" {
                guard request.fields.isEmpty else { throw invalid() }
                return try JSON.encode(["contextID": ItemValue.text(contextID)])
            }
            var replay: Scan?
            var scanRound: UUID?
            var ordinal: Int64 = 0
            var packageID: String?
            var operation = request
            let isInventory = request.operation == "syncInventory"
            let isResume = request.operation == "syncResume"
            if isInventory || isResume {
                let keys: Set<String> =
                    isInventory ? ["round", "ordinal"] : ["round", "ordinal", "packageID"]
                guard Set(request.fields.keys) == keys,
                    case .text(let roundText) = request.fields["round"],
                    let round = UUID(uuidString: roundText),
                    case .integer(let number) = request.fields["ordinal"], number >= 0, number < Int64.max
                else { throw invalid() }
                scanRound = round
                ordinal = number
                if isResume { packageID = try AuthorityRecord.persistentID(request.fields["packageID"]) }
                let old = isInventory ? inventory : resume
                if let old, old.round == round {
                    guard old.packageID == packageID else { throw invalid() }
                    if ordinal == old.ordinal {
                        replay = old
                    } else {
                        guard ordinal == old.ordinal + 1 else { throw invalid() }
                    }
                } else {
                    guard ordinal == 0 else { throw invalid() }
                }
                operation = .init(
                    isInventory
                        ? (ordinal == 0 ? "inventory" : "inventoryNext")
                        : (ordinal == 0 ? "resume" : "resumeNext"),
                    isResume && ordinal == 0 ? ["packageID": .text(packageID!)] : [:])
            }
            var before = replay?.before ?? state
            // Cached cursors never restore an earlier physical admission.
            before.compatibility = state.compatibility
            var encoded = try JSON.encode(operation)
            if let replay { encoded = replay.request }
            var limit = replay?.limit ?? maximumScanEntries
            let step: PeerExchangeStep
            while true {
                do {
                    step = try await coordinator.performPeerExchange(
                        encoded, state: before,
                        control: control, scanLimit: limit)
                    break
                } catch let error as TractandaError
                    where replay == nil && scanRound != nil
                    && limit > 1 && ["resourceLimit", "peerPayloadVerifying"].contains(error.code)
                {
                    // Preserve the same trusted starting cursor; a bounded smaller page can
                    // progress when128 individually valid records exceed the aggregate window.
                    try require(id)
                    try control.check()
                    limit /= 2
                }
            }
            try await authorize(id, control)
            try require(id)
            if let replay {
                try validateReplay(old: replay.response, fresh: step.response, inventory: isInventory)
                touched = ProcessInfo.processInfo.systemUptime
                return replay.response
            }
            // Bound both retained snapshots plus two responses independently of the pairing cap.
            guard try step.state.retainedByteCount() <= 128 * 1024 else {
                throw TractandaError("resourceLimit", "Logical continuation exceeds its state reservation.")
            }
            let priorInventory = inventory
            let priorResume = resume
            var published = false
            defer {
                if !published {
                    inventory = priorInventory
                    resume = priorResume
                }
            }
            if let round = scanRound {
                // Initial inventory replay must retain its original finite boundary, not capture
                // a later ordinary write. Reset only the before-page cursor/completion fields.
                if isInventory && ordinal == 0 {
                    before.boundary = step.state.boundary
                    before.inventoryCursor = nil
                    before.inventoryComplete = false
                    before.checkpoint = nil
                    encoded = try JSON.encode(PeerExchangeRequest("inventoryNext"))
                }
                guard step.response.count <= 128 * 1024 else { throw invalid() }
                let scan = Scan(
                    round: round, ordinal: ordinal, packageID: packageID,
                    before: before, limit: limit, request: encoded, response: step.response)
                if isInventory { inventory = scan } else { resume = scan }
            }
            let retained =
                try step.state.retainedByteCount()
                + (inventory.map { try $0.before.retainedByteCount() + $0.response.count } ?? 0)
                + (resume.map { try $0.before.retainedByteCount() + $0.response.count } ?? 0)
            guard retained <= 512 * 1024 else {
                throw TractandaError("resourceLimit", "Logical context exceeds its 512KiB reservation.")
            }
            state = step.state
            published = true
            touched = ProcessInfo.processInfo.systemUptime
            return step.response
        } onCancel: {
            control.cancel()
        }
    }
    private func validateReplay(old: Data, fresh: Data, inventory: Bool) throws {
        let a = try JSON.decode([String: ItemValue].self, old)
        let b = try JSON.decode([String: ItemValue].self, fresh)
        let key = inventory ? "entries" : "objects"
        guard case .list(let cached) = a[key], case .list(let current) = b[key], current.count >= cached.count
        else { throw invalid() }
        for (old, fresh) in zip(cached, current) {
            guard old.map?["descriptor"] == fresh.map?["descriptor"] else { throw invalid() }
            if !inventory {
                guard let oldOffset = old.map?["nextOffset"]?.integerValue,
                    let newOffset = fresh.map?["nextOffset"]?.integerValue, oldOffset <= newOffset,
                    old.map?["verifiedComplete"] != .boolean(true)
                        || fresh.map?["verifiedComplete"] == .boolean(true)
                else { throw invalid() }
            }
        }
    }
    private func invalid() -> TractandaError {
        TractandaError("invalidPeerCursor", "Logical scan ordinal or current proof differs.")
    }
}
