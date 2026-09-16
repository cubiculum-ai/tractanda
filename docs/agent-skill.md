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

The skill covers discovery, independent category axes, transient views, bounded retrieval, interpretation of search results, whole-field edit semantics and operation-ID retries. `tractanda_describe` comes from the connected native server; compiled adapter references apply only where the server declares the features they require. Existing project-specific skills can retain local conventions while referring to this shared workflow.

The connection example uses the configured default rather than assuming a profile named `default`. `tractanda_info` reports the running adapter's connection and build even when the native server call fails. Its native `features` and `connection.referenceCompatibility` distinguish declared support from absent/invalid declarations. Without declared support, missing fields indicate an unverified or older API rather than a proven server defect. After an upgrade, restart the adapter and refresh discovery: its compiled references do not change in a running process. The `tractanda.semantic-job-timing.v1` feature guarantees `createdAt`/`expiresAt` on result states and a pending polling hint. Retain that expiry; non-disclosing `notFound` errors omit timing.

Marketplace formats and commands follow the [Claude marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces) and [Codex plugin documentation](https://learn.chatgpt.com/docs/plugins). Available CLI/UI commands depend on the installed harness version.
