# Connect the skill to a store

Installing this skill supplies instructions only. It uses an existing Tractanda MCP connection or native client. The plugin deliberately contains no automatically launched MCP server: each user must select their installed executable, database profile and OS identity.

## Managed macOS installation

All installed databases share this stable executable:

```text
/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-mcp
```

A harness that accepts the common JSON MCP configuration shape can use:

```json
{
  "mcpServers": {
    "tractanda": {
      "command": "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-mcp",
      "args": ["--profile", "default", "--no-start", "--result-format", "text"]
    }
  }
}
```

Replace the `default` profile argument when the database has another name; the executable path stays the same. Keep the executable path as one string, including its spaces. Use the harness's documented configuration location and scope. Do not replace its other servers or copy credentials into this plugin.

For a Codex configuration that supports stdio MCP servers, the equivalent entry is:

```toml
[mcp_servers.tractanda]
command = "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-mcp"
args = ["--profile", "default", "--no-start", "--result-format", "text"]
```

`text` avoids duplicating result JSON in both text and structured content. A structured-capable harness can use `structured`; `both` is the compatibility default. Stdio is reserved for MCP messages, so do not wrap the adapter in a launcher that prints startup text there.

The system installer starts the server and bundled embedding host at boot through launchd. `--no-start` prevents a client from attempting an independent server launch. If the service is down, use the installed setup tool's `status` and the administrator's service-management workflow; repeatedly relaunching the MCP adapter will not repair it.

Local connections authenticate using Unix peer credentials. Running an agent under your account gives it your account's access; this skill is not a separate security identity. A separately provisioned OS account needs appropriate server admission and item permissions. Browser login uses an OS-account session. Remote HTTP MCP at `/mcp` requires authentication and a suitably protected transport; the preview binds loopback and is not an internet gateway.

## Source builds and native fallback

Use the actual built `tractanda-mcp` path and a configured profile, or `--socket PATH` with the expected server account. Profiles carry server identity; a different service owner without a profile requires the documented `TRACTANDA_SERVER_USER` setting. Never guess the UID from a model or adapter name.

Inspect profiles without opening a new store:

```sh
tractanda connections list
tractanda --profile default info
```

If only the native CLI is available, save JSON in a file and use:

```sh
tractanda --profile default request request.json
```

The native API uses `methodCalls`; for example:

```json
{"using":["https://tractanda.ai/ns/local-prototype/2"],"methodCalls":[["TractandaStore/describe",{"topic":"overview"},"overview"]]}
```

Read the repository's API guide for the native envelope and error handling. Avoid shell interpolation of item text; pass JSON through files or structured arguments. An executable's `--help` describes supported options. Linux packaging and a bundled Linux embedding runtime remain in development.

## Available served references

Start with `tractanda_describe`; it supplies the current catalog. The preview serves these MCP resources:

- `tractanda://reference/intro`
- `tractanda://reference/items`
- `tractanda://reference/query`
- `tractanda://reference/learning`
- `tractanda://reference/semantic`

Reference content comes from the connected server version. Use it to resolve differences between this skill and an upgraded server.
