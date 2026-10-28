# Propagate a completed change

Accumulate related fixes and documentation updates—including feedback from multiple reviewers—and run focused checks as you work. Releases can remain frequent; individual messages or typo fixes are not release boundaries. Start this workflow only when the maintainer explicitly requests a release. Source changes alone do not authorize preparation, signing, installation or publication, and do not start a background release queue. Local deployment also waits for that release request; ordinary development and manual updates remain in the workspace until then.

```sh
python3 scripts/release-macos.py release --notes 'Describe the completed change' --background
python3 scripts/release-macos.py status
```

For a live display, open `http://127.0.0.1:48730/` on the signing Mac. Background releases start or reuse this local observer. Start it independently with `python3 scripts/release-macos.py dashboard`; `status --watch` follows the same state in Terminal and `status --json` returns a concise machine-readable observation. The dashboard shows completed stages as N of M (14 for the current delivery contract; historical candidates retain their recorded plan), elapsed time, controller/child presence, recent log activity and upload stream-read progress when the OS exposes it. The total comes from the release plan, with each candidate retaining its planned stages; upload substeps do not increase it, and stages are not weighted by duration. A live process is not proof of progress; unavailable observations are labelled accordingly. Upload percentages describe local file consumption, with remote acceptance established only when publication verifies the assets. Quiet CI/notarization waits do not by themselves mean a stall. A confirmed missing/reused controller PID is reported as interrupted.

The observer binds only to loopback and exposes filtered status rather than configuration, notes, credentials or raw log contents. It is a native local utility with no model or scheduled agent. Closing the page does not stop a release. A changed observer script takes effect after restarting that observer process; it never requires interrupting the release controller.

`release` prepares and runs the Mac build through a deliberate pre-install authorization pause, then install/health through a separate cluster acceptance pause. Both real Linux package sets must be attached before artifact sealing; publication requires the separate acceptance action below. `--background` starts a detached local process writing `work/release-pipeline/runner.log`; it uses no agent, tokens, or scheduler. Omit it to run in the foreground. Resume an interrupted candidate with `run --background`. The separate `prepare` command remains available when a review pause is useful.

Source review and binary releases are separate. A source-only change can be committed, pushed as a pull request and merged after its checks without running this release workflow, changing `VERSION`, rebuilding packages or deploying services. The installed release and its sealed artifacts remain unchanged until the maintainer requests a release.

`prepare` audits public files, increments `VERSION` and the shared plugin versions, stages and commits the audited source, and creates an isolated checkout for that commit. It refuses another pending release. Finish unrelated or incomplete changes before preparing: this is an explicit completion boundary, not a watcher that publishes keystrokes.

`run` records resumable steps: full source tests, release build, Developer ID signing of executables and the native package, Apple notarization, ticket stapling, Gatekeeper verification, final archive/checksum generation, managed upgrade, canonical reader/installation identity verification, live executable digest/client-pin verification, ordinary push, successful GitHub source CI, then prerelease upload with verified remote checksums. It waits for CI itself, polling every 30 seconds for up to an hour (configurable with `--ci-timeout`). Resuming does not repeat completed expensive work. Changed prepared artifacts stop the run. Pending uploads use verified private temporary copies to isolate long transfers from file-sync renames. An unavailable signing key, failed notarization/assessment, failed check or CI failure stops propagation instead of publishing a partial release.

Notarization is a required gate, using the developer account already signed into Xcode. The script puts the exact signed package inside a disposable app archive, calls `xcodebuild -exportArchive` with automatic Developer ID signing and upload, then retrieves the notarized archive using `-exportNotarizedApp`. Apple's service scans nested containers. The wrapper is only a submission carrier: it is never installed or distributed. The package itself must staple successfully and pass signature, ticket and Gatekeeper checks before it can be published.

The private archive and Xcode distribution ID are recorded for restart; a timeout does not cause another upload. A fresh upload intent is persisted before every attempt. If owned, protected Xcode logs prove that account discovery failed before the upload step and the archive has no distribution entries, the helper retries the CLI once after two seconds. Persistent account failure stops with a specific observer message. Unknown outcomes remain blocked for reconciliation; an older failure cannot authorize repeating a later interrupted attempt. No account settings or credentials are changed. An interrupted upload is reconciled against the saved archive's successful distribution record; ambiguous results stop for inspection. The signed input is kept separate from the stapled final package. Checksums cover final bytes, and installation/publication require the notarization receipt. Temporary archives are removed after success. Standalone Mach-O executables in the tarball rely on Apple's online ticket lookup; tickets cannot be stapled to bare executables, so the native package is the recommended offline-verifiable distribution.

The GitHub release body is rendered from the sealed `docs/github-release-template.md`, with current filenames and version-pinned installation/API/skill links. Maintain the still-relevant setup, usage, backup and compatibility guidance there so each release remains usable when older distributions are removed. The changelog and commit history retain development detail.

System installation uses the ordinary macOS administrator dialog; the controller creates no persistent privileged helper or authorization exception. It stages the verified payload in a private temporary directory so root activation does not depend on privacy access to the developer's Documents directory. The native setup engine owns drain/stop, software replacement, startup/readiness and fail-closed recovery. Compatible binary upgrades preserve the existing canonical store, credentials and pending work in place; they do not copy the canonical store, prove a restore, reinitialize the cluster or reenroll peers. The release helper checks the candidate's reader declaration against the bounded existing canonical requirement, then verifies its monotonic identity and the unchanged installation properties after Setup succeeds. Normal storage backups remain an administrator policy separate from binary updates. It never uninstalls production. A failed publication can resume without rebuilding or reinstalling the same verified candidate.

If a source repair is required before a candidate has been installed or pushed, use `revise --notes 'Describe the repair'`. It commits the audited repair, updates the isolated checkout and invalidates prior validation/artifacts. An installed candidate can retain its unpublished version only through the guarded terminal CI-repair path or an explicit revision while paused before cluster acceptance. The cluster path requires valid installation authorization, a closed runner, the exact installed manifest/executable, and conclusive remote tag/release absence. Accepted or published candidates are excluded. Previous candidate evidence remains available; failed staging outputs are removed after successful publication.

The default database is upgraded through the generated native package, so macOS package receipts advance too. Other databases use the explicit setup command. Old installed versions are pruned only when their ownership receipt and full inventory match, retaining the active release, its immediate predecessor, and every version still recorded by another database. Canonical stores and indexes are never cleanup targets. Cleanup warnings are recorded when an unexpected file or ownership mismatch needs inspection.

Local build retention is separate from installed rollback retention. Before preparing another release and after successful publication, the script removes older completed release folders under `work/release-pipeline`. It keeps the active/pending candidate and the newest published downloads. Even the newest completed release sheds its sealed source worktree, SwiftPM build output and unpacked bundle; its `.pkg`, `.tar.gz`, checksums and compact evidence remain. Older versions leave small JSON receipts in `work/release-pipeline/receipts`; published source and downloads remain available on GitHub.

Use `python3 scripts/release-macos.py prune` to apply the same policy manually. It takes the workflow lock and refuses to race an active release. Missing version folders are harmless, and their stale linked-worktree registrations are removed only within this release tree. Unpublished/failed releases, malformed receipts, dirty or locked checkouts and symlinked version folders are preserved. Cleanup never traverses into canonical stores or the installed software tree. Cleanup errors after publication are recorded as warnings and do not force an already published release to rebuild.

Client launch configurations should point to the shared `current/bin` commands. A running stdio MCP session belongs to its client harness; replacing an executable does not change its loaded code or cached tool schemas. Reconnect that MCP server using the harness's control when required. Do not kill the surrounding conversation or discard unsaved terminal edits. HTTP clients reconnect to the restarted service.

After an explicit release request, the development task starts this deterministic script for the reviewed accumulated changeset. There is no scheduled agent follow-up, and no partially edited working tree is published. Failed operations stop with a recorded error rather than being retried indefinitely.

## Local maintainer configuration

Use Python 3.11+ on the signing Mac. Keep machine-specific paths and signing identities in ignored `work/release-pipeline/config.json`:

```json
{
  "repository": "OWNER/REPOSITORY",
  "branch": "main",
  "instance": "production",
  "softwareRoot": "/Users/Shared/Library/Application Support/Tractanda",
  "applicationIdentity": "Developer ID Application certificate SHA-1",
  "installerIdentity": "Developer ID Installer certificate SHA-1",
  "developerTeamID": "ABCDEFGHIJ",
  "modelDirectory": "/absolute/path/to/pinned/Granite/model",
  "documentModelDirectory": "/absolute/path/to/pinned/Granite-Docling/model"
}
```

The core executables, embedding host and native document converter are rebuilt from the sealed source. Release preparation still requires the pinned local Granite Embedding and 14-file Granite Docling model directories for build-time validation and retrieval/extraction checks. The converter uses a separate complete SwiftPM graph and the guarded pinned runtime patch. Standard release packages include the model workers, notices and hash-bound `models/manifest.json`, but omit model weights; missing files are provisioned from their fixed upstream revisions at runtime. Package assembly verifies worker profiles, the catalog, resource inventory and notices. A full/offline lower-level package can include both complete local model directories using `--include-model-weights`; those files must match the same fixed manifest. Model/tokenizer notices come from the reviewed source. This preview supports a guarded upgrade from an installer-owned Qwen or prior Granite runtime profile to the pinned Granite profile and rebuilds its derived vector index; unrelated/custom semantic configurations require explicit reconfiguration. Signing keys stay in Keychain. Release logs, prepared payloads, configuration and checkpoint state remain under ignored `work/release-pipeline`; they are not source publication inputs. The bundle manifest records the source commit so source, packages and the active release can be reconciled.

Select the full Xcode installation with `xcode-select`, sign into its Accounts settings, and make the team's valid Developer ID Application and Installer certificates available. The script checks those identities before preparing a release; Xcode manages account authentication during upload. No separate `notarytool` profile, app-specific password, or credential extraction is used. Account renewal and acceptance of changed Apple agreements remain account-holder actions in Xcode or Apple's developer site. See [Apple's notarization overview](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).


## Linux artifacts and the pre-publication cluster stop

These source changes do not start a release. After the explicit release boundary, use `prepare` to seal the final version/commit, build the real full amd64 and arm64 packages from that sealed checkout, then attach them before running the artifact stage. Current native runtime/component builds are verification inputs; they are not final versioned Linux core payloads. Keep useful warm objects, but do not rename an older package or change a receipt to make it match a new version.

```sh
python3 scripts/release-macos.py prepare --notes 'Concrete completed changeset'
python3 scripts/release-macos.py attach-linux --linux-assets /absolute/linux-release-inputs.json
python3 scripts/release-macos.py run --background
```

The input JSON uses profile `tractanda.release-linux-input.v1` and an `assets` list containing exactly these six fields for **each** of `amd64` and `arm64`:

```json
{
  "profile": "tractanda.release-linux-input.v1",
  "assets": [
    {
      "arch": "amd64",
      "package": "/absolute/amd64/tractanda.deb",
      "bundleManifest": "/absolute/amd64/bundle/bundle-manifest.json",
      "bundleBuildReceipt": "/absolute/amd64/bundle/lib/tractanda/linux-bundle-build.json",
      "producerSourceInputs": "/absolute/amd64/work/source-inputs.json",
      "producerResult": "/absolute/amd64/work/result.json"
    },
    {
      "arch": "arm64",
      "package": "/absolute/arm64/tractanda.deb",
      "bundleManifest": "/absolute/arm64/bundle/bundle-manifest.json",
      "bundleBuildReceipt": "/absolute/arm64/bundle/lib/tractanda/linux-bundle-build.json",
      "producerSourceInputs": "/absolute/arm64/work/source-inputs.json",
      "producerResult": "/absolute/arm64/work/result.json"
    }
  ]
}
```

Each package requires its existing adjacent `.deb.inventory.json` from the real Debian builder. Admission checks the package version/architecture/bytes/hash, the actual full bundle identity and manifest/inventory commitments, and the manifest-bound bundle-build receipt. It reconstructs the producer's existing normalized source commitment from `files`, `componentManifests`, `toolchain`, `buildEnvironment` and fixed build flags. Source paths, modes, sizes and hashes must equal the candidate's own existing `source_rows()` capture; component approvals must equal its finite admitted registry entries. Matching a version or an operator statement alone does not establish sealed core source. Component admission and actual native/model/lifecycle evidence remain their existing separate gates.

The controller keeps bound candidate-owned copies and small receipts. The published names are `tractanda_DEBIANVERSION_amd64.deb` and `tractanda_DEBIANVERSION_arm64.deb` (for example `tractanda_0.1.0~poc.15-1_amd64.deb`). Both join the same `SHA256SUMS`, private `/private/tmp` upload snapshot, GitHub asset-digest verification and interrupted-upload resume used by the Mac downloads. No APT host, signing key or second publisher is created. Missing/duplicate architectures, altered inputs, wrong source/manifest commitments and conflicting remote assets fail closed.

New candidates use delivery contract v2 with fourteen planned stages. `install-authorization` stops after the sealed/notarized Mac and both Linux artifacts exist, **before** managed Mac installation. Its two checks cover candidate compatibility/maintenance and current installation identity. Existing pending v1 candidates must be explicitly revised and resealed; they cannot run, install or publish through the new contract. Completed historical receipts remain readable.

The compatibility check must classify canonical reader/writer requirements, authorization/merge semantics and required peer capabilities. Verified compatible releases may upgrade one node at a time. A breaking canonical, semantic or peer-runtime change requires explicit coordinated maintenance: all active members must be reachable and upgraded before writes resume. An offline member delays that update. The roaming v2 capability and its source-stage successor, private JMAP hello `tractanda.personal-sync.v3` with frame version 4, require coordinated peer-runtime updates even though canonical item formats are unchanged. The latter retains the canonical `tractanda.personal-sync.v1` profile and requires the private vendor capability; see [the binding contract](private-peer-jmap-binding.md). Operator evidence must record the actual applicable maintenance decision; signing or a matching version cannot substitute for it.

```sh
python3 scripts/release-macos.py install-template > /absolute/install-authorization.json
# Verify candidate compatibility/maintenance and current installation identity.
python3 scripts/release-macos.py allow-install \
  --candidate EXACT_CANDIDATE_ID --evidence /absolute/install-authorization.json
python3 scripts/release-macos.py run --background
```

The install template requires the actual Raven StoreID/ReplicaID UUIDv1 pins and two explicit PASS verifications (`candidate-compatibility-and-maintenance`, `current-installation-identity`) with persistent nonsecret receipt hashes. Its candidate binding includes the configured Mac software root and instance, source commit/tree and all sealed artifacts, so changing the target or candidate invalidates it. Repeating `run` without `allow-install` cannot install anything. Signing, notarization, actual canonical reader admission, administrator authentication and live readiness remain required.

After installation and fresh Mac health, `cluster-acceptance` pauses separately before push, CI and publication. The runner records `status=paused` and the corresponding exact candidate ID/reason. Repeating `run` rechecks the applicable evidence and local health; it never turns missing evidence into approval. The existing completed poc.14 state and its historical twelve-step plan are unchanged. An unfinished legacy candidate must be explicitly revised into this delivery contract.

Cluster acceptance verifies the existing deployment: `raven-candidate-runtime`, `stash-candidate-runtime`, `current-membership-and-peer-runtime`, then `bidirectional-verification`. It never requires empty-target preparation, historical authority adoption, initial conversion or enrollment. Fresh installation/join and explicit recovery/import are separate administrator operations with their own applicable gates; historical initial-delivery receipts do not certify a later binary update.

```sh
python3 scripts/release-macos.py cluster-template > /absolute/cluster-acceptance.json
# Complete the actual ordered checks and fill their retained nonsecret evidence references.
python3 scripts/release-macos.py accept-cluster \
  --candidate EXACT_CLUSTER_CANDIDATE_ID --evidence /absolute/cluster-acceptance.json
python3 scripts/release-macos.py run --background
```

The template is deliberately unaccepted: all checks start `PENDING`, identity pins and evidence lists are empty. Supply the actual distinct lowercase UUIDv1 StoreID and Raven/Stash ReplicaIDs, keeping Raven's pins identical to the install authorization, and exactly the listed runtime/verification checks in order. Each check needs explicit `PASS`, a timezone-qualified verification completion time in chronological order, and retained absolute nonsecret receipt paths with exact SHA256 values. Never put private keys, target envelopes or passwords into this JSON. Preserve evidence unchanged after acceptance; if it changes or disappears, resume stops. These receipts attest actual results; a failed installation cannot be marked ready.

`accept-cluster` is a deliberate local operator action recording candidate/version/commit/tree, the signed Mac bundle and all Mac/Linux artifact/producer commitments. It records the caller UID and acceptance time. It is an operator attestation backed by retained receipt hashes, not independent cryptographic proof that a remote cluster converged. A subsequent `run` still rechecks local live health, artifact bytes and evidence before advancing. Acceptance does not itself push or publish.

Revising a candidate archives its Linux inputs/install authorization/cluster acceptance evidence and clears all delivery bindings; build and attach the real revised packages and repeat acceptance. Changed version/source/tree/manifest/assets also invalidate the candidate ID. A guarded unpublished cluster repair preserves the previous installation and evidence as history while invalidating all candidate-bound artifacts, install authorization and cluster acceptance. Initial conversion and enrollment receipts remain historical facts and are not recurring release prerequisites. Revision changes source only; rebuild and explicitly install the revised signed packages through their normal gates. Published versions and accepted cluster candidates cannot use this repair path.

An uninstalled descendant of an archived, unpublished cluster-repair candidate may also be revised after its native runner has stopped. The workflow rechecks the actual installed ancestor manifest and executable, retained installation authorization bytes, source ancestry, and authenticated absence of the version’s remote release and tag. It retains failed intermediate artifacts and invalidates every new delivery authorization; it does not install the failed descendant or repeat conversion or enrollment.
