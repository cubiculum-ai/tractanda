# Propagate a completed change

For an actively used installation, completion includes the running software and downloadable packages. Prepare one coherent, reviewed changeset after focused checks. Runtime, API, UI, template, installer, shared-skill and release-document changes use this workflow; private notes and experiments do not trigger publication.

```sh
python3 scripts/release-macos.py release --notes 'Describe the completed change' --background
python3 scripts/release-macos.py status
```

For a live display, open `http://127.0.0.1:48730/` on the signing Mac. Background releases start or reuse this local observer. Start it independently with `python3 scripts/release-macos.py dashboard`; `status --watch` follows the same state in Terminal and `status --json` returns a concise machine-readable observation. The dashboard shows completed stages as N of M (currently 12), elapsed time, controller/child presence, recent log activity and upload stream-read progress when the OS exposes it. The total comes from the release plan, with each candidate retaining its planned stages; upload substeps do not increase it, and stages are not weighted by duration. A live process is not proof of progress; unavailable observations are labelled accordingly. Upload percentages describe local file consumption, with remote acceptance established only when publication verifies the assets. Quiet CI/notarization waits do not by themselves mean a stall. A confirmed missing/reused controller PID is reported as interrupted.

The observer binds only to loopback and exposes filtered status rather than configuration, notes, credentials or raw log contents. It is a native local utility with no model or scheduled agent. Closing the page does not stop a release. A changed observer script takes effect after restarting that observer process; it never requires interrupting the release controller.

`release` prepares and runs the entire workflow. `--background` starts a detached local process writing `work/release-pipeline/runner.log`; it uses no agent, tokens, or scheduler. Omit it to run in the foreground. Resume an interrupted candidate with `run --background`. The separate `prepare` command remains available when a review pause is useful.

`prepare` audits public files, increments `VERSION` and the shared plugin versions, stages and commits the audited source, and creates an isolated checkout for that commit. It refuses another pending release. Finish unrelated or incomplete changes before preparing: this is an explicit completion boundary, not a watcher that publishes keystrokes.

`run` records resumable steps: full source tests, release build, Developer ID signing of executables and the native package, Apple notarization, ticket stapling, Gatekeeper verification, final archive/checksum generation, managed upgrade, canonical-file preservation, live executable digest/client-pin verification, ordinary push, successful GitHub source CI, then prerelease upload with verified remote checksums. It waits for CI itself, polling every 30 seconds for up to an hour (configurable with `--ci-timeout`). Resuming does not repeat completed expensive work. Changed prepared artifacts stop the run. Pending uploads use verified private temporary copies to isolate long transfers from file-sync renames. An unavailable signing key, failed notarization/assessment, failed check or CI failure stops propagation instead of publishing a partial release.

Notarization is a required gate, using the developer account already signed into Xcode. The script puts the exact signed package inside a disposable app archive, calls `xcodebuild -exportArchive` with automatic Developer ID signing and upload, then retrieves the notarized archive using `-exportNotarizedApp`. Apple's service scans nested containers. The wrapper is only a submission carrier: it is never installed or distributed. The package itself must staple successfully and pass signature, ticket and Gatekeeper checks before it can be published.

The private archive and Xcode distribution ID are recorded for restart; a timeout does not cause another upload. A fresh upload intent is persisted before every attempt. If owned, protected Xcode logs prove that account discovery failed before the upload step and the archive has no distribution entries, the helper retries the CLI once after two seconds. Persistent account failure stops with a specific observer message. Unknown outcomes remain blocked for reconciliation; an older failure cannot authorize repeating a later interrupted attempt. No account settings or credentials are changed. An interrupted upload is reconciled against the saved archive's successful distribution record; ambiguous results stop for inspection. The signed input is kept separate from the stapled final package. Checksums cover final bytes, and installation/publication require the notarization receipt. Temporary archives are removed after success. Standalone Mach-O executables in the tarball rely on Apple's online ticket lookup; tickets cannot be stapled to bare executables, so the native package is the recommended offline-verifiable distribution.

System installation uses the ordinary macOS administrator dialog; the controller creates no persistent privileged helper or authorization exception. It stages the verified payload in a private temporary directory so root activation does not depend on privacy access to the developer's Documents directory. The native setup engine repins/restarts server and embedding LaunchDaemons and rolls back registrations if startup fails. It preserves database ownership, paths, port and existing canonical files. It never uninstalls production. A failed publication can resume without rebuilding or reinstalling the same verified candidate.

If a source repair is required before a candidate has been installed or pushed, use `revise --notes 'Describe the repair'`. It commits the audited repair, updates the isolated checkout and invalidates prior validation/artifacts. It refuses to rewrite an installed or published candidate; those need a new release. Previous candidate evidence remains available; failed staging outputs are removed after successful publication.

The default database is upgraded through the generated native package, so macOS package receipts advance too. Other databases use the explicit setup command. Old installed versions are pruned only when their ownership receipt and full inventory match, retaining the active release, its immediate predecessor, and every version still recorded by another database. Canonical stores and indexes are never cleanup targets. Cleanup warnings are recorded when an unexpected file or ownership mismatch needs inspection.

Local build retention is separate from installed rollback retention. Before preparing another release and after successful publication, the script removes older completed release folders under `work/release-pipeline`. It keeps the active/pending candidate and the newest published downloads. Even the newest completed release sheds its sealed source worktree, SwiftPM build output and unpacked bundle; its `.pkg`, `.tar.gz`, checksums and compact evidence remain. Older versions leave small JSON receipts in `work/release-pipeline/receipts`; published source and downloads remain available on GitHub.

Use `python3 scripts/release-macos.py prune` to apply the same policy manually. It takes the workflow lock and refuses to race an active release. Missing version folders are harmless, and their stale linked-worktree registrations are removed only within this release tree. Unpublished/failed releases, malformed receipts, dirty or locked checkouts and symlinked version folders are preserved. Cleanup never traverses into canonical stores or the installed software tree. Cleanup errors after publication are recorded as warnings and do not force an already published release to rebuild.

Client launch configurations should point to the shared `current/bin` commands. A running stdio MCP session belongs to its client harness; replacing an executable does not change its loaded code or cached tool schemas. Reconnect that MCP server using the harness's control when required. Do not kill the surrounding conversation or discard unsaved terminal edits. HTTP clients reconnect to the restarted service.

The development task starts this deterministic script after a significant completed changeset. There is no scheduled agent follow-up, and no partially edited working tree is published. Failed operations stop with a recorded error rather than being retried indefinitely.

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
  "embeddingHost": "/absolute/path/to/tractanda-embeddings",
  "modelDirectory": "/absolute/path/to/pinned/model",
  "modelNotices": "/absolute/path/to/model/notices"
}
```

The pinned embedding payload must match the existing installation; changing the model requires separate explicit reconfiguration. Signing keys stay in Keychain. Release logs, prepared payloads, configuration and checkpoint state remain under ignored `work/release-pipeline`; they are not source publication inputs. The bundle manifest records the source commit so source, packages and the active release can be reconciled.

Select the full Xcode installation with `xcode-select`, sign into its Accounts settings, and make the team's valid Developer ID Application and Installer certificates available. The script checks those identities before preparing a release; Xcode manages account authentication during upload. No separate `notarytool` profile, app-specific password, or credential extraction is used. Account renewal and acceptance of changed Apple agreements remain account-holder actions in Xcode or Apple's developer site. See [Apple's notarization overview](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
