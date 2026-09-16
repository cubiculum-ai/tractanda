# Changelog

## 0.1.0-poc.4

The property catalogue and agent guidance now describe timestamp tags explicitly, including activity-entry dates and original source creation/modification times. Nested element descriptions document field conventions without implying nested-array query support.

## 0.1.0-poc.3

Ordinary actions use notes and category assignments for to-do and waiting states. The redundant action subclasses are removed from the type catalog and terminal editor. `waitingOn` remains available on any item; the served API guidance and shared agent skill explain the category-based workflow.

The macOS release script uses Xcode's signed-in developer account for automatic notarization, with resumable uploads, package ticket stapling and Gatekeeper verification before installation or publication. A separate notarytool credential profile is unnecessary.

## 0.1.0-poc.1

Initial source-available proof of concept: immutable item revisions, rebuildable SQLite/FTS5 indexes, overlapping categories and views, terminal/JSON clients, stdio MCP, optional semantic retrieval, and an example browser client.

This checkpoint also documents the implemented co-located shared daemon: Unix API plus optional loopback HTTP and Streamable HTTP MCP, session/authentication boundaries, user-level managed registration, system-administrator policy, and opt-in semantic `item-text-utf8-v2` input. Dedicated service-account deployment, privileged Linux PAM-helper installation/testing, and managed-startup verification remain pending.

See [release notes](docs/release-notes.md) for limits and verification scope.
