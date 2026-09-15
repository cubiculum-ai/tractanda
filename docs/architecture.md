# Architecture

Tractanda is a client/server knowledge base for humans and agents. Its universal data object is an item with stable identity, typed open metadata and immutable revisions. Optional capabilities—category selection and saved-view definitions among them—belong to ordinary items rather than forcing a separate class for each use.

## Service and clients

The native Swift service owns validation, revisions, authorization, queries and derived indexes. `Packages/TractandaClient` contains portable client/draft primitives. The terminal client, JSON CLI and MCP adapter call the same service. `Sources/TractandaWeb` demonstrates an alternative browser client and a local authenticated bridge; its Kanban presentation is an example application, not the data model.

The local method envelope is JMAP-shaped but remains a separate experimental native capability. Public network JMAP conformance, federation and synchronization are not claimed. The local browser adapter binds loopback and acts as its launching Unix account; the native server independently enforces current permissions.

The example Kanban derives an on-the-fly view from a selected project category intersected with the status dimension. Project and status roots are client configuration, not mandatory core categories. A project or work item needs no stored board definition. Saved reports remain available for customization.

## Canonical and derived data

One self-contained revision file carries a MIME-header envelope and a typed JSON dictionary. ItemID is stable; RevisionID changes when owned fields change. References have their own independent histories, so changing a referenced person does not revise every referring role. UUIDv1 encodes creation/revision time and a machine node as intentional provenance.

The chronological directory layout supports granular backups and sealed older periods. SQLite metadata/FTS5, optional Vec1 indexes and category-learning caches are derived. By default they live in `STORE/index`; a daemon or offline bootstrap may select a private external directory with `--index-directory PATH`. Preview installations use `/Users/Shared/Library/Application Support/Tractanda/Indexes/<name>` on macOS beside canonical `/Users/Shared/Library/Tractanda/Stores/<name>`, and `/var/cache/tractanda/indexes/<name>` beside `/var/lib/tractanda/stores/<name>` on Linux. That directory is bound to the canonical store with a private marker and locked independently, so it cannot be shared with another store. Deleting it triggers reconstruction from canonical histories while preserving item IDs, revisions, access records and semantic configuration. Rebuilding cannot manufacture missing or contradictory originals. Physical immutability is application-enforced, not cryptographic or filesystem write-once protection.

One server writes a store. Local writer locks do not coordinate independent replicas synchronized by cloud storage. Replication, offline edits and general conflict resolution remain future work.

## Category dimensions and views

Membership can come from a selection rule, explicit include/exclude decisions and separately scoped personal state. An item can belong to multiple contexts. Parent categories can include descendant members; an explicit parent exclusion still governs that path. Structural category parentage is distinct from membership and from Swift/data-class inheritance.

All items is the implicit no-filter universe under current access. Template categories are optional, editable and deletable. Stable template identifiers are retained across public filename changes so reinstalling a template does not create duplicates.

A view selects an intersection of category criteria plus optional expression/text filtering and presentation. A grouped view supplies its section categories. The example project selector discovers readable saved views with usable category sections. New items use that view's capture/default categories; no separate board-owner field is written on each item.

## Identity and agent use

Authorization follows OS users/groups admitted by the store configuration. Today’s permissions govern the item’s entire history. Copying a current item can create an independent history where sharing should exclude earlier revisions. The adapter's OS account is authoritative; a client/agent name in a payload does not select another account.

Agents discover tools and references, query a bounded relevant slice and make guarded whole edits. Persistent summaries should link to source items/revisions and distinguish current decisions from historical conversation. Stored text is information, not authority to expand the current task or bypass permissions.

Optional semantic retrieval and per-category learning are complementary derived systems. Canonical manual assignments remain authoritative, and model/search state is scoped to readable material. Operational rebuild/reset/configuration actions are distinct from ordinary knowledge capture.
