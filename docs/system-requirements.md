# System requirements

## Downloaded macOS preview

The macOS application targets **Apple Silicon (M1 or later) and macOS 15 or later**. Mac packages are arm64-only. Older bundled-model packages contain their selected assets; check the particular release notes. Packages built from the current source still include the server, clients, model workers and their pinned catalog, but omit large model weights by default. When a configured worker starts, it fetches missing files from the exact pinned revision and checks each size and SHA-256. Installation and core service startup do not wait for network model downloads; semantic indexing may show partial coverage until the embedding model is ready, while ordinary item reads, keyword search and synchronization remain available. A full offline package can include verified weights with `--include-model-weights`. Packaged macOS installations require no separate Xcode, Swift, Python or Java installation to run; installation requires normal macOS administrator authorization. See the [model runtime guide](embedding-runtime.md) for storage, status, prefetch and offline import.

## Memory planning

There is **no validated hard minimum for RAM**. As a provisional recommendation for running Tractanda alongside ordinary desktop applications, use a Mac with **16 GiB of unified memory**. Treat 8 GiB as constrained and untested, not as a certified minimum. 24–32 GiB provides additional room for heavier multitasking, imports and agent workloads; that is a comfort tier, not a measured requirement.

This recommendation applies to a Mac running the Tractanda server and bundled embedding service. Remote clients do not host that model. If you also run a local generative model, budget its memory separately.

The included model has 311 million parameters. Its on-disk weight file is BF16; the serving host converts model parameters to FP32. Storing all parameter values in FP32 alone is roughly 1.2 GiB, before tokenizer data, inference activations, MLX/Metal workspaces, allocator caches, the operating system and other applications. This arithmetic is not a peak-memory measurement. We do not have controlled 8 or 16 GiB tests or a measured MLX/Metal peak. A process RSS snapshot does not capture the complete unified-memory footprint, so it should not be used as the model's RAM requirement.

The application indexes stored text in 384-byte passages with 64-byte overlap. The host accepts up to 16 inputs per request and caps the aggregate batch at 32,768 tokens; it evaluates each input separately. These are serving limits, not a promise to index a 32,768-token document in one passage. See [embedding runtime details](embedding-runtime.md).

## Storage planning

The signed installer and tar archive for the historical `0.1.0-poc.13` Apple Silicon release were each about 499 MiB; its installed release directory was about 736 MiB, including roughly 627 MiB of model assets. Those bundled-release measurements do not size packages built from the current slim source, and the old **5 GiB** storage suggestion does not include the current model-provisioning reserve.

Model provisioning preserves **10 GiB of genuine filesystem-available space** plus the bytes it must stage. The checked-in catalog's embedding and Docling artifacts total 1,298,329,978 bytes (about 1.30 GB / 1.21 GiB). If both artifacts are absent from the service-owned model cache, plan for at least that amount in addition to the 10 GiB reserve—roughly 11.21 GiB available before additional headroom. A verified local source or full offline package avoids network retrieval, but its files may still need a separate service-owned cache copy. This is a capacity calculation from pinned asset sizes, not a measured minimum or final installer-size estimate. Canonical records, SQLite indexes, logs, document working data and backups require additional space that depends on the store; back up canonical stores separately.

Attachment support copies originals into the canonical store. Its runtime payload/export writes retain a 1 GiB reserve of genuine filesystem-available bytes, in addition to the bytes being written. That working-data guard is separate from model provisioning's 10 GiB reserve. Development attachment fixtures retain their own conservative 10 GiB reserve; this is not an additional product disk requirement. That attachment workflow was absent from the historical poc.13 release.

Docling accounts for 640,444,815 bytes (about 610.8 MiB) of the combined pinned model total
above; this is not an additional amount to add to that total. With model provisioning, those
assets are shared per host/revision instead of duplicated in every slim software release.
Its converter/resources and document working data require additional space.
This is a measured asset-size total, not a final installer size or peak-memory estimate. The
combined embedding/document runtime has no controlled unified-memory peak measurement;
the provisional RAM guidance above has not been revalidated for simultaneous conversion.
Document scratch/preparation and durable job state survive uninstall independently of unused
release cleanup. See [bundled document installation](install.md#bundled-native-document-extraction).

## Source builds and Linux

Building the core from source requires Swift 6.4. The complete macOS application targets macOS 15 or later. The embedding host can be built separately; on macOS it uses Apple's developer toolchain and Metal, while the portable Linux host uses a CPU backend. The Debian packaging workflow targets amd64 and arm64; the recent private managed installation and three-node cluster validation includes native amd64 Linux. That does not establish that current-source packages for both architectures are publicly downloadable. Final release artifacts, their size checks and the signed APT repository remain release work. The new slim model-provisioning changes are not deployed or published yet. Linux embedding inference has also been functionally checked in a Debian 12 container, but that check alone is not an end-user package requirement. See [embedding runtime build and checks](embedding-runtime.md) and [Linux package lifecycle](linux-package-validation.md).

On 1 October 2026, a separate source validation passed on Debian 12 ARM64 with Swift 6.4.0: the package build, 93 focused Core tests, all 189 TUI tests, 20 portable client tests, and native attachment lifecycle and UTF-8 extraction checks. This run did not rebuild or exercise the currently selected `osaurus-ai/vmlx-swift` embedding host. That historical run did not qualify the Linux installer, managed runtime or x86_64 platform.

On 2 October 2026, the current portable source passed a second validation on Debian 13 (Trixie) ARM64 with official Swift 6.4.0. It built the package and passed 98 focused Core tests, 23 MCP tests, all 189 TUI tests, 20 portable client tests, and guarded native attachment and extracted-text CLI fixtures. The pinned official multiarch image index is `sha256:c90a484cbd45ff768e05bfdb2a73c4cc8978de0d940d8eb2cf68fcede6bad8f8`; only its ARM64 variant was executed. This validates the portable source toolchain, not the `osaurus-ai/vmlx-swift` embedding host or Linux installer/managed-runtime packaging. That historical run did not qualify Linux x86_64.
