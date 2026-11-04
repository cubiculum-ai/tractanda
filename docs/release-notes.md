# Proof-of-concept preview

This is a source-available proof of concept. See the [changelog](../CHANGELOG.md) for version-specific changes. Formats and APIs may change before 1.0. Use a dedicated evaluation store and keep backups.

From **0.1.0-poc.6**, generic content uses the concrete `Item` class. Shipped templates, fresh installer samples, CLI fixtures and runnable examples use the current classes and native capability `/4` (since poc.8). Update and reconnect older clients. Historical stores are not destructively rewritten by the installer; use a fresh evaluation store to try the current samples. The automated sample check exercises loading, exact retries, view execution and an index rebuild from canonical files.

From **0.1.0-poc.10**, extracted-text diagnostics distinguish canonical text, FTS inputs, semantic source/chunk parameters and actual index freshness. Use the served query reference and the declared `tractanda.extracted-text.v1` feature.

## 0.1.0-poc.17.1 — retain reviews backed by canonical history

Pending and rejected reviews can refer to an exact revision already present in canonical history after peer synchronization has retired its private stage. The installer preserves the review ID, disposition and context. An explicit administrator resolution can use the verified canonical bytes while preserving the original revision. The review still requires the existing current-state and permissions checks. A missing or contradictory revision is refused.

For a new migration from 16.2, use the 17.1 package and matching 17.1 bridge helper. Standalone installations migrate automatically. For a cluster, use the coordinated sequence below with the matching 17.1 artifacts, prepare every retained member before installation, and complete each node only after every member has been upgraded. Reader floor 20, message-v1 and the physical layout are unchanged from 17.

A completed and released 17 installation can update to 17.1 through the normal package path without converting its canonical history again. An interrupted 17 operation or a completed 17 store still held by its administrator intent must be resolved with the exact original 17 package and intent before updating. A genuine interrupted 17.1 operation resumes only with the exact 17.1 package.

## 0.1.0-poc.17 — mandatory layout and record-format bridge

This version changes canonical directory names and the physical encoding of item revision files. Attachment staging and placement directories become `attachments/staging` and `attachments/placements`. Item revision files move from `items/YYYY/MM/DD/HH/mm/<itemID>/<revisionID>.tractanda` to `items/YYYY/MM/DD/HH/mm/<itemID>.<revisionID>.tractanda`. The bridge preserves logical IDs, schemas, fields, revision ancestry and history, body bytes, and attachment payload filenames and bytes; item record files are rewritten from the earlier MIME/typed-JSON envelope to `message-v1`. The new message form uses readable/scoped headers and a raw UTF-8 body, with no JSON item body or hidden duplicate. Logical revision formats 1 and 2 remain unchanged. New readers require reader floor 20 and both capabilities, `tractanda.physical-layout.flat-items.v1` and `tractanda.message-items.v1`. Completion is recorded in the visible root marker `canonical-layout.json`, including `recordEncoding: message-v1`; a missing or incompatible marker is a preflight refusal, not a signal to search old paths or convert during ordinary reads. See [the item-file format reference](item-file-format.md) for the wire form and recovery behavior.

The `.17` installer is the one-time bridge for stores using older layouts and item-file encoding. A standalone upgrade from `.16.2` automatically runs the installer-owned, resumable migration. The supported personal-install path can bridge from the current personal `0.1.0-poc.16.2` installation. Older enterprise/bootstrap maintenance workflows refuse preflight; complete or recover those installations with `0.1.0-poc.16.2` first, then use the normal standalone `.17` installer. The refusal happens before canonical migration or service disruption; on macOS the installer may already have staged unused candidate software files. Later releases require completed `.17` layout and record-encoding markers and must refuse to skip `.17`; they do not carry perpetual legacy-path or legacy-record conversion code.

For an existing cluster, schedule coordinated maintenance with the administrator. On each member, download the matching `.17` release artifact and verify it against the release checksums or signed APT metadata. On macOS, extract the matching `.17` bundle archive and check its signature. On Debian, extract the verified `.deb` into a fresh private directory with `dpkg-deb --extract PACKAGE DIRECTORY`, which places the candidate bundle at `DIRECTORY/opt/tractanda/current` without installing it. Set `CANDIDATE` to the absolute path of the extracted bundle containing `bundle-manifest.json`.

Run the helper from the downloaded bundle because the existing `.16.2` installation does not provide it.

```sh
sudo "$CANDIDATE/bin/tractanda-layout17" prepare --instance NAME --bundle "$CANDIDATE" --coordinated-maintenance
```

Prepare and stop every retained member before installing any `.17` package. The helper binds the installed and candidate manifests and store identity, records a one-time root-owned intent, and stops the selected local instance. Install `.17` on all members while keeping them stopped. On macOS, an unprepared install may stage unused candidate software before it refuses, while the current release, services and canonical data stay intact.

After verifying all members have upgraded, run the installed helper with `complete --instance NAME --all-members-upgraded` on each prepared member. Use `/Library/Tractanda/Software/current/bin/tractanda-layout17` on macOS or `/opt/tractanda/current/bin/tractanda-layout17` on Debian. This consumes the local hold and starts the selected instance. The flag records the administrator's assertion about all retained members. The helper verifies the local migration and does not check remote package state.

## Included

- Canonical revision files, SQLite metadata/literal FTS5 indexes, optional Vec1 retrieval, categories and saved views.
- CLI, TUI and stdio MCP over authenticated Unix sockets.
- Shared daemon: optional loopback HTTP browser/API surface and authenticated Streamable HTTP MCP in the same process.
- A macOS arm64 installer with boot-time system LaunchDaemons, empty/sample stores, separate canonical/index locations, a system connection registry and a shared client path with an owned `/usr/local/bin/tractanda-tui` symlink.
- Upgrade rollback and data-preserving uninstall. The preview reuses the existing `daemon` account and creates no users or groups.
- Distribution targets are macOS arm64 and Debian 13 amd64 and arm64. Consult the matching release for its exact artifact and qualification evidence.
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
