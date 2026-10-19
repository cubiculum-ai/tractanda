# Install the agent skill

The repository is also a plugin marketplace for Claude Code and Codex. Both packages use one [Tractanda skill](../plugins/tractanda/skills/tractanda/SKILL.md), so category semantics and editing guidance remain consistent.

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

Use the checkout's absolute directory instead of `cubiculum-ai/tractanda` when testing before publication. Compatible Agent Skills harnesses can install `plugins/tractanda/skills/tractanda` directly; keep its `references` directory with it. Invoke the installed skill by its harness name, such as `$tractanda` in Codex or `/tractanda:tractanda` in Claude Code.

Install the [macOS server bundle](install.md) separately, then follow the skill's [MCP connection guide](../plugins/tractanda/skills/tractanda/references/connection.md). Installing instructions alone does not create a database, connect an MCP server or confer permissions. The preview uses existing OS accounts; an adapter running as you has your access.

When authoring shorthand, discover `tractanda.inline-capture.v1` and the current capture tools, then read `tractanda://reference/items` for the exact contract. Retain the complete prepared plan for an uncertain retry; ordinary imports/commits do not interpret hashtags. Installed poc.14 does not provide this source-only feature until deployment. See the [capture guide](inline-capture.md).

The skill covers discovery, independent category axes, transient views, bounded retrieval, interpretation of search results, whole-field edit semantics and operation-ID retries. Query/get pages are live across requests: current permissions apply on each delivery, and `queryState`/`state` signal changes without pinning a result set. When the native server declares `tractanda.live-seek-cursor.v1`, eligible indexed queries can use opaque next/previous cursors; use the served query reference for supported shapes and exact API fields. A cursor is not permission and can become invalid after a relevant state change or server restart, so start a fresh query or use the exact position fallback. Other query shapes retain position paging. `tractanda_describe` comes from the connected native server; compiled adapter references apply only where the server declares the features they require.

Source-only Unit 2B2 client guidance preserves readable batch results while surfacing unresolved, incomplete and oversized outcomes. Its projection-state, conflicts and explicit-resolution tools are usable only when the connected server advertises `tractanda.revision-projection.v1`; they do not make the unchanged installed poc.14 support forks or offline intake. Ordinary writes retain revision-based guards, and the older `resolve` tool still traverses reference paths. Deferred review of stale offline authority requires an administrator decision and is not implemented in Unit 2B2. See the served API reference for details when the feature is actually available.

The shared skill is named `tractanda`. A local companion for a database whose profile is `production` can be named `tractanda-production`. Its connection selects `--profile production` or that configured default; the skill's name does not select or create a database. Use the actual profile reported by connection discovery and choose a companion name that does not collide with another skill. Local companions should keep local category IDs, naming conventions and workflows while referring to the shared skill. Avoid copying API behavior, class inventories or runtime paths into multiple skills. See the shared skill’s import guide for exact-payload journals and source-identity reconciliation.

The connection example selects the configured default profile. Read the shared [connection guide](../plugins/tractanda/skills/tractanda/references/connection.md) for feature compatibility, stale session detection and protocol-versus-service failures. Check info inside the active session after upgrades: a fresh harness health check may use a newer executable. An adapter restart and a harness tool-list refresh are separate: some harnesses enumerate tools only when the conversation/session starts. Reconnect or start a fresh session if a newly served tool is still unlisted; restarting only the process may not refresh that catalog. The served semantic reference describes job lifetimes and timing guarantees.

Marketplace formats and commands follow the [Claude marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces) and [Codex plugin documentation](https://learn.chatgpt.com/docs/plugins). Available CLI/UI commands depend on the installed harness version.
