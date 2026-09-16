# Build and test

## Prerequisites

- Swift **6.4** with SwiftPM and `swift format`.
- macOS 15+ or a compatible Debian-family Linux environment.
- SQLite headers with FTS5; on Linux, `libsqlite3-dev`, `libpam0g-dev`, `uuid-dev`, Python 3, and `acl` for optional real-account fixtures.

```sh
# Debian/Ubuntu, in an environment you administer
sudo apt-get update
sudo apt-get install libsqlite3-dev libpam0g-dev uuid-dev python3 acl
swift build
```

Dependencies are pinned in `Package.resolved`. The optional embedding host has its own package and lock file under `Packages/TractandaEmbeddings`; it requires separately obtained model files and its selected runtime. A successful core build does not prove model availability.

## Local daemon and managed service

Use the daemon when one process should host the Unix service, optional browser API and `/mcp` endpoint:

```sh
TRACTANDA_BIN="$(swift build --show-bin-path)"
"$TRACTANDA_BIN/tractanda" daemon STORE SOCKET --http-port 48728
```

`STORE SOCKET` are positional and must be separated by a space. HTTP defaults to port 48728 and binds only to loopback; use `--no-http` for native-only operation. Board rendering accepts either `--view ID` or `--project-root ID --status-root ID [--project ID]`.

`service prepare` makes reviewable private artifacts; `service install` then registers and starts them. Both accept the shared-daemon options:

```sh
"$TRACTANDA_BIN/tractanda" service prepare NAME STORE --shared --http-port 48728
"$TRACTANDA_BIN/tractanda" service install NAME STORE --shared --no-http
```

These development commands create a user-level launchd definition on macOS or user-level systemd unit on Linux, copy the executable and required bundled resources, and retain the compatible legacy native `serve` registration when `--shared` is omitted. The macOS preview installer is a separate path: it registers system LaunchDaemons for the server and embedding host under the existing `daemon` account. Linux systemd packaging, a dedicated service account and privileged PAM installation remain development work. The daemon does not need to run as root merely for password authentication.

## Verification

```sh
sh scripts/test.sh
```

This runs style checks, package/client tests, and independent native/MCP/HTTP/terminal checks using temporary stores and local build caches. Inspect test output as well as the command status.

Run normal tests as a named, non-root account. Permission fixtures distinguish service and administrator identities. A VM without a permanent hardware MAC must set `TRACTANDA_UUID_NODE`; a local container may use the real issuer host node. CI's synthetic `00:00:00:00:00:01` node is strictly for disposable fixtures—production must configure a real host node.

Real-account, managed-service, model and privileged-helper checks are separate, administrative test workflows. Their passing cannot be inferred from fake-credential or injected-identity tests. The first prerelease passed 303 package tests on each platform, with 13 additional standalone client tests, including text-v2 and the combined daemon. The macOS installation uses system LaunchDaemons for the server and bundled embedding host; native install, upgrade, reinstall and managed restart checks passed. A machine reboot was not part of that verification. Linux installer/runtime packaging and a real systemd boot remain in development.

## Packaging

Keep SwiftPM resource bundles beside a copied executable. The web client and TUI load bundled resources. Source builds are the current distribution path; signing, notarization, release packaging and publication are separate gates.

For a non-root Linux server authenticating other OS users, see [the restricted PAM broker](pam-broker.md). Its privileged helper is installed separately; the main daemon remains unprivileged.
