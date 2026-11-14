# Reusable memory and catch-up

Use this guidance when an agent needs to preserve or revisit useful context in a connected Tractanda store. Discover the instance's categories and saved views first. Use ordinary `Item`s, categories, references and views; read the served item/query references for exact fields, query grammar, and current capabilities.

## Capture useful context

Record decisions, preferences, evidence, open questions and handoffs with their source, date and confidence where useful. Keep provenance clear: distinguish a user's decision from an observation, inference or imported claim. Prefer a concise durable record over a transcript dump. Avoid duplicates, low-value activity logs, and repeating facts already maintained in a canonical item. Do not create duplicate status/priority fields when the instance already represents those concepts with categories.

Optional reusable view names may include **Knowledge**, **Decisions**, **Preferences**, **Evidence**, **Questions**, **Handoffs**, **Changed today** and **Recent changes**. Treat these as suggestions, not a required taxonomy; adapt, save or delete views to fit the instance and user's workflow. Ad hoc queries are fine. Personal **Seen**/**Unread** category overrides are manually maintained convenience labels: do not promise that a new revision automatically marks an item unread or that reading a view acknowledges its entries.

Inbox or recipient categories are labels for discovery. The underlying item permissions govern who can read or change content. Agents act through the connected OS user account or authenticated session and its ordinary ACLs, like other users; an agent name does not create an identity, separate authorization layer or provisioning workflow. Ordinary shared folders, chats and email remain ordinary workflows, not Tractanda-specific orchestration.

## Since-last-visit catch-up

Keep a small checkpoint in the agent's existing durable working state, scoped to the relevant store/account and query scope. It is not global server state. Query items created or modified at or after the last successful read cutoff, using only timestamp predicates supported by the connected server's served query grammar. Start with a user-relevant bounded window or project on the first run; broaden with an explicit date, text or semantic query when needed.

Use the query's returned `evaluatedAt`, or the start time of the successful query, as the next cutoff, not the time the query finishes. Hold the same `at` and `timeZone` across pages when the API exposes them. Process the intended scope before advancing the checkpoint. An inclusive boundary may return an item again; compare item and revision when useful. If the read is incomplete or unstable, keep the old checkpoint and report the limitation rather than advancing it.

This timestamp view is a convenience heuristic. Late offline arrivals can have old timestamps and may be missed; deletions are not necessarily represented. Do not treat it as a changefeed, complete audit history or guarantee of catch-up, and do not add an elaborate replay protocol. A view read does not mark every result acknowledged; avoid a global shared `lastAccess` field.
