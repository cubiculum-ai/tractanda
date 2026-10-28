# Tractanda

**A shared knowledge base for people and AI agents.**

Tractanda keeps versioned items, overlapping categories and reusable views in one local store. The Swift service owns revisions, queries and authorization; the CLI, TUI, stdio MCP adapter, optional shared daemon and browser example all use that service.

The terminal client offers temporary Text/Semantic item search with `F` / `Ctrl-F` from Views or Categories, across all readable items without saving a view. See the [terminal search guide](docs/terminal-search.md).

The macOS preview targets Apple Silicon (M1 or later) and macOS 15 or later; 16 GiB unified memory is a provisional practical recommendation. Existing bundled-model packages contain their selected model assets; check the particular release notes. Packages built from the current source include the model workers and pinned catalog but omit large weights by default; configured workers fetch missing files from the exact pinned revisions without blocking core service startup. A full offline package can include verified weights. See [macOS installation and service management](docs/install.md), [system requirements](docs/system-requirements.md) and the [model runtime guide](docs/embedding-runtime.md) for current source behavior and storage guidance. Linux installation availability depends on the selected release.

Optional inline capture resolves authored `#categories` and category-configured dates in one reviewed edit, retaining plain text and stable references. See the [capture guide](docs/inline-capture.md). This source change awaits an explicitly requested release/deployment; the installed preview remains on its existing build.

## Proof-of-concept status

This is source-available evaluation software. Formats and APIs are experimental; use a dedicated store and keep backups. The core builds with Swift 6.4 on macOS 15+ and Debian-family Linux. The optional embedding host is separately built and model-dependent.

- Immutable canonical revisions and rebuildable SQLite metadata, literal FTS5 and optional Vec1 indexes.
- Current-permission access to current content and item history.
- Categories, saved/transient views, terminal and JSON clients, stdio MCP, and an example browser Kanban.
- A shared daemon with a Unix API and optional loopback HTTP, including authenticated Streamable HTTP MCP.

Current source includes personal/workgroup peer synchronization, attachment/document workflows and macOS/Debian installers; live three-node qualification is distinct from the remaining broader lifecycle and fault testing. A native GUI, personal-subset mobile replication, automatic client failover and full agent-account provisioning remain future work. The macOS installer has passed isolated launchd install/restart/rollback/uninstall tests; actual reboot validation remains open. The first two previews were signed without notarization. The current release workflow requires Apple acceptance, ticket stapling and Gatekeeper verification before publishing a new installer; each release records its actual results.

## Start locally

```sh
swift build
TRACTANDA_BIN="$(swift build --show-bin-path)"
"$TRACTANDA_BIN/tractanda" init "$HOME/Documents/Tractanda/demo"
"$TRACTANDA_BIN/tractanda" serve "$HOME/Documents/Tractanda/demo" /tmp/tractanda-demo.sock
```

The traditional Unix API, CLI, TUI and stdio MCP adapter continue to work with this form. To run the co-located daemon instead, `STORE` and `SOCKET` are positional arguments, separated by a space:

```sh
"$TRACTANDA_BIN/tractanda" daemon "$HOME/Documents/Tractanda/demo" /tmp/tractanda-demo.sock --http-port 48728
```

It binds HTTP only to loopback. `--no-http` keeps the native Unix listener only. Optional board presentation is `--view ID`, or `--project-root ID --status-root ID [--project ID]`; these alternatives cannot be combined. See the [build guide](docs/build.md) for managed user services and the [API guide](docs/api.md) for authentication and MCP.

## Documentation

- [User guide](docs/index.html)
- [Build and test](docs/build.md)
- [API and agent integration](docs/api.md)
- [Inline category and date capture](docs/inline-capture.md)
- [Install the Claude/Codex agent skill](docs/agent-skill.md)
- [Agent access](docs/agent-access.md)
- [Security scope](SECURITY.md)
- [Release notes](docs/release-notes.md)

The bundled web manual is the same guide as `docs/index.html`. Documentation is included locally and can also be published with the manual workflow.

## Data and identity

Canonical data belongs outside the source checkout. One writer owns a store; separate file-synchronized writers are not coordinated. UUIDv1 identifiers intentionally retain time and host-node provenance. A production issuer must use its real host node; the synthetic CI node is only for disposable fixtures.

Raw filesystem access is an administrative boundary. Through the service, every request resolves the caller and rechecks current item permissions; that governs historical reads too.

## License

First-party code and documentation are available under the [PolyForm Noncommercial License 1.0.0](LICENSE). This is source-available software, not an OSI open-source release. Third-party components retain their own terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
