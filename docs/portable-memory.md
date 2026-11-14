# Portable memory workflow

This is a portable agent-memory workflow for using Tractanda as a continuing collaborator's durable memory. It uses ordinary Items, categories, saved views, the connected account and its current permissions. It adds no identity service, OAuth flow, enterprise authorization layer, or automatic harness writer integration.

Check the selected executable's `--help` for the memory commands; older clients may not include them. The bootstrap files under `plugins/tractanda/skills/tractanda/assets/memory/` are examples only. They are not active `AGENTS.md` or `CLAUDE.md` files and do not change harness settings.

## One collaborator, task-specific checkpoints

Use one ordinary profile Item for a continuing collaborator across projects, threads, models and machines. A profile is an Item ID selected in local configuration, not a password, permission grant, separate OS account or copy of all memories. Different collaborators can have separate profiles; ordinary ACLs decide what they can read and edit.

Use a different checkpoint Item for each continuing project/task context. Its content should let a fresh authorized session resume without the old process: repository and commit, branch and dirty state, references to required patches/artifacts, what changed, the next action, and open questions. Put durable cross-project facts in the collaborator's memory; keep temporary task progress in its checkpoint. For recall, reuse an existing Knowledge or Handoffs view; for captured Items, use category IDs selected by the user. This workflow adds no new default taxonomy or profile Item.

The binding file points to the store, profile Item and selected checkpoint Item. It can optionally select either a saved `viewID` or a `categoryPath`, and `captureCategoryIDs` for new memories. These are ordinary IDs, not copied content. The binding does not contain credentials or an endpoint. Keep it private and point it at Items in the same logical StoreID on each authorized peer. `itemState` and `queryState` in recall output describe a local observation; they are not portable cursors and must not be carried to another peer as a catch-up checkpoint.

An example binding shape is in [binding.example.json](../plugins/tractanda/skills/tractanda/assets/memory/binding.example.json). Replace every placeholder with IDs from the selected store. Choose either `viewID` or `categoryPath`, not both. Keep `profileItemID` and `checkpointItemID` distinct. The [Codex bootstrap](../plugins/tractanda/skills/tractanda/assets/memory/codex-bootstrap.txt) and [Claude bootstrap](../plugins/tractanda/skills/tractanda/assets/memory/claude-bootstrap.txt) are inert text templates to review and adapt; neither installs a hook or edits an instruction file.

## Recall and explicit writes

The source workflow defines these commands:

```text
tractanda memory recall --binding FILE [--limit 0..62] [--json]
tractanda memory remember --binding FILE --fields PRIVATE_JSON --journal NEW_DIR [--json]
tractanda memory checkpoint --binding FILE --expected-revision UUID --fields PRIVATE_JSON --journal NEW_DIR [--json]
tractanda memory resume JOURNAL [--json]
tractanda memory report JOURNAL [--json]
```

`recall` is read-only and content-bearing. It returns the configured profile, checkpoint, the first bounded page from the selected view/category scope, and a `truncated` flag. The default limit is 32; the maximum is 62. Default selected fields include available OKF status, freshness, sources, links and provenance claims; these remain assertions, and computation flags do not execute or attest anything. Raw import metadata is not included. Recognized source imports that are not complete are omitted and counted in `skippedIncompleteImports`; this sets `truncated`. An incomplete imported profile or checkpoint makes recall fail. If truncated, use the ordinary query/get workflow to complete the needed retrieval; recall is not a complete catch-up feed and does not mark entries read.

`remember` creates an ordinary Item and sets its `collaborator` field to the profile reference from the binding. `captureCategoryIDs` are included by default on that new Item while explicit category overrides in the fields file are retained. `checkpoint` revises the configured checkpoint Item with a required expected revision. Both commands take a private JSON file containing a tagged `ItemValue` field map. They do not create a memory record on every turn; call them for a deliberate durable note or handoff.

Each write stores its exact request in a new private journal before contacting the server. After an uncertain result, `report` reads the local journal without contacting the server; `resume` retries the same journal against the same store, endpoint and authenticated principal. Do not create a fresh journal or reconstruct a guessed retry. The journal is local operational state; it is not the canonical memory itself. Normal Item permissions apply, and a successful local receipt does not prove that another peer has received the revision.

## Portability and cutover

Copy only the non-secret binding configuration and the intended task checkpoint reference between authorized machines. Verify the same StoreID, profile/checkpoint IDs and ordinary permissions on the destination. Rebuild a task handoff from logical repository references and saved artifacts, not a machine-specific working directory or an old conversation process.

Keep native Codex/Claude memories, instructions and settings until a selected migration pilot has verified source preservation, Item readback and the expected fresh-session workflow. This bootstrap does not redirect automatic native writers or establish a cutover. For OKF source imports, use the separate [memory migration guide](memory-migration.md); imported authorship and verification remain claims, computations remain inert, and Tractanda-to-OKF export can lose semantics.
