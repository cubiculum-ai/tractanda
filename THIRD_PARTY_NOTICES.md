# Third-party components

Tractanda's first-party license does not replace dependency licenses. Package sources are fetched through SwiftPM at pinned revisions; model weights are not part of this repository. Keep applicable notices when distributing derived binaries.

## Core package

| Component | Pinned version | License reference |
| --- | --- | --- |
| SwiftNIO | 2.101.3 | [Apache-2.0 and bundled notices](LICENSES/swift-nio/) |
| Swift Log | 1.15.1 | [Apache-2.0](LICENSES/swift-log/) |
| Swift Crypto | 4.5.2 | [Apache-2.0 and bundled notices](LICENSES/swift-crypto/) |
| Swift ASN.1 | 1.7.2 | [Apache-2.0](LICENSES/swift-asn1/) |
| Swift Atomics | 1.3.1 | [Apache-2.0 with Swift exception](LICENSES/swift-atomics/) |
| Swift Collections | 1.6.0 | [Apache-2.0 with Swift exception](LICENSES/swift-collections/) |
| Swift System | 1.8.1 | [Apache-2.0 with Swift exception](LICENSES/swift-system/) |
| MCP Swift SDK | 0.12.1 | [Upstream licensing-transition notice and terms](LICENSES/swift-sdk/); the pinned source describes Apache-2.0 and retained MIT contributions |
| EventSource | 1.5.1 | [MIT](LICENSES/eventsource/) |

Exact revisions and repository URLs are in `Package.resolved`. The complete upstream license/notice texts copied from these dependency checkouts are retained under `LICENSES/`; the table is a navigation aid, not a replacement for those terms.

## SQLite and Vec1

SQLite is supplied by the operating system/package manager. Its FTS5 facility and SQLite-origin Vec1 are under SQLite's public-domain dedication. `Sources/CTractandaVec1/Vendor/vec1.c` retains its original public-domain statement and provenance comment. The surrounding portability wrapper is Tractanda code. No database or vector/model index is distributed as source content.

System PAM/UUID libraries are dynamically supplied by the platform and have their own package terms. The source package does not bundle those system libraries.

## Optional embedding host

`Packages/TractandaEmbeddings` pins upstream `osaurus-ai/vmlx-swift` at `61a4b20d4ad01b10466e8fc94c50402a9f994430`, which includes the merged tokenizer fixes [#487](https://github.com/osaurus-ai/vmlx-swift/pull/487) and [#514](https://github.com/osaurus-ai/vmlx-swift/pull/514); its resolved dependency graph is recorded separately. License/notice copies collected for that pin are retained under [LICENSES/optional-embedding-host](LICENSES/optional-embedding-host/), including vmlx, MLX-related native components and additional Swift dependencies.

Model weights must be obtained separately under the selected model's terms. Do not assume the runtime's license covers a model, tokenizer dataset or unrelated application material. Recheck the applicable notice set when updating a dependency or packaging a binary.


## Native Docling converter and model

The native converter uses `osaurus-ai/vmlx-swift` revision `61a4b20d4ad01b10466e8fc94c50402a9f994430`; its MIT license and collected MLX/runtime dependency notices are retained under [LICENSES/optional-embedding-host](LICENSES/optional-embedding-host/). The converter applies Tractanda's separately identified Idefics3 vision GELU precision patch (`idefics3-vision-gelu-f32-v1`) to that pinned runtime. The before/after source digests and patch digest are in [the runtime patch manifest](Packages/TractandaDocuments/RuntimePatches/manifest.json). This first-party patch remains subject to this repository's PolyForm Noncommercial License; that license does not replace the model or runtime notices.

Model assets are IBM Granite Docling 258M MLX, `ibm-granite/granite-docling-258M-mlx` revision `a8b999991fe8c521a0cec749973414eaaf823731`. The pinned Hugging Face revision declares Apache 2.0; IBM's [model card](https://huggingface.co/ibm-granite/granite-docling-258M) identifies IBM Research as developer and also states Apache 2.0. The pinned model revision, attribution, later conversion-provenance note and license copy are described in [the model notice](Packages/TractandaDocuments/ThirdPartyNotices/Granite-Docling-MODEL-NOTICE.md) and [Granite-Docling-LICENSE](Packages/TractandaDocuments/ThirdPartyNotices/Granite-Docling-LICENSE). No upstream `NOTICE` file was present in the pinned model snapshot. Its 14-file size/SHA-256 manifest is `Packages/TractandaDocuments/Sources/TractandaDocumentConverter/Resources/ModelAssets.json`.

The RGB resampler is Tractanda's Swift implementation derived from Pillow 12.3.0 resampling behavior, not copied Pillow C code. The Pillow MIT-CMU attribution and full license are in [the package notice](Packages/TractandaDocuments/ThirdPartyNotices/Pillow-LICENSE); this notice is separate from both the IBM model and vmlx runtime licenses.

## Bundled Granite embedding model

The preview bundles IBM Granite Embedding 311M Multilingual R2 at revision
`44399559930365213510b1ee2eb15ded83374f0e`. Model weights use Apache License 2.0.
IBM identifies its tokenizer as derived from Gemma 3, subject to the separate
Gemma Terms of Use, including the use restrictions in Section 3.2. Those component
terms apply to use and redistribution of the bundled tokenizer. The distribution
includes attribution, the model card, the Gemma terms and prohibited-use policy
under `licenses/Granite/`; their source copies are in [LICENSES/Granite](LICENSES/Granite/).
The model weights themselves are not in the source repository.
