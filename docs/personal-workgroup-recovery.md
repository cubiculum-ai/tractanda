# Personal and workgroup recovery model

The accepted recovery target serves personal, family, and small-workgroup use. Its content baseline is committed item revisions and their owned payloads, interpreted through current OS users, groups, and separately established local configuration. SQLite indexes, completed replication bookkeeping, old peer secrets, and historical authority/audit controls are not required content-recovery inputs. Unaccepted incoming stages remain separate.

**Installed versus staged.** The simplified Raven–Stash cluster was delivered from source `9712a931d07e25771074676bdc55ea97660d86f3`; the later Stash uuidd package update preserved its product payload and canonical history. TRAC-119 roaming and TRAC-120 robustness are staged source changes, not changes to those running services. No public release is implied. Current timestamped receipts and pending work are recorded in [the resume checkpoint](../outputs/Tractanda-Resume.md), [roaming evidence](../work/roaming-peer-20261025/RESULT.md), and the TRAC-120 evidence under `work/robustness-20261025/`.

## Content and current access

Each item revision carries its identity, author, explicit parent revision references, timestamps, owner/group/ACL, deletion state, and owned attachment references. Permission changes create revisions, and current permissions govern all history. Tombstones and independent offline branches remain ordinary history; timestamps alone do not establish causality or duplication. Unix accounts and groups supply identities.

Conflicting permissions consolidate restrictively; owners may relax them later. For owner/group, the latest authorized revision actually changing the field wins. UUIDv1 encoded ticks order these actual changes, with deterministic revision-ID ordering for exact ties; UUID time is not a clock-accuracy guarantee. Unrelated stale snapshots do not supersede an actual ownership change.

Ordinary opening requires an established personal profile. Raw or historical-format roots return `personalMigrationRequired` until an administrator explicitly selects their content and establishes fresh local configuration. Old-format placement alone does not certify previous admission. Selected-content recovery inventories that explicit set and its payload closure; it does not require an old ledger to certify the selection.

Personal startup reconstructs a fresh disposable SQLite index from canonical content. It validates ancestry, current ACL projection, and referenced payloads before publishing the index. Missing or damaged indexes can be rebuilt; missing/corrupt canonical content, changed store identity, unsafe custody, and insufficient real free capacity remain explicit errors. Recovery never promotes incoming stages or restores historical peer trust.

## Durable acknowledgement and interruption

The staged robustness implementation acknowledges personal writes only after file and publication-directory durability barriers succeed. Linux uses `fsync`; macOS also requests `F_FULLFSYNC`. Owned originals and saved documents flush on their actual destination filesystem, so a revision on another volume does not stand in for their durability. The reader capability floor becomes durable before publishing content that needs its new meaning. These barriers add storage latency.

If a personal revision may already exist but its durable acknowledgement fails, the operation returns `uncertainCommit`. Its canonical bytes and operation ID remain. Retry the exact request with the same operation ID; never invent a replacement operation merely because the response was uncertain.

A running service can repair an interrupted canonical publication before its next admitted request. The serial Store owner revalidates current local identity/policy, drains and retires pooled SQLite handles before replacing the index, and rebuilds from canonical content only. It then resumes pooled readers; private incoming stages remain private. Healthy recovery/drain work waits for completion with cooperative shutdown cancellation, without a new elapsed-time failure threshold.

A failed transient recovery is coalesced: later requests receive the retained error until a retry delay has elapsed. `TRACTANDA_PERSONAL_RECOVERY_RETRY_SECONDS` sets that delay, default 30 seconds, measured from failure completion. This delay does not terminate active work. Canonical corruption or ambiguous identity/policy requires explicit repair and reopen instead of repeated automatic scans.

Completed membership preparation and baseline cleanup synchronize the root and flush its retained, validated reader-fence file on the same filesystem. An already-absent cleanup leaf still executes that barrier after an uncertain earlier unlink. Exact completed-membership retry removes only its own matching preparation and preserves a later different preparation. In-process baseline cleanup retry retains its exact finalization token after projection completion; this is temporary operation state, not another persisted history ledger.

Apple documents the distinction between [file synchronization](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html) and [the full-flush operation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html). A flush remains dependent on storage honoring its promises; Apple describes even the stronger operation as a [best-effort persistence guarantee](https://developer.apple.com/documentation/xcode/reducing-disk-writes). Fault injection and abrupt subprocess exit test application ordering and process-crash recovery; they do not prove physical power-cut behavior on arbitrary devices.

## Membership and compatible upgrades

Explicit fresh pairing and current administrator-controlled membership govern peer access. Additions require all current members plus the joining node online; removals require all retained members online, while the departing node may be offline. Any current member may initiate. Omitted peers are out; an explicitly readmitted peer is in. Replicated content cannot overwrite local membership or credentials. Fresh-cluster recovery establishes new pairing rather than resurrecting old trust. Preserve the old Stash archive without merging its dataset into the current cluster.

For ordinary compatible upgrades of established protected personal stores, stopped-writer checks use the durable monotonic reader fence under the existing writer lock. They validate current root custody, personal profile, StoreID/ReplicaID, and supported reader requirements without decoding every item. Missing, weakened, unsupported, or cross-store markers fail closed; this path never manufactures or weakens a marker. It proves reader compatibility, not content integrity. Explicit import, selected-content recovery, and migration retain their inventory checks. Breaking formats/merge semantics retain coordinated maintenance across all current members.

A future enterprise import preserves common identities, ordinary history, content, attachments, and supported permissions while beginning an honest audit baseline at import time. Export to this edition may discard enterprise-only auditing and must disclose unsupported semantic mappings. Enterprise implementation and backend choice remain separate future work.

See [personal/workgroup entrypoints](personal-workgroup-api.md) and [peer enrollment](personal-peer-enrollment.md) for the current APIs. These documents describe source contracts; they do not authorize deployment or publication.
