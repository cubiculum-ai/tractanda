# Tractanda

**A shared knowledge base for people and AI agents.**

Tractanda keeps versioned items, overlapping categories and reusable views in one local store. The Swift service owns revisions, queries and authorization; the CLI, TUI, stdio MCP adapter, optional shared daemon and browser example all use that service.

For the executable preview, see [macOS installation and service management](docs/install.md). Linux packaging remains in development.

## Proof-of-concept status

This is source-available evaluation software. Formats and APIs are experimental; use a dedicated store and keep backups. The core builds with Swift 6.4 on macOS 15+ and Debian-family Linux. The optional embedding host is separately built and model-dependent.

- Immutable canonical revisions and rebuildable SQLite metadata, literal FTS5 and optional Vec1 indexes.
- Current-permission access to current content and item history.
- Categories, saved/transient views, terminal and JSON clients, stdio MCP, and an example browser Kanban.
- A shared daemon with a Unix API and optional loopback HTTP, including authenticated Streamable HTTP MCP.

Synchronization, attachment workflows, a native GUI, general internet deployment, full agent accounts/homes, and Linux installation remain incomplete. The macOS installer has passed isolated launchd install/restart/rollback/uninstall tests; actual reboot validation remains open. No notarized release binary is claimed.

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
