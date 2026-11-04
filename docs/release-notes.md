# Proof-of-concept preview

This is a source-available proof of concept. See the [changelog](../CHANGELOG.md) for version-specific changes. Formats and APIs may change before 1.0. Use a dedicated evaluation store and keep backups.

From **0.1.0-poc.6**, generic content uses the concrete `Item` class. Shipped templates, fresh installer samples, CLI fixtures and runnable examples use the current classes and native capability `/4` (since poc.8). Update and reconnect older clients. Historical stores are not destructively rewritten by the installer; use a fresh evaluation store to try the current samples. The automated sample check exercises loading, exact retries, view execution and an index rebuild from canonical files.

From **0.1.0-poc.10**, extracted-text diagnostics distinguish canonical text, FTS inputs, semantic source/chunk parameters and actual index freshness. Use the served query reference and the declared `tractanda.extracted-text.v1` feature.

## 0.1.0-poc.17 — mandatory layout and record-format bridge (unpublished)

This unpublished release changes canonical directory names and the physical encoding of item revision files. Attachment staging and placement directories become `attachments/staging` and `attachments/placements`. Item revision files move from `items/YYYY/MM/DD/HH/mm/<itemID>/<revisionID>.tractanda` to `items/YYYY/MM/DD/HH/mm/<itemID>.<revisionID>.tractanda`. The bridge preserves logical IDs, schemas, fields, revision ancestry and history, body bytes, and attachment payload filenames and bytes; item record files are rewritten from the earlier MIME/typed-JSON envelope to `message-v1`. The new message form uses readable/scoped headers and a raw UTF-8 body, with no JSON item body or hidden duplicate. Logical revision formats 1 and 2 remain unchanged. New readers require physical-layout capability `tractanda.physical-layout.flat-items.v1` and floor 19, plus message capability `tractanda.message-items.v1` and reader floor 20. Completion is recorded in the visible root marker `canonical-layout.json`, including `recordEncoding: message-v1`; a missing or incompatible marker is a preflight refusal, not a signal to search old paths or convert during ordinary reads. See [the item-file format reference](item-file-format.md) for the wire form and recovery behavior.

The `.17` installer is the one-time bridge for stores using older layouts and item-file encoding. A normal standalone `.17` install automatically runs the installer-owned, resumable migration. The supported personal-install path can bridge from the current personal `0.1.0-poc.16.2` installation. Older enterprise/bootstrap maintenance workflows refuse preflight; complete or recover those installations with `0.1.0-poc.16.2` first, then use the normal standalone `.17` installer. The refusal happens before canonical migration or service disruption; on macOS the installer may already have staged unused candidate software files. Later releases require completed `.17` layout and record-encoding markers and must refuse to skip `.17`; they do not carry perpetual legacy-path or legacy-record conversion code.

For an existing cluster, use the previously approved administrator-directed coordinated maintenance process; this release adds no distributed migration protocol. Prepare each member with `sudo tractanda-layout17 prepare --instance NAME --bundle ABSOLUTE_CANDIDATE --coordinated-maintenance`. The `.17` helper binds the installed and candidate manifests and StoreID, records a root-owned one-time intent, and stops only the selected locally managed instance through verified Setup. Prepare and stop every member, then install `.17` on all members while keeping them stopped. After all members are upgraded, run `sudo tractanda-layout17 complete --instance NAME --all-members-upgraded` on each prepared member. It verifies that member's `.17` completion marker, consumes its one-time intent and starts only that local instance. The flag is an administrator assertion that all cluster members are upgraded; it does not prove remote package or service state. On macOS, an unprepared install may stage unused candidate software before refusing, but refusal precedes canonical data migration or service disruption. This is coordinated maintenance, not rolling migration. The commands are implemented in the unpublished candidate; package and cluster rollout qualification remains separate.

## Included

- Canonical revision files, SQLite metadata/literal FTS5 indexes, optional Vec1 retrieval, categories and saved views.
- CLI, TUI and stdio MCP over authenticated Unix sockets.
- Shared daemon: optional loopback HTTP browser/API surface and authenticated Streamable HTTP MCP in the same process.
- A macOS arm64 installer with boot-time system LaunchDaemons, empty/sample stores, separate canonical/index locations, a system connection registry and a shared client path with an owned `/usr/local/bin/tractanda-tui` symlink.
- Upgrade rollback and data-preserving uninstall. The preview reuses the existing `daemon` account and creates no users or groups.
- The currently published `0.1.0-poc.16.2` includes Debian 13 packages for amd64 and arm64, alongside the macOS arm64 installer. Consult that release's evidence for the exact package and host checks.
- Current-permission history access, system-administrator policy, and semantic `item-text-utf8-v2` input over eligible owned text fields.
- A shared agent skill packaged for Claude Code, Codex and Agent Skills-compatible harnesses.

## Limits and pending deployment work

- HTTP binds loopback by default and is not an internet-facing gateway.
- A dedicated service account and full agent account/home provisioning are deferred. The preview uses `daemon`; another service with that same OS identity can access its files.
- macOS browser password login uses OpenDirectory. The Linux PAM broker passed real, synthetic-credential tests in a disposable Debian container; host installation remains an administrator action. No production password was used. See [PAM broker setup](pam-broker.md).
- Do not run a server as root solely for PAM.
- The bundled macOS semantic provider is Granite Embedding 311M multilingual R2 through vmlx-swift, with pinned model/runtime revisions, tokenizer fixes #487/#514 and the applicable model/tokenizer notices. Installer-managed Qwen profiles are upgraded and their derived vectors rebuilt. The obsolete subject/body-only input mode has been removed; indexes are rebuildable.
- The published Linux package scope is Debian 13 on amd64 and arm64. That support statement is specific to those packages and does not establish other distributions or storage environments.
- Real macOS lifecycle checks passed on isolated empty/sample stores: both launchd jobs ran as `daemon`, restart preserved records, a deliberately failed upgrade rolled back, and uninstall preserved canonical data. Boot registration is configured, but an actual machine reboot is not part of that test. Production data was not used for uninstall testing.
- Each release records the package builds and targeted checks actually run. Consult its version-specific evidence; the general workflow description does not imply a full-suite run for every release.
- Personal/workgroup synchronization and attachment workflows are implemented. The `0.1.0-poc.16.2` evidence includes a three-node current/history consistency check; that result is specific to the recorded installation and does not establish arbitrary federation, rolling upgrades, failover, or exhaustive fault coverage. Broader recovery limits remain proof-of-concept scope. A native GUI and full agent-account provisioning remain future work.
- The macOS publication workflow verifies Developer ID signatures, package notarization, stapling and Gatekeeper acceptance before publishing each installer.

## Evaluation guidance

Use a dedicated store, back up canonical revisions, and validate actual OS identities, permissions, credential behavior and managed-service behavior in your own controlled environment. Configure UUIDv1 production issuers with a real host node; the CI synthetic node is disposable-fixture-only. Review dependencies and the selected PolyForm Noncommercial license before any distribution decision.
