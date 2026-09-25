# Bundled Granite embedding model

Model: IBM Granite Embedding 311M Multilingual R2.
Source: https://huggingface.co/ibm-granite/granite-embedding-311m-multilingual-r2
Pinned revision: `44399559930365213510b1ee2eb15ded83374f0e`.

The nine runtime files are copied without modification. Original BF16 model
weights have SHA-256 `dcb6431bfa6e817fe100a2b0521360cec3383963b03fa966b685de18ca310d31`.
The host verifies every weight, tokenizer and configuration input before loading.
Computation uses FP32, CLS pooling and L2 normalization, returning 768 dimensions.

The weights use Apache License 2.0 (`LICENSE`). IBM's original model card is
`MODEL_CARD.md`. Its tokenizer attribution identifies a Gemma 3-derived component,
subject to Google's separate terms. `NOTICE`, `Gemma-Terms.html` and
`Gemma-Prohibited-Use-Policy.html` accompany that component. The use restrictions
in Section 3.2 are incorporated into the terms for using and redistributing the
bundled tokenizer. Tractanda's first-party license does not replace these terms.

Terms sources, retrieved 25 September 2026:
https://ai.google.dev/gemma/terms
https://ai.google.dev/gemma/prohibited_use_policy
Google Developers page content is provided under CC BY 4.0 unless otherwise noted;
local notice copies preserve the legal text and link to its source.

Runtime: osaurus-ai/vmlx-swift main `e07bd67becffb4718004c3db076ee8c153ef7f92`
with PR #487 and #514, pinned through rcfa/vmlx-swift at
`b7a2b97efc2d8ed44ddf3c4b7af25766b372339f`. Runtime notices are separately
retained under `licenses/optional-embedding-host/`.
