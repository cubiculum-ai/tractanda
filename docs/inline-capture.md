# Capture categories in plain text

Inline capture is optional authoring: write category mentions in an item's body, review their interpretation, then save text and metadata together. Enable **Interpret #hashtags** in the terminal editor or **Interpret #categories** in the web editor and preview before saving. Normal saves and imported email, documents or code do not interpret hashtags. The original body stays intact.

Use `#Ready` for a simple name, `#[Needs attention]` for spaces, or `#[Deadlines/Tomorrow]` for a qualified category path. Categories may have editable aliases such as `#deadline-tomorrow`. Only existing categories you can currently read are eligible. Duplicate names require qualification or `#[category-uuid]`; unknown names do not create categories. Unresolved names, ambiguity, exclusions and date conflicts appear for review. Every issue must be resolved before the edit can save.

Escape literal mentions with a backslash: `\#literal`. Code spans/fences, URL fragments and Markdown link destinations remain literal. Reserved slash/bracket/backslash characters in names can be addressed by stable ID; brackets have no separate escaping language. Authoring limits fail explicitly without truncation. See [the exact API forms and limits](api.md#explicit-inline-capture).

## Dates come from category configuration

The name Tomorrow has no built-in meaning. Configure the category's **capture date property**, **day offset** and named **timezone** in the terminal category editor or through ordinary API properties. For example, a Tomorrow category can target an ordinary `plannedDate` field, add one calendar day and use `Europe/Vienna`. Another category may explicitly target `dueAt` or `startsAt`. Its own time-window rule determines subsequent membership.

Preview freezes a local calendar date, including midnight and daylight-saving transitions. It writes existing date-only tagged text containing `YYYY-MM-DD`; it creates no reminder, alarm or implicit deadline. Existing timestamps, differing dates or explicit field removals produce conflicts. Date capture does not permanently assign the item to Tomorrow: ordinary rules can select it as Tomorrow today and Today tomorrow. New conflicting manual pins require review; independent existing decisions remain authoritative.

With one configured Tomorrow category and ordinary Ready/Tractanda categories, this sentence can set `plannedDate` and assign both other categories:

```text
#tomorrow we’re #ready to implement hashtag references in #Tractanda
```

The optional starter template has both deadline and event Today/Tomorrow categories, making bare `#tomorrow` ambiguous. Use `#deadline-tomorrow`, `#event-tomorrow` or a qualified path. All template data is editable/deletable. Updated templates apply to new installations; existing categories are untouched and can be configured through TUI/API after deployment.

## Later edits and uncertain saves

An unchanged mention retains its stable binding through renames, case/NFC changes and body edits. Its date stays frozen after midnight; subsequent explicit date/category edits remain authoritative. Reused bindings are marked **no change**. A prior captured date is historical provenance, not a proposal to overwrite the current field.

Removing a hashtag removes text; existing assignments/dates stay intact. Reintroducing a removed tag requests fresh interpretation and can conflict with an existing date. Unassign or change dates explicitly. An advanced separate ordinary edit can clear capture provenance without deleting independent metadata.

Save publishes one guarded revision after current source/category/permission checks. After uncertainty, retain and retry the exact prepared plan; do not create another item or preview again as a retry. CLI `capture-preview`, `capture-commit` and `capture-note --preview` offer the same interpretation. Agents discover support through `tractanda_info` and the served items reference. See [the API contract](api.md#explicit-inline-capture).

## Workspace and deployment status

TRAC-062 is implemented in source. Installed poc.14 stays on its existing build and text corpus v6 until an explicit release/deployment request. This source uses corpus v7 to omit operative capture configuration/provenance from search while retaining meaningful aliases. At the next authorized deployment, normal derived-index/profile checks require reconstruction/reindexing from canonical content, preserving IDs, history, model choice and settings. No production store, index or category configuration was changed.
