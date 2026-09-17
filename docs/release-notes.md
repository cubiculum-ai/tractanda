# Proof-of-concept preview

This is a source-available proof of concept. See the [changelog](../CHANGELOG.md) for version-specific changes. Formats and APIs may change before 1.0. Use a dedicated evaluation store and keep backups.

From **0.1.0-poc.6**, generic content uses the concrete `Item` class. Shipped templates, fresh installer samples, CLI fixtures and runnable examples use the current classes and native capability `/4` (since poc.8). Update and reconnect older clients. Historical stores are not destructively rewritten by the installer; use a fresh evaluation store to try the current samples. The automated sample check exercises loading, exact retries, view execution and an index rebuild from canonical files.

From **0.1.0-poc.10**, extracted-text diagnostics distinguish canonical text, FTS inputs, semantic source/chunk parameters and actual index freshness. Use the served query reference and the declared `tractanda.extracted-text.v1` feature.

## Included

- Canonical revision files, SQLite metadata/literal FTS5 indexes, optional Vec1 retrieval, categories and saved views.
- CLI, TUI and stdio MCP over authenticated Unix sockets.
- Shared daemon: optional loopback HTTP browser/API surface and authenticated Streamable HTTP MCP in the same process.
- A macOS arm64 installer with boot-time system LaunchDaemons, empty/sample stores, separate canonical/index locations, a system connection registry and a shared client path with an owned `/usr/local/bin/tractanda-tui` symlink.
- Upgrade rollback and data-preserving uninstall. The preview reuses the existing `daemon` account and creates no users or groups.
- Current-permission history access, system-administrator policy, and semantic `item-text-utf8-v2` input over eligible owned text fields.
- A shared agent skill packaged for Claude Code, Codex and Agent Skills-compatible harnesses.

## Limits and pending deployment work

- HTTP binds loopback by default and is not an internet-facing gateway.
- A dedicated service account and full agent account/home provisioning are deferred. The preview uses `daemon`; another service with that same OS identity can access its files.
- macOS browser password login uses OpenDirectory. The Linux PAM broker passed real, synthetic-credential tests in a disposable Debian container; host installation remains an administrator action. No production password was used. See [PAM broker setup](pam-broker.md).
- Do not run a server as root solely for PAM.
- The bundled macOS semantic provider is Qwen3-Embedding-0.6B through vmlx-swift, with pinned model/runtime revisions and included model licenses. Granite Embedding 311M multilingual R2 remains a planned integration. The obsolete subject/body-only input mode has been removed; indexes are rebuildable.
- Linux remains in development. Earlier Debian source, real-account and synthetic-provider checks do not certify the current installer or a real CPU embedding runtime. No systemd guest boot is claimed.
- Real macOS lifecycle checks passed on isolated empty/sample stores: both launchd jobs ran as `daemon`, restart preserved records, a deliberately failed upgrade rolled back, and uninstall preserved canonical data. Boot registration is configured, but an actual machine reboot is not part of that test. Production data was not used for uninstall testing.
- Each release validates its sealed source through package/client tests and native IPC, permissions, Kanban, learning, MCP, shared-daemon and TUI integration checks. Consult the version-specific release evidence for that run.
- General synchronization, attachments, a native GUI and broader operational recovery remain incomplete. The macOS publication workflow verifies Developer ID signatures, package notarization, stapling and Gatekeeper acceptance before publishing each installer.

## Evaluation guidance

Use a dedicated store, back up canonical revisions, and validate actual OS identities, permissions, credential behavior and managed-service behavior in your own controlled environment. Configure UUIDv1 production issuers with a real host node; the CI synthetic node is disposable-fixture-only. Review dependencies and the selected PolyForm Noncommercial license before any distribution decision.
