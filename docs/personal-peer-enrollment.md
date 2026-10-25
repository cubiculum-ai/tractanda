# Personal/workgroup fresh peer enrollment

Final source/private validation passed a combined24/24 suite plus separate standalone1/1 and configured-empty-key/online-prepare1/1 checks; earlier failures remain preserved. Linux packaging and live enrollment remain separate verification steps. Do not infer deployment, installation, membership or completed synchronization from these commands alone. The installed application and current canonical stores stay untouched until their authorized deployment operation passes its normal gates. This workflow uses the selected source's raw ordinary item history and owned payloads; it never imports the old peer's production installation, database, authority ledger, receipts, credentials or secrets.

Every peer remains an equivalent member. Each pair receives two fresh directional TLS contexts, so either endpoint can reconnect. Both authenticated ends pull a finite inventory on every accepted current connection. Concurrent dialing selects the same socket by shared pairing ID; it does not choose a permanent source/master. Current administrator membership is separate from replicated items.

## Inputs and identities

Retain the verified precautionary archive separately. Use the current source StoreID, a fresh target root and the locally selected access policy. Run store commands as the owning service account, with an explicit current human administrator where shown. These commands acquire the store's exclusive writer; they never stop a daemon for you. Source configuration can instead use the native authenticated commands once the new daemon is running.

```
tractanda personal-peer target-create TARGET_ROOT COMMON_STORE_ID ACCESS_JSON
tractanda personal-peer local-identity TARGET_ROOT
```

The fresh factory rejects an occupied target and creates a new ReplicaID using the common StoreID. It does not copy a source ReplicaID. Keep the target empty: no starter categories or sample items before its explicit baseline selection. Choose a current membership document using `PersonalMembershipConfiguration`: profile `tractanda.personal-membership.v1`, the common `storeID`, a fresh UUIDv1 `configurationID`, and sorted unique members with their ReplicaIDs and configured DNS hostnames. Do not use pinned IP addresses. Local Unix names/groups must resolve on each host; network synchronization never provisions accounts.

For the initial two-member configuration, prepare the same proposal on both hosts. `EXPECTED_DIGEST_OR_-` is `-` only when no current membership exists; later changes use the actual current digest. A shared UUIDv1 nonce is convenient. The recognized administrator name must agree across the hosts.

```
tractanda personal-peer local-prepare ROOT MEMBERSHIP_JSON EXPECTED_DIGEST_OR_- NONCE ACTOR
```

Save each exact preparation response privately. Native preparation while serving is:

```
tractanda --profile production personal-peer prepare MEMBERSHIP_JSON EXPECTED_DIGEST_OR_- NONCE
```

Preparation grants no item access. Addition requires all current members and the joining node online; removal requires every retained member online, with no need for the departing member. Mixed add/remove changes are rejected. An explicit local administrator readmission may discard the joining node's obsolete local membership assumptions, but still requires fresh pairing and every member of the selected current cluster online. It is not automatic resurrection of old membership.

## Fresh private pairing and local runtime

Create two separate empty owned private directories (mode 0700) for each pair, then generate files using the existing qualified TLS credential format:

```
tractanda personal-peer pair-files MEMBERSHIP_JSON LEFT_REPLICA RIGHT_REPLICA LEFT_PRIVATE_DIR RIGHT_PRIVATE_DIR
```

Each directory receives that host's fresh dialing and accepting credential. Secrets are protected binary files, never terminal JSON. Transfer only the correct host's files through the authenticated private administration channel. Keep ownership/mode compatible with the receiving service account; registration captures only bounded owned regular files without symlinks or extra ACLs. For more than two members, generate each new pair into separate empty directories and register the complete required local file set for the proposed configuration.

```
tractanda personal-peer local-register ROOT MEMBERSHIP_JSON ACTOR CREDENTIAL_FILE...
```

Native registration accepts protected local paths, not secret bytes in method arguments:

```
tractanda --profile production personal-peer register MEMBERSHIP_JSON CREDENTIAL_FILE...
```

The service account must own and be able to capture those local files. Missing/substituted credentials do not become trusted through mere file placement.

Create an explicit new runtime document for each host. It wraps the established local endpoint settings in profile `tractanda.personal-runtime.v1`; old unwrapped authority runtime JSON is rejected before opening a store or listener. The helper uses each remote member's configured hostname and a deterministic `REMOTE_REPLICA-dial` local alias.

```
tractanda personal-peer runtime-file MEMBERSHIP_JSON LOCAL_REPLICA PEER_PORT NEW_PRIVATE_JSON
```

Managed Setup preserves/captures that bounded document and passes its owned path as `--peer-runtime-config`. Linux binaries remain dpkg-owned. Keep ordinary package compatibility/readiness, macOS signed managed upgrades and authorization gates. Do not modify a managed installation in place. The distribution UUID service must pass normal UUID issuance checks; this workflow adds no Tractanda-only uuidd override.

## Control-only preparation, commit and baseline

Before any target content arrives, select the source explicitly on the empty target:

```
tractanda personal-peer local-baseline-begin TARGET_ROOT SOURCE_REPLICA ACTOR
```

Or use the native `baseline-begin SOURCE_REPLICA` command on a fresh serving target. Save its local selection ID privately; this token is never sent over the peer protocol. Start both configured new daemons through their owned lifecycle. A locally prepared proposal can authenticate only control messages using its exact staged credentials/configuration digest. Inventory, reads, staged writes and publication still require committed current membership. A readiness probe exposes only whether both ends have committed; it prevents data attempts from tearing down healthy control channels during sequential commit.

```
tractanda --profile production personal-peer commit THIS_HOST_PREPARATION_JSON
```

Commit on each required host. The runtime collects exact configuration/nonce readiness replies over actual authenticated active sockets and passes opaque host-only acknowledgements to Core. Request JSON cannot assert that a member was online. Disconnect cancels its presence control; current membership/credential checks apply again at commit. Already-committed members can answer the same selected configuration's readiness for the remaining members, allowing a partially completed operation to resume honestly.

The source remains available while the target captures/copies its finite baseline and catches up. During an explicitly pending baseline, the target retains imported raw history but withholds ordinary content serving until final reconstruction. Startup does not silently finish or promote a baseline. Inspect progress through authenticated native status:

```
tractanda --profile production personal-peer sync-status
tractanda --profile production peer status
```

`sync-status` reports per authenticated configuration the completed finite cuts and the last revision outcomes/byte count. Wait for the initial cut and a fresh rescan from the selected source, inspect errors/review outcomes and then close that target's exact selection:

```
tractanda --profile production personal-peer baseline-finish SELECTION_ID
```

This reconstructs current item state using the selected ordinary history and local identities. It is not evidence that an unrelated old store was compared or merged. Verify current content, ordinary history, deletion states and owned payload reads through normal APIs. Then create a small ordinary item on each side, observe it on the other, verify a revision in both directions, and restart a peer to check persisted convergence. Production verification must use the authorized operator plan and exact receipts.

## Continuations, limits and interruption

Inventory is a finite local catalogue high-water cut with bounded pages. Completed progress uses a disposable per-peer watermark bound to both local and remote SQLite catalogue generations and the consumed rowid. Unchanged polls use cheap empty suffix cuts; new writes enumerate only the suffix. A lost/rebuilt index on either side or a lost/corrupt cursor triggers a fresh scan. UUID order is not treated as causal or append order. Missing parents and owned dependencies are completed before a descendant body is downloaded/applied, using disposable private disk frames with one current descriptor/dependency cursor in memory; canonical-known parents are distinct from merely complete staging. Reverse-ordered ordinary chains need one dependency walk, not repeated whole-store rescans. Revision identities and hashes make duplicate visits idempotent; independent ordinary branches remain history. Owned originals and document trees use bounded dependency pages and at most 256 KiB raw chunks; an arbitrary Int64 original is never placed into one JSON message. Partial bytes stay in distinct private staging and resume by verified offset after disconnect. Newly unaccepted or stale-author proposals remain distinct from ordinary canonical items. Current permissions and membership are checked again at publication.

Personal v3 rejects authority v2 frames and historical operations before their payload can enter the personal gateway. Frame length is bounded, pre-capability frames have a smaller bound, each direction has one outstanding request, and current members are checked on attach and on each request. The qualified TLS1.3 hybrid PSK adapter, authenticated identities, PFS/PQ exchange and cipher checks are unchanged.

There is no overall data-session timer. DNS/kernel connection attempts are separately bounded; active TLS/capability and individual RPC/partial-frame work use generous configurable finite defaults of 24 hours:

- `TRACTANDA_PERSONAL_PEER_HANDSHAKE_SECONDS`
- `TRACTANDA_PERSONAL_PEER_OPERATION_SECONDS`

Both time budgets accept positive finite values up to seven days; invalid configured values fail startup. These are per-attempt/per-operation budgets, not renewed absolute transfer deadlines or fabricated progress. In particular, a healthy slow TLS exchange does not inherit the old short 30 second handshake cap. Membership presence follows the actual live authenticated socket and cancellation, not a short elapsed-time approval window. Explicit cancellation, actual connection failures, resource limits and current membership changes remain effective.

`TRACTANDA_PERSONAL_PEER_WORK_BYTES` configures the private dependency-frame byte budget (default 256 MiB, minimum 256 KiB), with the genuine 10 GiB free-space reserve checked by secure writes. It limits temporary work storage rather than the number of store revisions; completed active-path keys are removed on pop. Work frames carry no permanent admission identity and can be discarded/rescanned after interruption.

The final combined macOS run passed24 focused cases. Its actual daemon case copied2,209 reverse-catalogue-order ordinary revisions with a1 MiB staging limit, exercised empty/suffix cuts, both connection directions, partial-original restart/resume and payload reads. Separate standalone1/1 and configured-empty-key/online-prepare1/1 checks also passed; these are distinct invocations. Earlier failures remain retained in RESULT.json. This is bounded private validation, not live cluster proof or unlimited-scale convergence. Receipts are under `work/simple-sync-20261025/incoming/`; transport source seal is `work/simple-sync-20261025/transport/SOURCE-11.json`.
