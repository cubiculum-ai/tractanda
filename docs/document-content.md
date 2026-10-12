# Canonical document content v2

Document extraction is versioned content on an ordinary item. Original payloads remain immutable. New saved extraction uses `tractanda.attachment-document.v2`; known v1 inline representations remain readable in immutable history. The current native converter bridge still has its older input/page limits until the paged job integration is completed. Storage support alone does not establish OCR accuracy or full search coverage.

## Item reference

The reserved `attachmentDocument` list contains at most 128 bounded descriptors. A v2 descriptor has `schema`, processing `state`, UUIDv1 `representationID`, current local `attachmentID`, immutable extraction `source`, `extractedAt`, converter `identity`, empty legacy `pages`, and `content`:

```json
{
  "schema": "tractanda.document-content.v2",
  "contentID": "UUIDv1",
  "manifestSHA256": "64 lowercase hexadecimal digits",
  "rootSHA256": "64 lowercase hexadecimal digits",
  "pageCount": 104,
  "totalEncodedBytes": 9600000,
  "coverage": {
    "converted": 103,
    "unsupported": 1,
    "truncated": 0,
    "timedOut": 0,
    "failed": 0
  }
}
```

Counts are checked nonnegative signed 64-bit integers. `totalEncodedBytes` sums exact page JSON bytes, excluding proof/manifest metadata. Coverage counts all terminal page outcomes; `complete` means every page passed structural conversion validation, while `partial` explicitly retains failed/unsupported outcomes. Neither state asserts that recognized text or table semantics are accurate. The reference describes immutable identity independently of future replica materialization availability.

## Canonical files and proofs

The UUIDv1 content identity is assigned after preparing the extraction, during publication. Its UTC timestamp determines:

```text
documents/content/YYYY/MM/DD/HH/mm/<contentID>/manifest.json
documents/content/YYYY/MM/DD/HH/mm/<contentID>/pages/<floor((page-1)/128)>/<page>.json
documents/content/YYYY/MM/DD/HH/mm/<contentID>/nodes/<level>/<floor(ordinal/128)>/<ordinal>.json
```

`tractanda.document-manifest.v2` stores content/publication IDs, original provenance, converter identity, extraction date, root level/encoded length/hash, page count, page-byte total and coverage. `publicationID` binds the unique private stage to its immutable candidate and prevents an identity collision from becoming a shared copy.

Each `tractanda.document-page.v2` file contains one 1-based page number, original SHA-256, terminal status, optional converted page, and optional failure code. Converted pages retain raw DocTags, parsed blocks/text, cropped raster SHA-256, geometry and generation-stop metadata. Core reparses raw output and validates its source units. Other outcomes contain no fabricated parsed output. Page bytes contain neither a current owner ID nor the local content/representation IDs, so copies retain exact page bytes and original provenance.

Each `tractanda.document-node.v2` file contains its level, ordinal and 1–128 entries. An entry has ordinal, first/last page, encoded length and SHA-256. Level zero authenticates page files; higher levels authenticate child nodes. Ranges and ordinals are contiguous. The compact manifest authenticates the root; a random page verifies at most nine bounded nodes and that page. Full closure verification visits each node/page in order with a bounded recursion stack. No all-pages hash array, raster array or whole-document string is required.

Page files have a 2 MiB working window; proof/manifest metadata has a 64 KiB window. These are bounded processing resources, not aggregate document-size limits. Runtime filesystem capacity comes from the same operator setting as original writes (`--attachment-minimum-free-bytes`, default 1 GiB reserve); scale fixtures separately require a genuine 10 GiB reserve and a 16 MiB cap. Capacity checks fail closed and do not count purgeable space.

## Publication and recovery

Work stays below private `documents/.staging`. Each dependency is synchronized and sealed; the complete hash tree is verified before preparation completes. A bounded immutable sibling publication receipt retains candidate identity across an uncertain reply or restart. Files and parent directories are synchronized before the complete tree moves atomically without replacement into chronological canonical storage. An identical publication retry repeats synchronization of both the canonical destination parent and the staging source parent before acknowledging the candidate. Only afterward may a fresh authorized CAS item revision refer to it. Failure may retain private work or unreachable immutable content; it never permits a revision to refer to missing output.

Daemon rebuild has immediate admin-only admission and bounded authenticated progress/cancellation (`tractanda.store-rebuild.v2`); it preserves the existing exclusive reader/producer drain. Interrupted dirty indexes are restreamed before startup admission, with no partially built SQL cursor reuse. Direct offline rebuilding remains synchronous. Rebuild verifies all historical content dependencies once per owning item/content identity, using disposable SQLite ownership/deduplication tables. Missing/corrupt canonical dependencies fail recovery. Converter/model execution is never part of rebuilding saved content.

## Reads, copies and export

`TractandaAttachment/document` defaults to bounded metadata for v2. An explicit `pageNumber` returns one `outcomes` entry, including its converted `page` when available. The legacy top-level `pages` array is empty for v2. Current permissions govern metadata, pages and historical selection.

Native feature `tractanda.attachment-document-content.v2` declares the bounded storage/read contract. `TractandaAttachment/documentContent` returns exact manifest/node/page bytes in a bounded window. Arguments are `itemID`, `attachmentID`, optional `revisionID`, `kind` (`manifest`, `node`, `page`), `level`, `index`, `offset` and `limit` (1–262144). For nodes, index is the node ordinal; for pages, index is the 1-based page number. Reachability is authenticated from the item reference, not inferred from a filesystem name. Results include content ID, relative path, exact byte count/hash, byte offsets, base64 bytes and completion state. No client filesystem path is accepted.

Daemon copies prepare originals and page trees off the Store queue, retain bounded intent/receipt recovery state, and publish only after fresh source readability and exact source CAS checks. Same-intent retries join the bounded task; native clients wait through short cancellable requests. Uploads and copies share `--attachment-staged-byte-quota`. Actual private original bytes, page/proof/manifest bytes and uncommitted copy intent/receipt bytes are charged before bounded writes. Startup streams filesystem metadata and reconstructs those counters, retaining canonical dependencies published by an interrupted copy until its final item CAS completes. Pending uploaded originals likewise retain their charge through physical publication until item CAS/replay/disposal; validated upload intents rebuild those counters on restart. Actual upload checkpoint bytes are charged separately from a 16 KiB reserved replacement window, which keeps bounded tombstone/cleanup possible after a quota reduction. A synchronized completion marker releases that copy's recovery budget; committed operation replay repairs a missing marker after fresh target authorization. A failed partial write may conservatively retain its charge until disposal or restart recounts the actual bytes. This aggregate operator quota is separate from the filesystem free-space reserve and imposes no format-sized document ceiling.

Copies include only active, hash/size/media-matching representations from selected current content. Local original/content/representation IDs and physical files are independent; original extraction provenance is retained. Detached/stale output remains in source history and is excluded from the copied state.

`tractanda export-item SOCKET ITEM_ID DESTINATION_DIRECTORY` captures one current revision and exports `revision.json`, each active original as `<attachmentID>.original`, and each active v2 representation's exact canonical manifest, reachable hash nodes and page outcomes under `document-content/<contentID>/`. The relative paths inside each content directory are the canonical `manifest.json`, `nodes/<level>/<bucket>/<ordinal>.json` and `pages/<bucket>/<page>.json` paths. The revision's representation maps attachment/representation IDs to that local content ID and retains converter/source provenance. Inline historical representations remain in `revision.json`; inactive representations have no exported dependency tree.

Every dependency read pins the captured revision and uses current server permission checks. A later readable head does not change the export snapshot. Unavailable, denied, incomplete, mismatched or corrupt dependencies abort the private adjacent stage; the destination is published only after original hashes, canonical closure/coverage and fsync checks pass, without replacing an existing file, directory or symlink. Reads use <=256 KiB windows, retain <=64 KiB proof nodes and one <=2 MiB page outcome, and traverse the format's at-most-nine proof levels with at most128 entries per frame. There is no whole-document page ceiling or RAM buffer. Unsupported, truncated, timeout and failed outcomes retain their exact stored bytes. Export never follows source provenance into foreign/historical item dependencies: copied content uses its current local content ID.

This is a selected-current export, not a full-store backup or an import/roundtrip contract, and it does not promise reconstruction of an original `.emlx` signature.

## Implementation locations

- Portable schema/read values: `Packages/TractandaClient/Sources/TractandaClient/{AttachmentDocument,DocumentContent}.swift`.
- Canonical tree/proofs and descriptor-relative I/O: `Sources/TractandaCore/{DocumentContentStore,DocumentContentFiles}.swift`.
- Publication, authority, copy and recovery: `Sources/TractandaCore/{Store,AttachmentCopy,StagingByteQuota,Service,ServiceCoordinator,Index}.swift`.
- Atomic directory move: `Sources/CTractandaPlatform/{Platform.c,include/TractandaPlatform.h}`.
- Storage and integration checks: `Tests/TractandaCoreTests/DocumentContent{Storage,Integration}Tests.swift`.

Paged converter/jobs, page FTS/semantic projection and export/client completion remain explicit integration boundaries until their respective units pass.

Rebuild status and its latest-job private journal are implemented in `Sources/TractandaCore/StoreRebuild.swift`, using portable `StoreRebuildStatus` in `Packages/TractandaClient/Sources/TractandaClient/StoreRebuild.swift`. The controller checks explicit GCD cancellation between bounded work units and file/directory synchronization entries; a separate durability-entry counter records that productive phase. HTTP session identity/admission bypasses the occupied Store queue with fresh OS lookup against the unchanged admitted policy. Shutdown requests cooperative stop before awaiting maintenance. The controller does not rely on a parent Task's cancellation state. Status writes are at most 16 KiB. A cancelled dirty rebuild requires restreaming recovery, while cancellation during the initial producer/reader drain can leave the prior index trusted. An uninterruptible syscall or SQLite statement remains stopping until it returns. The journal is operational recovery metadata, not canonical user content or a resumable SQL cursor.
