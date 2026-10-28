# TractandaClient

Portable Swift 6.4 client and presentation behavior for Tractanda's **experimental native protocol**. This package has no SQLite, PAM, terminal or GUI dependency. It compiles for macOS, Debian and the matching Swift WebAssembly SDK.

- `ItemTransport` sends one UTF-8 native method envelope asynchronously. Implement `discoveryContext()` when its endpoint or authentication can change; its returned identifier partitions discovery. Otherwise call `ItemClient.invalidateSession()` before reusing the client with a changed context.
- `ItemClient` uses `https://tractanda.ai/ns/jmap/1` and discovers one logical-store account through `TractandaSession/get`. It caches that explicit local document per transport/authentication context, injects the account into account-scoped methods, preserves explicit `accountId` and `#accountId`, and refreshes after metadata-state changes before the next call. Discovery is single flight under concurrent requests; mutations are never replayed to refresh discovery. The public HTTPS Session/resources are separate pending work.
- `itemRecords` returns standard read DTOs with separate `properties` and `fieldProperties` selectors. Supplying maxBytes explicitly selects `TractandaItem/getBounded`; full-content `items` intentionally uses that bounded extension. `revision(itemID:revisionID:)` reads the RevisionID collection and verifies the item identity. Unresolved DTOs retain resolution with null content, never an invented representative. `ItemQuery` emits standard filter/comparator arguments and intentionally requests totals.
- The transport contexts encode canonical tagged integers as decimal strings only at declared method argument paths. Read DTO wrappers decode themselves; typed facades decode declared capture/sharing/resolve extension result slots separately. Use the explicit `.wire` argument mode for already-wire JSON, including MCP tools and CLI rawcall; checked export forwarding preserves its exact wire envelope. Canonical bytes and intent hashes are unchanged.
- `ItemClient` validates responses, returns consistent server-ordered pages, and submits guarded immutable revisions. Mutations return a compact `MutationReceipt` with confirmed `itemID`, `revisionID`, `operationID`, replay/index status and finite diagnostics. Acknowledge recovery before refreshing; content is read separately with `revision(itemID:revisionID:)` using the returned immutable revision. A refresh failure does not make a confirmed save uncertain. Retain the exact operation ID and intent after an uncertain error.
- Explicit `prepareCapture(CapturePreparation)` / `commitCapture(CapturePlan)` authoring calls use shared server interpretation and retain the frozen plan for retries. Ordinary commits do not parse hashtags. See the [capture/API contract](../../docs/api.md#explicit-inline-capture).
- `ItemEditorDraft` patches only edited fields and preserves unknown metadata. Class changes request retyping without replacing item identity.
- `ItemWorkspace` owns selection, category paths, paging, editing and retry state on `MainActor`. Views perform writes only from explicit actions.
- `PendingEditStore` records a frozen request before sending. Restoring a pending edit never submits it. Existing items are reauthorized before recovered content is displayed.
- Browser WebAssembly supplies a fetch transport; local IPC and secure file recovery are supplied by `TractandaCore`. A native HTTP client transport will be selected when an actual caller requires it.

This is not a conforming network JMAP implementation. The current methods and capability remain those in [the local protocol document](../../docs/api.md).

```sh
swift test --package-path Packages/TractandaClient
```

The project verification scripts also run these tests with project-local caches. See [build and test](../../docs/build.md) and [release limitations](../../docs/release-notes.md).
