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

The skill covers discovery, independent category axes, transient views, bounded retrieval, interpretation of search results, whole-field edit semantics and operation-ID retries. The connected server's `tractanda_describe` and served references remain authoritative for its current API. Existing project-specific skills can retain local conventions while referring to this shared workflow.

Marketplace formats and commands follow the [Claude marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces) and [Codex plugin documentation](https://learn.chatgpt.com/docs/plugins). Available CLI/UI commands depend on the installed harness version.
