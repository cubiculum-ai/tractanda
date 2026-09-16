# macOS preview installation

The downloadable preview targets Apple Silicon Macs. It contains the server, terminal client, MCP adapter, native installer and their required runtime libraries. A bundle with semantic retrieval also contains the pinned Qwen3 embedding model and the vmlx-swift host. Running the downloaded bundle does not require Xcode, Swift, Python or a model download.

Linux remains in development. Its source and local HTTP embedding-provider interface are retained; a supported Linux installer is a later step.

## Install an empty or sample database

The native `.pkg` opens in macOS Installer and asks for administrator authentication. On a new installation it creates a sample database for the logged-in console user. On an existing installation it upgrades the system registry's default database, preserving its owner, data and port. The welcome and license pages explain the preview's scope. Use the archive installer below to choose an empty database, a different name or custom ports; the same native setup engine performs both forms of installation.

Unpack the bundle, open Terminal in its directory, and run:

```sh
sudo ./install.sh --name default --sample
```

The account invoking `sudo` becomes the initial admitted user and owns the sample items. When installing from an existing root shell, supply `--owner` with an existing OS username. Use `--empty` instead of `--sample` to initialize only the access policy, without optional categories, views or example items.

The preview reuses the existing `daemon` OS account and creates no users or groups. The server's storage identity is separate from the human ownership and permissions recorded in items. Root and members of the macOS `admin` group administer the server.

The installer registers system LaunchDaemons for the server and, when included, its embedding host. They start at boot, before login, and restart after a failure. Startup checks include the native service identity, admission policy, HTTP endpoint and model readiness.

| Content | Default parent directory |
| --- | --- |
| Canonical records and durable settings | `/Users/Shared/Library/Tractanda/Stores` |
| Rebuildable SQLite, text and vector indexes | `/Users/Shared/Library/Application Support/Tractanda/Indexes` |
| Installed releases, connection registry and receipts | `/Users/Shared/Library/Application Support/Tractanda` |

Each database occupies its own named subdirectory. Back up the complete canonical store, including its durable settings. Indexes can be regenerated.

Use `--data-root` and `--index-root` to select different parent directories. Existing paths must have suitable ownership and permissions; the installer refuses to change unrelated shared folders or adopt an unrecognized database. It reports an unsafe parent before installing. A read-only plan is available with:

```sh
./bin/tractanda-setup plan --bundle . --name default --sample
```

## Connect

Open [the local web example](http://127.0.0.1:48728/) and sign in with your OS username and password. The web client is an example of an alternative client; the same server supports the terminal and agent interfaces.

Start the installed terminal client with `tractanda-tui`, or select another database explicitly. Omit `--profile` for the configured default; `default` is not a magic profile name:

```sh
tractanda-tui --profile NAME
```

The shared executable lives at `/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-tui`. The installer adds `/usr/local/bin/tractanda-tui` as a symlink when that path is available and protected. It leaves an unrelated existing command untouched. All databases share client binaries and identical release payloads; a database is selected through connection preferences or `--profile NAME`.

The local TUI authenticates through the kernel-supplied identity of its Unix socket connection. It does not ask for your password again.

For another database, choose another `--name` and `--port`. The embedding service uses the next port, so reserve both. Clients select a database with `--profile NAME`. User connection preferences take precedence over the installer-owned system registry.

## Manage, upgrade and uninstall

Use the installed setup executable with `status`, `start`, `stop` or `restart` and `--name`. Changes to system services require `sudo`:

```sh
sudo "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-setup" restart --name default
```

To upgrade, unpack the new bundle and run its installer:

```sh
sudo ./bin/tractanda-setup upgrade --bundle . --name default
```

Upgrade preserves the existing database, owner and connection settings. It verifies copied files, switches service definitions and the stable client link, and restores the previous registrations if startup fails. Prototype data formats may require an explicit migration or an index rebuild; backward compatibility is not promised before 1.0.

Uninstall using:

```sh
sudo "/Users/Shared/Library/Application Support/Tractanda/current/bin/tractanda-setup" uninstall --name default
```

This unloads the database's owned jobs and removes their definitions and connection entry. Releases still needed by another installed database remain; the shared client entry retargets an available release. Uninstalling the last database removes the owned TUI command symlink and unused releases. Canonical records, indexes and the recovery receipt remain. The `daemon` account is never removed or modified. Reinstall can reuse retained data; optional templates are not reapplied over your edits.

## Build a distribution

Use the [release command](release-workflow.md) for distribution: it signs code and the installer with the configured Developer ID certificates, submits the distribution to Apple through Xcode, waits for acceptance, staples the package ticket, verifies Gatekeeper acceptance and then calculates final checksums. Publication stops if any gate fails. Authentication uses the developer account already signed into Xcode; no separate notarytool profile or credentials in the checkout are needed. Earlier previews 0.1.0-poc.1 and 0.1.0-poc.2 were signed but not notarized.

The lower-level `scripts/package-macos.py` assembles a signed payload from a staged, audited Git checkout. Documentation, examples, templates and skill files come from that reviewed index; ignored research files and interpreter caches are excluded. Its default ad-hoc identity is for local development only and is rejected by the release workflow. The packager includes runtime libraries, removes development library search paths, hashes the payload and asks the bundled installer to validate it.

Wrap that bundle in a native Installer product with `python3 scripts/build-macos-pkg.py --bundle PATH --output Tractanda-0.1.0-poc.1-arm64.pkg --sign-identity 'Developer ID Installer: …'`. It has a standard payload and Bill of Materials at the final release path, so Installer's **Show Files** lists the installed software. Small scripts validate the destination and use `tractanda-setup` for service registration; generated database/runtime files are managed by that tool. The license is rendered as HTML. There is no separate persistent staging copy. It targets the running Apple Silicon system, requires macOS 15 or later, and includes welcome and completion pages.

The builder verifies a temporary payload copy's hashes and code signatures, writes data-only cpio archives, and removes metadata-only entries from the full Bill of Materials before signing the final product. This avoids serializing even macOS's protected provenance attributes. The input release and installed data are untouched; no AppleDouble `._` entries are shipped.

That lower-level builder produces the signed input to `scripts/notarize-macos.py`; its output alone is not the final distribution. A valid Developer ID signature without notarization can still be rejected by Gatekeeper. Use the release command to complete and verify all steps. Bare executable tickets cannot be stapled, so the archive requires an online notarization lookup; the native package carries its ticket for offline verification.

A new release uses a new directory. Reinstalling the same release pauses registered services using those files and resumes them after setup. If Apple's Installer fails before its completion script runs, rerun the installer or use `tractanda-setup start --name NAME`; canonical data is separate from the package payload.
