# Agent access

Agents use ordinary operating-system accounts and the same Tractanda tools, admission policy and item permissions as people. An MCP label, model name or tool configuration is not an identity boundary: a local agent acts as the OS account running its client. Provisioning accounts and groups is normal OS administration, outside Tractanda. An account may be used by a person or an agent according to the operator's needs.

## Sharing work

Humans and agents can work together through the CLI, TUI, MCP and other normal clients. An account must be admitted by the local store policy, and current item permissions govern what it can read or change, including access to history. Identity and OS group membership are resolved again for requests. New items are private to their authenticated creator unless permissions say otherwise.

Categories and saved views organize records; they do not grant access. Share the intended items and any category definitions needed for navigation through the normal permissions. An agent using the same OS account as a person has that account's authority, not a separate agent identity or independent scope.

Fresh stores use the personal/workgroup profile and admit the creating OS account. Its current access configuration is local operational state in `.tractanda-personal-profile.json`, not a canonical item. An administrator can change that policy with `configure-access` or `TractandaStore/configureAccess`; the policy is validated against current item permissions. Historical `AccessConfigurationItem` revisions do not reinstall local admission during rebuild.

## Client authentication

Local CLI, TUI and stdio MCP clients connect to the Unix socket using OS peer credentials. The native `TractandaAuth/createSession` method with empty arguments can issue a bearer token only for that peer's own account; HTTP cannot use it to choose a UID. HTTP sessions authenticate an OS account and are revalidated against current identity and access. Browser password login uses OpenDirectory on macOS and PAM on Linux.

On managed Linux installations, a separate privileged authentication helper performs PAM verification for the non-root daemon. Do not run the whole daemon as root to obtain PAM access. `/mcp` provides authenticated Streamable HTTP; stdio MCP remains available for locally launched clients. Hosted OAuth and independent agent-specific authorization scopes are not currently provided.

Separate OS accounts can be used where separate authority is desired. Verify the intended account's admission, current and historical item access, and revocation on the actual deployment; this guide does not claim a distinct agent account has been tested on your installation.

See [security scope](../SECURITY.md) and [build guidance](build.md).
