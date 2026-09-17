# Changelog

## 0.1.0-poc.10

This consolidated preview supersedes the early distributions. Its release page contains current installation, client/agent usage, storage, backup and compatibility guidance without depending on earlier release notes. The unpublished poc.9 candidate was superseded before installation or publication.

TRAC-094 adds read-only extracted-text diagnostics through the native API and MCP. Source, FTS-input and summary projections identify current revisions, extraction rules, byte counts and independent index freshness. Large results use explicit continuation/oversized IDs; current permissions apply before text or index metadata is returned. The extraction profile and embedding model are unchanged.

The web project selector refreshes correctly after removal of the old task-kind filter. Clearing a nonempty description or working-notes field removes its key. The user manual now covers current installation, categories, views, TUI controls, learning and recovery; agent guidance distinguishes cached harness tool lists from adapter processes and documents mutually exclusive retrieval options.

Release tooling reclaims completed local build trees while preserving active candidates, current downloads, compact receipts and installed rollback versions. The observer recognizes paused releases. Publication and local deployment now follow explicitly requested batches rather than individual edits.

## 0.1.0-poc.8

Category membership defines priority and other classifications. Native category-axis sorting, category-backed columns, effective-membership projection and generic Kanban category controls replace parallel classification fields. Source samples follow the same conventions. The experimental native capability advances to `/4`; clients must update and reconnect.


## 0.1.0-poc.7

Notarization records every upload attempt and retries a proven pre-upload Xcode account-discovery failure once through the CLI. Uncertain outcomes still require reconciliation, and the release observer reports a concise failure cause.

The release dashboard and CLI show completed stages out of the planned total. The workflow and observer share one stage definition, and each prepared candidate records its plan. Upload substeps do not inflate the count. Foreground CLI releases launched with a relative script path are recognized using their verified working directory.

The Kanban sidebar displays the connected server's reported version beneath the Tractanda name and above Workspace. Default cards within each column now sort by priority, with blank priorities last; explicit saved-view sorting is preserved in both browser and native exports.

Agent guidance covers stale session adapters, exact-payload imports, operation-ID limits/rejections/replays, required unset arrays, local field conventions and thin project skills. Native protocol rejections are distinguishable from unavailable services, mutation validation errors give corrective retry advice, and the property catalogue includes workingNotes.

## 0.1.0-poc.6

`Item` is now the concrete generic root. The empty `NoteItem` subclass is removed from the registry, client defaults, templates, examples and agent guidance. Specialized subclasses remain. The experimental native API advances to capability `/3`; older clients must be updated and reconnected.

Fresh samples and saved-view templates use ordinary `Item` records. Release checks now load the shipped examples and category template, verify exact retries, then rebuild the sample database from canonical files and compare records and views.

## 0.1.0-poc.5

Release progress is visible through a local dashboard and live status/watch commands, distinguishing verified controller presence from measurable activity. Agent guidance clarifies saved-view ordering, manual category criteria and shared/personal assignments; the property catalogue exposes categoryOrder.

## 0.1.0-poc.4

The property catalogue and agent guidance now describe timestamp tags explicitly, including activity-entry dates and original source creation/modification times. Nested element descriptions document field conventions without implying nested-array query support.

## 0.1.0-poc.3

Ordinary actions use notes and category assignments for to-do and waiting states. The redundant action subclasses are removed from the type catalog and terminal editor. `waitingOn` remains available on any item; the served API guidance and shared agent skill explain the category-based workflow.

The macOS release script uses Xcode's signed-in developer account for automatic notarization, with resumable uploads, package ticket stapling and Gatekeeper verification before installation or publication. A separate notarytool credential profile is unnecessary.

## 0.1.0-poc.1

Initial source-available proof of concept: immutable item revisions, rebuildable SQLite/FTS5 indexes, overlapping categories and views, terminal/JSON clients, stdio MCP, optional semantic retrieval, and an example browser client.

This checkpoint also documents the implemented co-located shared daemon: Unix API plus optional loopback HTTP and Streamable HTTP MCP, session/authentication boundaries, user-level managed registration, system-administrator policy, and opt-in semantic `item-text-utf8-v2` input. Dedicated service-account deployment, privileged Linux PAM-helper installation/testing, and managed-startup verification remain pending.

See [release notes](docs/release-notes.md) for limits and verification scope.
