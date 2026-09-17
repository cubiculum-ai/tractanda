# API and agent integration

Use executable help and `TractandaStore/describe` as the operational reference for this experimental API. The local capability is `https://tractanda.ai/ns/local-prototype/4`, not a published network JMAP extension.

`Item` is the concrete generic class and the superclass of the specialized families. `classID == "Item"` selects generic items; `kMDItemContentTypeTree == "Item"` includes all classes. Older prototype clients using capability `/2` must be updated and reconnected before using this server.

## Native API and daemon

The native CLI sends ordered JSON method calls over a Unix socket:

```sh
tractanda call /tmp/tractanda-demo.sock TractandaItem/query \
  '{"expression":"subject ==[cd] \"*design*\"","limit":16}'
tractanda get /tmp/tractanda-demo.sock ITEM_ID
```

The envelope is `{ "using": [CAPABILITY], "methodCalls": [[METHOD, ARGUMENTS, CALL_ID]] }`; the CLI unwraps one result. Socket peer credentials establish the caller—arguments cannot select another actor. The CLI, TUI and `tractanda-mcp SOCKET` stdio adapter continue to use this Unix route.

The daemon adds optional loopback HTTP in the same process:

```sh
tractanda daemon STORE SOCKET --index-directory INDEX_DIRECTORY --http-port 48728
```

`STORE` and `SOCKET` are separate positional arguments. Omit `--index-directory` to retain the compatible `STORE/index` layout; its selected external directory may contain only derived SQLite/FTS, Vec1 and learning-cache files. `--no-http` is native-only. The optional presentation parameters are exactly `--view ID` or `--project-root ID --status-root ID [--project ID]`.

## HTTP authentication and MCP

HTTP `/auth/login` accepts an OS username and password, then `/api` and `/mcp` require its bearer token. On macOS the password path uses OpenDirectory. Linux arbitrary-user verification needs the separate privileged PAM helper deployment; its host installation and real credential tests are pending. Do not run the daemon as root merely for PAM.

`TractandaAuth/createSession` is special only on the native socket: an envelope with that one method and empty arguments issues the peer's **own** session token. It rejects UID selection. The same method over HTTP does not mint a token.

`/mcp` implements Streamable HTTP JSON. A session is bound to the authenticated principal; sessions and in-flight requests are bounded globally and per user, expire when idle, and are re-authorized on each request. There is no SSE endpoint or event replay. Clients initialize with HTTP POST, retain `Mcp-Session-Id`, and may DELETE that session. stdio MCP remains a separate local adapter.

For stdio, omit `--profile` to use the configured default. `--profile default` selects a literal profile with that name; it is not a special default alias. User defaults precede the system default, and several local aliases may resolve to one socket. The adapter captures that selection at startup; restart it after changing connection settings.

`tractanda_info` adds `connection` diagnostics: `transport`, the selected `profile`/`profileSource` and `socketPath` where applicable, expected server account, adapter identity and `referenceRevision`. Native-call failures retain this local block with `status: "error"` and the original error, without cached server facts. A successful response has `status: "ready"`; when native feature `tractanda.runtime-identity.v1` is declared, `server` contains release version, executable SHA-256 when readable, process ID and process instance ID. A source build without a matching bundle manifest reports version `development`; its digest distinguishes builds but does not prove feature support. The integrated HTTP adapter reports `transport: "inProcess"`, with no fabricated socket/profile, and cannot answer while its server process is down.

Native `TractandaStore/info` returns a `features` array of versioned behavior IDs. This build declares `tractanda.runtime-identity.v1` and `tractanda.semantic-job-timing.v1`. These identify API support, not authorization or model availability. The MCP adapter compares fresh declarations with its `requiredServerFeatures` in `connection.referenceCompatibility`: `satisfied` when all listed requirements are declared, `missingFeatures` plus `missingServerFeatures` when a valid declaration omits them, `unverified` when the declaration is absent/invalid, and `unavailable` when native info failed, and `protocolMismatch` when the reachable native server explicitly rejects the adapter capability with `unsupportedCapability`. This distinction does not establish which side is older. Extra unknown feature IDs are ignored. Skew does not make otherwise successful info a tool error. Neither build hashes nor cached declarations substitute for current feature support. An advertised feature with missing required fields is a contract violation; undeclared support is unverified.

MCP reference resources are compiled into the adapter, while `tractanda_describe` is served by the native backend. References remain static during an adapter process; this preview advertises neither resource subscriptions nor list-change notifications. Restart/reinitialize after an upgrade and refresh discovery. The initialize version includes build and reference digests; `connection.referenceRevision` is the full reference-text cache key. If only the native server restarted, its process instance changes independently of the stdio adapter.

## Permissions and administration

All reads, writes and history requests use current item permissions; changing access affects historical visibility too. OS identity and group membership are refreshed per request. An optional `AccessConfigurationItem` has profile `tractanda.access.v1`; `administration: "system"` recognizes root plus `admin` on macOS or `sudo` on Linux, unless `administratorGroup` overrides the OS group. Without an access configuration, legacy `serviceOwner` administration remains in effect pending migration.

## Guarded changes and compact retrieval

Saved views are a capability of ordinary items carrying `viewDefinition`; no dedicated view class is needed. `viewDefinition.presentation.sections` is an ordered list of category references. Saved-view clients preserve that order. Implicit project boards use it as a preferred sequence and append other eligible status leaves; otherwise, they traverse the Status hierarchy with siblings ordered by integer `categoryOrder` (default zero), then name and ID. Status names are data, not built-in client behavior.

A category with the valid selection expression `itemID == ""` has no direct rule matches, allowing shared/manual or personal assignments to determine membership; child categories can still contribute inherited members. Shared `categoryOverrides` live on the target item. A caller-owned `PersonalStateItem` has an unpinned `target` reference and `personalOverrides`, taking precedence for that caller. Removing a personal override falls back to shared decisions/rules. These operations change categorization, never access rights.

Ordinary actions use `Item` and category assignments for to-do, waiting and other workflow states. Change membership to change those states; no class transition is needed. Every item may carry `waitingOn` as a tagged reference to a person/event or explanatory text, or leave it unset. Category rules and manual overrides determine membership independently of that property. Discover supported concrete types with `TractandaStore/describe` (`topic: "types"`).

Kanban preserves native query order. The optional sample Project definition sorts by Priority **category membership**. Project-specific `viewDefinition.sort` and `presentation` override those defaults independently, without inheriting selection criteria. With neither definition supplying a sort, normal modified-time order applies. Priority, urgency, work type, assignment and optionality are categories; the client does not write parallel scalar fields. `sortOrder` remains optional ordinary metadata only for explicit saved sorts and is never populated by browser saves.

In the TUI view editor, enter `category:<axis UUID>` as a sort or column target; ordinary field names continue to address owned metadata.

A query sort has up to four distinct targets: `{"property":"modifiedAt","isAscending":false}` or `{"categoryRootID":"<axis UUID>","isAscending":true}`. Category comparators use effective membership in ordered immediate children (`categoryOrder`, name, ID). Descendants inherit into that branch; multiple matches take the first branch. A root exclusion wins, and unranked items stay last in either direction. In canonical `viewDefinition.sort` and `presentation.columns`, `categoryRootID` is a tagged current reference. A column chooses either `property` or `categoryRootID`, with its usual title/width.

`TractandaCategory/memberships` (MCP `tractanda_memberships`) accepts 1–64 `ids`, 1–8 `categoryRootIDs` and optional `at`. It returns `state`, ordered `roots`/children, `memberships[itemID][rootID]` as matching category IDs, and non-disclosing `notFound`. This is an ephemeral ACL-filtered projection, never an item property. A childless root returns its own ID when included. Use a fixed clock and compare state across batches.

Web edits preserve untouched absent fields and unknown metadata. Clearing existing text explicitly stores empty text; API `unset` removes it. The client writes subject/body/workingNotes, checklist content and changed category overrides only. It does not materialize empty fields or inject dependencies/order values on an unrelated edit.

Tagged values include text, integer, real, boolean, date, bytes, reference, list and object. Use a persisted `operationID` and exact payload; an uncertain mutation is retried with both unchanged. IDs are nonempty text of at most 200 UTF-8 bytes with no NUL characters, scoped to store and authenticated actor. A definite pre-commit rejection does not consume an unused ID, so corrected arguments may reuse it. Reconcile any earlier uncertain attempt first. An exact replay returns `replayed: true` and the original committed revision, not a newer head; current read permission still applies. `unset` is required even when it is `[]`. Existing updates also require the current `expectedRevisionID`. Changes replace whole top-level fields, so fetch and merge a map before replacing it.

Use `date` for timestamps, even though both date and text values are serialized as strings. For `activityNotes` and `activity`, each list element is a tagged object with `at` as a tagged date and `text` as tagged text. For example, `at` can be `{"type":"date","value":"2026-09-08T14:15:34.048628+00:00"}`. The property catalogue returned by `TractandaStore/describe` documents the nested element types as conventions; arbitrary additional fields remain supported.

Imported source times belong in ordinary `originalCreatedAt` and `originalModifiedAt` date fields when known. The service-managed `createdAt` and `modifiedAt` describe the Tractanda item itself. Leave unknown times unset. Dates require an ISO 8601 timestamp with a timezone: do not invent a time or zone for an imprecise source date. Date-tagged values support date comparisons and are omitted from full-text extraction. The current query grammar addresses top-level fields and scalar lists, not nested activity object arrays.

Get/history support `full`, `content`, `summary`, or explicit top-level `properties`. Get is byte-bounded: follow ordered `remainingIDs`, handle `oversizedIDs` with a narrower projection, and compare state. An omitted projected property is not an unset field.

`state`/`queryState` cover the administrator's store, or an ordinary caller's readable revision set and group context. They are not scoped to the query result or a pinned snapshot. Keep `at` and `timeZone` fixed across relative-date pages. Per-item revision guards decide whether an edit conflicts; an unrelated state change does not require repeating committed imports or abandoning a batch of known item IDs.

`tractanda_get` and `TractandaItem/get` take an `ids` array, even for one item. Single-item explain/history/revision/resolve calls take `itemID`; `itemIDs` is not an alias.

## Literal and semantic search

`text` is a literal FTS5 phrase, not raw FTS syntax. It searches subject, body, and owned tagged-text metadata: for example `workingNotes`, `checklists`, `labels`, and arbitrary custom text fields. `tractanda.item-text.v3` emits subject/body first, then sorted root fields; object keys sort and list order remains. The following exclusions apply **only at the root**:

`itemID`, `revisionID`, `classID`, `schemaVersion`, `createdAt`, `modifiedAt`, `supersedes`, `actor`, `operationID`, `requestIdentity`, `isDeleted`, `permissions`, `accessConfiguration`, `categoryOverrides`, `personalOverrides`, `categoryParents`, `selection`, `viewDefinition`, `learningFeedback`, `learningSettings`, `developmentUUIDMigration`, `templateKey`.

Empty or whitespace-only text values are omitted together with their field labels. Nonblank values retain their original bytes. A nested ordinary field with one of those names remains owned text. Extraction never traverses references or reads bytes, attachments, or remote content. Named metadata SQL predicates are a separate query mechanism.

Semantic retrieval is optional and uses the same owned-text corpus as FTS5. The single input encoding is `item-text-utf8-v2`; the earlier subject/body-only prototype mode has been removed. The current extraction rules are `tractanda.item-text.v3`. Extraction-rule versions participate in the semantic profile identity, so a rules upgrade rebuilds the disposable vector index without changing the model, canonical records or item history. Before asserting semantic coverage, agents should inspect `TractandaSemantic/status`, especially `inputEncoding`, `itemTextProfile`, coverage and index counts. LSM query behavior is unchanged.

Semantic configuration, rebuild and reset are administrator operations. The embedding endpoint is an operational loopback configuration, not a query-supplied URL. Semantic filtering still applies current permissions and the same category/query constraints.

With native feature `tractanda.semantic-job-timing.v1`, semantic search starts a caller-scoped job with a fixed **120-second lifetime from creation**. Successful search and pending/ready/failed result states include `createdAt` and `expiresAt`; pending states also include `retryAfterMilliseconds` (currently 500), a polling interval rather than a prediction of remaining latency. The `at`/`timeZone` evaluation clock does not affect expiry, and polling never renews it. Jobs live in native-server memory: the same principal may resume polling after a stdio adapter restart, but a native-server restart loses them. Model/profile changes and index reset/rebuild may invalidate jobs earlier. Retain your query's expiry: `notFound` errors omit timing and deliberately do not distinguish expired, unknown or foreign jobs. Start a new search. Without the feature declaration, do not assume newer compiled adapter documentation describes the connected server.

## UUID node policy

UUIDv1 values intentionally encode a time and node provenance value. Production must use a real eligible host node (or explicitly configure the issuer node where hardware identity is unavailable). CI's synthetic node exists solely for disposable test fixtures and must never be copied into production configuration.
