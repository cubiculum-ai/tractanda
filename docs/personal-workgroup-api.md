# Personal/workgroup entrypoints

These are source contracts. Installed services and existing stores remain unchanged until separately authorized preparation and deployment.

## Creation and opening

`ItemStore.initializeFresh(...)` now creates the personal/workgroup profile, using the supplied local access policy or the creating OS account. It creates no canonical policy item. Its bounded initialization key is an accepted request label, not historical authorization or permission to replace an established policy.

`ItemStore.openInitialized(...)` accepts a named active or interrupted personal profile and opens the fully initialized ordinary runtime. Historical-authority installations and raw content trees without that profile return `personalMigrationRequired`; opening never silently converts them.

The underlying explicit APIs are `initializePersonalWorkgroup`, `openPersonalWorkgroup` and `activatePersonalWorkgroupContent`. Selected activation requires deliberately prepared committed content. Preparation may preserve canonical files in place while retaining old operational/pending data separately; there is no canonical-copy or old-ledger prerequisite. Preparation of a particular installation remains a separate operation.

Setup bootstrap uses the same creation contract under the selected service UID. Read-only Setup inspection passes the expected filesystem owner through profile, fence, StoreID and replica reads; it does not assume the inspecting process owns daemon files.

## Current local policy

`ItemStore.configurePersonalAccess(_:)` atomically replaces current OS admission/admin settings. Old `AccessConfigurationItem` revisions remain content and do not reinstall policy during rebuilding. Item ownership/group/ACL changes still create revisions; current rights govern all history.

The native method is `TractandaStore/configureAccess`. Its only argument is `configuration`, containing a complete tagged `ItemValue` descriptor with the existing `tractanda.access.v1` shape. The caller must be a current administrator. Its result contains `state`, `configured: true` and `persistenceProfile: "personal-workgroup"`. This is settings replacement, not an item commit or fabricated policy revision. Pending query delivery rechecks the new admission policy.

`tractanda configure-access STORE POLICY_JSON REQUEST_LABEL` reads that same tagged descriptor and returns those acknowledgement fields. The bounded label is accepted but is not a persistent canonical replay receipt. Item-operation intents and replay receipts remain in ordinary revisions. The old canonical-item `configureAccess` Core helper is not the personal policy route.

If publication becomes uncertain after replacing the policy file, the object stops serving data and cannot rebuild under stale admission. Reopening reads current policy before restoring readiness.

## Service contract

Item/query/get/history/resolve and commit envelopes retain their existing formats. Personal history uses the existing bounded serial path because the historical pooled optimization assumes projection rows. This is a performance follow-up, not a proof requirement. Pooled query/get delivery still rechecks current access and state.

`TractandaStore/info` adds `persistenceProfile`, `clustering.state: "unsupported"` and `activeCanonicalFormats`. Existing `canonicalFormats` remains the software declaration used for signed-bundle comparison; the active declaration describes this personal runtime. The personal capability and reader/writer fence use level16.

Daemon startup rejects any configured peer-runtime path before reading it, opening Store, binding listeners or claiming readiness. Fresh/disabled personal managed definitions omit that argument; nonnil retained settings prevent registration. Startup erases no peer configuration or secrets. Fresh pairing remains future work; no active cluster is advertised.

Asynchronous rebuilding retains cancellation, genuine capacity checks, bounded chunk/page work and publication authorization. Counters follow actual verified/projected work. Cancellation leaves canonical bytes intact, publishes no partial index and reports `requiresRecovery`/`indexTrusted` truthfully. Private process-level fault tests do not establish hardware power-loss guarantees.


## Local content inspection and activation

- `tractanda inspect-content STORE [--owner OS_USER] [--output PRIVATE_JSON]`
- `tractanda activate-content STORE TAGGED_CONFIG_JSON --index-directory PATH`

Both commands require an explicit local path and reject connection/profile options before any resolution or autostart. They are not remote server/MCP file operations. Inspection uses the explicit account's expected UID, or infers the root's filesystem owner; it does not impersonate that owner and needs actual filesystem read permission. It creates no profile, identity, writer marker, placement database or index. An existing writer lock is opened read-only and shared-locked nonblocking; an active cooperating writer is refused. A raw root without a lock must be explicitly kept offline/stable. Per-file checks do not establish a concurrent snapshot.

`ContentInspectionReport` (`tractanda.content-inspection.v1`) contains bounded item/revision IDs, explicit parents, physical heads including deletion, original envelope sizes/SHA256, relative locations and diagnostic kinds. Referenced originals and saved-content document descriptors include only successfully streamed/hash-checked locations. Empty verified-location lists and diagnostics disclose missing/invalid data. Orphan/unreferenced bytes are not verified or listed; inline document bytes are covered by their original revision-envelope digest. No item/document text, old control contents or credentials are emitted. Byte-budget counters describe charged I/O windows, not an assertion that every charged byte passed validation.

The report's completeness is structural DAG/unique-head/referenced-payload scope only. OS identity mapping, old admission, prepared-root status and runtime readiness are explicitly not evaluated. Old-format placement is not historical admission. The report is not an approval/export certificate and is never an activation input. A structurally incomplete report is still emitted with exit2; usage, filesystem and resource errors exit1. `--output` creates a new private0600 file in an existing private caller-owned directory outside the physical source, refusing overwrite/symlinks and source-local destinations. Without it, JSON goes to stdout.

Activation uses the existing selected-content Core API with the explicit tagged local access policy and required index directory. The executing account must own the private content tree. The command does not switch OS identity, move/delete old or unknown entries, promote pending data, copy canonical files, choose conflicting heads or accept a force flag. Unprepared legacy/operational roots are refused. A failed initial attempt may leave its ordinary writer lock/local pending initialization state; canonical and unknown content is retained.

`ContentActivationReport` returns new current runtime StoreID/ReplicaID, profile/state/readiness and item/revision counts, with no canonical policy-item revision. Item/revision identities, history and owned payload bytes remain unchanged. A retry of an already active personal root must match its local policy and retains runtime IDs. Fresh runtime identity can invalidate old client bindings/sessions/cursors/download receipts; reconnect/review is separate from canonical-content preservation.

Routine index loss on an initialized personal store uses normal opening or native `rebuild`, retaining current local configuration/IDs. `activate-content` is the explicit initial prepared-raw-root operation, not a replacement for ordinary rebuilding and not a live migration authorization.
