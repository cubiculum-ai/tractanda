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

The skill covers discovery, independent category axes, transient views, bounded retrieval, interpretation of search results, whole-field edit semantics and operation-ID retries. `tractanda_describe` comes from the connected native server; compiled adapter references apply only where the server declares the features they require. Project-specific skills should have a distinct name, such as `tractanda-<store>`, and keep local category IDs, naming conventions and workflows while referring to the shared skill. Avoid copying API behavior, class inventories or runtime paths into multiple skills. See the shared skill’s import guide for exact-payload journals and source-identity reconciliation.

The connection example selects the configured default profile. Read the shared [connection guide](../plugins/tractanda/skills/tractanda/references/connection.md) for feature compatibility, stale session detection and protocol-versus-service failures. Check info inside the active session after upgrades: a fresh harness health check may use a newer executable. Reconnect and refresh discovery when needed. The served semantic reference describes job lifetimes and timing guarantees.

Marketplace formats and commands follow the [Claude marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces) and [Codex plugin documentation](https://learn.chatgpt.com/docs/plugins). Available CLI/UI commands depend on the installed harness version.
