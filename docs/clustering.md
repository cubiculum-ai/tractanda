# Personal and workgroup clustering

Tractanda connects personal, family, and small-workgroup installations as equivalent full-server peers. Each physical replica has one writer. Item content is multiwriter: members can make independent offline edits and exchange them when connected. Any current member may coordinate membership changes; there is no permanent master.

This page describes the current checkout's source contract and operator interface. Native pairing was privately qualified in separate Mac27, Linux94 and focused LinuxSDK5 runs, including two- and three-node fixtures; these source tests are distinct from live deployment. Raven, Stash, and Starlet now have live three-node membership on the approved filesystem layout. After exactly one managed Starlet restart, independent status checks showed all three nodes ready with the same membership digest; each observed two connected data-capable peers, and normal content/history checks passed before and after restart. Older public releases may differ from the current checkout, and no public release of the layout migration is claimed. Fixture results do not establish a 16-member deployment. See the [current project checkpoint](../outputs/Tractanda-Resume.md) for exact status and separate validation receipts.

## Content, access, and recovery

Committed item revisions and their owned payload files are the content source of truth. A standalone recovery rebuilds its disposable index from the selected canonical item history and payload closure, then uses fresh local configuration and OS identity mappings. It does not require the old SQLite database, authority ledger, replication receipts, or peer secrets. Old-format placement alone does not prove prior admission; an administrator-selected recovery set must make that limitation explicit. Unaccepted incoming or staged data stays separate and is never silently promoted during normal startup or recovery.

Current item permissions govern access to all history, and permission changes create ordinary item revisions. Unix accounts and groups provide the global user names, while UID/GID, administrator and sudo-group mappings remain local. Tractanda does not provision OS accounts. Replicated item content cannot overwrite current local peer membership or credentials.

Independent authored revisions are preserved. Non-overlapping ordinary edits can merge into ordinary history; conflicting content requires review and explicit resolution. Concurrent permissions consolidate restrictively, and an owner may relax them later. For ownership fields, the latest authorized revision that actually changes the field wins by UUIDv1 encoded ticks, with a deterministic revision-ID tie-break for exact timestamp ties. A disconnected peer may not yet know a remote edit or revocation, so local readiness or a successful connection alone does not prove convergence.

## Membership and pairing

Peer membership and credentials are current administrator-controlled configuration. An omitted peer is out; an explicitly readmitted peer is in. Past exclusion is not permanent, and a fresh-cluster recovery uses explicit fresh pairing rather than restoring old membership automatically. Disposal protects surviving peers; it never deletes items based on their origin.

Adding a member requires all current members and the joining node online. Removing one requires all retained members online; the departing member may be offline. These coordination rules do not make any member a permanent master. The initial native coordinator limit is 16 resulting members, while canonical membership metadata supports 256; private validation has covered two- and three-node scenarios only. No 16-node scale claim is established.

The native flow uses a current administrator-issued, single-use pairing code. Deliver it through a private terminal or private file; it is never placed in command arguments, logs, or ordinary JSON. An unused code expires. Once accepted, the daemon-owned job continues if the CLI exits or disconnects, and can be inspected or resumed. Pairing uses the existing TLS 1.3 forward-secret hybrid PSK binding; peer pairing does not require a public CA or ACME. This private peer binding is distinct from the certificate-authenticated HTTPS/JMAP binding for ordinary network clients.

## Set up a first member and add a full-listener peer

Use the same current checkout build on each host and give each member a stable DNS hostname. Make the selected peer TCP port reachable between those hosts. Unix users and groups must already exist on each system; Setup does not create them. The current checkout and locally verified Raven/Stash deployment use the layout in [installation](install.md); older public releases may differ.

On Debian, install the complete `.deb`, then initialize a first source with an existing OS username. On macOS, install the `.pkg` and keep its standalone sample store for the first member. In both cases, explicitly configure a listener and enable synchronization with a nonsecret peer runtime file. Substitute a port allowed by your host/network firewall:

```sh
umask 077
cat > peer-runtime.json <<'JSON'
{
  "profile": "tractanda.personal-runtime.v1",
  "settings": {
    "version": 1,
    "listen": {"host": "0.0.0.0", "port": 48732},
    "peers": [],
    "synchronization": {"enabled": true, "intervalSeconds": 15}
  }
}
JSON
chmod 600 peer-runtime.json
```

For a Debian first source, pass that file to Setup:

```sh
sudo /opt/tractanda/current/bin/tractanda-setup install --name production --owner EXISTING_OS_USER --first-source --sample --peer-runtime-configuration peer-runtime.json
```

For a macOS `.pkg` first source, keep its installed sample profile (normally `default`) and configure its listener through Setup:

```sh
sudo /Library/Tractanda/Software/current/bin/tractanda-setup upgrade --name default --peer-runtime-configuration peer-runtime.json
```

Check the local StoreID and listener state:

```sh
tractanda --profile production cluster status
```

Use the actual profile name on macOS if it is not `production`. The `Store:` line is the public StoreID. To issue the first invitation, name the first host's stable DNS route:

```sh
tractanda --profile production cluster invite --hostname first.example --out "$HOME/tractanda-invitation.txt" --json
```

The JSON output contains public invitation metadata, including the StoreID; the private code is written only to the new mode-`0600` file. Keep that file private and give its code to the joining operator through a private channel. Do not put the code in a shell command or ordinary log.

For a joining host that must listen for additional peers, install the current software without a sample store. Create its own nonsecret `peer-runtime.json` with a listener port and an initially empty `peers` array. Obtain the target StoreID from `cluster status` or invitation metadata. On macOS, choose **Customize → deselect Initialize a sample store**. On Debian, install the complete `.deb` first. Run the matching full-listener Setup command as the existing OS user:

```sh
sudo /Library/Tractanda/Software/current/bin/tractanda-setup install --name production --owner EXISTING_OS_USER --empty --fresh-personal-target --store-id STORE_ID --peer-runtime-configuration peer-runtime.json
```

On Debian, use `/opt/tractanda/current/bin/tractanda-setup` in place of the macOS path. This deliberately omits `--new-instance-only` and `--outbound-peer-sync`: it prepares a listening target with the configured runtime. Then, on that host, enter the invitation privately at the hidden prompt:

```sh
tractanda --profile production cluster join --hostname joining.example
```

This ordinary join uses the already prepared target. The `--prepare-new` convenience path creates an outbound-only target and does not open a listener; current topology allows at most one outbound peer per node. Use full-listener Setup when adding a member to a three-or-more-node mesh. Check `cluster join-status`, `cluster resume`, and `cluster status` on the relevant hosts until the baseline completes and membership lists the intended nodes. These status views are local evidence; verify ordinary content and history in both directions as well.

Establish the listener and peer policy once through Setup. Later enrollment updates only protected current routes and jobs through the daemon; it does not repeat privileged installation steps. For a full-listener target, install without a sample store and follow [fresh-target Setup](personal-fresh-target-setup.md). The `cluster join --prepare-new` shortcut instead prepares an empty outbound-only target, uses the invitation's public StoreID, and submits the code privately; it does not listen for peers. Ordinary `cluster join` never auto-adopts or replaces an unknown or occupied store. Setup resumes only its exact owned preparing operation.

## Commands

The source CLI accepts these forms (the standard configured local profile is `production`):

```text
tractanda --profile production cluster invite [--hostname DNS] [--fallback-host DNS] [--out PRIVATE_FILE] [--resume] [--json]
tractanda cluster join --prepare-new NAME --hostname TARGET_DNS [--code-file PRIVATE_FILE] [--no-wait] [--json]
tractanda --profile production cluster join --hostname TARGET_DNS [--replace-expired] [--code-file PRIVATE_FILE] [--no-wait] [--json]
tractanda --profile production cluster join-status [--operation-id UUID] [--json]
tractanda --profile production cluster resume [--operation-id UUID] [--json]
tractanda --profile production cluster status [--json]
```

`invite` writes the code to a private terminal or private output file; `--json` requires `--out` and returns invitation metadata only. `invite --resume` redisplays the same still-unused invitation to a private sink. `join` reads the code privately from a terminal or `--code-file`. Use `--prepare-new` only for an explicitly selected empty target, and do not combine it with `--replace-expired`. Ordinary `join` does not initialize or replace a store. `--no-wait` returns the current operation summary; otherwise the CLI follows progress. If the CLI exits, use `join-status` or `resume` for the same operation. Bounded expired-candidate recovery is privately qualified: original/pending continuations race a fresh unused-code authentication, accepted continuations win, and an unverified candidate is never promoted.

An unjoined target remains fenced from ordinary content until the selected baseline is complete. Enrollment selects a source explicitly, transfers committed history and owned payloads, and requires baseline completion before ordinary content use. Staged or stale-author data remains separate for review. Startup does not silently finish a baseline.

`cluster status` reports current local configuration and observed progress or errors with their actual timestamps. It does not invent totals, percentages, or remote health from stale observations. An open connection, empty report, or completed transfer cut does not prove all peers are healthy or converged. The per-server `peer status` and `personal-peer sync-status` commands remain lower-level diagnostics.

## Routes and upgrades

Node-local ordered DNS alternatives may change routing without changing shared membership identity or digest. Names are resolved again for each reconnect. The authenticated ReplicaID and current credentials establish peer identity; an IP address does not. An established connection supports incoming and outgoing item synchronization. Those labels identify which side initiated the socket, not a one-way data permission.

Compatible software updates may proceed through the normal managed macOS upgrade or standard Debian `dpkg` package upgrade. They keep canonical data in place and require no whole-store copy or reconversion. A breaking canonical-format or authorization/merge-semantics update requires coordinated maintenance: all active members, including roaming members, must be reachable and upgraded before writes resume. Package installation alone does not enroll a peer or establish readiness. Never use ordinary file synchronization to copy a live store as a substitute for the peer protocol.

## Related references

- [Recovery model](personal-workgroup-recovery.md)
- [Peer enrollment](personal-peer-enrollment.md)
- [Fresh target setup](personal-fresh-target-setup.md)
- [Private peer JMAP binding](private-peer-jmap-binding.md)
