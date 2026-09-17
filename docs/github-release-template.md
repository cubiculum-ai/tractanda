# Tractanda {{VERSION}}

Tractanda is a shared knowledge base for people and AI agents: immutable file-backed items, overlapping categories, reusable or temporary views, and rebuildable search indexes. This is an experimental, source-available preview under the [PolyForm Noncommercial License 1.0.0]({{TAG_URL}}/LICENSE).

## This release

{{CHANGES}}

Use the downloads attached to **this release**. These notes consolidate the still-relevant setup and usage guidance from earlier previews; you do not need their release pages or installers.

## Download and install

**Apple Silicon Mac, macOS 15 or later:** download `Tractanda-{{VERSION}}-arm64.pkg` and open it in macOS Installer. A fresh installation creates a sample database for the logged-in user. An existing installation upgrades its system-default database, preserving its data and settings; read the compatibility guidance below before upgrading an early prototype store.

The package is Developer ID-signed, notarized, stapled and checked by Gatekeeper. `SHA256SUMS` contains the download checksums. The bundle includes the pinned Qwen3-Embedding-0.6B model, vmlx-swift host, required runtime libraries and third-party/model notices. No Xcode, Swift, Python or separate model download is needed to use it.

For a fresh evaluation installation with explicit choices, unpack `tractanda-{{VERSION}}-macos-arm64.tar.gz` and run from that directory:

```sh
sudo ./install.sh --name demo --sample
tractanda-tui --profile demo
```

Use `--empty` instead of `--sample` for an empty store. Names such as `demo`, `production` or `test` identify separate databases; they are not reserved names. Choose unused service/model ports when installing multiple databases. The archive's bare executables rely on Apple's online notarization lookup; the stapled `.pkg` is the recommended offline-verifiable installer.

See [installation, upgrades and uninstall]({{TAG_URL}}/docs/install.md) for detailed options and the read-only installation plan.

## Start using it

- **Web example:** open <http://127.0.0.1:48728/> on the server Mac and sign in with your macOS account. The current user manual is available at `/manual`; an [online guide](https://cubiculum-ai.github.io/tractanda/) is also available.
- **Terminal client:** run `tractanda-tui`, or `tractanda-tui --profile NAME` for a particular database. Local Unix-socket connections use the OS identity you already logged in with, so the TUI does not request your password again.
- **Profiles:** omit a profile to use the configured default. There is no magic profile named `default`. A profile selects a database, while the web Project selector selects a category within that database.
- **Stable commands:** clients share `/Users/Shared/Library/Application Support/Tractanda/current/bin`. The installer creates `/usr/local/bin/tractanda-tui` as an owned symlink when that path is available; another database does not require another copy of the executables.

An item can belong to several categories without being copied. Project, status, priority, urgency and assignment are category memberships. A Kanban board selects project-and-status membership; reference material without a status remains searchable without appearing on the board. Generic content uses `Item`, and any ordinary item can carry a category or saved-view definition. Templates and category names are optional data.

Views support custom columns, sections and category-based ordering. Full-text search covers eligible owned text; optional semantic retrieval supplements it. Extracted-text diagnostics distinguish canonical source, FTS inputs, semantic chunk parameters and index freshness. Current permissions apply to every client and the item's entire history.

## Connect an agent

Claude Code:

```text
/plugin marketplace add cubiculum-ai/tractanda
/plugin install tractanda@tractanda
```

Codex CLI with plugin support:

```sh
codex plugin marketplace add cubiculum-ai/tractanda
codex plugin add tractanda@tractanda
```

Other Agent Skills-compatible harnesses can install the skill directory with its supporting references. Installing the skill does **not** connect a server or grant permissions; configure MCP separately for the intended database and OS account. An agent running under your account has your account's access.

See [skill installation]({{TAG_URL}}/docs/agent-skill.md), [connection setup]({{TAG_URL}}/plugins/tractanda/skills/tractanda/references/connection.md) and [the API guide]({{TAG_URL}}/docs/api.md). After an upgrade, check the actual adapter/server versions and refresh the harness's tool catalog. Restarting an adapter alone may leave its old tool list cached. Use the server's current discovery and served references for API details.

## Data, startup and recovery

The installer registers boot-time system LaunchDaemons for the server and bundled embedding host, reusing the existing `daemon` account without creating users or groups. Installing an update repins and restarts the managed services, with rollback if startup fails. Dedicated service/agent accounts remain future work.

Default parent directories:

| Content | Location |
| --- | --- |
| Canonical records and durable settings | `/Users/Shared/Library/Tractanda/Stores/NAME` |
| Rebuildable metadata, text and vector indexes | `/Users/Shared/Library/Application Support/Tractanda/Indexes/NAME` |
| Software, connection registry and installation receipts | `/Users/Shared/Library/Application Support/Tractanda` |

Back up the **complete canonical store**, including durable settings and ownership/permissions. SQLite and semantic indexes are derivatives, not the only copy of your information. Use the supplied uninstall tool: it removes the owned service registrations/software while preserving canonical data and indexes, and retains software needed by other databases. Do not synchronize independently writable copies of a store as if that provided supported clustering.

## Compatibility and current limits

- **Pre-1.0 formats and APIs can change.** Start with a fresh sample/evaluation database when exploring this release. Before using an older store, keep a complete backup and verify its format against the current release. The installer preserves files; it is not a universal migration tool for early prototype formats. An index rebuild cannot by itself convert incompatible canonical records. Do not install an older binary against a newer store.
- The native experimental capability is `/4`; update and reconnect older clients. The obsolete action/note-specific classes and duplicate classification fields are not the current data model. Timestamp properties use date tags. Applications should discover the current type/property catalogue and feature declarations.
- HTTP is loopback-oriented, not an Internet-facing gateway. The preview's shared `daemon` identity does not isolate its files from another service running under that same account.
- Linux source work continues; a ready Linux installer and bundled CPU embedding runtime are not part of this preview. macOS MLX packaging does not establish Linux runtime readiness.
- Qwen3 remains the bundled model. Granite Embedding 311M multilingual R2 integration is planned; this release does not switch models. Search diagnostics do not perform an index migration or rebuild.
- Attachments, synchronization/offline replicas, a native SwiftUI GUI, scheduled automations and broader feed integrations remain planned. Category learning provides suggestions; automatic classification is not implemented.

The release workflow validates sealed source, code/package signatures, notarization and Gatekeeper acceptance, managed upgrade and canonical-file preservation, live executable identity, and GitHub source CI before publishing. Earlier disposable-store lifecycle checks cover restart, failed-startup rollback and data-preserving uninstall; they do not amount to a production-readiness guarantee or a Linux boot certification.

Source commit: `{{SOURCE_COMMIT}}`. See [the changelog]({{TAG_URL}}/CHANGELOG.md) and commit history for development details. Private stores, credentials, research materials and model weights are excluded from Git; the download carries its required dependency and model notices.
