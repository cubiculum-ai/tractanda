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

## Optional macOS embedding host

`Packages/TractandaEmbeddings` pins `osaurus-ai/vmlx-swift` at `d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee`; its resolved dependency graph is recorded separately. License/notice copies collected for that pin are retained under [LICENSES/optional-embedding-host](LICENSES/optional-embedding-host/), including vmlx, MLX-related native components and additional Swift dependencies.

Model weights must be obtained separately under the selected model's terms. Do not assume the runtime's license covers a model, tokenizer dataset or unrelated application material. Recheck the applicable notice set when updating a dependency or packaging a binary.

## Optional bundled Qwen embedding model

The macOS preview may bundle Qwen3-Embedding-0.6B at revision `97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3`. The weights remain under Apache License 2.0, independently of Tractanda's first-party license. The distribution includes the license, attribution and provenance under `licenses/Qwen3/`. Model weights are not part of the public source repository. See the [pinned model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B/blob/97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3/README.md).
