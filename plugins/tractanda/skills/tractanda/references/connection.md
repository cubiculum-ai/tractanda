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
      "args": ["--no-start", "--result-format", "text"]
    }
  }
}
```

Omitting `--profile` selects the configured default: the user's default takes precedence over the system registry's default. A literal profile named `default` exists only if that installation created one; it is not a magic alias. For an explicit database, add `"--profile", "NAME"` using a name from `connections list`. Profile names are local aliases, and several names may resolve to the same socket. Keep the executable path as one string, including its spaces. Use the harness's documented configuration location and scope. Do not replace its other servers or copy credentials into this plugin.

For a Codex configuration that supports stdio MCP servers, the equivalent entry is:

```toml
[mcp_servers.tractanda]
command = "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-mcp"
args = ["--no-start", "--result-format", "text"]
```

`text` avoids duplicating result JSON in both text and structured content. A structured-capable harness can use `structured`; `both` is the compatibility default. Stdio is reserved for MCP messages, so do not wrap the adapter in a launcher that prints startup text there.

The system installer starts the server and bundled embedding host at boot through launchd. `--no-start` prevents a client from attempting an independent server launch. If the service is down, use the installed setup tool's `status` and the administrator's service-management workflow; repeatedly relaunching the MCP adapter will not repair it.

Local connections authenticate using Unix peer credentials. Running an agent under your account gives it your account's access; this skill is not a separate security identity. A separately provisioned OS account needs appropriate server admission and item permissions. Browser login uses an OS-account session. Remote HTTP MCP at `/mcp` requires authentication and a suitably protected transport; the preview binds loopback and is not an internet gateway.

## Source builds and native fallback

Use the actual built `tractanda-mcp` path and a configured profile, or `--socket PATH` with the expected server account. Profiles carry server identity; a different service owner without a profile requires the documented `TRACTANDA_SERVER_USER` setting. Never guess the UID from a model or adapter name.

Inspect profiles without opening a new store:

```sh
"/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda" connections list
"/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda" --default info
```

If only the native CLI is available, save JSON in a file and use:

```sh
"/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda" --default request request.json
```

The native API uses `methodCalls`; for example:

```json
{"using":["https://tractanda.ai/ns/local-prototype/2"],"methodCalls":[["TractandaStore/describe",{"topic":"overview"},"overview"]]}
```

Read the repository's API guide for the native envelope and error handling. Avoid shell interpolation of item text; pass JSON through files or structured arguments. An executable's `--help` describes supported options. Linux packaging and a bundled Linux embedding runtime remain in development.

`tractanda_info` exposes the adapter's frozen `connection` binding, including the resolved profile/source and socket. A native-call error still includes that local block. Native `features` explicitly declares supported behavior; `tractanda.runtime-identity.v1` supplies server build/process identity and `tractanda.semantic-job-timing.v1` supplies semantic timing. `connection.referenceCompatibility` reports `satisfied`, `missingFeatures`, `unverified` (no valid declaration), or `unavailable` (native info failed), and lists `requiredServerFeatures`. Missing support must not be inferred from a digest or assumed from newer adapter references. Error replies never retain a cached native declaration. Restart the adapter after editing profiles or moving a socket. The HTTP adapter is in the server process, so it cannot provide diagnostics when that entire process is down.

References are static within an adapter process; this preview does not advertise subscriptions or list-change notifications. After an upgrade, restart/reinitialize and refresh tools/resources. Use the initialize version and `connection.referenceRevision` as cache identifiers, and refresh native info after a server restart or behavior mismatch. With `tractanda.semantic-job-timing.v1`, jobs last 120 seconds from creation and report `expiresAt`; polling never prolongs them. Restarting only a stdio adapter can resume the same principal's job within that lifetime. A non-disclosing `notFound` error omits timing: retain the earlier expiry rather than expecting the error to distinguish a stale job from an unknown ID.

## Available served references

Start with `tractanda_describe`; it supplies the current catalog. The preview serves these MCP resources:

- `tractanda://reference/intro`
- `tractanda://reference/items`
- `tractanda://reference/query`
- `tractanda://reference/learning`
- `tractanda://reference/semantic`

Reference content comes from the running MCP adapter build; `tractanda_describe` comes from the native server. Gate feature-dependent reference claims on the native feature declaration. An advertised feature that omits required fields is a contract violation; an absent/invalid declaration means unverified support, often an older server. Upgrade and restart both components together when the API changes.
