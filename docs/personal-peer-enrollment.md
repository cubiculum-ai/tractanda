# Personal and workgroup peer enrollment

This guide describes native pairing in the current checkout. Private qualification passed separate Mac27, Linux94 and focused LinuxSDK5 runs, including two-node and three-node fixtures; those source tests are distinct from live deployment. Raven, Stash, and Starlet now have a live three-node membership. After exactly one managed Starlet restart, independent status checks showed all three nodes ready with the same membership digest; each observed two connected data-capable peers, and normal content/history checks passed before and after restart. Older public releases may differ from the current checkout; no public release of the layout migration is claimed. Check the [Resume checkpoint](../outputs/Tractanda-Resume.md) for current receipts and limits.

## Before pairing

Peers are equivalent full-server members with one writer per physical replica and multiwriter item history across replicas. Any current member can coordinate an addition. All current members and the joining node must be online for an addition; removing a peer requires all retained peers online, but the departing peer can be offline.

Set up the peer listener and policy once through the normal Setup workflow. Give each node a stable DNS hostname and configure the chosen peer port through the host firewall. The native join flow then uses the protected daemon route and job store; it does not repeat privileged Setup steps. On macOS, deselect the optional sample-store component on a fresh joining host. A populated sample or existing installation cannot be adopted, replaced, or erased by joining. Linux binaries remain owned by `dpkg`.

For a full-listener target, use the [fresh-target Setup procedure](personal-fresh-target-setup.md) to prepare an empty store with its public StoreID and nonsecret listening configuration. Then use ordinary `cluster join` with the code at the hidden prompt. The `--prepare-new` shortcut prepares an outbound-only target and does not open a listener; current topology supports at most one outbound peer per node, so use full-listener Setup when building a three-or-more-node mesh. Existing or unrelated data remains protected; Setup resumes only its exact owned preparing transaction. User-shadow profiles and occupied stores are refused.

## Issue a private invitation

On an established member, an authorized administrator issues a single-use code. A standalone first source must specify its stable hostname because it has no current membership route yet. Send the code to the joining operator through a private terminal or a private file:

```text
tractanda --profile production cluster invite --hostname first.example --out "$HOME/tractanda-invitation.txt" --json
```

The command prints public invitation metadata, including the StoreID, as JSON; it writes the private code only to a new mode-`0600` file. The StoreID can also be read from `tractanda --profile production cluster status`. Never put the code in command arguments, logs, or ordinary JSON. Keep the code file private and deliver its contents through a private channel. An unused invitation expires. If delivery fails or the CLI exits before delivery, `invite --resume` redisplays the same still-unused code to a private terminal or output file; it does not mint a replacement.

Optional `--fallback-host DNS` values add ordered node-local routes. Routes affect reachability only; the authenticated ReplicaID and current credentials establish identity. DNS names are re-resolved on reconnect.

## Join and follow the operation

On the joining node, enter the code at the private prompt, or provide a protected code file:

```text
tractanda --profile production cluster join --hostname target.example
tractanda --profile production cluster join --hostname target.example --code-file /secure/path/invitation.txt
```

`--hostname` names the joining node; the code already contains the issuer's routes. Use `--prepare-new NAME` only when explicitly creating a new empty target. Use `--replace-expired` only for its dedicated expired-code recovery path; the bounded replacement-candidate renewal flow is privately qualified. Do not use it to replace an existing store.

The CLI/Setup handoff keeps the code in memory rather than argv, logs or installation receipts. The daemon persists protected invitation/continuation credentials for exact recovery, and its accepted job continues independently of the CLI, terminal and connection. The default CLI waits and prints changed progress; `--no-wait` returns the current operation summary. The join can be inspected or continued with:

```text
tractanda --profile production cluster join-status
tractanda --profile production cluster join-status --operation-id UUID
tractanda --profile production cluster resume --operation-id UUID
```

The operation uses the established TLS 1.3 forward-secret hybrid PSK peer binding. This certificate-free private peer binding is distinct from the certificate-authenticated HTTPS/JMAP endpoint used by ordinary network clients. Peer connections are private protocol channels and do not require CA or ACME enrollment.

## Baseline, permissions, and recovery

The new target is durably marked unjoined from its first identity. Ordinary item access remains fenced until the daemon job completes the exact selected source's finite cut and fresh rescan, with no active/error transfer or unresolved incoming review. Normal pairing does not require a manual baseline-finish command. Startup does not infer a source or promote staged data; after restart the same job obtains fresh process-bound cut observations before finishing. Verify the status operation's actual conditions and errors before treating enrollment as complete.

Committed item revisions and their owned payloads are the content history. Current item permissions govern all history. Permission conflicts consolidate restrictively. Independent edits remain ordinary history; conflicting content is reviewed and explicitly resolved. Unaccepted incoming or stale-author proposals stay separate until an authorized decision accepts or resolves them. Refer to the [recovery contract](personal-workgroup-recovery.md) for canonical recovery, ACL, identity, and ownership-order details.

Current membership and credentials are local administrator configuration, not replicated item content. Omitted peers are out; explicit readmission is allowed. Fresh-cluster recovery uses fresh pairing instead of resurrecting old membership. Disposal does not delete items based on which peer originated them.

## Status and limits

Use `tractanda --profile production cluster status` for the current local configuration and observed operation progress or errors. Times are reported only for events actually observed. The status does not invent a total or percentage, and an old connection observation is not current peer health. `peer status` and `personal-peer sync-status` provide lower-level local diagnostics; none alone proves global convergence.

The first native coordinator limit is 16 resulting members. Canonical metadata supports 256, but private source scenarios have exercised two and three members only; the live three-node delivery is recorded separately. This is not a 16-member capacity claim. Package installation, a prepared target, or an accepted invitation alone is not proof of a running listener, complete baseline, successful deployment, or synchronized cluster.

See [clustering](clustering.md) for membership, upgrade, and route rules, and [private peer JMAP binding](private-peer-jmap-binding.md) for the transport boundary.
