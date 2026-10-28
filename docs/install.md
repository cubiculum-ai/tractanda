# macOS and Debian preview installation

The current checkout contains macOS and Debian installer sources; build and release availability depends on the selected artifact. Older public releases may not include the current installer behavior or layout. Raven, Stash, and Starlet now have live three-node membership on the layouts below. After exactly one managed Starlet restart, independent status checks showed all three nodes ready with the same membership digest; each observed two connected data-capable peers, and normal content/history checks passed before and after restart. Select the published release and its version-pinned instructions when installing.

See [system requirements](system-requirements.md) for the macOS version/architecture floor and provisional RAM and disk planning guidance.

## Install an empty or sample database

The native `.pkg` opens in macOS Installer and asks for administrator authentication. On a new installation it creates a standalone sample database for the logged-in console user by default. For a first cluster member, keep that sample store and configure its peer listener as described in [clustering](clustering.md). For a joining host, choose **Customize** and deselect **Initialize a sample store**; then use Setup's full-listener fresh-target procedure in [fresh target setup](personal-fresh-target-setup.md). The `cluster join --prepare-new` shortcut is outbound-only and is intended for a two-node connection, not a full listening mesh. On an existing installation the `.pkg` upgrades the system registry's default database, preserving its owner, data and port. The welcome and license pages explain the preview's scope. Use the archive installer below to choose an empty database, a different name or custom ports; the same native setup engine performs both forms of installation.

Unpack the bundle, open Terminal in its directory, and run:

```sh
sudo ./install.sh --name default --sample
```

The account invoking `sudo` becomes the initial admitted user and owns the sample items. When installing from an existing root shell, supply `--owner` with an existing OS username. Use `--empty` instead of `--sample` to initialize only the access policy, without optional categories, views or example items.

The preview reuses the existing `daemon` OS account and creates no users or groups. The server's storage identity is separate from the human ownership and permissions recorded in items. Root and members of the macOS `admin` group administer the server.

The installer registers system LaunchDaemons for the server and included local model workers. The core service starts after its identity, admission policy and HTTP endpoint checks pass; it does not wait for model downloads. Standard packages include pinned model metadata but omit bulky weights; configured workers retrieve missing files from their fixed model revisions and verify file sizes and SHA-256 values. This first-use step needs network access. For offline installation, provide complete verified model artifacts or use a full package built with `--include-model-weights` on the Mac packager or Linux producer and packager. Package assembly itself never downloads weights. See [model status, prefetch and offline import](embedding-runtime.md) for the `Models` paths and vector catch-up behavior.

The following is the **approved managed server layout**, used by current macOS and Debian packages. Keep one directory per store, including its separate rebuildable index.

| Purpose | macOS target | Debian target |
| --- | --- | --- |
| Canonical records | `/Library/Tractanda/Stores/<store>` | `/opt/tractanda/var/lib/tractanda/Stores/<store>`; `/var/lib/tractanda` is an alias to the private data root |
| Rebuildable index | `/Library/Tractanda/StoreIndices/<store>` | `/opt/tractanda/var/lib/tractanda/StoreIndices/<store>` |
| Per-store work and document state | `/Library/Tractanda/Work/<store>` | `/opt/tractanda/var/lib/tractanda/Work/<store>` |
| Durable installation receipts/state | `/Library/Tractanda/Installation` | `/opt/tractanda/var/lib/tractanda/Installation` |
| Verified model artifact cache | `/Library/Tractanda/Models` | `/opt/tractanda/var/lib/tractanda/Models` |
| Configuration | `/Library/Tractanda/Configuration` | `/opt/tractanda/etc/tractanda`; `/etc/tractanda` is an alias to this configuration directory |
| Versioned software and active pointer | `/Library/Tractanda/Software/releases/<build>` and `Software/current` | dpkg-owned `/opt/tractanda/current` |
| Logs | `/Library/Logs/Tractanda` | `/var/log/tractanda`; `/opt/tractanda/var/log/tractanda` is an alias |
| Runtime sockets, PIDs and locks | `/private/var/run/tractanda` | `/run/tractanda`; `/opt/tractanda/run/tractanda` is an alias |
| Temporary installer payloads | `/private/var/tmp/tractanda-install-<id>` | system temporary directory, scoped to the installer transaction |
| CLI entrypoints | `/usr/local/bin` links | `/usr/bin` wrappers |

The macOS service uses `/Library/LaunchDaemons`. No server data or cache is placed in Application Support or Caches. Debian keeps persistent content outside the dpkg-owned software tree; its existing protected `/run/tractanda-auth-<instance>` helper path remains distinct. Software, durable data and derived indexes remain separate across compatible upgrades. Back up the complete canonical store, including its durable identity and owned payloads. Rebuildable indexes can be regenerated.

For the first migration from the legacy layout to per-instance ephemeral runtime preparation, the old helper cannot truthfully roll back a failed new-layout startup. If candidate startup fails, keep that host stopped in its preparing state and retry only the exact candidate; the other verified node remains available. Once the new layout is installed, a later qualified rollback regenerates the matching root-preparer from the restored release receipt. Each instance selects its helper release from its own receipt, independently of `Software/current`; boot-time checks cover the bounded manifest and helper entry, not model payloads.

## Install a Debian package

Use the [signed preview APT repository](apt.md) for ordinary installation and updates. Direct `.deb` assets are also attached to each release; check the selected architecture against that release's `SHA256SUMS`. APT can install a downloaded local package and satisfy its dependencies from configured Debian repositories:

~~~sh
sudo apt install ./tractanda_0.1.0~poc.16-1_amd64.deb
~~~

On arm64, use `tractanda_0.1.0~poc.16-1_arm64.deb`. That package requires Debian 13 with systemd and the existing `daemon` account; Setup does not create users or groups. Dpkg owns its active files in `/opt/tractanda/current`. Installing a package does not enroll a node or establish synchronization. Follow [cluster architecture and operations](clustering.md) for peer setup.

After the package is installed, initialize a fresh standalone store and sample content by naming an existing human OS account:

~~~sh
sudo /opt/tractanda/current/bin/tractanda-setup install --name production --owner EXISTING_USERNAME --first-source --sample --peer-runtime-configuration peer-runtime.json
~~~

Replace `EXISTING_USERNAME` with that account's login name. `peer-runtime.json` is the nonsecret listener/synchronization settings file described in [clustering](clustering.md); create it before running Setup. Use `--empty` instead of `--sample` to omit sample content. `--first-source` initializes this store as a standalone first source; it does not enroll another node. Prepared-replica adoption uses a separate command and independently supplied store and replica UUIDv1 pins; follow the cluster setup procedure for that workflow.

Package build, installation, and live-cluster status are separate facts. The lifecycle procedure in [Linux package lifecycle validation](linux-package-validation.md) describes checks for a future release; it is not a user prerequisite for installing an already published package or evidence that a current-layout package is available.

The canonical store's `.tractanda-store-identity.json` is durable metadata and belongs in that backup. External indexes bind to its persistent UUIDv1; paths, device numbers and inodes are diagnostic only because they can change after moves, restores or reboots. Deleting a derived index must not delete the canonical identity. Early device/inode bindings upgrade only when their recorded identity still matches; a mismatched old index requires an explicit, data-preserving index rebuild.

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

Use the installed `tractanda-tui` entrypoint or the exact executable path reported by Setup. The verified macOS target uses `/usr/local/bin` links to `/Library/Tractanda/Software/current/bin`; the verified Debian target uses `/usr/bin` wrappers for the dpkg-owned `/opt/tractanda/current`. On an installation not yet migrated, use the executable path from that installed release. All databases share client binaries and identical release payloads; a database is selected through connection preferences or `--profile NAME`.

The local TUI authenticates through the kernel-supplied identity of its Unix socket connection. It does not ask for your password again.

For another database, choose another `--name` and `--port`. The embedding service uses the next port, so reserve both. Clients select a database with `--profile NAME`. User connection preferences take precedence over the installer-owned system registry.

## Manage, upgrade and uninstall

Use the installed setup executable with `status`, `start`, `stop` or `restart` and `--name`. Changes to system services require `sudo`:

```sh
sudo tractanda-setup restart --name default
```

The Setup `status` command reports the macOS LaunchDaemon state. Linux package/service status is platform-specific; use the release's Debian instructions and [cluster operations](clustering.md). In source builds with peer support, `tractanda peer status` reads the running daemon's nonsecret loaded peer-runtime and synchronization state; it does not start a service or check remote cluster convergence.

To upgrade, unpack the new bundle and run its installer:

```sh
sudo ./bin/tractanda-setup upgrade --bundle . --name default
```

Upgrade preserves the existing database, owner and connection settings. It verifies copied files, switches service definitions and the stable client link, and restores the previous registrations if startup fails. Prototype data formats may require an explicit migration or an index rebuild; backward compatibility is not promised before 1.0.

The current source build also accepts `--peer-runtime-configuration INPUT_JSON` or `--disable-peer-runtime` on `plan`, `install` and `upgrade` only. Supply at most one. Omitting both preserves the configuration recorded for that instance; a new instance with no configuration remains disabled. The replacement input is a bounded, regular JSON file containing nonsecret endpoint and synchronization settings. `plan` validates and reports the proposed replacement or disable action without applying it; install and upgrade publish the chosen settings as a protected, per-instance service configuration. Disabling removes only that runtime configuration and leaves canonical pairings and private credentials intact. During install or upgrade, Setup checks the daemon's loaded status against the managed receipt before completing; a failed transition follows its existing rollback or recovery path. Availability and loaded settings depend on the installed release and database instance. Runtime settings remain disabled for a new instance unless explicitly configured; installing a package does not establish live cluster synchronization.

Uninstall using:

```sh
sudo tractanda-setup uninstall --name default
```

This unloads the database's owned jobs and removes their definitions and connection entry. Releases still needed by another installed database remain; the shared client entry retargets an available release. Uninstalling the last database removes the owned TUI command symlink and unused releases. Canonical records, indexes and the recovery receipt remain. The `daemon` account is never removed or modified. Reinstall can reuse retained data; optional templates are not reapplied over your edits.

## Build a distribution

Use the [release command](release-workflow.md) for distribution: it signs code and the installer with the configured Developer ID certificates, submits the distribution to Apple through Xcode, waits for acceptance, staples the package ticket, verifies Gatekeeper acceptance and then calculates final checksums. Publication stops if any gate fails. Authentication uses the developer account already signed into Xcode; no separate notarytool profile or credentials in the checkout are needed. Earlier previews 0.1.0-poc.1 and 0.1.0-poc.2 were signed but not notarized.

The lower-level `scripts/package-macos.py` assembles a signed payload from a staged, audited Git checkout. Documentation, examples, templates and skill files come from that reviewed index; ignored research files and interpreter caches are excluded. Its default ad-hoc identity is for local development only and is rejected by the release workflow. The packager includes runtime libraries, removes development library search paths, hashes the payload and asks the bundled installer to validate it.

Wrap that bundle in a native Installer product with `python3 scripts/build-macos-pkg.py --bundle PATH --output Tractanda-VERSION-arm64.pkg --sign-identity 'Developer ID Installer: …'`. Replace `VERSION` with the staged bundle’s version. It has a standard payload and Bill of Materials at the final release path, so Installer's **Show Files** lists the installed software. Small scripts validate the destination and use `tractanda-setup` for service registration; generated database/runtime files are managed by that tool. The license is rendered as HTML. There is no separate persistent staging copy. It targets the running Apple Silicon system, requires macOS 15 or later, and includes welcome and completion pages.

The builder verifies a temporary payload copy's hashes and code signatures, writes data-only cpio archives, and removes metadata-only entries from the full Bill of Materials before signing the final product. This avoids serializing even macOS's protected provenance attributes. The input release and installed data are untouched; no AppleDouble `._` entries are shipped.

That lower-level builder produces the signed input to `scripts/notarize-macos.py`; its output alone is not the final distribution. A valid Developer ID signature without notarization can still be rejected by Gatekeeper. Use the release command to complete and verify all steps. Bare executable tickets cannot be stapled, so the archive requires an online notarization lookup; the native package carries its ticket for offline verification.

A new release uses a new directory. Reinstalling the same release pauses registered services using those files and resumes them after setup. If Apple's Installer fails before its completion script runs, rerun the installer or use `tractanda-setup start --name NAME`; canonical data is separate from the package payload.

## Bundled native document extraction

A configured macOS arm64 release includes `tractanda-document-converter` and the pinned artifact
metadata for `ibm-granite/granite-docling-258M-mlx` at revision
`a8b999991fe8c521a0cec749973414eaaf823731`. Standard packages omit its 14 weights/metadata
files (640,444,815 bytes total, about 610.8 MiB). On first configured use, the worker fetches
missing files from that fixed revision and checks the manifest's exact sizes and SHA-256 hashes.
The optional full/offline package can carry all 14 files and verifies them against the same
manifest. Build scripts never download model weights. Pinned SwiftPM source dependency
resolution remains part of the normal explicitly requested release build.

The data-only `documentExtraction` descriptor records converter identity, worker protocol,
model revision/manifest hash, the `osaurus-ai/vmlx-swift` runtime revision and the reviewed GELU
patch identity/hash. The shared `models/manifest.json` lists both models' fixed-revision files;
the ordinary bundle inventory hashes that manifest and any weights included in a full package.
Shared MLX resource bundle names must have identical contents and modes;
assembly rejects collisions. The converter uses the same dependency, signing, installer,
notarization and verification pipeline as the other executables. Model Apache 2.0 attribution,
runtime notices and Pillow licensing accompany the payload.

The installer owns the daemon's converter/model paths inside the immutable release. Each
instance receives a private `document-state/NAME/scratch`
directories under the installation configuration root, owned by `daemon` with mode 0700.
They are separate from canonical records, indexes and immutable software. These workspaces
and durable job metadata survive uninstall; existing unused-release deletion rules still apply.
Uninstall does not implicitly discard document jobs. Reinstall or changed release/model paths
can leave retained jobs paused because their saved configuration identity differs. Inspect job
status and make an explicit resume/rebase/discard or configuration-recovery decision; the
installer does not silently adopt old jobs into a changed runtime.

Upgrade uses the existing registration/receipt rollback transaction and preserves prior release
references and user data. Readiness checks configured identity, converter hash, prepared-input
requirement and worker protocol from native info. The verified release inventory and hashed
LaunchDaemon definition bind model and filesystem paths. Configured readiness does not prove
that weights have loaded or that inference succeeded; actual converted-content validation is a
separate gate. Document jobs stream originals and process bounded pages without a whole-document
page ceiling. The current 1024-token/page output budget, quotas and coverage failures remain
visible; arbitrary original size does not imply unlimited generated text. The poc.15 Debian
packages include the local document runtime and pinned model manifest. Standard packages download
weights only when needed; full/offline packages may include verified weights. Their
install/start/restart and live-sync acceptance remains a separate gate. Source edits do not install or activate a release;
a release/deployment still requires an explicit request.

## Canonical reader compatibility

New signed bundles declare canonical reader/writer formats and semantic compatibility levels; the running service reports the same declaration in `TractandaStore/info`. API feature or executable version names do not substitute for this declaration. Verified legacy bundles without it are treated as format-1 readers. The private `canonical-reader.json` requirement belongs to the logical StoreID, survives backup/restore, and advances durably before any format-2 record is published. It never moves backward or rewrites historical content. The source internal authority-intake mode raises reader level 3 and `tractanda.authority.v1` before authority persistence affects eligibility, while item MIME remains version 2. Such data always requires authority enforcement or a stopped, explicit failure; disabling the mode never permits linear fallback. Later unsupported review/control semantics fail closed. This source-only capability does not authorize installing or enabling intake.

Setup establishes missing compatibility proof from a bounded inventory while the writer is stopped and its root lock is held. Before rollback, reload or client repinning it checks the current requirement again. Shared clients must also cover what every registered writer can publish, so another store cannot raise its requirement just after the check. An uninstall target is excluded only after its writer has stopped and its registration is gone. Unknown proof or an incompatible old reader leaves the target stopped with a preparing receipt and recovery reason. Keep live data and verified backups intact and retry with a compatible bundle; never restore a backup over writes accepted during the failed attempt.

The activation wrapper independently prevents an old service restart when its declared support does not cover the store. Backup copies preserve the original requirement bytes; the live requirement may only gain formats, levels or capabilities while retaining the same StoreID. A failed restoration retains a durable stopped recovery receipt and removes only exactly owned definitions. This guard is implemented in source; it does not authorize installation, rollback or deployment outside an explicit release request.

Server and bundled embedding startup readiness have no total elapsed time limit. A live process may take more than two hours to become ready; the operator may cancel a stuck startup. Individual network and IPC probes remain bounded. Setup reports actual process state and changing errors, stops on a terminal process exit or cancellation, and does not invent progress while waiting. Readiness remains required before declaring an installation active.

Installer sample/template mutations use an explicit long-response local IPC path. It keeps reading the same response across idle socket waits without sending the request again. Ordinary status probes and default connections keep their bounded waits. Cancellation, EOF and malformed frames still fail, and an uncertain mutation must retain its operation ID for any later exact retry.
