# Terminal item search

Press `F` or `Ctrl-F` in Views, the item report or Categories, use forwarded `Cmd-F`, or choose View → Search items (Text / Semantic). Enter a query; Tab focuses Mode, arrows select Text or Semantic, and Enter or Ctrl-S submits. The optional Spotlight expression narrows either mode. Ctrl-F still moves right inside editing fields.

Search results are temporary and cover all currently readable items independently of the selected view or category. No SavedView is created or modified. Text mode uses native full-text querying and ordinary bounded paging. The saved-view editor keeps its own selection/filter editor.

Semantic search runs in the background after explicit submission. Status distinguishes pending, ready, failed, unavailable, expired/invalidated and partial coverage. Escape from results or a newly submitted query cancels prior work locally; old replies cannot replace the current screen. Query and mode edits remain drafts until submission, so canceling the popup preserves a pending search. An unavailable semantic service retains your query: press F and explicitly choose Text.

Semantic results preserve native similarity order, retain the first passage for each item, and show its score/snippet with normal item preview and navigation. The server returns at most 64 passages, so these are top matches with no further semantic pages. Scores are similarities, not probabilities. Partial coverage means some current readable content has no indexed embedding. Current item reads omit inaccessible, deleted or revision-mismatched passages. Selection and clock revalidation run in the background without re-embedding; the ranked list remains a refreshing snapshot while detailed preview and passages are withheld, and rapid navigation keeps the newest selection. Native get continuations are bounded, and the client retains at most 16 MiB of full revisions; oversized or omitted hits are counted visibly.

F changes query/mode; R refreshes; A clears search and opens All items; Escape or Back returns to the previous context. Category drafts and the prior workspace's focus, selection and paging are retained and return reads use current authorization. A blank query and expression clears search. Search does not change your saved view.

These changes remain in source until an explicitly requested release/deployment. The bundled `/manual` and in-terminal Help contain the same invocation and limitations.
