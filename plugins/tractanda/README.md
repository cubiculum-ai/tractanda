# Tractanda agent skill

One shared skill teaches agents to discover a Tractanda store, combine category dimensions, retrieve context efficiently and make recoverable versioned edits. Claude and Codex manifests package the same `skills/tractanda` directory. Other Agent Skills-compatible harnesses can install that directory using their own skill installer.

The plugin contains guidance and examples, not executables, hooks, credentials or an automatically launched MCP connection. Install/connect Tractanda separately and select the intended database and OS identity. See [connection setup](skills/tractanda/references/connection.md).

Repository marketplace: `cubiculum-ai/tractanda`. Marketplace and plugin names are both `tractanda`.

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

For an unpublished local checkout, use its absolute directory instead of the GitHub source in the marketplace-add command. After installation, invoke the skill as offered by the harness (Codex: `$tractanda`; Claude plugin skill: `/tractanda:tractanda`) or ask it to work with the connected Tractanda base.

First-party skill content follows the enclosed PolyForm Noncommercial License 1.0.0 and notice. It is source-available, not an OSI open-source license.
