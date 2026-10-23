# Server clustering contract and implementation status

The selected target is a full logical-store replica for all users on every explicitly trusted server peer. The initial delivery is Raven on macOS and Stash on Debian Linux; Starlet is not part of this initial cluster. Each client normally uses its local peer. Every peer can accept local writes during a partition. This is asynchronous multi-writer replication; disconnected peers cannot immediately learn remote changes or revocations. Personal subsets and client failover are later work.

## Current operator status

`tractanda [--profile NAME | --socket PATH] peer status` is the implemented operator query for one local server. For example, `tractanda --profile production peer status` prints JSON and does not start a stopped service or initialize a store. It requires an authenticated administrator connection. The response contains local canonical facts (StoreID, ReplicaID, readiness, disposal and pairing counts) and loaded runtime facts (enabled/state, configuration digest, listener/responder flags, transport connection counts, and synchronization job/edge/outcome counters). It does not enumerate remote nodes, last-seen times, connected human/agent sessions, remote health or cluster convergence. The native `TractandaPeer/status` method is handled on the native socket path only; it has no generic HTTP/MCP route, and the TUI has no cluster-status screen. `tractanda-setup status` reports local macOS LaunchDaemon state, not peer health. Do not treat a local `ready` status, an open connection, or zero queued work as proof that every replica is synchronized.

Package installation, target enrollment/adoption, readiness, synchronization and cluster acceptance are separate operational gates. A successful local verifier or local `peer status` response does not by itself establish an accepted or converged cluster. Follow the release-specific acceptance checklist and preserve its actual receipts; a package being installed does not imply that peer synchronization is enabled.

## Confirmed peer removal and credential policy

Servers are entry points to one logical system. On15October2026 the user selected timestamp-based peer retirement under trusted administered clocks, superseding the earlier accepted-membership snapshot rule for peer removal. Existing user-revocation causal rules and current item/global permissions are unchanged. Preserve all original identities, bytes and historical admission facts; current permissions govern every historical read.

A removal's canonical `effectiveAt` is exactly the decoded UUIDv1 issuance time of that same removal root. A contribution from an authenticated retired origin whose RevisionID issuance time is at or after the earliest active cutoff requires exact administrator review, including contributions already accepted elsewhere. Earlier contributions still pass ordinary source/current authority, parent and graph checks. ItemID creation time, raw UUID/node ordering and logical modifiedAt are not this clock. Trusted clocks can drift or be backdated; the selected policy deliberately does not add binary/remote-clock attestation.

Authority events strictly after an issuer's valid removal lose that issuer's authority. Exact100ns simultaneous removal events retain both PRE-event authorities; ordinary data at the exact cutoff remains conservatively held. Same-root UUID/effectiveAt equality makes direct issuer invalidation edges strictly ordered in time. Replaying the same admitted root candidates suppresses stale invalid-root effects without choosing a UUID winner. Each root's immutable source proof remains separate from its current active effect. The user confirmed one global user base and global administrators: authenticated administrative decisions from explicitly paired full-server peers apply cluster-wide after exact source PRE authority and issuer validation. Receiver-local administrator recognition is not an additional veto. That global cluster remains the active model here. A separate someday idea is loose federation through selective message/item exchange between independent Tractanda systems: received content becomes local items, classified by the recipient's local categories and governed by its local permission policy. It does not require a shared namespace or full-store replication. Provenance and source identity should be retained conceptually, while addressing, protocol, conflict handling and exact identity mapping remain undecided. This is not part of the current cluster foundation. UID/GID or group differences within that cluster are local mapping/configuration drift, and replication does not provision accounts.

Credential-only rotation preserves StoreID, ReplicaID, revision identities and exact historical receipt testimony. Private endpoint credential removal remains local even when canonical retirement propagates. Re-adding a credential cannot override a still-valid origin cutoff. A cooperative replica learning its own valid removal refuses new ordinary local publication while retaining permitted reads, exact committed retries and control-plane intake/recovery; it cannot mint fresh review authority to restore itself.

### Bounded source-cut publication

A local write first joins accepted remote control history and pending disposition effects into its
source cut. Both joins pack ordinary control records by their complete encoded MIME-envelope size,
including JSON escaping and headers, as well as the existing entry and parent limits. Every page
retains the exact target, eligibility, policy, cause and selected-evidence bindings and chains to the
preceding local control. The authority envelope limit remains 128 KiB; one delta that cannot fit is
rejected rather than truncated. Planning alone does not consume pending effects: the existing sealed
publication and validated-current-head checks still govern their removal. This uses the existing
control format and leaves source/current permissions and exact operation retries unchanged.

Configured full-server origin attestation remains the trust model; no end-to-end signature or new trust-pin scheme is implied. Source administrator testimony explicitly records source service-owner principal and default administrator group, checked against the exact source PRE policies. Receiver `admin`/`sudo` defaults and copied UID/GID never establish a remote or local privilege. Canonical aliases for item/admission mapping remain separate from exact source OS administrator-group membership.

The source runtime samples configurable `time.nist.gov` on randomized30–60minute idle intervals, with a5second attempt timeout and5second tolerance. The existing pure `PeerClockHealth` owns scheduling and the health latch. The daemon admits one UDP sample only when actual authority intake is enabled, canonical state is ready, private peers are configured and the coordinator is idle. Public daemon startup still leaves intake disabled, so installed/default operation schedules no clock probes. An ordinary request arriving after probe launch proceeds normally. Shutdown cancels and drains the sample before closing the NIO group. Unknown/unavailable reference time does not stop offline work. Confirmed bad health prevents only a NEW retirement; unavailable or inconclusive results preserve that restriction until a confirmed healthy sample. The sampler never changes the OS clock or requires a sample for every write.

NTP is unauthenticated drift mitigation, not proof of honest time or authenticated NIST identity. Each48byte response must match the chosen resolved endpoint and unpredictable request nonce and pass header/timestamp/era checks. Offset uses actual send wall time and monotonic elapsed time; a material actual wall-clock step during the probe invalidates the result. Uncertainty includes network delay, server root delay/dispersion and local timestamp allowance. DNS shares the attempt deadline. Portable libc resolution cannot be physically cancelled: the sampler permits only one outstanding lookup, detaches cancelled/timed-out callers promptly and discards late results without accessing a closed event loop. No new lookup starts until the OS returns. The deadline includes ordinary event-loop scheduling and bounded local numeric-bind/close cleanup, with no extra DNS or remote wait. No live NIST probe has been used for verification; the coherent308 Linux runtime suite does not include a live NIST probe.

The workspace supplies graph analysis, merge planning, current projection and internal peer intake, including bounded original-attachment streaming described below. New local source commits record their origin and normalized writes; old canonical bytes remain unchanged. Projection and runtime synchronization remain disabled by default. The source includes an explicit peer listener, fixed-role connector, finite bidirectional sync driver, enrollment/activation paths, and the read-only native `tractanda peer status` command. Nothing starts or enrolls a peer implicitly. Current Raven/Stash installation and acceptance state is recorded above and in the Resume checkpoint; this page does not claim cluster acceptance.

The status command disables managed-service startup, uses the authenticated local transport UID, and checks current administrator authority before and after asynchronous status reads. Its native-only response is bounded and redacted; status reads no keys and does not mutate credentials, enrollment, activation, or repair state.

### Managed peer-runtime settings (source only)

The current Setup source accepts one of `--peer-runtime-configuration INPUT_JSON` or `--disable-peer-runtime` on `plan`, `install` and `upgrade` only. With no option, Setup preserves the instance's receipt-managed settings; a new instance without settings remains disabled. Replacement validates a bounded regular v1 JSON document of nonsecret endpoint and synchronization settings. Planning validates and describes the transition without applying it; install or upgrade publishes it as a protected per-instance configuration owned by the service account. Disabling removes that runtime settings file while leaving canonical pairings and private credentials intact. These options are unavailable for `dry-run`, `status`, `start`, `stop`, `restart` and `uninstall`.

`tractanda-setup status` reports local macOS LaunchDaemon state. `tractanda peer status` reports the running local daemon's loaded peer-runtime and synchronization state; it does not start a service or prove remote cluster convergence. The following C2 test receipts are historical source-validation results: Mac28 passed 28 selected same-UID/protected-file/native-loopback cases with 18 fixture proofs; managed macOS installation, registration and account ownership were mocked. Linux portable20 passed 20 selected cases with ten proofs and eight explicitly excluded macOS-only mocked installer methods; its receipt records `PASS_AFTER_CAPTURE_AND_POSTCHECK_RECOVERY` after the local verifier supervisor hit a completion-time Broken pipe. These tests did not establish Linux package installation or live synchronization. Debian 13 amd64 and arm64 package/Setup paths exist; host installation, prepared-target adoption and synchronization still require their release-specific acceptance gates. See the [C2 audit](../outputs/verification/cluster-2026-10-18/PEER-MANAGED-CONFIGURATION-C2-AUDIT.md), [Mac receipt](../outputs/verification/cluster-2026-10-18/PEER-MANAGED-CONFIGURATION28-MACOS-RESULT.json) and [Linux receipt](../outputs/verification/cluster-2026-10-18/PEER-MANAGED-CONFIGURATION-LINUX20-RESULT.json).

The source also provides `tractanda [--profile NAME | --socket PATH] peer credential register --file PRIVATE_KEY_FILE --origin UUID [--origin UUID...] --operation-id UUID`. It captures an existing caller-owned regular private credential file locally, bounded to 4,096 bytes and checked for safe mode, links and ACLs; the file path, not credential bytes, is passed on the command line. Origins and the operation ID must be unique canonical UUIDv1 values, with at most 256 origins. It preserves profile/socket selection and disables managed-service startup. The native exchange authenticates the kernel transport UID and requires current administrator authority before READY and again at commit; READY itself grants no lasting authority. An ordinary write can change the broad registration review context while input is pending, so a stale commit is rejected for review rather than silently retried. The API preserves existing same-generation registration semantics: it does not generate keys, rotate credentials, enroll a peer, or expose private payload through generic JSON, HTTP or MCP routes. Availability depends on the installed release; having this command does not mean peer enrollment or replication has been performed.

The source now also provides a bounded Stage1 `peer enrollment` CLI: `pair` creates the local private pair file, `begin` submits it, `step` advances finite preparation, `status` reads progress, `accept` acknowledges the exact source approval, `register` completes the accepted peer registration, `export-target` writes target-only activation material, and `read` writes selected bounded objects. Pairing is offline; the other actions use an existing native connection and disable managed-service startup. The CLI receives paths and identifiers, not private bytes. Core handles the private binary input/output; these payloads do not enter generic JSON, HTTP or MCP routes. The pair file is bounded to 12,344 bytes, native begin metadata to 16 KiB, target-only output to 135,184 bytes and each object read to at most 1 MiB. Status results are bounded nonsecret metadata.

The offline Setup helper is `tractanda-setup --prepare-peer-target ROOT STORE_UUID SOURCE_REPLICA_UUID`. It runs as the existing non-root service account and prepares a private empty target directory without creating a Store or index. The just-built command was exercised twice on macOS and Linux as a matching non-root real/effective UID; this does not prove privileged cross-UID launch, account provisioning or live enrollment. The operation record grants no membership or ordinary opening permission.

The source also contains a finite target-owned binary-stdio helper: `tractanda-setup --activate-peer-target-stdio ROOT SOURCE_REPLICA_UUID BOOTSTRAP_UUID BOOTSTRAP_SHA256 APPROVAL_UUID APPROVAL_SHA256`. It requires matching non-root real/effective custody and separately trusted public pins. After its framed READY response, the caller transmits the existing target-only private envelope; no credential bytes belong in arguments, environment, ordinary JSON or logs. The helper holds one target writer through bounded resume/append/finish operations, uses only Core-produced in-memory cursors and releases it on close/EOF/error after synchronous work settles. Missing established canonical proof or keys remains a repair error. Cancellation cannot promise rollback after a commit begins.

This helper does not launch a service, choose remote accounts or perform source registration. The source now includes a local supervisor and explicit `peer enrollment activate` command. It captures the target input before resolving the source connection, checks the current source authority, invokes the fixed target helper, retries only the bounded transient-verification response, and registers only after the target reports CLOSED and the helper has been reaped. Clean Mac20 and Linux20 invocations each passed the same 20 methods with no failures or skips and 15 actual fixture proofs; these repeated platform runs are not 40 distinct methods. Four parser-only cases and one anonymous-pipe case have no filesystem proof. The Linux run used the reviewed Linux helper lookup and verifier mapping; Mac captured the mapping but did not execute it. Both runs are same-UID. They do not establish privileged cross-UID execution, real SSH authentication or negotiated hybrid KEX, account/service provisioning, arbitrary-size completion or live enrollment. The earlier failed Linux16/4 attempt remains separate. The earlier Stage2A helper selections passed separately on macOS and Linux x86_64, each with ten actual fixture proofs; their capture-repair and Linux support-script details remain historical evidence. Managed macOS currently installs Setup at `/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-setup`; there is no `/usr/local/bin/tractanda-setup` default. Linux packaging remains deferred.

Accepted status verifies the exact canonical approval, publication receipt, retained bytes, graph proof and historical source authority. It does not use generic eligibility as a substitute; a missing acceptance seal returns `peerRepairRequired` without repairing it. Accepted acknowledgment is limited to the exact operation author or a current administrator. Target-only export and each read recheck current authority and delivery context before output. The Stage1 selection passed 33 methods on macOS and 32 on Linux, with no failures or skips; Linux excludes only the Darwin-specific extended-ACL case. The Linux verifier mapping was separately reviewed and was not exercised by the Mac run. These bounded tests do not prove Stage2 orchestration or deployment. A separate two-test macOS activation-liveness probe completed four fresh revisions across 23 append units at an 8 MiB/page-eight owning budget; the 56,432-byte maximum owning-counter charge excludes filesystem read I/O. Four finish attempts under a reduced window were refused before publication, then default completion passed. This demonstrates no default-limit failure or permanent stall in this scope and is not a scale result.

The clean coherent308 run passed 308 selected methods with no failures or skips on macOS and Linux x86_64. It includes all nine read-only status methods and two three-replica scenarios over local loopback TCP: offline/reconnect and independent concurrent metadata writers with merge, quiet checkpoints and cold index rebuild; and document relay/resume, exact part hashes/references through concurrent merge, quiet checkpoints and rebuild. The finite sync steps are primarily harness-driven; one separate B-edge outage/recovery probe exercises the background driver. The Linux-only support-script delta was separately reviewed and was not exercised by the Mac run. The approved 128 MiB cap applies only to clustering test fixtures; the 10 GiB genuine free-space reserve and other limits remain unchanged. These bounded scenarios do not validate large-scale behavior, arbitrary topologies, live mixed-host deployment or the full operator workflow. End-to-end use of a human UID through a distinct daemon UID remains unverified.

The focused private-credential registration selection passed 17 methods on macOS and 16 on Linux, with no failures or skips. Linux omits only the conditional Darwin extended-ACL test. This batch is separate from the coherent308 baseline; its verifier-script support delta was reviewed for Linux and was not exercised by the Mac run.

Local workspace evidence only: [private-registration Mac audit](../outputs/verification/cluster-2026-10-18/PRIVATE-REGISTRATION-MACOS-AUDIT.md), [private-registration Linux audit](../outputs/verification/cluster-2026-10-18/PRIVATE-REGISTRATION-LINUX-AUDIT.md), [Stage1 Mac33 audit](../outputs/verification/cluster-2026-10-18/ENROLLMENT-STAGE1-MACOS-AUDIT.md), [Stage1 Linux32 audit](../outputs/verification/cluster-2026-10-18/ENROLLMENT-STAGE1-LINUX-AUDIT.md), [Stage1 Linux32 receipt](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-STAGE1-LINUX32-RESULT.json), [activation liveness2 audit](../outputs/verification/cluster-2026-10-18/ACTIVATION-LIVENESS2-AUDIT.md), [Stage2A Mac audit](../outputs/verification/cluster-2026-10-18/PEER-TARGET-STDIO19-CAPTURE-MACOS-AUDIT.md), [Stage2A Linux audit](../outputs/verification/cluster-2026-10-18/PEER-TARGET-STDIO-LINUX19-AUDIT.md), [Stage2A Linux receipt](../outputs/verification/cluster-2026-10-18/PEER-TARGET-STDIO-LINUX19-RESULT.json), [B1 Mac audit](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR20-MACOS-AUDIT.md), [B1 Mac result receipt](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR20-MACOS-RESULT.json), [B1 lookup-recapture audit](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR20-LOOKUP-MACOS-AUDIT.md), [B1 lookup-recapture receipt](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR20-LOOKUP-MACOS-RESULT.json), [B1 Linux20 audit](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR-LINUX20-AUDIT.md), [B1 Linux20 result](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SUPERVISOR-LINUX20-RESULT.json), [Linux16 result](../outputs/verification/cluster-2026-10-18/PEER-PRIVATE-REGISTRATION-LINUX16-RESULT.json), [coherent308 macOS audit](../outputs/verification/cluster-2026-10-18/COHERENT308-MACOS-AUDIT.md), [coherent308 Linux audit](../outputs/verification/cluster-2026-10-18/COHERENT308-LINUX-AUDIT.md), [Linux result receipt](../outputs/verification/cluster-2026-10-18/PEER-SYNC-LINUX308-RESULT.json), [status implementation](../outputs/verification/cluster-2026-10-18/PEER-STATUS-IMPLEMENTATION.md), [status closure](../outputs/verification/cluster-2026-10-18/PEER-STATUS-MACOS-CLOSURE.json), [TCP1 result](../outputs/verification/cluster-2026-10-18/PEER-SYNC-TCP1-MACOS-RESULT.json), [scheduler1 receipt](../work/peer-sync-unit3-20261018/preserved-scheduler1.json), [Stash Linux foundation result](../outputs/verification/cluster-2026-10-17/INTAKE-RESUME-LINUX91-RESULT.json), and [current checkpoint](../outputs/Tractanda-Resume.md).

Any future strategy for synchronizing development source trees is separate from canonical item/document replication. It is future work and does not establish peer membership or authority.

An isolated certificate-free handshake proof passed using TLS 1.3 external PSK with a fresh hybrid X25519MLKEM768 exchange. That proof covered macOS arm64 and Debian13 Linux arm64, including a direct cross-OS protected exchange. A later, separate native Stash x86_64 foundation run passed root1 and TLS17 batches; those results are earlier foundation evidence; current selected integrated runtime validation is separately recorded for coherent308 on Linux x86_64. The same pinned wrapper backs the private metadata session described below. A current lifecycle/export source snapshot passed combined Core/TLS linking and synthetic handshakes on both ARM64 platforms; the old PRE-C1 proof remains historical evidence. The listener and pairing implementation are included in the current packages, but the configured runtime keeps peer serving/synchronization disabled until target adoption, readiness and acceptance gates pass. Source registration has passed for the current Stash operation; it is not proof of target adoption or a running listener.

`revisionAncestry` uses profile `tractanda.revision-ancestry.v1`, kind, origin ReplicaID, sorted parent IDs, written/unset field-name lists and authored/reviewed frontier. Automatic materializations additionally identify their merge profile. Values come from that revision's immutable snapshot; roots seed every semantic field and explicitly addressed unchanged values remain writes. This managed metadata is excluded from content/search prose and cannot be authored or carried into a copy by clients.

New ancestry records use canonical **format v2**, with a matching `X-Tractanda-Format-Version` header. Existing v1 files remain immutable and carry no ancestry. V2 requires validated provenance; the new reader rejects a v1 record that claims it. Old software fails closed on v2 instead of carrying stale ancestry into an edit. Native CLI/TUI/MCP readers must upgrade coherently; old connected clients may need a reconnect without terminating their conversations. Projections retain the actual record format even when returning only selected fields.

Modern ancestry requires UUIDv1 persistent identities. Original-format records that already use v1 identities retain edit/copy/retry/recovery support. Unmigrated v4 identities remain readable, but modern editing rejects explicitly and preserves their original bytes/current/history; it does not silently rewrite identity or grant a compatibility exception. Any future migration needs its own approved preservation contract.

**Deployment blocker:** before enabling this source in an installed build, activation and rollback must check record-read compatibility. Once any v2 revision is published, automatic rollback to a v1-only reader is unsafe. Preserve all newer canonical writes; never restore old data over them to make an old binary start. The source guard now raises a durable minimum-reader requirement before v2 publication and checks signed/runtime declarations before reload or repinning; focused source verification passed. No release/deployment is authorized by this foundation.

Private `.tractanda-replica-identity.json` retains a UUIDv1 ReplicaID distinct from logical StoreID. It identifies this local store instance, with no MAC/path/device binding. Legacy reads need no allocation; an authenticated local write initializes it durably under the writer lock. Modern history without its retained identity fails closed. Restores preserve this file; explicit clones receive a fresh identity while retaining original revision origins. Future replication packages must exclude the local identity file. Stage1 now has a source-only explicit enrollment command family for bounded pairing, intake, status, acceptance, registration and target-only export. The finite Stage2A helper and Stage2B local supervisor are described above; remote launch and live joining remain separate.

## Revision and merge rules

Preserve every original canonical revision, ItemID, RevisionID, actor, timestamp and immutable request identity. Persistent IDs are actual UUIDv1 values issued by the originating machine. Existing linear snapshots can supply applied field deltas without rewriting their files. New authored events distinguish explicit writes/unsets from unchanged inherited values; explicitly addressing an unchanged value still records an authored write. Authored ancestry determines causality, not clocks or UUID ordering.

Ordinary top-level fields merge independently. Maps and ordered lists are atomic: separate nested-key edits still affect the same top-level field. Tagged values remain distinct; absence/unset differs from empty values or the text `null`. Keep causally maximal authored writes per field. Concurrent identical values/unsets coalesce; different values conflict and require review. Security policy, deletion/restoration, retyping/schema, category structure/rules, personal-state and attachment lifecycle semantics are protected. Such changes cannot be combined generically with concurrent content merely because the field names differ.

An automatic merge is a new physical revision with explicit actual parents and zero authored writes. Its claimed authored frontier and full semantic payload must match recomputation from complete parents using the supported profile. Equivalent independent merges retain their separate UUIDv1 files. They share semantic state and do not trigger another merge. Select the causal current frontier first; only within its validated equivalent class choose the greatest parsed modified timestamp, with a stable RevisionID tie. Older frontiers never become current because their timestamp or UUID sorts later.

Explicit resolution consumes its exact reviewed frontier and supplies writes for every conflicting/protected field, including choices equal to an existing branch. A resolution is authored; concurrent resolutions can themselves conflict. Exact duplicate nodes are inert; one identity with different snapshot/ancestry is invalid.

The pure helper accepts complete, bounded, single-item graphs. Supplied snapshots pass `Revision.validate` and `ItemSemantics.validate`. It rejects unknown profiles, missing/cyclic/cross-item ancestry, multiple roots, changed creation timestamps, noncanonical/non-v1 identities and snapshots inconsistent with normalized applied writes. Node, edge, work and conservative encoded-value/ancestry budgets fail closed. The derived catalogue validates larger histories using bounded disk graph rows. The in-memory helper remains a bounded reference, and increasing its limits does not make it a scalable runtime adapter. A draft is not a complete canonical validator: eventual publication must recheck domain/global invariants and current authority against actual store state.

Automatic-merge and explicit-resolution validation uses checked exact 100 ns arithmetic over supported proleptic Gregorian UTC instants (years 0001–9999, up to seven fractional digits; numeric timezone offsets normalize to UTC). Integer civil-date conversion avoids platform calendar cutovers. New time must exceed every actual input parent, even if the clock moved backward or an input is in the future. Invalid precision, dates and exhausted range fail. The draft factory allocates an injected real UUIDv1 only after eligibility/time validation; it creates a plan, not a canonical author/receipt or published revision. The source publication planner chooses the greater of the current clock floored to a millisecond and the greatest exact input time floored to a millisecond plus 2 ms. It checks exact and existing parser round trips; actual index ordering and date filters must observe the advance. UUID issuance time stays independent of this logical clock. V2 local authored ancestry is already emitted in source; The source Store publisher now applies this clock to new authored and manual-resolution records; existing records remain unchanged.

## Projection foundation being implemented

Merge profile `tractanda.merge.v2` permits a zero-write clock reconciliation when the causal current representation is older than an accepted historical timestamp. Its actual parents include the current representative and a distinct accepted revision witnessing that higher timestamp; its singleton authored frontier and full payload are recomputed from those parents. This also handles a legacy linear chain whose authored clock moved backward. An equivalent-only materialization without a higher-clock witness is invalid.

The analysis clock floor is the maximum exact timestamp of all validated accepted revisions of that item. It is derived again on rebuild, not held only in process memory. Private unadmitted or quarantined packages do not contribute to this floor. Late obsolete higher-clock arrivals can require reconciliation, but they never replace current content. Existing equivalent current-frontier arrivals select the greatest representative and create no extra record. Every valid reconciliation exceeds all its inputs, so finite accepted arrivals reach a state needing no further clock materialization.

The shared planner distinguishes a semantic conflict from an unmaterializable payload or ancestry limit. Valid parent snapshots can combine into a record above the publication byte ceiling. Preserve the originals and expose the resource/review result; do not truncate values or label the graph corrupt. A ready plan still needs complete canonical record, domain, global-invariant and current-authority checks at publication. The default runtime gate remains linear. The source-only projection mode integrates these foundations for isolated validation. Foreign intake and transport are implemented behind explicit default-off runtime configuration; the bounded three-node scenarios below passed on macOS and Linux.

## Remaining full-peer scope

The source projection mode coordinates recovery, graph admission, history paging, permissions, CAS and receipts. History lists accepted physical revisions in parsed timestamp order with stable ties, while current state follows causal ancestry. Unresolved items have an explicit conflict channel/query status. Historical reads and attachment/replay access enforce conservative current policies. Authority-intake and transport implementations are now present in source. The coherent308 receipts include two passing three-node scenarios on both platforms: metadata synchronization through an offline peer and concurrent writers, and saved-document relay/resume through concurrent merge and rebuild. They do not establish arbitrary-topology or large-scale convergence, nor a live mixed-host deployment.

Full-peer intake must preserve accepted revisions and authorization-race evidence through validated private staging and managed publication. Cross-item invariants need their own conflict contract: concurrent category-parent changes can form a cycle despite no same-item fork. Preserve both accepted edges as evidence and expose the invariant conflict without corrupting the store or silently choosing an edge.

The internal authenticated metadata adapter connects the proved TLS wrapper to existing durable package exchange. The daemon listener, fixed-role connector, pairing/enrollment paths and finite sync driver are implemented in source, but synchronization is disabled by default and no external listener or remote host is configured. The Stage1 and bounded local Stage2A/B1 commands provide explicit native operator paths. B1 passed the same bounded 20-method selection on macOS and Linux; both runs are same-UID fixture validation. The fixed SSH launch path then passed the same30 selection on macOS and Linux with simulated SSH-shaped children and 19 fixture proofs per platform. These are repeated platform results, not 60 distinct methods. Real SSH authentication and negotiated KEX, privileged cross-UID operation, full lifecycle workflows and live enrollment remain unverified. The coherent308 selected current-source runtime batch passed on macOS and Linux x86_64; the Linux-only support-script delta was separately reviewed and was not exercised by the Mac run. New operation receipts distinguish origin peer, principal and operation while preserving original request identity. Keep uncertain client writes pinned to their originating peer; retrying a create elsewhere before replication can allocate another item. Origin-scoped receipts do not guarantee global exactly-once creation.


## Current projection source mode

`ItemStore.revisionProjectionEnabled` defaults to false. The source-only enabled mode rebuilds disposable current status and conservative permissions from accepted authored-frontier snapshots, materializes ordinary compatible changes, and exposes unresolved states through `TractandaItem/state`, mixed `get` outcomes, authorized query completeness and the conflict list. It serves no chosen branch as current during a conflict. Exact historical records, attachments and retry receipts remain subject to current conservative policy. Permission conflicts and store-wide access-configuration divergence fail closed for unprivileged callers while retaining a common current administrator/root repair route.

Ordinary mutations retain `expectedRevisionID` and require the resolved representative, fresh authority and current constraints. `resolveConflict` separately requires an item state token, exact reviewed frontier and explicit choices for conflicts and protected fields. Owners/editors retain existing rights across every conservative policy witness; administrator-only stale-authority intake review belongs to the later foreign-intake stage. A resolution can select retained attachment state; attachment lifecycle/extraction operations create new attachment identities or generated representations.

Recovery records cross-item category cycles as invariant conflicts while preserving all original records. Full-record or analysis limits produce explicit resource states; omitted detail vectors are marked incomplete. Logical `modifiedAt` advancement is separate from the physical local publication folder. Existing current caches and canonical inventory jointly gate restart admission; missing or stale graph proof requires recovery before a write. Current-state tokens are cached per item, and ordinary validated append advances graph proof without scanning the entire store.

The mode and client presentation passed focused source validation; it remains disabled by default. Projection alone does not enable peer intake, enrollment, transport, production serving, deployment or old-reader rollback. The source canonical compatibility guard is implemented; the signed managed-release gates still apply before any future installation.


The unpaged Core history convenience method is bounded to 64 MiB and 4,096 records and fails explicitly above either bound; the native paged API retains its separate smaller delivery window. Current history still lists every accepted physical record when consumed through pages. Recovery visits every accepted item root in projection mode; the linear iterator remains a proof for items without forks. Resource failure after immutable publication cannot be reported as a harmless materialization block: the file remains and the store requires recovery before serving again.

## Internal metadata intake A — source foundation

`ItemStore.authorityIntakeEnabled` defaults to false and requires projection enforcement. This internal mode has no Service/native/CLI intake route or supported product path. The source has focused validation for durable metadata staging/publication, current-authority evaluation and recovery. Intake remains an internal foundation while foreign protected-review admission, payload closure and transport are unfinished. A bounded package is only eligible under explicitly configured full-server trust. An authenticated immediate peer may vouch only for its configured origin allowlist; UUIDs do not authenticate origins, relaying never enrolls a new origin, and there is no claim of an end-to-end origin signature.

Package/index and bootstrap index/page objects have bounded fan-out. Baseline totals stream through the derived index and do not use the pure reducer's 256/512 reference limits or a 65,536-revision store ceiling. An explicit current administrator pins one initial complete bootstrap cut. Legacy originals without origin metadata require that typed bootstrap admission; modern unknown origins remain withheld.

Original MIME bytes, IDs, provenance, actors, timestamps and request identity remain unchanged. Framed chunks resume from verified offsets. Sealed journals bind the package, immediate peer/configuration and exact descriptors. Actual receiver locators are synchronized before file publication; duplicate objects reuse one verified immutable file. New arrivals use a local publication subtree, independently of logical timestamps or UUID time. Chunk copies are removed after durable retention. Existing exact bytes can be adopted by a new manifest without retransmission.

One retained inventory tracks original locations and dispositions. Only eligible ancestor-closed revisions enter the existing accepted graph catalogue. Never-admitted held originals remain evidence and are excluded from ordinary history, queries and retry receipts. Recovery replays sealed publications; unsealed/orphan files cannot silently become accepted. A malformed raw authority observation cannot reserve an evidence slot. Election checks the actual origin, bytes, actor, parents and normalized intent against fresh configured receipts and real current name/group/policy evaluation. Contradictory complete testimony requires review; missing proof stays resumable. Different policy IDs alone do not establish a permission change.

Runtime A's intended scope is ordinary `Item` metadata only. Payload/attachment/document closure is missing; protected foreign changes, other classes, review decisions and origin/global-admission demotion await B. Causal revocation reconciliation remains a later validation gate. Reader compatibility alone never admits an existing baseline: a private StoreID/ReplicaID-bound initialization proof records whether an explicit initial cut is required. Until pinned, administrator maintenance/rebuild is available but ordinary requests and new local publication are blocked. The reviewed cut must cover the immutable pre-intake ID/digest inventory, even if later observations of those bytes are withheld. Local cross-item admission changes requiring missing accepted-control causality are refused before publication. B must freeze the sparse accepted-control DAG and managed zero-write reconciliation profile together; no pending byte, assessment flag or wall timestamp supplies that proof. Internal intake remains off until A/B and recovery validation are complete.

Authority persistence raises and synchronizes reader level 3 plus `tractanda.authority.v1` before eligibility effects. A disabled reader refuses such a store instead of falling back to linear acceptance. Unsupported later control context also fails closed. Publication/resource failures retain exact files and dirty recovery state. Private configuration, replica identity, initialization/initial-history proofs, local legacy receipt proofs, credentials and disposable indexes are never package objects. Legacy local replay additionally requires its pre-intake proof to match StoreID, local ReplicaID, exact revision and digest; an imported format-1 baseline revision remains history and cannot impersonate a local retry. Work/byte/disk limits apply per operation with bounded pages and a genuine free-space reserve; large baselines can span packages. Missing parents can be supplied later and the sealed package's commit explicitly retried. Validation evidence is recorded under `outputs/verification/cluster-2026-10-14/`; source does not imply deployment.


## Internal causal authority B — validated source foundation

The internal, default-off authority mode now has a sparse accepted-publication/control DAG. `controlCommit` records bind exact accepted/disposition targets, immutable chosen authored-evidence bindings, direct accepted import controls and an explicit previous local control. Authored evidence freezes its writing replica's PRE-publication cut in `sourceControl`. Its exact source-cut IDs must occur in `parentAuthorityIDs`; additional authority parents are observations only. Observation does not enlarge the accepted cut, and `acceptedAuthority` remains a separate explicit review proof. The LOCAL atomic review stage below enforces its exact D/C closure; foreign protected-review admission remains disabled. Revocation tests acceptance **and eligibility** at that exact cut; receiving an observation or retaining an old policy is insufficient. A later grant does not retroactively approve a stale intent. Effective policy equivalence is evaluated rather than inferred from changed UUIDs. Current node-local user/group resolution and read permissions remain mandatory.

Local authored item, evidence and control seal as one recoverable unit. Receiver authored acceptance seals its exact selected testimony before private assessment/current publication. Recovery restores that historical decision and then applies current invalidations/holds before serving; it never treats the decision as an unconditional present grant. Private reconciliation identities reserve actual UUIDv1 output/witness IDs before preparation and preserve their exact bytes across interruption. All original files, actors, timestamps and paths remain unchanged.

Ordinary-content demotion removes affected revisions from the accepted projection, retaining their originals. A zero-write `tractanda.authority-reconciliation.v1` revision has only eligible item parents and separate validated control/visibility witnesses referring to held originals. Its publication clock exceeds eligible inputs and the proven local exposure floor. Imported source visibility alone cannot create local history or inflate that floor. Stable semantic cause keys exclude their own equivalent outputs; obsolete/equivalent materializations do not trigger merge or acknowledgement loops. Incoming zero-write merge.v2 and authority materializations use the same existing projector in their own parent context.

Previously validated LOCAL acceptance retains historical membership even for a branch never directly displayed. Only a real LOCAL READY-representative visibility witness supplies an exposure clock. Current eligible policies filter exact revision, projected get and paged history; returned demoted IDs carry the additive `historicalDispositions` map with value `demoted`. If no eligible current policy remains, original history is administrator-review-only. Pending/unaccepted evidence cannot grant access, become ancestry or impersonate retry success. Authority-mode history temporarily uses the bounded serial verified union rather than pooled history hydration; ordinary get/query and nonauthority pooling remain unchanged.

Bounded indexed work queues finish interrupted disposition and local-visibility effects before serving. The reviewed initial cut has one-time streamed accepted-history bookkeeping and READY-only exposure; warm empty queues do not rescan all items. Receiving controls, known bytes or equivalent materializations emits no shared acknowledgement. A later real authored publication incorporates the needed accepted imports. Exact-cut policy coverage uses only fully validated authored context and bounded existing ancestry; equivalent contexts require equal complete payloads, while causally obsolete policies remain superseded.

These effects require reader level **4** and `tractanda.authority-causal.v1`, synchronized before control publication. Disabled/unknown enforcement fails closed. Fresh ordinary AccessConfiguration transitions require existing administrator authority. The subsequent LOCAL protected-review stage is described below. The internal managed origin-retirement lifecycle is described below. Foreign protected-review admission is being integrated in the shared-authority unit below; payload/document dependency intake, public enrollment/listeners and live deployment remain disabled. Resource failures preserve immutable evidence and keep the affected recovery/serving gate closed. Focused native B, recovery, history and exchange checks passed across the recorded repair/closure runs; the evidence distinguishes earlier failures and overlapping cases. Implementation remains source-only and no production capability is enabled.


## Internal atomic protected review

The source now provides internal `prepareAuthorityReview` and `resolveAuthorityReview` methods for a fresh current administrator. There is no Service/native/CLI/UI review route. The request names exact held B and selected evidence, an item/policy/authority token, complete reviewed decision/control-hold frontiers, an origin-pinned operation ID and explicit choices for every held authored field and conflict/protected field. Ordinary conflict resolution continues to preserve existing owner/editor rights; this administrator requirement applies to stale-authority admission.

One sealed unit binds unchanged B, decision D, fresh resolution C and its evidence, positive effects and legitimate visibility. C's actual parents/context, complete encoded record, permissions, named principals, references and global invariants are validated before sealing, then checked again under fresh local authority. D uses the PRE-review accepted policies; B's proposed grant cannot authorize C. Choosing C's new grant or revocation is an explicit fresh decision. Missing permission metadata grants no ordinary ACL rights; it does not inherit an older ACL. B is never an intermediate current projection, and unnamed descendants stay held.

Reader level **5** plus `tractanda.authority-review.v1` is raised and synchronized before effects. The review stage introduced derived schema **16**; finite inventory below advances it to **17**. Derived state is disposable and rebuilt. Composite `(control, previous policy)` invalidation paging retains every reviewed revocation through later grants. The exact named B/C of an applied atomic unit do not invalidate their own adoption, but later controls and unrelated/unnamed originals have no exemption.

Private actual UUIDv1 identities, times and a resumable manifest are reserved before publication. Sealed failures preserve originals and the recovery gate. Rebuild validates provisional D/C in their own contexts, then restores exact later LOCAL accepted authored rows through existing parent/delta bookkeeping when they became eligible after the initial scan. Attachment/document integrity checks remain mandatory. Existing private ReplicaID is loaded before replay so covered historical negatives are not mistaken for new effects. Obsolete pending negatives are consumed only against exact current LOCAL positive acceptance and validated causal proof; no eligibility, history, clock or newer cause is rewritten.

A completed operation retry may acknowledge historical committed C with fresh current state/disposition under current administrator access. It never reapplies an old approval or implies that C remains current. Warm replay emits no acknowledgement controls or new materializations. Unsupported persisted LOCAL `reviewHold` source context fails recovery closed after retaining originals; foreign unaccepted observations cannot become validated holds or block unrelated accepted work. Public review routes and trust enrollment remain separate gates; the private shared-review integration is described below. All of this remains source-only and default-off.


## Internal per-object resume/status

The default-off internal intake now reports context-bound paged per-object progress. It validates fresh private configuration and immutable package/manifest binding; no public gateway is exposed. Missing index pages explicitly block discovery. Verified contiguous chunks or exact known-original matches remain separate from current held/missing/eligible outcomes and physical staged/prepared/sealed/applied phases. Recovery suppresses unavailable dispositions.

Checksum intent is durable before each fixed1MiB chunk (except the final tail); intent alone acknowledges no bytes. Reopen verifies actual bytes, and exact retry completes an interrupted write. Old unverifiable partial stages fail explicitly. Hierarchical cursors, parsed-page caching, result/hydration/work/staging bounds and genuine10GiB reserve remain enforced. Focused32/32 plus a separate overlapping quota/truncation precision check passed; see `UNIT-2C3-RESUME-STATUS.md`. Subsequently completed finite inventory, export and private gateway work is described below.


## Internal finite descriptor inventory

C2 captures a finite receipt-sequence cutoff under disposable derived schema17. Context-bound opaque cursors advance over scanned rows, including filtered-empty pages; newer publications wait for the next pass. A successfully completed pass can return an opaque in-memory checkpoint for a later capture to start after its completed maximum and stop at the new maximum. Partial or failed passes yield no checkpoint; rebuild, Store, peer, or configuration mismatch rejects one. This continues receipt enumeration only, not transfer or eligibility. Run a fresh full capture when changes may alter qualification of earlier receipts, such as a changed legacy bootstrap proof. Verified configured-origin held observations, private-local records and explicitly pinned legacy originals are discoverable independently from query eligibility. Inventory creates no canonical acceptance, acknowledgement or byte-transfer API. Focused42/42 checks passed; see `UNIT-2C3-FINITE-INVENTORY.md`.

## Internal managed peer lifecycle and shared authority

The private lifecycle preserves exact historical credential Contexts and immutable reserved Configuration publications across rotation, removal, interruption and retries. `configurePeerIntake` remains initialization/addition-only. Explicit sorted retirement origins must belong to the removed endpoint's relay allowlist; an empty set removes only that endpoint. No origin is inferred from a peer label, and private configuration/credentials never become package objects.

Timestamp retirement source integration uses reader7/`tractanda.shared-authority.v1` and disposable schema19. A root binds exact source PRE control and administrator policy/testimony, operation, explicit origins and same-root UUID issuance time. Runtime snapshot-membership gating and snapshot construction are removed; earlier root/page originals remain audit evidence. An old activated root lacking explicit timestamp semantics requires explicit recovery/migration, never an invented cutoff. No production migration is performed by this source work.

Exact canonical admission receipts preserve historical source proof independently of current effects. Bounded replay orders admitted candidates by event time and computes currently valid cutoffs. Origin/decoded-UUID-time indexes select affected retained contributions, with separate derived timestamp-hold/recheck rows. Re-evaluation preserves still-valid removals, current user/global/item invalidations, actual LOCAL admission facts and ancestor closure. Missing foreign dependencies stay inert; lost proof beneath a durable admission seal fails recovery closed. Immutable source PRE policies load from retained bytes and exact source-cut frontiers, not mutable receiver current projection rows; this never supplies a fallback current grant.

Shared D/B/C review wiring preserves exact original B, fresh resolution C, selected evidence, source PRE policies/frontiers and applicable retirement-root bindings. Prior approval cannot bypass a newly learned removal cause. Fresh foreign proof must complete authenticated origin/source PRE administrator/issuer and own-parent/payload/clock checks before a durable private admission seal; observations and raw wire roles cannot register positive acceptance. Receiver concurrency uses C's unchanged actual parents and the existing graph conflict rules. A retired reviewing origin cannot publish a fresh shared decision. Legacy unqualified reviewHold observations remain explicitly unsupported rather than silently becoming authority.

This unit is under focused native validation and independent source review. See `outputs/verification/cluster-2026-10-15/SHARED-AUTHORITY-CONTRACT.md`, `SHARED-AUTHORITY-REVIEW.md` and the dated runtime logs. Earlier lifecycle/export/transport test receipts remain historical evidence for their exact source snapshots. No complete shared-cluster runtime or installed deployment is claimed.

## Internal resumable outbound metadata export

The private Store export path captures a finite current descriptor-inventory boundary, then selects exact roots in pages of at most128 entries. Closing selection fixes those roots. Every selected sequence and descriptor is reverified against the captured boundary; a decoded future sequence ceiling is rejected at begin. Ordinary later publication does not invalidate the plan or add roots. Every operation checks canonical readiness, current configured Context and a stable security binding over private Configuration plus exact active global AccessConfiguration revision IDs/digests. Rotation, removal or policy changes invalidate stale handles; generic Store generation is deliberately excluded so late dependencies can arrive.

Private immutable numbered events under `authority/export/` precede atomic derived queue transitions. Queue rows contain descriptors, receipt identity and direct-edge continuations, with indexed deduplication by original ID; they never contain canonical item bodies. Exact retry replays a synchronized event before advancing. A disposable inventory epoch change explicitly invalidates unfinished work. Sealed manifest/page/descriptor/receipt artifacts survive derived rebuild and read exact verified canonical originals through current receipt continuity. Export state is private operational data, never canonical authority or a transferable credential.

Bounded steps page existing normalized dependencies, selected or candidate evidence and actual verified record references: actual revision parents/frontier, PRE policy/control context, full control delta targets/policies/causes/evidence, exposure/reconciliation and review witnesses, bootstrap members and retirement root/page membership. Reverse control/review/exposure/retirement witnesses are restricted to the finite captured receipt ceiling. Missing explicit dependencies may arrive afterward and fill their existing slots; unrelated later reverse witnesses do not extend the pass. ID/kind/length/digest conflicts reject. Missing references and unsupported payload, historical retirement or unqualified reviewHold semantics remain explicit incomplete states and block successful sealing. Typed shared-review/timestamp-retirement export closure is under current validation.

Closure produces bounded immutable leaf and index pages through the existing PeerPackage validators. Page UUIDv1s and exact bytes are journaled before exposure; a sealed manifest fixes package identity and all descriptors. Both direct manifest delivery and object reads verify the immutable manifest seal. Each selected read verifies the descriptor plus original bytes/identity and returns at most1MiB without re-encoding or exposing filesystem paths. An exact receiver-known claim suppresses bytes only; descriptor, dependency and current origin checks still run, and later reads can retransmit. Relay uses a fresh package UUID while preserving originals.

Object, step, hydration, journal/output and disk allowances return explicit resource errors while preserving prior synchronized progress. Short-step cancellation checks complement SQLite budgets; genuine10GiB available-space reserve remains mandatory. Logical chains and hierarchies span many calls without an operation-wide graph-depth cap. No planning, manifest publication or transfer creates a content revision, shared ACK, accepted control or admission. The older eager metadata/control helpers remain small fixture/verification helpers and are not used by this exporter. The private session adapter includes listener, connector, pairing and finite background synchronization; the per-instance runtime remains disabled by default. Package installation does not enable it. The current Raven/Stash acceptance gate is documented above. The coherent308 batch passed bounded three-node metadata and saved-document mesh scenarios on macOS and Linux. Large-scale or arbitrary-topology convergence, fuller operator controls and deployment remain separate gates. Focused foundation results and review are under `outputs/verification/cluster-2026-10-15/`.

## Private authenticated metadata exchange

`TractandaPeerTransport` is a separate package-private target depending on Core, the pinned TLS wrapper and NIOCore. Core remains TLS-free. It installs on an inactive channel with one injected host-private pairing record. A genuine authenticated TLS session must match exact StoreID, ordered replica identities/roles, pairing UUID and credential/configuration digest before Core resolves the current private peer Context. Frames cannot supply a trusted Context, permitted origins, actor UID, filesystem path or private operation/key file. Stage1 pairing/enrollment commands exist in source; dynamic peer discovery and full target activation are not provided by this stage.

`PeerExchangeGateway` routes finite inventory, durable export planning/selection/closure, manifest/descriptor/chunk reads and intake begin/append/status/verified resume/commit through the existing ServiceCoordinator admission/rebuild/shutdown fences and private serial Store owner. Each connection retains only one inventory, resume and export continuation slot. Context, canonical readiness and stable global-access-policy/private-configuration binding are checked for each operation. Rotation, removal and policy changes invalidate old sessions/slots. Ordinary writes can proceed during a transfer: commit obtains the existing authority token freshly inside its serialized dispatch, then delegates to the existing acceptance engine. A genuinely new parentless ordinary Item uses its proposed owner/permissions only after indexed absence checks exclude every prior catalogue, projection/policy and local/retired history row; existing missing or dirty policy proof still fails closed.

Application exchange v2 requires three ordered compatibility controls in each direction after TLS/current Store binding: a strict bounded declaration of current canonical reader/writer support and retained durable floor, an exact SHA-256 acknowledgment of the peer declaration, and an empty READY. Both directions use the existing canonical requirement and possible-writer checks. Local Core admission and final current-floor/authority validation commit before advertising READY; outgoing ordinary work waits for peer READY and local READY flush. Compatibility controls share existing byte/work/session budgets and one absolute operation deadline. Version 1, unknown keys/profile/StoreID, missing/duplicate/unordered controls and incompatible readers/writers refuse before ordinary exchange. TLS crypto profile, ALPN and pairing credentials are unchanged.

Compatibility claims grant no item or administrator authority. Direct Core ordinary exchange, authorization and synchronization require admission; every operation/delivery rechecks the current durable local floor and existing current-authority/retirement gates. Each new physical logical lease resets admission, including cached scan replay. Claims remain bounded connection state, with no migration/cohort registry or canonical schema change. These C1 changes are source-only and default-off. One coherent Mac37 and one coherent Linux37 invocation passed the same 37 methods with zero failures/skips and 28 fixture proofs each; these are repeated platform validations, not 74 distinct methods. Linux had no excluded Mac-only methods and matched 1,238 project plus three support inputs, all 1,245 current Mac inputs and its before/after environment. This does not establish a live cluster, production configuration or coordinated fleet upgrade. C2 has separate managed-configuration results above and is not established by these C1 receipts. See the [C1 audit](../outputs/verification/cluster-2026-10-18/PEER-COMPATIBILITY37-AUDIT.md), [Mac result](../outputs/verification/cluster-2026-10-18/PEER-COMPATIBILITY37-MACOS-RESULT.json) and [Linux result](../outputs/verification/cluster-2026-10-18/PEER-COMPATIBILITY-LINUX37-RESULT.json).

The internal wire uses a four-byte big-endian bounded length followed by versioned canonical JSON. The header is validated before payload buffering, including while Core authentication opens. Frames are limited to2MiB, accommodating one existing1MiB chunk through the envelope. Request IDs are bounded, ordered and connection-local; unknown/noncanonical fields, duplicate/unordered IDs, unsolicited responses and pipelining reject. Defaults allow1024 total operations and64MiB per direction,30 seconds per operation and300 seconds per session. One operation remains active until its response flushes; auto-read/backpressure, explicit cancellation and absolute deadline checks cover queued Store work, authentication, encoding and delivery. Existing work/read/staging/disk bounds remain in force.

Disposable macOS and Linux ARM64 NIOEmbedded async-channel tests exercise encrypted exact originals in both directions, a real1MiB chunk interrupted and resumed after fresh TLS, ordinary writes during transfer, unchanged canonical bytes on exact replay, missing-parent retry, explicit unsupported payload closure, policy/credential/removal denials and protocol/quota boundaries. Transport ACKs, inventory completion, known-original claims and sealed transfer receipts never grant acceptance. The preceding metadata-source combined dependency gate covered both ARM64 platforms; the original-streaming delta below has separate macOS validation. Focused adapter validation passed17 cases on macOS and the same17 plus12 portability cases on Linux; these overlapping platform runs are reported separately. The source listener and connector are included in the current package, but the current runtime remains disabled pending Stash adoption and cluster acceptance. The coherent308 batch covers bounded three-node scenarios on macOS and Linux; live mixed-host synchronization and broader topology remain unverified. Package/host setup has occurred for the initial Raven–Stash attempt; see the current operator checkpoint for its exact gate state.

The private adapter checks active global retirement of both actual local and authenticated remote ReplicaIDs at open and every normal operation. A relay's allowed-origin list, peer nickname or network/MAC identity is not that remote identity; active relays can still carry retired-origin evidence under the existing review rules. Private pairing files remain local; receiving a global root does not rewrite them, and retained credentials cannot restore retired membership. A self-retired node retains existing local reads, exact committed retries and administrative recovery, while normal peer serving and downloads are fenced.

Outbound requests, inbound result delivery and received-response caller success obtain current authorization from the serial Store owner. Delayed callbacks reauthorize; a removal activated by an intake suppresses its normal response without rolling back durable work. Final serial-owner authorization is the linearization boundary: one bounded frame already authorized before removal may be queued or in transit and cannot be recalled. Cancellation/deadlines remain checked before delivery. A denied inbound operation may receive only a bounded sanitized failure code/text before the channel closes; an idle old session fails on its next use or deadline. This source change has focused validation recorded separately from the older transport proof.

Automatic delivery/discovery of canonical removal and a purpose-scoped remote administrative recovery route remain absent. A denial code is neither a canonical retirement root nor an automatic self-fence on an uninformed recipient. There is no normal-data recovery exception, unsolicited retirement notice, configured listener or real pairing. These are explicit gates before live deployment; source isolation does not claim a deployed cluster or removal notification/control plane.

Payload planning must also preserve sealed archives: a late-arriving immutable original can have an old UUID timestamp while the corresponding date subtree is already read-only. A future attachment transfer plan must resolve that conflict through local append-only placement/receipt resolution, as item intake does, rather than rewriting original descriptors or reopening sealed archives. This is a recorded design constraint; payload integration is not implemented by this authority unit.


## Original payload publication placement

Original payload identity and physical placement are independent. New originals are published in
`attachments/payloads/<UTC arrival year/month/day/hour/minute>/<attachmentID>.payload`; existing
files remain in their original locations. UUID issuance dates, descriptors, SHA-256 signatures,
canonical item revisions and original bytes are unchanged. The payload-placement reader capability
and level8 floor are synchronized before publication; this capability does not enable authority
intake or clustering.

A disposable SQLite lookup in the configured index directory is bound to the canonical StoreID.
Initial external-index binding precedes upload/quota recovery. Indexed reads retain existing
bounded stat/hash-cache/stream safeguards; normal reads, unknown-ID misses and startup with a
valid lookup do not enumerate archives or hash entire originals repeatedly. The converter receives
the actual resolved path and retained file identity. Quota reconstruction for published unfinished
uploads/copies uses the same resolver.

Append-only private arrival intents and synchronized pending lookup rows precede file publication.
An unpublished intent from an earlier period is superseded into the current period. Existing exact
originals are reused; publication never replaces a file. File and directory synchronization precede
lookup acknowledgement, which precedes canonical attachment reference publication. Interruption
can leave a resumable private stage or an unreferenced immutable original. Recovery checks pending
paths individually; a lost/recognized-corrupt lookup is reconstructed from canonical payload files.
Ambiguous duplicate IDs fail closed; no first-path election, deletion, archive reopening, or ID rewrite
is performed. Missing canonical identity on retained payload storage also fails closed.

Explicit cold recovery streams directory entries and hash chunks with bounded memory, SQLite
cache/row windows and cancellation. It currently runs synchronously and restarts enumeration after
interruption; it does not promise a persisted scan cursor. Read-only archive ownership/mode rules
match item archives. Runtime writes retain the configured reserve/quota policy and check the actual
canonical or external-index filesystem; the earlier validation host's10GiB reserve,32MiB fixture
cap and512MiB warm-build-growth allowance were testing controls for that run. The later approved
128MiB allowance is only for clustering test fixtures. This placement prerequisite is reused by
the original peer transport below. Saved document manifest/node/page closure remains a separate unit.
No compressed-original extraction is introduced.


## Internal original-attachment streaming

This source-only unit supersedes earlier metadata-only attachment gates. New input uses
`tractanda.peer-package.v2`, and new immutable export plans use `tractanda.peer-export.v2`.
The package/index/object field shapes, canonical MIME headers, item revisions, original UUIDs,
descriptors and payload bytes are unchanged. Metadata retains positive lengths, its existing size
limits and 1 MiB chunks. Attachment lengths/offsets use checked signed-64-bit-compatible values;
original frames are at most 256 KiB, and wire frames remain at most 2 MiB. A zero original requires
the exact empty SHA-256 and explicit verified completion at offset zero; no append is needed.
Compressed or otherwise opaque originals are copied without extraction.

Export records exact canonical descriptor/revision/receipt witnesses and closes original
references, actual parents, authority and bounded inline `attachmentText` source revisions. Saved
text validates its source item/revision/attachment signature and actual original as well as its
bounded UTF-8+BOM hash. Missing originals remain explicit `missingOriginalPayload` dependencies and
prevent sealing. Nonempty foreign `attachmentDocument`, including saved document content trees,
remains unsupported. Existing verified PRIVATE LOCAL attachment, text and document saves continue.
No LOCAL phase or storage readiness is inferred from a wire field or source assertion.

A receiver reserves a private UUIDv1 stage bound to the exact package/object descriptor. One
contiguous original file is accompanied by bounded checksum intents, received markers and a
private monotonic high-water checkpoint. Intent alone acknowledges nothing. Appends and verified
resume synchronize actual bytes and acknowledgment state before success. Missing acknowledged
state, aligned or partial acknowledged truncation, changed retries and corrupt prefixes fail closed.
Only a proved unacknowledged partial tail may be discarded. Read/work allowances cover actual
metadata, proofs and bounded hashing; active verification jobs continue across operations with
bounded memory. Whole-original hashing can restart after process loss or verification-job expiry;
transferred, verified stage bytes remain reusable. Original source/sink paths never materialize a
whole payload `Data`; metadata keeps its bounded existing path.

Shared configurable staging accounting includes pending journal/phase/proof/checkpoint bytes,
temporary peaks, original stages and published-but-unapplied holds, including restart reconstruction.
Capacity checks use the actual receiving filesystem; no-copy publication enforces the existing
same-filesystem prerequisite. The host validation reserve is not a new product quota. Publication
verifies complete closure, seals, then publishes originals through arrival placement before any
referencing canonical metadata. Failure leaves resumable private work or unreferenced originals.
Normal index/stat/cache safeguards avoid full-payload hashing on every read or chunk.

Before a durable v2 seal, reader level **9** and `tractanda.peer-originals.v1` are synchronized.
A narrow retained-v1 decoder preserves exact manifests/digests, phase evidence and canonical
originals across replay. Consumed duplicate metadata staging may be replaced by an exact retained
canonical locator. Sealed v1 effects and exact preexisting PRIVATE LOCAL reservations continue
internally; unsealed foreign v1 bytes remain accounted and inert. New network traffic never falls
back to v1, and an old export requires a fresh v2 plan. There is no canonical migration.

Current Store readiness, configured peers, local/immediate-peer retirement, source authority and
fresh current ACLs remain mandatory through final delivery. Active relays may carry retired-origin
evidence without granting acceptance. See the contract, independent review and exact runtime
receipt in `outputs/verification/cluster-2026-10-15/PEER-ORIGINAL-STREAM-*`. Fixtures use two or three
chunks, empty originals, fault boundaries and mocked capacity; no large-payload scale result is claimed. The coherent308 batch passed bounded three-node metadata and saved-document mesh scenarios on macOS and Linux; this does not validate large-payload scale behavior or arbitrary topologies. Enrollment, listeners, background synchronization and
document-tree transfer have source implementations behind explicit default-off configuration; the full operator workflow and deployment remain separate gates.

Development source-tree synchronization is a separate future strategy, outside Tractanda's canonical
replication protocol. No source-sync tool or transport is adopted by this cluster decision.

## Archive-safe local document placement

The source document-placement prerequisite publishes new complete saved-document trees under
`documents/content/<local UTC arrival minute>/<contentID>`. Content/publication UUIDv1 identities,
source and converter provenance, manifests, hash nodes, page bytes and partial/failure outcomes
remain unchanged. Existing UUID-time trees remain at their original locations. Local copy keeps
its existing independent identity semantics. This prerequisite enables no foreign document traffic;
the later framing checkpoint below supersedes its package-v2 baseline while document admission
continues refusing foreign saved-document closure.

`DocumentPlacement` maintains a StoreID-bound disposable SQLite locator beside the item index,
including explicitly bound external indexes. A valid locator permits normal startup, page reads
and final misses without enumerating archives. Missing or corrupt locators rebuild by bounded,
cancellable no-follow enumeration and complete tree verification. Duplicate IDs or unsafe entries
fail closed. Filesystem device/inode values are transient race/filesystem checks, never store identity.
Missing canonical StoreID is never recreated over retained documents or items.

Immutable arrival intents preserve publication choices. If an unpublished period closes, a new
intent selects the current period without modifying the old intent or writing its archive. Complete
manifest/node/page closure and every file/subdirectory are verified and synchronized before a
no-replacement directory publication; destination/source parents precede the derived locator and
any canonical item reference. Recovery repairs those durability boundaries for a discovered orphan
even when both intent and lookup are absent. Same-filesystem staging/publication remains required;
there is no cross-filesystem whole-tree copy fallback. Actual read-only canonical archives may be
read without requiring their old owner mapping or attempting fsync on the read-only mount.

The locator is used by extraction, document reads, copies, job resume/disposal, corpus/rebuild and
published-but-uncommitted quota reconstruction. Shared quota retains actual encoded stage, proof,
receipt, temporary and pinned publication bytes; actual destination-filesystem capacity checks
also guard directories, canonical intents and derived index growth. Normal page reads still check
one bounded proof path, rather than hashing a complete tree. An internal exact-byte storage
publication entry point preserves foreign manifests/IDs for later transport integration, but grants
no item authority and is not exposed through the peer wire.

Before first arrival-tree publication the source raises reader level **10** with
`tractanda.document-placement.v1`. Reader 9 refuses that retained store. Document-capable
v3 intake has its separate reader-11 gate; placement alone does not implement document intake.
Document sources already carry positive Int64 lengths without a format-level 8 MiB limit.
Historical inline-v1 output stays bounded to 1–2 pages. The legacy blocking converter bridge keeps
its 8 MiB whole-input guard; paged native jobs use a verified source path and their existing runtime
budgets. Placement work neither loads a model nor changes inference limits.

The contract and focused native/static evidence are retained under
`outputs/verification/cluster-2026-10-16/`. The coherent308 selected current-source runtime passed on Linux, but it does not establish dedicated mounted read-only/foreign-owner archive behavior or foreign document transfer. Deployment remains a separate gate.

## Document framing and private-stage checkpoint B1

New internal packages/plans use `tractanda.peer-package.v3` / `tractanda.peer-export.v3`.
Exact retained v1/v2 descriptors, manifests and export evidence keep their original profiles;
nil optional part addresses do not change their encoded bytes or hashes. Fresh network input
requires v3, while reserved PRIVATE LOCAL old-profile continuation stays narrowly internal.
Before v3 sealing the source synchronizes reader **11** and `tractanda.peer-documents.v1`.

Document parts have internal `(contentUUIDv1, manifest|node|page, level, ordinal)` addresses.
Canonical UUIDs and stored schemas remain unchanged. Metadata indexes anchor manifests only;
nodes/pages are discovered from the original document proof tree. Manifest/node limits stay
64 KiB, page limits 2 MiB, and document chunks 256 KiB. Package metadata UUID collision checks
remain intact. A content UUID is never replaced by an invented canonical page identity or sender path.

`PeerDocumentTransfer` binds a separate receiver-private UUIDv1 tree stage and byte stages.
Every node/page append requires its exact length/hash/address to be reachable through the anchored
manifest and at most nine bounded proof nodes. Chunk intent, synchronized actual bytes and a
durable monotonic high-water checkpoint precede acknowledgment. Partial-tail repair cannot discard
acknowledged bytes. Cold digest work uses the existing bounded verification engine and continues
across operation windows; process loss may restart verification while retaining transferred bytes.

Verified parts move by same-filesystem no-replacement rename into their exact private tree paths,
preserving bytes and avoiding a second document copy. Interrupted rename retries repair both
directory-sync and quota ownership before acknowledgment. Shared quota reconstructs private proof,
byte-stage and tree bytes, including published-unapplied trees, and guards temporary peaks and
actual destination capacity. Transfer completeness grants no item permission or conversion success.

B1 validates framing and the storage bridge only. Package export/relay integration, resumable SQL
whole-tree closure, source-revision binding, all admission/projection readiness seams, encrypted
foreign transfer and its final publication/recovery matrix remain B2. Until B2 is complete, the
existing foreign-document refusal remains active. No live listener, pairing or deployment is enabled.

## Saved-document transfer integration B2

This source integration supersedes the preceding A/B1 checkpoint limitations. V3 export carries a
manifest anchor in the bounded metadata closure; resumable SQL traversal discovers exact hash
nodes/pages through internal composite addresses. Page counts and total document bytes are not
limited by metadata object counts or one operation's work/read allowance. Individual pages remain
at most 2 MiB and travel in at most 256 KiB chunks. Unusable one-proof allowances fail explicitly;
ordinary budget exhaustion returns continuation without restarting completed cursor work.

The receiver verifies complete source-revision/original bindings, all-kind identities across package
and retained history, raw manifests/nodes/pages, converter provenance and exact conversion outcomes.
Missing, corrupt or conflicting dependencies block sealing. A legitimate partial/failed conversion
can still have complete transport. Originals and complete durable trees precede canonical references;
arrival placement, immutable intents and derived indexed lookup retain the A contract. Exact retained
v1/v2 proof bytes and reserved PRIVATE LOCAL continuations remain recoverable; fresh traffic uses v3.

A durable closed-stage barrier refuses supported append/retry/adopt/discard mutations during bounded
final inspection. Verified per-part stamps detect changed nested entries across yielded work. Final
inspection completion, fresh publication context and directory publication share one owner operation.
This relies on the established service-owned filesystem boundary; it is not protection against a
privileged host owner concurrently damaging files. Storage readiness grants no item or origin authority.
Current ACLs, source authority, retirement cuts and fresh commit fences remain separate requirements.

Verified pages build hidden corpus generations incrementally using existing source keys and overlays.
Only accepted current-head links expose their text. Held/revoked text stays hidden even for a readable
existing item. Rebuild uses authenticated raw page lengths, preserving noncanonical JSON whitespace.
Peer corpus work has a separate count namespace while actual encoded bytes, temporary growth and
filesystem reserve remain charged. Applied pins retire in bounded windows; idle disposable preparation
expires after one hour without cursor/inspection progress. GC releases charges only after actual
disposal. Canonical history, saved outcomes and acknowledged transfer bytes remain intact.

Internal LOCAL review has separate target and exact-request preflight methods returning an unfinished
or ready private handle. They bind the authenticated actor/store/origin, evidence, current state and
request intent, prepare bounded storage/corpus work outside preview transactions, and recheck current
authority before publication identity/sealing. Existing prepare returns a complete snapshot and resolve
returns only a committed result; neither reports pending work as success. Cache loss requires bounded
preparation again. Exact committed replay retains its early historical-acknowledgment path. No public
review endpoint or new client workflow is introduced.

Focused ordinary corpus/TLS, recovery and INTERNAL LOCAL review checks passed in the retained B2
checkpoints; the final affected-consumer gate passed 98 cases, with 14 distinct LOCAL review cases
passing across their focused runs. These do not revalidate every historical suite. Dedicated behavior for mounted-readonly/foreign-owner archives, cross-filesystem publication and committed review replay after retirement remains unverified by the coherent308 scope.
This internal review subfeature remains source-only and default-off; those tests do not establish a
live review endpoint.

### Finite local enrollment supervisor (source only)

`peer enrollment activate` captures the private target-only envelope before resolving the source
connection. Explicit independently trusted source/bootstrap/approval pins remain required. The
source uses its existing authenticated native UNIX endpoint, expected kernel daemon UID and current
canonical authority; it never starts a daemon. Each path-free source read returns at most 64 KiB,
and the supervisor assembles only one descriptor-bounded target chunk at a time. One monotonic job
cutoff includes nonblocking source connect and frame IO. Resource, repair and authorization failures
are explicit; the workflow does not spin or repair canonical evidence. Only the exact
`peerPayloadVerifying` transient retains the same target Session and retries the same operation
(or source descriptor/offset), with a fixed yield, finite work counter and current absolute
deadline/cancellation checks. No offset advances until the exact reply succeeds.

The local helper is the fixed `tractanda-setup` sibling of the actual running image, with ownership,
mode, no-follow and mutation-ACL checks. There is no PATH, argv-zero or arbitrary-command fallback.
A newer helper profile is required before transmitting private input. For a different existing OS
custodian, only the protected managed macOS helper and typed noninteractive sudo invocation are
supported; Debian package and Setup paths exist. Privileged cross-UID adoption must be validated on
the supported package/runtime combination before use. OS invocation selects filesystem custody,
not a global application identity. No accounts, services or installations are created by this
local enrollment CLI.

FINISHED is an activation receipt. CLOSED additionally means the original Session control scope
has unwound and its Store/writer has been released. Source registration follows validated FINISHED,
validated CLOSED and actual owned-child reap, in that order. Lost closure acknowledgment reports
uncertain target custody and skips registration; exact accepted material can be retried. Registration
response loss is separately uncertain because an already-started synchronous canonical mutation
cannot be promised rollback. Abort retains child ownership through TERM, bounded grace, exact-owned
fallback and wait/reap; physical OS cleanup can outlast the semantic deadline. On a cross-UID abort, reaping sudo does not prove
that every privileged descendant or writer has stopped: unconfirmed target custody remains
explicitly uncertain and registration is skipped. Private buffers are
cleared best-effort without a stronger Swift memory-erasure claim. The fixed SSH transport is described below.

Focused fixtures use isolated same-UID stores. They do not establish privileged cross-UID deployment,
arbitrary-size eventual completion, or complete-cluster restoration. Historical verification receipts
retain their exact selected cases and limits.

### Fixed SSH enrollment transport (B2; source only)

`peer enrollment activate` accepts a remote destination only when `--ssh-host HOST`, `--ssh-login OS_USER` and `--ssh-platform macos|linux` are all supplied. The optional `--target-user OS_USER` selects an existing remote custodian; the source never resolves that name locally or treats SSH identity as canonical application authority. The workflow keeps the source process's actual kernel UID, uses the existing authenticated source socket without starting a service, and preserves independent source-replica, bootstrap and approval pins.

The client is fixed at protected `/usr/bin/ssh`; the remote helper path is fixed by platform: macOS `/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-setup`, Linux `/opt/tractanda/current/bin/tractanda-setup`. Debian packaging now installs the Linux helper; host-specific presence and readiness must still be verified before activation. The current Stash packaged guard has a cross-UID StoreID-reader defect, so the path being installed does not mean prepared-target adoption is currently passing. SSH uses `-F/dev/null`, `-T`, `-Snone`, strict existing known-host checking, batch mode, no host-key updates, no forwarding, no agent forwarding, no compression, and an exact replacement KEX list `mlkem768x25519-sha256,sntrup761x25519-sha512`. This disables user SSH configuration, multiplexing and PTY allocation, and provides no classical KEX fallback. Separate local runtime probes are intentionally omitted; the fixed invocation enforces the options and unsupported combinations fail before READY/private input. The bounded connect timeout sits under the single absolute job deadline.

The source sends the private target envelope only after the exact helper READY response and both public pins have validated. Success requires validated FINISHED, strong CLOSED, successful reap of the owned local SSH client and then source registration. Any earlier SSH/client loss leaves remote custody uncertain and skips registration. Local reap does not prove remote descendants stopped. The accepted source implementation was independently reviewed. One coherent macOS invocation and one coherent Linux invocation each passed the same 30 selected methods with zero failures/skips and 19 complete filesystem fixture proofs; do not sum them as 60 distinct methods. The Linux run matched all 1,236 frozen project inputs plus three support inputs, all 1,242 current Mac inputs and unchanged before/after environment fingerprints. Its 21 recorded PIDs are absent; 18 local helper/client children were explicitly reaped, and the validation unit is not found/inactive with MainPID zero and an empty control group. The macOS and Linux SSH cases use controlled SSH-shaped children pumping the actual built same-UID helper. They do not establish real host authentication, a negotiated hybrid KEX, privileged invocation, deployment or live enrollment. See the [B2 Mac30 audit](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SSH30-MACOS-AUDIT.md), [Mac result receipt](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SSH30-MACOS-RESULT.json), [B2 Linux30 audit](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SSH-LINUX30-AUDIT.md) and [Linux result receipt](../outputs/verification/cluster-2026-10-18/PEER-ENROLLMENT-SSH-LINUX30-RESULT.json).

The user accepted coordinated maintenance for canonical-format or authorization/merge changes: all active nodes, including roaming members, must be reachable and upgraded before writes resume; a verified compatible change may roll. The peer configuration and prepared-target paths have advanced beyond the historical planning-only state described in older test receipts. C1's compatibility preflight passed bounded Mac37/Linux37 validation; C2's default-off managed configuration path has bounded Mac28/Linux20 source results. Those tests mocked installation and do not establish host lifecycle behavior. Debian package installation is now supported and has been exercised on Stash, but its packaged prepared-adoption guard is blocked by the current cross-UID reader defect. No live Raven–Stash cluster acceptance or publication is claimed.
