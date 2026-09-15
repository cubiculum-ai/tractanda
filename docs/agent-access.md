# Agent access

An MCP label, model name or tool configuration is not an identity boundary. Native CLI/TUI/stdio MCP callers are identified by Unix peer credentials; HTTP callers receive an authenticated OS-account session. The service resolves identity and group membership on every request and applies current item permissions to current content and history.

## Sharing and administration

Category membership and saved views organize records; they do not grant access. Explicitly share the category definitions needed for navigation and the intended items. New items are private to their authenticated creator unless permissions say otherwise.

For a multi-user migration, create and review a canonical `AccessConfigurationItem` (`tractanda.access.v1`) and permission changes first. `administration: "system"` uses root plus the host administrator group (`admin` on macOS, `sudo` on Linux), or a configured `administratorGroup`; old stores retain `serviceOwner` administration until migrated. `legacyUsers` is a receipt-compatibility bridge, not a substitute for identity verification.

The existing offline planner can prepare guarded permission requests for an initially unconfigured store, but it neither creates accounts nor installs a shared service. Review every grant, include deleted heads in the inventory, preserve operation IDs, back up canonical data, and stop on conflicts. A plan or fake-identity test is not proof of production isolation.

## Shared daemon and browser use

The daemon's Unix endpoint still uses peer identity. Native `TractandaAuth/createSession` with empty arguments can issue only that peer's own bearer token; HTTP cannot choose a UID or mint one through that method. Browser login uses macOS OpenDirectory. Linux cross-user password verification needs a separately deployed privileged PAM helper; installation and real-account testing remain pending. Do not run the daemon as root merely to support PAM.

`/mcp` is authenticated Streamable HTTP JSON with bounded per-user sessions, not SSE/replay. Stdio MCP remains available for clients that launch it locally.

## Deployment checklist

1. Use a dedicated, non-root OS account for the agent and run the agent host itself under that account or equivalent isolation.
2. Verify the account can read/edit only intended current and historical records, cannot administer the store, and loses access after revocation.
3. Verify ordinary human access, service restart, and current OS group membership behavior.
4. Keep credentials, stores and agent homes outside the source checkout. Full managed agent accounts/homes are deferred; do not represent this guide as an installer.

See [security scope](../SECURITY.md) and [build guidance](build.md).
