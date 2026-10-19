# Linux Debian packaging and apt distribution plan

Status: assembler source implemented; complete Linux delivery remains gated. On 18 October 2026 the user requested proper amd64 and arm64 .deb packages before installing the first cluster. D1/D2 source passed a clean focused Mac73/48 and native x86_64 Linux55/30, using mocked privilege/package/systemd operations and real tiny canonical adoption/disposal fixtures. No complete architecture package or privileged package lifecycle is claimed. Existing release/publication and live-deployment gates remain.

## Hosting answer and recommendation

An apt repository is a generated tree of package files, indexes and signed release metadata served over HTTP(S). It does not require a specialized running package-server application. GitHub Pages can serve such a tree; GitHub Packages currently has no Debian/apt registry. GitHub Releases can store downloadable .deb assets, but merely uploading them does not provide the apt indexes/signatures/update workflow.

Proposed stable public address: https://apt.tractanda.ai/ (not configured). A custom hostname lets the backing static host change later without changing client source definitions. First measure the complete retained package set: GitHub Pages limits a published site to 1 GB and has a 100 GB/month soft bandwidth limit. Core packages might fit; model weights and retained versions can exceed that budget. Keep apt generation independent of hosting, and use a static object store/CDN or existing HTTPS host for the complete repository if needed. A dedicated server is not required. Do not assume arbitrary external release URLs in package Filename entries are a working substitute for a tested archive layout.

Illustrative layout, not a live repository:

```text
dists/preview/InRelease
dists/preview/Release
dists/preview/Release.gpg
dists/preview/main/binary-amd64/Packages.xz
dists/preview/main/binary-arm64/Packages.xz
pool/main/t/tractanda/tractanda_<debian-version>_amd64.deb
pool/main/t/tractanda/tractanda_<debian-version>_arm64.deb
```

Generate metadata with standard Debian tools and retain package/checksum consistency during publication. Use a dedicated archive signing key and a deb822 .sources entry scoped with Signed-By; never disable apt authentication. Public fingerprint/key distribution and protected signing-key custody are publication setup tasks. No key generation or repository publication is authorized by this document alone. GitHub Actions can build both native architectures; official runner labels include ubuntu-24.04 and ubuntu-24.04-arm. Repository generation should work with the same files on Pages, object storage or another static host.

## User decisions confirmed 18 October

Dpkg owns the active Linux binaries. Rollback uses an older .deb, subject to actual canonical-reader compatibility; do not implement a separate Setup-managed active/rollback payload tree. Configured-service package upgrades should follow normal Debian lifecycle, with safe pre-replacement stop/drain, verified restart and truthful failure state. Major version changes signal incompatibility without replacing format or cluster-maintenance checks.

The finished Linux installation set must include the same capabilities and bundled/external dependency boundary as the macOS .pkg, including embeddings and document extraction. Do not finish with core-only/embedding-only packages or substitute an externally operated inference service for a bundled runtime. Existing daemon custody is retained for the POC; no automatic new-account provisioning. Apt hosting remains undecided until measured sizes. These choices supersede earlier alternatives in the inventory/D0 proposal.

## Required implementation order

1. **Linux Setup/systemd integration.** Reuse canonical-format checks, protected configuration, receipts, actual loaded-status verification and recoverable upgrade semantics. Implement the currently rejected Linux system installer and lifecycle backend; preserve current admission/ACL/identity rules. Package installation must distinguish unconfigured, first-source and prepared joining replicas, and must not silently bootstrap an unrelated store on a joining host.
2. **Debian package layout and runtime closure.** Produce native amd64 and arm64 artifacts from the same reviewed source, Swift 6.4 baseline and dependency locks. Use Debian 13 build environments as the proposed baseline and separately validate current Kali Rolling. Determine dependencies from each shipped ELF closure; bundled Swift/private libraries must be intentional, audited and included in licenses/manifests. Do not ship binaries linked accidentally against Stash-only development paths or infer runtime Depends from -dev build packages.
3. **Lifecycle and architecture verification.** Test package contents/architecture with dpkg-deb and lint checks, then actual installation, configured service boot/start/readiness, compatible upgrade, interrupted upgrade/retry, rollback refusal, remove/reinstall and data preservation in disposable systemd environments on each native architecture. Verify systemd system units, not merely existing user-manager fixtures. No production-store test target.
4. **Signed apt repository generation.** Generate both architecture indexes from actual packages, sign release metadata, verify with an isolated apt client using the scoped key, and test normal updates plus tamper rejection. Add a native architecture CI matrix. Keep publication explicit/batched, separate from build/test jobs and untrusted PR code.
5. **Prepared-target adoption and live cluster installation.** Complete the remaining prepared-replica setup contract with real package paths; only after packaging/lifecycle checks use a separately authorized installation/enrollment on Stash. Raven production conversion, server installation and joining remain explicit live steps.

## Packaging contracts to settle during implementation

- Linux SetupRoots use /opt/tractanda for payloads, /etc/tractanda for configuration, /var/lib/tractanda/stores for canonical data and /var/cache/tractanda/indexes for derived indexes. Dpkg owns the real /opt/tractanda/current tree and fixed /usr/bin entrypoints; Setup owns mutable receipts and instance registrations. Runtime sockets use /run with boot recreation. Keep fixed trusted helper resolution and canonical/index separation.
- The Linux stub's tractanda service-account name is superseded: use the existing daemon account with explicit custody checks and no account provisioning.
- Package core binaries, CPU inference runtime and model data with full macOS package parity; any split into multiple .debs must preserve the complete installation set and verified bundle composition. Models are architecture-independent only if the exact files/format are genuinely shared. Do not silently drop Linux embeddings/document extraction or claim the existing macOS bundle restrictions are lifted.
- Ordinary verified compatible upgrades may roll. Breaking format/authorization/merge upgrades require coordinated maintenance across all active nodes before writes resume. apt/unattended-upgrades cannot be treated as cluster approval; package lifecycle must enforce or explicitly block activation accordingly, with truthful status. dpkg downgrade is not proof of canonical-data compatibility.
- Map POC versions into Debian prerelease ordering (for example, 0.1.0~poc.15-1) and test transitions with dpkg version comparison; do not silently let a preview sort newer than its intended stable release.
- Removal must preserve canonical stores, identities, private keys and history. Purge semantics must not become an implicit database erasure. Fresh install, unconfigured join and existing-service upgrade require separate tests. Use idempotent noninteractive maintainer hooks and respect service-start policy in disposable install environments.

## Current inventory and limits

See [Linux packaging inventory](../outputs/verification/cluster-2026-10-18/LINUX-DEB-PACKAGING-INVENTORY.md) for historical file pointers and [D2 result](../work/linux-deb-20261018/D2-LINUX55-RESULT.md) for current bounded source coverage. The systemd backend, package transaction and explicit prepared-target adoption are implemented in source. Production full-payload admission stays closed while Linux runtime/Docling identity and feature parity are unfinished. Stash source validation remains x86_64-specific and CI has no accepted ARM64 package job. Passing source mocks do not establish privileged installation, either complete package or ARM64 inference.

## D3 complete bundle and Debian assembler

`scripts/package-linux.py` consumes a **complete producer-prepared payload directory** and a `tractanda.linux-bundle-input.v1` JSON specification. It does not compile, download, choose models or supply a core-only mode. `scripts/build-linux-deb.py` consumes the admitted bundle and creates one complete architecture-specific package. The tracked native payload producer, `scripts/produce-linux-payload.py`, is implemented and has passed its independent source review and synthetic checks. Actual native component builds and full payload/package validation remain required; finished delivery must not depend on reconstructing an untracked `work/` directory or inventing descriptors by hand. The finite production component registry remains unadmitted until native behavior and closure validation succeed. The first amd64 Swift6.4.1 converter compile and bounded synthetic-image CPU inference have passed: 106 tokens completed normally in 369 seconds, with all seven frozen facts and the actual private/OS loaded providers verified. This is an observed latency for one fixture, not a throughput claim. Final install-path PDF/worker tests, Linux CPU phase-budget integration, the matching embedding helper, both complete packages and their lifecycle gates remain unfinished.

Both commands require a native Debian13 builder of the requested architecture. AMD64 maps to ELF machine62 / bundle x86_64 / x86-64 baseline; ARM64 maps to machine183 / bundle arm64 / armv8-a. Actual ELF headers, interpreter, GNU ISA notes, symbol-version requirements and recursive private/OS dependency edges are inspected. Private library resolution must follow the actual confined `$ORIGIN` paths; unknown, conflicting, escaping or shadowed dependencies fail. OS providers are resolved through the builder's Debian package database; runtime Depends conservatively requires at least those installed provider versions, rather than inferring dependencies from development-header package names. `curl`, `lsof` and `sudo` are explicit operational dependencies; Python3 and systemd are pre-dependencies for the reviewed pre-unpack control scripts. Debian13's glibc baseline is2.41. These checks are necessary static evidence; actual minimum-CPU and feature execution is still required. [Debian release notes](https://www.debian.org/releases/trixie/release-notes/whats-new.html), [GNU readelf](https://sourceware.org/binutils/docs/binutils/readelf.html).

The machine-readable producer input has exactly these fields:

| Field | Producer contract |
| --- | --- |
| `profile` | Literal `tractanda.linux-bundle-input.v1` |
| `version`, `arch` | Actual artifact version; `amd64` or `arm64`. Packaging never edits VERSION. |
| `minimumCPU` | `x86-64` or `armv8-a`, matching the architecture. |
| `sourceInputsSHA256` | SHA256 of the producer's complete frozen source/resource/build-input inventory; not an inferred Git HEAD for a dirty build. |
| `buildFlags` | Actual normalized global compiler arguments, including C/Swift forwarding and CPU selection. Host/native or stronger ISA flags, opaque response files and unreviewed backend forwarding are refused. |
| `semanticProfile` | Current reviewed software profile `tractanda.peer-exchange.v2`; no claim of cluster maintenance approval. |
| `documentExtraction` | Exact generated descriptor from the accepted converter/runtime identity table. No prefix or arbitrary closure hash grants admission. |
| `dynamicLoads` | Unique relative paths of every additional private ELF root opened dynamically; static DT_NEEDED scanning alone cannot discover all such loads. |
| `runtimeNotices` | Explicit relative `licenses/` paths for all bundled private runtime components. |

The producer must stage all seven binaries (`tractanda`, `tractanda-tui`, `tractanda-mcp`, `tractanda-setup`, `tractanda-auth-helper`, `tractanda-embeddings`, `tractanda-document-converter`), web resources, the complete reviewed public asset set, all private libraries and resource bundles, selected Granite/Docling models and notices. The public asset selection, Git-index modes and LICENSES-to-licenses projection match macOS packaging; prepare it from an audited clean public asset index. Granite uses the existing real helper's pinned asset/profile declaration; Docling reuses the existing exact fourteen-file model validator and pinned model/patch manifests. R2's approved Linux closure/identity is still a prerequisite, not a fabricated producer field. There is no new converter `--describe` API.

The assembler writes the existing closed BundleManifest shape and hash inventory, plus `lib/tractanda/linux-bundle-build.json` containing input, baseline and dependency evidence. It always invokes the actual shipped Setup's `plan --bundle` validator. Consequently the current unapproved Linux document/runtime path fails closed; a descriptor assertion or a synthetic test cannot turn it into a supported package. Models, binaries, licenses and resources remain in the same closed manifest; links or writable/special payload entries are rejected. Copies are bounded and checked against the captured bytes, with a genuine10GiB reserve and explicit staging budget. Deliberately dispatched per-file optimized kernels require separate producer/ISA proof; they are not permission for stronger global compilation flags.

The `.deb` builder stages fixed dpkg-owned `/opt/tractanda/current` and four `/usr/bin` wrappers. It installs no preconfigured instance, service account or canonical store. Per-instance systemd registrations remain generated mutable state under D2's ownership/recovery contract. The builder embeds the reviewed fallback source and exact one-line canonical compatibility declaration into the four control scripts and rejects unresolved tokens. `--upgrade-class` is mandatory and does not bypass actual canonical/semantic/coordination checks. POC version `0.1.0-poc.14` becomes Debian `0.1.0~poc.14-1`; packaging revision is explicit and VERSION remains unchanged.

The default package `Maintainer` is `rcfa - Cubiculum-AI <1831995+rcfa@users.noreply.github.com>`, matching an existing local Git author identity; `--maintainer` remains available for an explicit override. The noreply address is identity metadata, not a support mailbox. The `Bugs` field points to `https://github.com/cubiculum-ai/tractanda/issues`. Distribution will use our own APT repository. The copyright notice and SOURCE_DATE_EPOCH remain explicit inputs. One bounded immutable manifest capture supplies the staged bytes and compatibility/result commitments; source drift is refused, and the completed stage is admitted against that snapshot. Root-owner archive metadata, fixed compression settings and deterministic inventory are used; the resulting control and data archives are streamed and compared to the complete stage without extracting model files again. Actual storage includes directories and private compressor temporary files, with checks after staging, after even an immediately completed compressor and before final publication. The final package name is published only after those checks. Actual package bytes/SHA256, installed-size estimate and every content row are recorded in a neighboring inventory JSON. No signing, apt hosting, installation or release occurs. [Debian control fields](https://www.debian.org/doc/debian-policy/ch-controlfields), [dpkg-deb reproducibility and rootless metadata](https://manpages.debian.org/trixie/dpkg/dpkg-deb.1.en.html).

Illustrative operator commands, to be run only after the producer/R2/native/resource gates are satisfied:

```sh
python3 scripts/package-linux.py --arch amd64 --payload "$PREPARED_PAYLOAD" \
  --input-spec "$PRODUCER_SPEC" --output "$COMPLETE_BUNDLE" --max-stage-bytes "$BUNDLE_BUDGET"
python3 scripts/build-linux-deb.py --arch amd64 --bundle "$COMPLETE_BUNDLE" \
  --output "$DEB_OUTPUT" --copyright-file "$COPYRIGHT_NOTICE" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" --upgrade-class compatible \
  --debian-revision 1 --max-stage-bytes "$PACKAGE_BUDGET"
```

The command uses the project Maintainer identity by default. Pass `--maintainer 'Name <email>'` only when the package should carry a different maintainer identity; keep the support URL in the package's `Bugs` field distinct from that email.

Remaining acceptance is concrete: actual native producer outputs for each architecture; approved full runtime/model closure and minimum-CPU execution; actual clean Debian13 bundle/package builds and size measurements; installation/boot/upgrade/interruption/downgrade/remove/reinstall in disposable systemd guests with real broker authentication; both models' inference/extraction parity; reproducible archive comparison and package lint. Kali evidence remains supplementary. Hosting stays deferred until the complete measured package set is available.

Retain 128 MiB clustering fixture allowance and 10 GiB genuine free-space reserve. Package/runtime/model build estimates may exceed fixture sizes and must be budgeted before staging; never lower the reserve or copy model weights twice merely to populate both architecture archives. Prefer suitable native remote/CI workers for large builds. No release or host installation was performed in this planning pass.

## Primary references checked 18 October 2026

- [GitHub Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)
- [GitHub Packages supported registries](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages)
- [GitHub Releases assets and limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [GitHub Pages custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/about-custom-domains-and-github-pages)
- [GitHub native runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [APT archive authentication and signing](https://manpages.debian.org/trixie/apt/apt-secure.8.en.html)
- [apt-ftparchive index generation](https://manpages.debian.org/trixie/apt-utils/apt-ftparchive.1.en.html)
- [Debian maintainer-script lifecycle](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html)
