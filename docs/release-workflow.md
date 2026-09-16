# Propagate a completed change

For an actively used installation, completion includes the running software and downloadable packages. Prepare one coherent, reviewed changeset after focused checks. Runtime, API, UI, template, installer, shared-skill and release-document changes use this workflow; private notes and experiments do not trigger publication.

```sh
python3 scripts/release-macos.py release --notes 'Describe the completed change' --background
python3 scripts/release-macos.py status
```

`release` prepares and runs the entire workflow. `--background` starts a detached local process writing `work/release-pipeline/runner.log`; it uses no agent, tokens, or scheduler. Omit it to run in the foreground. Resume an interrupted candidate with `run --background`. The separate `prepare` command remains available when a review pause is useful.

`prepare` audits public files, increments `VERSION` and the shared plugin versions, stages and commits the audited source, and creates an isolated checkout for that commit. It refuses another pending release. Finish unrelated or incomplete changes before preparing: this is an explicit completion boundary, not a watcher that publishes keystrokes.

`run` records resumable steps: full source tests, release build, Developer ID signing, native package and archive construction, an upgrade of the existing managed installation, canonical-file preservation, live executable digest/client-pin verification, ordinary push, successful GitHub source CI, then prerelease upload with verified remote checksums. It waits for CI itself, polling every 30 seconds for up to an hour (configurable with `--ci-timeout`). Resuming does not repeat completed expensive work. Changed prepared artifacts stop the run. Pending uploads use verified private temporary copies to isolate long transfers from file-sync renames. Failed staging outputs are retained for inspection. An unavailable signing key, failed check or CI failure stops propagation instead of publishing a partial release.

System installation uses the ordinary macOS administrator dialog; the controller creates no persistent privileged helper or authorization exception. It stages the verified payload in a private temporary directory so root activation does not depend on privacy access to the developer's Documents directory. The native setup engine repins/restarts server and embedding LaunchDaemons and rolls back registrations if startup fails. It preserves database ownership, paths, port and existing canonical files. It never uninstalls production. A failed publication can resume without rebuilding or reinstalling the same verified candidate.

If a source repair is required before a candidate has been installed or pushed, use `revise --notes 'Describe the repair'`. It commits the audited repair, updates the isolated checkout and invalidates prior validation/artifacts. It refuses to rewrite an installed or published candidate; those need a new release. Previous candidate evidence remains available; failed staging outputs are removed after successful publication.

The default database is upgraded through the generated native package, so macOS package receipts advance too. Other databases use the explicit setup command. Old installed versions are pruned only when their ownership receipt and full inventory match, retaining the active release, its immediate predecessor, and every version still recorded by another database. Canonical stores and indexes are never cleanup targets. Cleanup warnings are recorded when an unexpected file or ownership mismatch needs inspection.

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
  "embeddingHost": "/absolute/path/to/tractanda-embeddings",
  "modelDirectory": "/absolute/path/to/pinned/model",
  "modelNotices": "/absolute/path/to/model/notices"
}
```

The pinned embedding payload must match the existing installation; changing the model requires separate explicit reconfiguration. Signing keys stay in Keychain. Release logs, prepared payloads, configuration and checkpoint state remain under ignored `work/release-pipeline`; they are not source publication inputs. The bundle manifest records the source commit so source, packages and the active release can be reconciled.
