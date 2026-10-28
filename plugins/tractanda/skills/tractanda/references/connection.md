# Connect the skill to a store

Installing this skill supplies instructions only. It uses an existing Tractanda MCP connection or native client. The plugin deliberately contains no automatically launched MCP server: each user must select their installed executable, database profile and OS identity.

## Managed macOS and Debian installations

For the current managed layout, all databases on a host share the installed client executables. macOS keeps release binaries under `/Library/Tractanda/Software/current/bin`; Debian keeps them in the dpkg-owned real directory `/opt/tractanda/current/bin`. The installers expose public commands through `/usr/local/bin` on macOS and `/usr/bin` on Debian. Older public packages may use different layouts or lack current features; check the installed executable's `--help` and the connected server's advertised features.

These executable paths are for an adapter running on that host. The stdio CLI/TUI/MCP adapter connects to a local Unix-domain socket; connection profiles and `--socket` accept socket paths, not remote URLs. For remote access, use a separately configured endpoint as described below.

The MCP executable paths are:

```text
macOS: /Library/Tractanda/Software/current/bin/tractanda-mcp
Debian: /usr/bin/tractanda-mcp
```

A harness that accepts the common JSON MCP configuration shape can use:

```json
{
  "mcpServers": {
    "tractanda": {
      "command": "/Library/Tractanda/Software/current/bin/tractanda-mcp",
      "args": ["--no-start", "--result-format", "text"]
    }
  }
}
```

For Debian, use `/usr/bin/tractanda-mcp` as the command in the same configuration shape. Omit `--profile` to use the configured default: a matching user profile/default takes precedence over the system registry, then the configured system default is used. If neither selects a profile, the client uses its automatic per-OS-user socket. A literal profile named `default` exists only if configured; it is not a magic alias. For an explicit database, add `"--profile", "NAME"` using a name from `connections list`. Profile names are local aliases, and several names may resolve to the same socket. Keep the executable path as one string. Use the harness's documented configuration location and scope. Do not replace its other servers or copy credentials into this plugin.

For a Codex configuration that supports stdio MCP servers, the equivalent entry is:

```toml
[mcp_servers.tractanda]
command = "/Library/Tractanda/Software/current/bin/tractanda-mcp"
args = ["--no-start", "--result-format", "text"]
```

`text` avoids duplicating result JSON in both text and structured content. A structured-capable harness can use `structured`; `both` is the compatibility default. Stdio is reserved for MCP messages, so do not wrap the adapter in a launcher that prints startup text there.

The current macOS installer registers system LaunchDaemons; the Debian package uses systemd. `--no-start` prevents a client from attempting an independent server launch. On macOS, inspect the instance with `tractanda-setup status --name NAME`. On Debian, prefer `systemctl status tractanda-server-NAME.service` for an unprivileged service check; Setup's `status` additionally checks protected installation receipts and requires authorized administrator execution. The macOS server label is `ai.tractanda.server.NAME`. Use native `info` to check application readiness on either platform; service-manager status alone does not establish readiness or cluster convergence. Restarting the MCP adapter does not repair a stopped server. Current-layout runtime settings and log locations are documented in the installation guide linked below.

Local CLI/TUI/MCP-to-daemon connections authenticate using kernel-supplied Unix peer credentials. Running an agent under your account gives it that OS account's access; the skill is not a separate identity. A separately provisioned OS account needs local admission and item permissions. Remote HTTP MCP at `/mcp` is a separate configured and authenticated endpoint; it is not a Unix-socket profile or the public HTTPS/JMAP API. The HTTPS/JMAP API is another network interface with its own authenticated session contract. Peer synchronization has its own shared administrator-coordinated membership and private TLS 1.3 forward-secret hybrid PSK binding; endpoints and secrets are host-local. Peer authentication is not an ordinary client login and does not require public-CA certificates. Never copy peer secrets or current membership configuration between hosts with file synchronization.

The user connection file is `~/Library/Application Support/Tractanda/connections.json` on macOS and `${XDG_CONFIG_HOME:-~/.config}/tractanda/connections.json` on Linux. The installer-owned system registry is `/Library/Tractanda/Configuration/connections.json` on macOS and `/etc/tractanda/connections.json` on Linux. User profiles override same-named system profiles; a user's configured default takes precedence over the system default. Setting `TRACTANDA_CONFIG` selects an explicit user configuration file and disables implicit system-registry fallback. Use `tractanda connections list` to inspect configured profiles and `tractanda --default --no-start info` to check the selected endpoint. Listing a profile does not prove the server is live. Do not assume a profile named `default` exists.

## Cluster operations and runtime notes

The native operator commands are `tractanda --default --no-start cluster status`, `cluster invite`, `cluster join`, `cluster join-status` and `cluster resume`; discover exact syntax with `tractanda --help` or the selected executable's `--help`. Invitations and pairing codes are secret: use the private prompt/file flow, never command arguments or ordinary logs. For coordination, pairing and convergence rules, see the [personal/workgroup clustering guide](https://github.com/cubiculum-ai/tractanda/blob/main/docs/clustering.md).

The bundled embedding host uses Apple's MLX/Metal path on Apple Silicon macOS and a CPU backend on Linux. The API contract is shared, but inference speed and readiness can differ by platform. A slow or unready embedding service does not mean item text is absent; use ordinary metadata/category/text retrieval and check semantic readiness separately. See the [embedding runtime guide](https://github.com/cubiculum-ai/tractanda/blob/main/docs/embedding-runtime.md), [installation guide](https://github.com/cubiculum-ai/tractanda/blob/main/docs/install.md) and [API guide](https://github.com/cubiculum-ai/tractanda/blob/main/docs/api.md).

## Source builds and native fallback

Use the installed platform entrypoint or the actual built `tractanda-mcp` path and a configured profile, or `--socket PATH` with the expected server account. Profiles carry server identity; `TRACTANDA_SERVER_USER` can pin a different local daemon account when needed. This variable does not authenticate a network client. Do not infer local UID/GID equality across cluster members; OS account names are shared at the product level, while numeric IDs and administrator groups are host-local mappings.

Profile names identify stores, not project categories. For example, a main store may use `production`, with separate `test` or purpose-specific profiles. Use the configured names rather than inventing aliases for each project.

Skill names are separate from connection profiles. A local companion named `tractanda-production` can document a connection using `--profile production`; naming a skill does not select or create that profile. Confirm the connection's actual profile rather than inferring it from the skill title.

Native CLI command names are separate from MCP tool names. Use `tractanda describe SOCKET [TOPIC]` for native discovery and `tractanda extracted-text SOCKET ITEM_ID...` for extraction and source maps when those wrappers are present in the selected executable. Check that executable's `--help`; older builds may not provide every wrapper. For an operation without a CLI wrapper, use only the request method and capability contract advertised by that server and the current API guide. Command spelling does not define argument or result schemas; consult current served references and advertised capabilities.

Inspect profiles without opening a new store:

```sh
tractanda connections list
tractanda --default --no-start info
```

If only the native CLI is available, save JSON in a file and use:

```sh
tractanda --default --no-start request request.json
```

The native CLI's `request` and `call` forms use the capabilities and method schemas declared by the selected server. Do not copy a stale namespace or envelope from an old example; discover with `tractanda --default --no-start describe overview` and use the served API reference. Avoid shell interpolation of item text; pass JSON through files or structured arguments. An executable's `--help` describes supported options.

`tractanda_info` exposes the adapter's frozen `connection` binding, including the resolved profile/source and socket. A native-call error still includes that local block. Native `features` explicitly declares supported behavior; `tractanda.runtime-identity.v1` supplies server build/process identity and `tractanda.semantic-job-timing.v1` supplies semantic timing. `connection.referenceCompatibility` reports `satisfied`, `missingFeatures`, `unverified` (no valid declaration), `unavailable` (native info could not be obtained), or `protocolMismatch` (the reachable server rejected this adapter's native capability), and lists `requiredServerFeatures`. Missing support must not be inferred from a digest or assumed from newer adapter references. Error replies never retain a cached native declaration. Restart the adapter after editing profiles or moving a socket. The HTTP adapter is in the server process, so it cannot provide diagnostics when that entire process is down.

On macOS, Setup repoints the stable `Software/current` symlink during an upgrade. On Debian, dpkg replaces package files under the stable real `/opt/tractanda/current` directory. In either case an already-running adapter process may continue with its old executable, so reconnect the harness to start a fresh process and refresh tool discovery. A harness health check may succeed through a fresh process while the current session still uses an old one. Inspect `tractanda_info` within the active session. With `tractanda.runtime-identity.v1`, compare `connection.adapter.version` and `server.version` by release components (not lexical string order). An older adapter needs reconnection and fresh discovery before relying on its compiled references or making writes, even if feature compatibility is satisfied. A newer adapter must still gate feature-dependent behavior on the server declaration. Unversioned/development builds or differing digests alone do not establish which build is older.

`protocolMismatch` and native `unsupportedCapability` mean a server answered but refused the requested API capability; update/reconnect the adapter or server to matching versions. They do not establish which side is older. A stopped/unreachable server needs service diagnosis. Neither outcome justifies changing item permissions or repeatedly retrying writes.

References are static within an adapter process; the current adapter does not advertise subscriptions or list-change notifications. After an upgrade, distinguish restarting the adapter from refreshing the harness's cached tool list. Some harnesses enumerate tools once per session. Reconnect the MCP connection and refresh discovery; if the harness cannot refresh within a conversation, use a fresh session. Do not infer server support merely from whether a tool is listed, or attempt to invoke an unlisted tool. Use the initialize version and `connection.referenceRevision` as cache identifiers, and refresh native info after a server restart or behavior mismatch. With `tractanda.semantic-job-timing.v1`, jobs last 120 seconds from creation and report `expiresAt`; polling never prolongs them. Restarting only a stdio adapter can resume the same principal's job within that lifetime. A non-disclosing `notFound` error omits timing: retain the earlier expiry rather than expecting the error to distinguish a stale job from an unknown ID.

## Available served references

Start with `tractanda_describe`; it supplies the current catalog. The preview serves these MCP resources:

- `tractanda://reference/intro`
- `tractanda://reference/items`
- `tractanda://reference/query`
- `tractanda://reference/learning`
- `tractanda://reference/semantic`

Reference content comes from the running MCP adapter build; `tractanda_describe` comes from the native server. Gate feature-dependent reference claims on the native feature declaration. An advertised feature that omits required fields is a contract violation; an absent/invalid declaration means unverified support, often an older server. Upgrade and restart both components together when the API changes.

Model artifact cache, service-account prefetch/import commands and vector catch-up are operator
tasks documented in the workspace's [local model runtime guide](../../../../../docs/embedding-runtime.md).
`tractanda models status` and `TractandaModel/status` availability depends on the installed
server version; older published packages do not include this source update, and model status is
not a standalone MCP tool in the current source.


Servers declaring `tractanda.attachment-transfer.v2` retain unfinished originals through restart and use sliding idle upload retention. Native original finish/content can return retryable `attachmentVerifying` with phase, verified/total bytes and a 100 ms retry hint. Repeat the exact request, or inspect native `TractandaAttachment/uploadStatus` (uploadID) / `TractandaAttachment/integrity` (itemID, attachmentID, optional revisionID); every request resolves current permissions. Native/portable client wrappers perform cancellable retries without a total-original deadline. Finish/content/abort require singleton daemon envelopes (`attachmentSingletonRequired`). The current MCP tool catalogue remains read-only for originals; these native status methods are not MCP tools. Daemon copies prepare independent current content off-queue, returning retryable `attachmentCopyPending` for exact guarded retries; source ACL/CAS and committed replay remain authoritative. New stored document trees declare `tractanda.attachment-document-content.v2`; native document/documentContent provide bounded page/proof access. Page search and self-contained export remain pending; do not claim completion of large-document extraction from transfer support alone.

Daemon feature `tractanda.store-rebuild.v2` provides admin-only singleton rebuild admission/status/cancel. `TractandaStore/rebuild` requires a stable `operationID`; it returns immediately with a UUIDv1 `jobID`. Inspect the latest job with `TractandaStore/rebuildStatus` and cancel a specific job with `TractandaStore/rebuildCancel`. Ordinary requests receive `serviceBusy` during exclusive reader/producer drain and rebuild. Status authorization resolves current OS administrator membership even while the Store queue is occupied. A failed/cancelled dirty rebuild requires canonical restreaming recovery; saved v2 page content is validated without OCR. The latest bounded progress journal is operational state, not a resumable SQL cursor. See `docs/api.md` for no-progress settings and CLI commands. Legacy `serve` cannot perform this asynchronous operation; use the daemon.

Original upload status may include `staging` usage separating actual original/checkpoint bytes from reserved bookkeeping. Physical original publication does not release pending recovery quota before item CAS/replay or durable disposal. Each admitted upload reserves a bounded 16 KiB checkpoint replacement window. Reduced quotas still allow retained-work reopening and bounded cleanup; new data/admission must fit the operator budget and configured filesystem reserve.
