import CSQLite
import Foundation

/// Queue-confined private Store input work. It binds a frozen SQL stage to one whole immutable
/// canonical closure across work windows. Completion is structural only, never an authority seal.
/// Store supplies a fresh context/writer-custody check and validates all semantics before sealing.
final class AtomicAuthorityStageValidation {
    private let index: ItemIndex
    let stage: AtomicControlStage
    private let archive: AtomicAuthorityArchive
    private let handle: AtomicAuthorityArchive.Handle
    private let contextCheck: () throws -> Void
    private var freeze: ItemIndex.AtomicStageFreeze?
    private var reader: AtomicAuthorityArchive.Reader?
    private var pending: [AtomicAuthorityArchive.UntrustedStagingFact] = []
    private var pendingOffset = 0
    private var streamComplete = false
    private var staging: Bool
    private var parents: Int64 = 0
    private var supports: Int64 = 0
    private var domainSection: AtomicAuthorityFormat.Section = .parents
    private var domainRow: Int64?
    private var domainCount: Int64 = 0
    private(set) var complete = false
    private(set) var waitingForPart: AuthorityBinding?
    private var closed = false
    private var failed = false
    private(set) var parsedWindows: Int64 = 0
    private(set) var comparedFacts: Int64 = 0

    init(
        index: ItemIndex, stage: AtomicControlStage, archive: AtomicAuthorityArchive,
        handle: AtomicAuthorityArchive.Handle, contextCheck: @escaping () throws -> Void
    ) throws {
        self.index = index
        self.stage = stage
        self.archive = archive
        self.handle = handle
        self.contextCheck = contextCheck
        guard stage.header.binding == handle.binding,
            try archive.rootBytes(handle) == stage.rootBytes
        else { throw AtomicAuthorityFormat.invalid("Canonical work requires its exact reserved root.") }
        try contextCheck()
        try index.initializeAtomicAuthoritySchema()
        try index.beginAtomicControlStage(stage)
        staging = try !index.atomicStatus(stage).complete
        if !staging { freeze = try index.freezeAtomicStage(stage.header.binding) }
        do {
            reader = try archive.beginValidation(handle)
        } catch {
            if let freeze { try? index.releaseAtomicStageFreeze(freeze) }
            freeze = nil
            throw error
        }
    }
    deinit { try? close() }

    /// The parser callback only buffers one physical leaf's untrusted facts plus its carried entry.
    /// SQL work runs afterwards. A healthy quantum yield never throws through Reader/Decoder,
    /// never resets a parse prefix, and never grants completion while a buffered fact remains.
    func step(maximumFacts: Int = 128) throws -> Bool {
        try index.withCatalogueScanBudget(reusingActiveBudget: true) {
            try self.stepBody(maximumFacts: maximumFacts)
        }
    }
    private func stepBody(maximumFacts: Int) throws -> Bool {
        guard !closed, !failed, (1...128).contains(maximumFacts), let reader else {
            throw AtomicAuthorityFormat.invalid("Closed/failed atomic canonical comparison.")
        }
        do {
            try check()
            if complete { return true }
            var work = 0
            while work < maximumFacts {
                guard try index.atomicPrivateWindowHasRoom() else { return false }
                if pendingOffset < pending.count {
                    let fact = pending[pendingOffset]
                    let ordinal = fact.section == .parents ? parents : supports
                    if staging {
                        try index.appendAtomicControlEntry(
                            stage, section: fact.section,
                            ordinal: ordinal, value: fact.value)
                    } else {
                        try index.compareAtomicStagedFact(stage, fact: fact, ordinal: ordinal)
                    }
                    if fact.section == .parents { parents += 1 } else { supports += 1 }
                    if !staging { comparedFacts += 1 }
                    pendingOffset += 1
                    work += 1
                    continue
                }
                pending.removeAll(keepingCapacity: true)
                pendingOffset = 0
                if !streamComplete {
                    var bytes = 0
                    let bound =
                        try AtomicAuthorityEntryStream.maximumEntryBytes(.effects)
                        + AtomicAuthorityFormat.maximumChunkBytes
                    let receive: (AtomicAuthorityArchive.UntrustedStagingFact) throws -> Void = { fact in
                        // Data/custody/shape failures remain terminal parser errors. No quota-consuming
                        // SQL, ACL evaluation or healthy-yield exception may enter this callback.
                        bytes += try JSON.encode(fact.value).count
                        guard bytes <= bound else {
                            throw AtomicAuthorityFormat.invalid(
                                "Untrusted atomic leaf queue exceeds its model bound.")
                        }
                        self.pending.append(fact)
                    }
                    let window = AtomicAuthorityArchive.Window(
                        maximumParts: 1, maximumBytes: AtomicAuthorityFormat.maximumEnvelopeBytes)
                    let structure =
                        try staging
                        ? reader.stageAvailableWindow(window: window, onUntrustedFact: receive)
                        : reader.stageWindow(window: window, onUntrustedFact: receive)
                    waitingForPart = reader.waitingForPart
                    if waitingForPart != nil { return false }
                    parsedWindows += 1
                    streamComplete = structure != nil
                    work += 1
                    continue
                }
                if staging {
                    guard parents == stage.parents.entryCount, supports == stage.effects.entryCount else {
                        throw AtomicAuthorityFormat.invalid(
                            "Untrusted staging stream counts differ from root.")
                    }
                    try index.finishAtomicControlStage(stage)
                    try reader.close()
                    freeze = try index.freezeAtomicStage(stage.header.binding)
                    self.reader = try archive.beginValidation(handle)
                    parents = 0
                    supports = 0
                    streamComplete = false
                    staging = false
                    // The next native call continues comparison with the new reader. Do not
                    // continue using this call's captured (now closed) initial-stage reader.
                    return false
                }
                let expected = domainSection == .parents ? stage.parents.entryCount : stage.effects.entryCount
                let batch = try index.atomicRowDomainPage(
                    stage, section: domainSection, afterRow: domainRow, limit: 1)
                domainCount = try AtomicAuthorityFormat.sum(domainCount, batch.count)
                guard domainCount <= expected else {
                    throw AtomicAuthorityFormat.invalid("Frozen stage contains extra noncanonical rows.")
                }
                domainRow = batch.lastRow
                work += 1
                if batch.count != 0 { continue }
                guard domainCount == expected else {
                    throw AtomicAuthorityFormat.invalid("Frozen stage row count differs from its root.")
                }
                if domainSection == .parents {
                    domainSection = .effects
                    domainRow = nil
                    domainCount = 0
                } else {
                    let status = try index.atomicStatus(stage)
                    guard parents == stage.parents.entryCount, supports == stage.effects.entryCount,
                        status.parents == parents, status.facts == supports,
                        status.targets == stage.effects.targetCount, status.complete
                    else {
                        throw AtomicAuthorityFormat.invalid(
                            "Frozen stage summaries differ from canonical input.")
                    }
                    try check()
                    complete = true
                    return true
                }
            }
            try check()
            return false
        } catch {
            failed = true
            try? close()
            throw error
        }
    }

    /// Store is the only semantic caller. Fresh context and all-row prefix binding are rechecked
    /// under BEGIN IMMEDIATE before its validation/seal/activation closure. That closure may not
    /// expose success until the canonical accepted proof and the one derived commit are durable.
    func withFinalWriter<T>(
        existingAcceptance: AtomicAuthorityAcceptance.Sealed? = nil,
        _ body: (LogicalControlSource) throws -> T
    ) throws -> T {
        guard complete, !closed, !failed else {
            throw AtomicAuthorityFormat.invalid("Private comparison is not complete.")
        }
        if let existingAcceptance, existingAcceptance.receipt.root != stage.header.binding {
            throw AtomicAuthorityFormat.invalid("Historical final writer names another accepted root.")
        }
        defer { try? close() }
        return try index.withAtomicFinalWriter(existingAcceptance: existingAcceptance) {
            try self.check()
            let previous = self.index.activeAtomicControlFinalization
            self.index.activeAtomicControlFinalization = self.stage.header.binding
            defer { self.index.activeAtomicControlFinalization = previous }
            let result = try body(.atomic(self.stage))
            // Activation legitimately changes current heads/policies, so do not compare the old
            // semantic digest here. Immutable canonical input and the frozen SQL epoch, however,
            // must still be unchanged before COMMIT (including trigger/prepared writes in body).
            guard let freeze = self.freeze else {
                throw AtomicAuthorityFormat.invalid("Atomic finalization lost its input lease.")
            }
            try self.index.checkAtomicStageFreeze(freeze)
            guard try self.reader?.recheckRoot() == self.stage.rootBytes else {
                throw AtomicAuthorityFormat.invalid("Canonical root changed during finalization.")
            }
            return result
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        if let freeze {
            try index.checkAtomicStageFreeze(freeze)
        } else if !staging {
            throw AtomicAuthorityFormat.invalid("Atomic comparison lease is absent.")
        }
        try contextCheck()
        guard try reader?.recheckRoot() == stage.rootBytes else {
            throw AtomicAuthorityFormat.invalid("Canonical root changed during private comparison.")
        }
    }
    func close() throws {
        guard !closed else { return }
        closed = true
        defer {
            if let freeze { try? index.releaseAtomicStageFreeze(freeze) }
            freeze = nil
            reader = nil
            pending.removeAll()
        }
        try reader?.close()
    }
}
