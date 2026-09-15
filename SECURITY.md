# Security and deployment scope

Tractanda is experimental local/workgroup software, not a hardened internet service or tamper-proof store.

The native endpoint is a Unix socket authenticated from OS peer credentials. Every request resolves its current OS account and current group membership, then rechecks item permissions; the same current permissions govern history. CLI, TUI and stdio MCP retain this behavior.

The shared daemon can additionally bind loopback HTTP and `/mcp`. HTTP uses authenticated bearer sessions. `/mcp` is Streamable HTTP JSON with bounded global and per-user session/request state; it has no SSE stream or replay facility. A local native `TractandaAuth/createSession` call with empty arguments creates only that socket peer's own token. HTTP cannot choose a UID or mint a token through that method.

Browser password login uses macOS OpenDirectory. On Linux, a narrowly scoped privileged PAM helper component for another user's credentials is being finalized separately; host installation and real credential testing remain pending. Never run the whole server as root merely to obtain PAM access. Password success in fake-credential tests is not evidence of an OS-authenticated deployment.

An optional canonical `AccessConfigurationItem` (`tractanda.access.v1`) may set `administration: "system"`. System administration recognizes root and OS administrator membership—`admin` on macOS and `sudo` on Linux—unless `administratorGroup` explicitly selects another OS group. OS membership is refreshed per request. Existing stores without this configuration retain legacy `serviceOwner` administration until an explicit migration.

Do not expose loopback HTTP through a proxy or change its bind address without a separate security review. Keep stores, credentials and deployment configuration outside the source tree. Raw filesystem access, backups and exported copies remain administrative boundaries. UUIDv1 IDs expose time/host-node provenance.

Report vulnerabilities privately and do not include tokens, passwords, private records or live stores in reports. See [agent access](docs/agent-access.md) for the separate-account and permission review process.
