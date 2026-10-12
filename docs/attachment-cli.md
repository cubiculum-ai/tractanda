# Resumable attachment and document-job CLI

This interface is unreleased source. Source integration and focused fake-transport checks are independent of native model readiness and installed application deployment.

Large originals use a retained regular file descriptor, a bounded SHA-256 pass and chunks of at most 256 KiB. File size and offset use Int64; no original is loaded into one Data value. FIFO, directory and final-component symlink sources are rejected without waiting for a writer. The initial hash reads only the initial stat length plus one EOF sentinel; growth and per-chunk stat changes produce an explicit fileChanged error. Reopening after interruption verifies content size and SHA-256. Device/inode/stat metadata is ephemeral handle verification, never persisted cross-reboot identity.

The normal connection resolver supports either positional SOCKET or leading --profile/--default/--socket options. The configured default may select production; the receipt implementation does not hardcode a profile name.

```text
tractanda --profile NAME attachment begin ITEM_ID EXPECTED_REVISION OPERATION_ID FILE [MEDIA_TYPE]
tractanda --profile NAME attachment resume RECEIPT_ID
tractanda --profile NAME attachment status UPLOAD_ID
tractanda --profile NAME attachment abort RECEIPT_ID_OR_UPLOAD_ID

tractanda attachment SOCKET begin ITEM_ID EXPECTED_REVISION OPERATION_ID FILE [MEDIA_TYPE]
```

`begin` saves and prints the receipt before calling the server. It retains the exact bounded request, including operationID (an idempotency identity, not a credential), so a lost admission reply can replay exactly. A successful admission saves and prints uploadID before any file bytes. Begin performs admission only; resume sends remaining data and makes one finish request.

`resume` first queries known server state and replays the persisted begin intent. After expiry, an identical begin intent may admit a fresh server handle; it is durably saved and printed with an explicit restarted event before data. A new-handle persistence failure attempts an abort of only that new uncommitted handle and reports recovery errors while retaining the previous receipt. Begin's offset is the authoritative received byte position; uploadStatus.verifiedBytes is integrity hash progress and must never be used as a transfer offset. Already committed replies and verifying/verified/published stages reconcile without requiring the local original to exist. Remaining transfer reopens and hashes the recorded source before sending bytes, checks each acknowledgement, and atomically records its offset. Receipts survive connection failures, verification-in-progress replies and revision conflicts. Verification is observable with status and a later explicit resume; the command has no automatic polling loop.

A changed source or revision conflict requires a deliberate decision. Abort the retained upload before beginning a changed intent. Uploads have no rebase API; the CLI never creates a fresh operation identity or silently rebases publication. Document jobs have their separate explicit rebase command below.

Receipts live in the current user's application support directory under Tractanda/CLI/AttachmentUploads. Directory traversal is anchored with no-follow descriptors, the final directory is owner-only 0700 and files are owner-only 0600. Files are limited to 16 KiB and at most 64 receipts are retained. Replacements synchronize bytes, rename atomically, and synchronize the parent directory. The receipt stores no credentials or file body. Its selected socket path is a connection fence, not a canonical database UUID; an endpoint change requires explicit selection of the original connection and cannot establish immutable database provenance by itself.

```text
tractanda --profile NAME document-job start ITEM_ID EXPECTED_REVISION ATTACHMENT_ID OPERATION_ID
tractanda --profile NAME document-job status JOB_ID
tractanda --profile NAME document-job list [AFTER_JOB_ID|-] [LIMIT]
tractanda --profile NAME document-job cancel JOB_ID
tractanda --profile NAME document-job resume JOB_ID
tractanda --profile NAME document-job rebase JOB_ID EXPECTED_REVISION
tractanda --profile NAME document-job page JOB_ID PAGE_NUMBER
tractanda --profile NAME document-job discard JOB_ID
```

Each document-job command makes one request. List returns one window (default 32, maximum 64). Page accepts a positive Int64 ordinal and returns exactly one provisional stage page. Provisional output has no canonical saved revision/content identity or citation. Successful document processing coverage establishes terminal outcomes across inspected pages; it is not an OCR accuracy claim. Rebase changes publication expectation while retaining original source revision and accepted pages; cancel retains work and discard explicitly disposes only authorized uncommitted stages.
