# Canonical item-file format: message-v1 (`.17`)

## Scope and version layers

A canonical item remains one self-contained file per immutable revision. The `.17` `message-v1` encoding uses a constrained message-style header block, a blank line, and an optional raw UTF-8 body. Writers use CRLF; readers accept LF or CRLF. It has no JSON item body and no hidden JSON duplicate of the revision fields. API method JSON and configuration JSON are separate formats and remain JSON.

Three version indicators have separate meanings:

| Indicator | Meaning |
|---|---|
| `X-Tractanda-Encoding: message-v1` | Physical representation of this file. |
| `X-Tractanda-Format-Version: 1` or `2` | Logical revision format. Existing rules remain: v1 is legacy and has no canonical ancestry; v2 requires `revisionAncestry`. |
| `schemaVersion` / `X-Schema-Version` | Item field schema version, a positive integer. It does not select the file encoding or revision format. |

New readers require floor 20 and capability `tractanda.message-items.v1`. This is distinct from the `.17` physical-layout floor of 19. The completed `canonical-layout.json` marker declares `recordEncoding: message-v1`; the store reader requirement records the floor/capability fence. Later readers must refuse stores without the completed transition. The one-time `.17` installer helper converts prior MIME/JSON record files; ordinary runtime reads do not convert legacy files.

The item field map is open, not a closed schema registry. Its recursive tagged value types are text, Int64, finite real, Boolean, date, list, object, reference, and bytes. `TractandaStore/describe properties` is explicitly non-exhaustive. Message-class identifiers such as `EmailMessageItem` do not introduce a closed set of fields.

## File structure

The codec uses message-style header syntax, not a general RFC 5322 mail parser. It accepts LF or CRLF line endings and one blank line before the body; bare CR in the header block is invalid. Header names are visible ASCII except colon. Readers match names case-insensitively. Writers use the spellings shown here and emit `Name: value` with one space after the colon. Readers remove at most one optional SP or HTAB separator after the colon; additional whitespace remains part of the value. They also accept continuation lines beginning with SP or HTAB and append their whitespace/text to the preceding value; writers do not fold headers. Duplicate scalar headers, malformed escapes, and malformed typed-field containers are rejected. Unrecognized header values follow the extension rules below.

```text
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: binary
X-Tractanda-Encoding: message-v1
X-Tractanda-Format-Version: 2
X-Body-Present: true
X-Body-Media-Type-Present: false
X-Item-ID: <item UUID>
X-Revision-ID: <revision UUID>
X-IsA: Item
X-Schema-Version: 1
X-Actor: user:<actor>
X-Operation-ID: <operation identity>
Subject: A "quoted" subject with a literal \ path

<exact UTF-8 body bytes>
```

`Content-Transfer-Encoding: binary` is required. `body` is emitted as raw UTF-8 without normalization, trimming, reflow, Base64, or an added newline. `X-Body-Present` preserves the difference between no `body` field and an explicitly empty body. `X-Body-Media-Type-Present` preserves the difference between no `bodyMediaType` field and a recognized explicit media type. Recognized values are `text/plain`, `text/markdown`, and `text/html`; absent type uses `text/plain` in Content-Type while retaining the absence flag. An unsupported or atypical `bodyMediaType` value stays in typed fields rather than being discarded by the media-type shortcut.

Simple built-in text headers such as `Subject` are written literally when safe; quotes and backslashes in those values are literal characters. Unsafe control-containing text is represented in typed fields. Typed header text escapes backslash, quote (inside quoted values), newline, carriage return, tab, and control characters. `\u{HEX}` represents a Unicode scalar. Neither path trims spaces or normalizes Unicode. Canonical output sorts object keys by UTF-8 order; list order remains significant.

The implemented record limit is 8 MiB for the complete header block and body.

## Readable headers for established fields

| Header | Field and value |
|---|---|
| `Subject` | `subject` text, emitted as a literal header value when safe. Backslashes and quotes are literal on this path. |
| `X-Item-ID`, `X-Revision-ID`, `X-IsA` | `itemID`, `revisionID`, `classID`. |
| `X-Supersedes` | Optional `supersedes` revision ID. |
| `X-Actor`, `X-Operation-ID` | Server-managed actor and operation ID. |
| `X-Created-At`, `X-Modified-At` | Typed date values, escaped without changing the timestamp text. |
| `X-Schema-Version` | Positive integer in decimal. |
| `X-Is-Deleted` | Optional `true` or `false`. |
| `X-Request-Identity` | Optional opaque exact retry receipt. If its text contains a control value that cannot be carried safely, it stays in the typed text extension. |

Built-in scalar headers appear at most once; header families declared as repeated below may repeat. Values are not coerced to text; a value that does not match a compact field form stays in typed fields when the revision is otherwise valid. Existing semantic validation still applies after decoding.

## Readable view headers

`viewDefinition` is an ordinary object shared by all item classes. Its known query and presentation fields use readable, repeatable headers:

| Header | Meaning |
|---|---|
| `X-View-Language` | Query language profile. |
| `X-View-Expression`, `X-View-Text` | Optional expression and literal search text. |
| `X-View-Include`, `X-View-Exclude` | Repeated current category IDs for `categoryPath` and `excludedCategoryIDs`; order is preserved. Each may carry a `; label="..."` display hint. |
| `X-View-Sort` | Repeated named-parameter rows, in sort order: `property=name; direction=ascending|descending` or `category=UUID; direction=...`. Category selectors may carry `label="..."`. |
| `X-View-Presentation` | Presentation profile, currently `tractanda.table.v0`. |
| `X-View-Column` | Repeated named-parameter rows: `property=name; title="Subject"; width=40` or `category=UUID; title="Status"; width=20`. Column order is preserved; category selectors may carry `label="..."`. |
| `X-View-Section` | Repeated current category IDs in section order; optional parameters `collapsed=yes|no`, `collapsed-order=N` (zero-based), and `label="..."`. No collapse state preserves an absent `collapsedSections` field; `collapsed=no` preserves an explicitly empty list. |

Representative readable view headers:

```text
X-View-Language: tractanda.spotlight.v0
X-View-Expression: subject == "Open"
X-View-Include: 018f8f2a-0000-1000-8000-000000000001; label="Active"
X-View-Sort: property=modifiedAt; direction=descending
X-View-Presentation: tractanda.table.v0
X-View-Column: property=subject; title="Subject"; width=40
X-View-Section: 018f8f2a-0000-1000-8000-000000000002; collapsed=no; label="Work"
```

Repeated header order preserves include/exclude, sort, column, and section list order. Labels are optional display hints only: IDs remain authoritative, and no category lookup by label occurs. Unknown parameters are rejected; unknown view keys and empty arrays remain in typed fields, so absence and explicit emptiness are distinguishable. Unknown keys inside a view column are retained.

## Structured known fields

| Field | Readable representation |
|---|---|
| `permissions` | `X-Permissions-Profile`, `X-Permissions-Owner`, `X-Permissions-Group`, `X-Permissions-Mode`, plus a typed `X-ACL-` subtree. The current profile is `tractanda.permissions.posix.v1`; mode uses four octal digits. |
| `revisionAncestry` | `X-Ancestry-Kind`, `X-Ancestry-Origin`, repeated `X-Ancestry-Parent`, `X-Ancestry-Written-Field`, `X-Ancestry-Unset-Field`, and `X-Ancestry-Frontier`, plus optional `X-Ancestry-Merge-Profile` and `X-Ancestry-Witness` (`recordID SHA-256`). It remains server-managed; logical revision format 2 requires ancestry. |
| `categoryParents` | Repeated `X-Category-Parent` current category IDs. |
| `categoryOverrides` | Repeated `X-Category-Override` rows with current category ID and escaped `include` or `exclude` value. |
| `attachments` | Repeated `X-Attachment` rows: attachment UUID, quoted display filename, media type, Int64 byte count, and SHA-256. The original payload remains outside the item file and is managed through the attachment lifecycle. |
| `activityNotes`, `activity` | No special header family is used. Their list/object values use typed extension headers; the documented convention is each element has `at` as a tagged date and `text` as tagged text. |

The encoder uses a compact known-field form only when the value matches the supported shape. Otherwise, an otherwise-valid tagged value stays in typed fields. This does not make semantically invalid field contents valid. Class identifiers such as `EmailMessageItem` select an item class; they do not define closed per-class field schemas.

## Typed extension fields

Top-level custom fields and nested object/list values use typed headers. The type names follow the current `ItemValue` union: `Text`, `Date`, `Integer`, `Real`, `Boolean`, `Reference`, `Bytes`, `Object`, and `List`.

```text
X-Field-Object: "custom"
X-Field-List: "values"
X-Field-Text: first
X-Field-Integer: 17
X-Field-End:
X-Field-End:
```

An object child carries its literal key as a quoted escaped value; a list element has no key and is appended in order. `X-Field-Object` and `X-Field-List` open a container; `X-Field-End` closes the innermost container. Writers emit an empty value after the colon-space on an end marker; readers accept optional SP or HTAB after the colon. An empty object or list is its opening header followed by `X-Field-End`; an empty text value is an explicit text header with an empty payload. A missing field has no representation.

For readability, the code block abbreviates empty end-header values as `X-Field-End:`. Canonical writer output is `X-Field-End: ` followed by CRLF.

`Reference` uses an item ID, optionally followed by `/` and a revision ID. `Bytes` use canonical Base64. Integer, finite real, Boolean, and date values retain their tagged types. Unknown top-level field names are quoted as data rather than converted into header names. Unknown `ItemValue` type tags are unsupported; adding a value type requires an explicit profile/capability decision.

Each node in a nested field tree emits a bounded number of headers, so representation size grows linearly with the value tree and encoded scalar bytes. No JSON object is carried as a duplicate of item fields.

## Optional retry receipt

`requestIdentity` is optional server-managed text in message-v1. Normal commits currently store Base64-encoded canonical JSON request bytes; automatic merges can encode ancestry JSON. Replay behavior compares the stored string exactly, so a retained receipt must survive byte-for-byte and must not be decoded and re-encoded as an equivalent object. The message form uses `X-Request-Identity` when the value is a safe literal; values with control characters use the typed text extension. The field is an operational replay receipt only: it contains no unique canonical item content and is the only canonical field this recovery path may discard opaquely. IDs, timestamps, actor, operation ID, parent references, permissions, ancestry, and ordinary fields remain readable and preserved.

During controlled recovery/rebuild from retained item history, the receipt may be omitted while the revision, history, current content, and new edits remain usable. A retry of the old operation ID then fails closed with `retryReceiptUnavailable`; the old operation is never re-executed and no duplicate effect occurs. Read the item or history to reconcile it, and use a fresh operation ID plus the current expected revision for any new edit. This optionality applies to message-v1 recovery; published `.16.2` records still require their historical receipt field.

## Legacy records, parsing, and edits

Existing `.16.2` records use the earlier MIME envelope with a typed JSON dictionary body. The `.17` external helper reads these legacy records, preserves logical revision formats 1 and 2, and writes `message-v1` while completing the recorded layout transition. For message-v1, header names are case-insensitive; duplicate scalar fields and malformed typed containers are rejected. Readers accept folded continuation lines and unreserved extension headers. Known reserved header families are decoded by their schema, while other unreserved `X-*` headers can carry text or repeated text values. The writer uses safe lower-case `x-*` extension headers for simple text values and typed `X-Field-*` containers for other values. Reserved names and malformed/reserved-family records are not treated as arbitrary extensions.

Canonical revision files are immutable history. For a content change, use the normal import or commit path so the system creates a new revision. For damaged storage or noncanonical file bytes, use a supported recovery/repair process with the exact backup and evidence; do not hand-edit a canonical file or use ordinary import as a byte-repair tool.

## Practical roundtrip and rejection matrix

Qualification checks compare decoded `formatVersion` and the complete field map, not only rendered text:

1. Roundtrip logical revision formats 1 and 2, identifiers, schema version, timestamps, supersedes, deleted state, and arbitrary top-level fields.
2. Preserve absent body, empty body, nonempty body, raw UTF-8 bytes, each recognized body media type, absent media-type metadata, and unsupported/atypical media type in typed fields.
3. Exercise every `ItemValue` type, nested object/list combinations, empty values, list order, object keys with spaces/quotes/controls, Unicode without normalization, canonical byte Base64, and references with and without revision IDs.
4. Roundtrip known structures: simple and extended POSIX ACLs; ancestry with optional merge profile/witness; category parents and overrides; multiple attachments; saved views with repeated include/exclude/sort/column/section headers, collapsed order, empty properties, and unknown view/column extensions.
5. Reject malformed or ambiguous records: missing required headers (including binary content-transfer encoding), duplicate scalar fields, duplicate object keys, unclosed containers, stray end markers, malformed escapes/tokens, noncanonical Base64, unsupported encoding, malformed reserved-family headers, compact-plus-extension duplicate fields, inconsistent body-presence flags, bare CR in headers, and byte-limit overflow. Verify LF/CRLF, optional whitespace after colons, folded continuation lines, and supported unreserved extension headers are accepted.
6. Migrate genuine `.16.2` fixtures through the external helper and compare IDs, logical version, complete field values, body bytes, and exact `requestIdentity`. Include historical records with absent/empty fields and noncanonical legacy header forms according to the bridge's documented parser contract. Separately remove an optional receipt from a disposable migrated copy, rebuild, verify reads/history/new edits, and confirm an old retry fails with `retryReceiptUnavailable` without reexecuting.
7. Verify that message-file encoding does not change API/configuration JSON, and that content edits create new revisions while repair/rebuild remains a separate operation.

The codec and external-helper behavior have focused source tests and private fixture evidence, including receipt-loss recovery and a combined bridge-to-Core review-state fixture. The review fixture uses synthetic old-format metadata reverse-encoded from a new-Core peer fixture; it is not evidence from a `.16.2` peer runtime. These fixtures cover source and private-store behavior. Distribution, host and cluster results are recorded separately with the corresponding release.
