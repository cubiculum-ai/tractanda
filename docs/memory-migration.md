# Import and export agent memory

The memory-migration commands provide an explicit path for importing a selected directory of notes or OKF v0.2 concepts into ordinary Tractanda Items. It supports shared agent-memory workflows. It does not change how Codex or Claude save native memories, scan a home directory, configure a harness, or redirect future writes to Tractanda.

Keep the selected source files and native memory settings intact while reviewing an import. Treat a completed import as verified only after reading its report and checking representative imported Items, originals and links in the destination store. Do not delete or disable the source as part of import.

## Select a source explicitly

The importer accepts `directory`, `okf`, `codex` and `claude` adapters, each pointed at a directory the operator selected. Codex and Claude selections are treated as supplied exports or notes; the importer does not locate their live memory stores or infer a global/project scope by scanning the machine. The current Codex/Claude adapters project Markdown and text notes; other regular files are retained as originals with an unsupported-format diagnostic, not interpreted as JSONL or a framework database.

Choose a stable namespace for the logical source and keep using it for later previews and reports. The namespace is the source's import identity, not a filesystem path, content hash, user identity or permission grant. OKF concept IDs come from bundle-relative Markdown paths without `.md`; non-OKF records use their relative paths. An explicit rename map is available in the plan model; source disappearance does not authorize deleting an imported Item. Imported tags remain data and category proposals; the importer does not create categories or assign them automatically.

## Preview, inspect, apply and resume

Clients exposing these commands support the following workflow:

```text
tractanda import limits
tractanda import preview --adapter directory|okf|codex|claude --source DIR --namespace TOKEN --out PLAN [--limits PRIVATE_JSON]
tractanda import inspect PLAN
tractanda import apply PLAN --journal NEWDIR
tractanda import resume JOURNAL
tractanda import report JOURNAL
tractanda export-memory --namespace TOKEN --out NEWDIR
```

Add `--json` to commands that emit a report or summary. `import limits` prints the default limits as JSON without contacting the server. The default permits 256 records; to select a larger source, save that output to a private file, adjust the desired bounds and pass it with `--limits`. The file must be owned by the current account, inaccessible to other users and at most 16 KiB; all limits are validated before scanning. The chosen limits are retained in the plan. `preview` reads only the explicitly selected local directory and writes a private, bounded plan; it does not contact the server. The plan records source identities, original-file path/size/digest, typed projections, link evidence and parser diagnostics. `inspect` compares a saved plan with the connected destination and returns per-record outcomes before writes. `apply` writes through the currently connected account using normal Item permissions and creates a private journal in a new directory. `resume` continues that journal against its bound store, endpoint and principal; `report` reads the retained report without applying more work.

Retain the plan, journal and exact source directory through completion. Keep the namespace stable. Use the same store, account and peer when resuming uncertain work. The journal is needed for exact pending write/upload retry; do not rebuild intent from a changed source and guess. If it is lost, use the completed source-to-Item mapping and current records to reconcile what already completed before creating a new plan. A new preview is not an exact retry.

Reports can distinguish `create`, `update`, `unchanged`, `localDivergence`, `conflict`, `duplicate`, `missing`, `incomplete`, `tombstone` and `failed` outcomes, along with diagnostics. Tombstone discovery requires the server's `tractanda.query-include-deleted.v1` capability and uses metadata-only queries; if the feature is absent or discovery is incomplete, import stops. Incomplete, conflicted, duplicate or tombstoned records require review; do not force them through as creates. A tombstone is evidence that this source identity already has a deleted Item. Import does not silently resurrect it. Apply uses only the permissions of the authenticated destination account and does not import source ACLs.

Use one active writer per namespace. Duplicate discovery covers only Items readable to the current account and is not a distributed uniqueness lock; concurrent imports on different peers can still race. Current Item permissions remain in force for discovery, reads and writes.

The report's replication field states local canonical state only; replication acknowledgement is not established. Verify local writes and separately verify replication when another peer must use the imported memory.

## What an OKF import means

The adapter pins OKF v0.2 at `6a2845dd6ce30c3a866a5d55ef8221964fd96372`. Each concept needs a non-empty `type`; unknown type values and additional keys remain consumable and are retained with diagnostics. `index.md` and `log.md` are auxiliary bundle records. The adapter projects `type` to `okfType`, `title` to `subject`, and preserves understood description, resource, tags, status, provenance and lifecycle fields. Tags produce category proposals only. An absent status has effective value `stable`. A bare `verified` mapping is normalized to one event. Verification and source links are retained as claims. An `Item` projection does not authenticate an OKF actor or transfer an ACL.

The exact original file and raw frontmatter are retained separately from typed projections. Markdown outgoing links record a parsed destination, fragment, source location and local, external, missing, unsafe or unsupported resolution; `rawMarkdown` and the original file preserve the exact occurrence and reference definitions. “Local” means the target document exists in the selected bundle; fragment/heading existence is not validated or rendered. Source-ID markers can join declared OKF sources, but general footnote rendering and dialect-specific placement semantics remain unsupported; legacy v0.1 citations are preserved but not interpreted. A broken link does not reject the concept. The bounded parser supports ordinary scalars, lists, mappings and completed acyclic aliases. It rejects forward/self-referential or over-limit aliases; custom tags and non-string/complex keys are carried as inert data with diagnostics where they do not have native projections.

The common projections are ordinary fields, not new Item classes:

| Source concept | Tractanda projection |
| --- | --- |
| Type, title and body | `okfType`, `subject`, `body` |
| Description, resource and bundle version | `okfDescription`, `okfResource`, `okfVersion` |
| Tags and lifecycle | `okfTags`, `okfStatus` (default `stable`), valid `okfStaleAfter` date |
| Generation and verification claims | `okfGeneratedClaim`, `okfVerifiedClaims`; a supported generation timestamp also supplies the claimed `originalModifiedAt` |
| Sources and usage window | `okfSources`, `okfUsageWindow`; typed supported nested date claims remain in `importMetadata.dateClaims` |
| Outgoing links | `importLinks` with raw target/fragment, resolution state and an optional Item reference |
| Full frontmatter and unprojected extensions | Original attachment plus `importMetadata.yaml` and raw frontmatter |

These source lifecycle fields do not replace project status or priority category memberships. Category proposals require an explicit mapping; importing source tags does not create a taxonomy automatically.

Timestamps without a valid explicit-offset ISO 8601 datetime are preserved in the original evidence and ignored as native dates. The current date projection accepts seconds, optional fractional seconds, and `Z` or `±HH:MM`; other timestamp spellings remain source evidence only. Do not infer UTC for date-only or timezone-free values. `generated`, `verified`, source authors and trust tiers are imported assertions, not authenticated authorship or ACLs. Status and stale-after fields are data; no automatic deletion or alarm follows from them.

Attested Computation fields, code and resource locators are retained as declarations. The importer does not execute them, contact their resources, create execution receipts or assert attestation. OKF v0.2 does not define a complete portable execution/attester protocol. Consumers must report computation content as inert, unexecuted and unattested.

Exact-byte retention is distinct from semantic support. The current mapping does not promise full OKF rendering, all YAML extensions, general footnote behavior, or complete link/UI navigation. Read the plan and report diagnostics before relying on a projected meaning.

## Export and cutover

`export-memory --namespace TOKEN --out NEWDIR` produces a new directory with a `memories/` Markdown projection, `items/` native Item exports, `manifest.json` and `report.json`. The manifest maps source IDs and aliases to Item/revision IDs, import state and the files. The native export includes the selected revision and its active original attachments and document dependencies; the readable projection reflects the current subject/body, which may differ from the imported original after edits. Tombstoned Items are omitted from the readable bundle and reported; incomplete imports are marked incomplete. Export pins each selected Item revision independently, so it is not an atomic store snapshot or backup. Treat this as a portability aid, not a full Tractanda-to-OKF semantic round trip. Permissions, peer state, active harness instructions and some Tractanda-specific semantics do not become equivalent OKF semantics. Inspect the export and diagnostics; it carries no Tractanda authority or writer integration.

This workflow does not turn off Codex/Claude native memory writers or modify `AGENTS.md`, `CLAUDE.md`, harness settings, global profiles or local memory paths. A later cutover requires a selected integration and a separate verified migration decision. Until then, maintain source memories and Tractanda imports as explicitly separate stores.

Keep intent journals outside the selected source directory. `import report` takes the journal lease; it reports a busy journal while an import or resume holds that lease. It is a recovery/status reader, not a concurrent live-progress stream.
