# TractandaClient

Portable Swift 6.4 client and presentation behavior for Tractanda's **experimental native protocol**. This package has no SQLite, PAM, terminal or GUI dependency. It compiles for macOS, Debian and the matching Swift WebAssembly SDK.

- `ItemTransport` sends one UTF-8 native method envelope asynchronously.
- `ItemClient` validates responses, returns consistent server-ordered pages, and submits guarded immutable revisions.
- `ItemEditorDraft` patches only edited fields and preserves unknown metadata. Class changes request retyping without replacing item identity.
- `ItemWorkspace` owns selection, category paths, paging, editing and retry state on `MainActor`. Views perform writes only from explicit actions.
- `PendingEditStore` records a frozen request before sending. Restoring a pending edit never submits it. Existing items are reauthorized before recovered content is displayed.
- `HTTPItemTransport` uses URLSession on macOS/Linux. Browser WebAssembly supplies a fetch transport; local IPC and secure file recovery are supplied by `TractandaCore`.

This is not a conforming network JMAP implementation. The current methods and capability remain those in [the local protocol document](../../docs/api.md).

```sh
swift test --package-path Packages/TractandaClient
```

The project verification scripts also run these tests with project-local caches. See [build and test](../../docs/build.md) and [release limitations](../../docs/release-notes.md).
