import Foundation

extension AuthorityStore {
    /// Bounded review-domain input only. Neither constructor proves canonical stream closure,
    /// administrator rights, source/current permission or historical acceptance. Store must
    /// compare the frozen canonical stage and validate the complete D/B/C review before use.
    struct ReviewControlSummary: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case legacy, atomic }
        let kind: Kind
        let originalBytes: Data
        let binding: AuthorityBinding
        let origin: String
        let actor: String
        let createdAt: String
        let previous: AuthorityBinding?
        let bootstrap: AuthorityBinding?
        let parents: [AuthorityBinding]
        let deltas: [DispositionDelta]

        init(legacy: VerifiedControlPlan) throws {
            let reopened = try VerifiedControlPlan(
                control: AuthorityRecordCodec.decode(legacy.control.originalBytes))
            guard reopened == legacy else {
                throw Self.invalid("Legacy review summary changed its exact original plan.")
            }
            try Self.requireShape(
                binding: legacy.binding, previous: legacy.localParent,
                parents: legacy.parents, deltas: legacy.deltas)
            kind = .legacy
            originalBytes = legacy.control.originalBytes
            binding = legacy.binding
            origin = legacy.control.record.originReplicaID
            actor = legacy.control.record.actorPrincipal
            createdAt = legacy.control.record.createdAt
            previous = legacy.localParent
            bootstrap = legacy.bootstrap
            parents = legacy.parents
            deltas = legacy.deltas
        }

        init(
            atomic: AtomicControlStage, parents: [AuthorityBinding], supports: [LogicalControlSource.Support]
        ) throws {
            guard parents.count == 1, supports.count == 2,
                supports[0].ordinal == 0, supports[1].ordinal == 1,
                atomic.parents.entryCount == 1, atomic.parents.targetCount == 0,
                atomic.effects.entryCount == 2, atomic.effects.targetCount == 2
            else {
                throw Self.invalid("Review summary requires one PRE parent and exactly two target effects.")
            }
            let reopened = try AtomicControlStage(rootBytes: atomic.rootBytes)
            guard reopened == atomic else {
                throw Self.invalid("Atomic review summary changed its exact original stage.")
            }
            for support in supports {
                try AtomicAuthorityEntryStream.validate(support.delta.itemValue, section: .effects)
                guard
                    support.fingerprint
                        == AuthorityRecordCodec.sha256(try JSON.encode(support.delta.itemValue))
                else {
                    throw Self.invalid("Review support fingerprint differs from its complete typed fact.")
                }
            }
            let deltas = supports.map(\.delta)
            try Self.requireShape(
                binding: atomic.header.binding, previous: atomic.header.previous, parents: parents,
                deltas: deltas)
            let parentBytes = try AtomicAuthorityEntryStream.frame(parents[0].itemValue, section: .parents)
                .count
            let effectBytes = try deltas.reduce(0) {
                $0 + (try AtomicAuthorityEntryStream.frame($1.itemValue, section: .effects)).count
            }
            guard atomic.parents.byteCount == Int64(parentBytes),
                atomic.effects.byteCount == Int64(effectBytes)
            else {
                throw Self.invalid(
                    "Review stream byte counts differ from the supplied complete typed entries.")
            }
            kind = .atomic
            originalBytes = atomic.rootBytes
            binding = atomic.header.binding
            origin = atomic.header.origin
            actor = atomic.header.actor
            createdAt = atomic.header.createdAt
            previous = atomic.header.previous
            bootstrap = atomic.header.bootstrap
            self.parents = parents
            self.deltas = deltas
        }

        private static func requireShape(
            binding: AuthorityBinding, previous: AuthorityBinding?, parents: [AuthorityBinding],
            deltas: [DispositionDelta]
        ) throws {
            // This review producer joins its complete source cut before D. Its post-control
            // therefore has one original PRE. This is not a general atomic-control parent cap;
            // Store still proves that complete joined cut and the actual decision D.
            guard let previous, parents == [previous], previous.recordID != binding.recordID,
                deltas.count == 2, deltas.allSatisfy({ $0.eligible && $0.evidence != nil }),
                deltas[0].target.revisionID < deltas[1].target.revisionID,
                deltas[0].target.itemID == deltas[1].target.itemID,
                deltas[0].causes.count == 1, deltas[0].causes == deltas[1].causes,
                deltas[0].causes[0].recordID != binding.recordID,
                deltas[0].causes[0].recordID != previous.recordID
            else {
                throw invalid(
                    "Review post-control must bind its PRE and distinct positive B/C pair to one decision.")
            }
            for delta in deltas {
                try AtomicAuthorityEntryStream.validate(delta.itemValue, section: .effects)
            }
        }
        private static func invalid(_ message: String) -> TractandaError {
            .init("invalidAuthority", message)
        }
    }
}
