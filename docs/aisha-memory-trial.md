# Staged memory trials

This runbook describes planned, user-run import and handoff trials for the portable memory workflow. It does not record a completed trial. The Aisha-specific source format and its native memory behavior have not been established here; treat the provided selection as ordinary files and let preview diagnostics show what the importer can interpret.

## 1. Aisha selected-note trial on Stash

Use a directory containing only the notes the user selected for this trial. Do not point the importer at Aisha's home directory, a live memory database, or a directory containing unrelated private material. Preserve the original export unchanged in its existing location. Unsupported files can be retained as originals, but are not thereby understood as Aisha-native memory records.

Run the installed client as the intended existing OS account, with its ordinary Tractanda permissions. Do not use `sudo`. On the current Linux layout, set `CLI` to `/opt/tractanda/current/bin/tractanda`; on the current macOS layout, use `/Library/Tractanda/Software/current/bin/tractanda`. Confirm the installed client displays the relevant syntax with `"$CLI"` and `"$CLI" import` before proceeding. Use the already configured Stash connection or add `--profile ACTUAL_PROFILE` before the subcommand if this account requires an explicit local profile. The commands do not accept or store credentials.

Create a private work area outside the source export and copy the selected files into its `source` directory without editing them:

```sh
umask 077
STAGE="$HOME/tractanda-memory-pilot/aisha-stash"
CLI="/opt/tractanda/current/bin/tractanda"
mkdir -p "$STAGE/source"
chmod 700 "$STAGE" "$STAGE/source"
```

After copying the selected export into `"$STAGE/source"`, verify that it contains only the intended files. Preview using the generic directory adapter because Aisha's native format is not asserted to be Codex, Claude or OKF:

```sh
"$CLI" import limits > "$STAGE/import-limits.json"
"$CLI" import preview --adapter directory \
  --source "$STAGE/source" \
  --namespace aisha-selected-notes-trial-v1 \
  --out "$STAGE/plan.json"
"$CLI" import inspect "$STAGE/plan.json"
```

Review the complete inspect report and diagnostics before any write. Confirm the proposed source identities, record count, file sizes, digests, projections, links and outcomes. Stop for `incomplete`, `duplicate`, `conflict`, `tombstone` or unexpected mappings; do not change the namespace or start a second preview as a retry. If the selected export exceeds the displayed defaults, adjust a private copy of `import-limits.json` deliberately and create a new reviewed plan before proceeding.

Only after the inspect report is acceptable, apply once with a new journal directory:

```sh
"$CLI" import apply "$STAGE/plan.json" --journal "$STAGE/journal"
"$CLI" import report "$STAGE/journal"
```

Keep the source export, plan and journal. For an uncertain response, inspect `report`, then resume the same journal against the same Store, endpoint and account:

```sh
"$CLI" import resume "$STAGE/journal"
"$CLI" import report "$STAGE/journal"
```

Verify representative imported Items, their visible category/view membership, their original attachments and the final report. Then make a separate readable export for inspection:

```sh
"$CLI" export-memory --namespace aisha-selected-notes-trial-v1 \
  --out "$STAGE/verified-export"
```

Compare its manifest, diagnostics, native Item revisions and original attachment bytes with the import report and source files. This checks the importer/exporter behavior; it does not establish Aisha-format fidelity for unsupported structures or prove another peer has received the data. Keep Aisha's original export intact.

## 2. Small selected Codex and Claude notes pilot

After the Aisha trial is reviewed, repeat the same preview, inspect, apply, report and export sequence with one small, explicitly selected Markdown/text note or export from each harness. Use separate private staging directories and stable, distinct namespaces for the two sources. The `codex` and `claude` adapters interpret selected Markdown/text notes; they do not inspect live harness directories, import transcript/database semantics, or configure future writes. Where a file's meaning is uncertain, use the generic `directory` adapter and rely on diagnostics rather than infer a framework-specific schema.

Fill these paths with the actual user-selected exports and private work directories. Keep them separate from the exports themselves:

```sh
CODEX_SOURCE="/absolute/path/to/selected-codex-notes"
CODEX_STAGE="$HOME/tractanda-memory-pilot/codex"
CLAUDE_SOURCE="/absolute/path/to/selected-claude-notes"
CLAUDE_STAGE="$HOME/tractanda-memory-pilot/claude"
mkdir -p "$CODEX_STAGE" "$CLAUDE_STAGE"
chmod 700 "$CODEX_STAGE" "$CLAUDE_STAGE"

"$CLI" import preview --adapter codex --source "$CODEX_SOURCE" \
  --namespace codex-selected-notes-pilot-v1 --out "$CODEX_STAGE/plan.json"
"$CLI" import inspect "$CODEX_STAGE/plan.json"
"$CLI" import apply "$CODEX_STAGE/plan.json" --journal "$CODEX_STAGE/journal"
"$CLI" import report "$CODEX_STAGE/journal"

"$CLI" import preview --adapter claude --source "$CLAUDE_SOURCE" \
  --namespace claude-selected-notes-pilot-v1 --out "$CLAUDE_STAGE/plan.json"
"$CLI" import inspect "$CLAUDE_STAGE/plan.json"
"$CLI" import apply "$CLAUDE_STAGE/plan.json" --journal "$CLAUDE_STAGE/journal"
"$CLI" import report "$CLAUDE_STAGE/journal"
```

Apply only after reviewing each inspect report. If a report is uncertain, use that source's same journal for `import resume` and `import report`; do not replay with a new plan or namespace. Export each pilot namespace to a separate new directory and verify its manifest and retained originals using the same `export-memory` command shown above.

Use the ordinary existing OS account and current ACLs. Keep the source files, Codex/Claude memories, instruction files and settings intact. Do not install bootstrap text, hooks or a global profile, and do not claim native-writer cutover from a successful import. The import records are ordinary Tractanda Items with source provenance; they do not establish a separate agent identity.

For deliberate recall/checkpoint trials, first select the actual StoreID, one continuing collaborator profile Item, a distinct task checkpoint Item and either an existing saved view ID or a category path. Fill the private binding from [the example](../plugins/tractanda/skills/tractanda/assets/memory/binding.example.json); do not invent IDs, and do not include credentials or endpoints. Use `memory recall` and verify the returned profile, checkpoint, bounded scope and `truncated` flag. Use `memory checkpoint` only with the actual current revision ID and a private new journal. Recall state is local to the caller/peer and is not a portable cursor.

## 3. Raven-to-Starlet fresh-session handoff

The release is not qualified for memory cutover until the actual handoff succeeds. On Raven, use the selected ordinary account to checkpoint a real task and verify that the same StoreID/profile/checkpoint revisions replicate to Starlet. Then start a fresh authorized session on Starlet without Raven's memory directories, use the same private ID-only binding and the normal local account permissions, recall the profile/checkpoint, and resume from logical repository, commit, branch and saved artifacts. Record the actual readback and replication evidence. A successful local write or export alone is not this handoff.

Keep all existing native memories and settings on both machines during these trials. Do not disable or redirect native writers based on the Aisha import or the small Codex/Claude pilot. Any future writer integration or cutover requires its own selected implementation and is considered only after this real Raven-Starlet handoff is verified.
