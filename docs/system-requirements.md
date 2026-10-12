# System requirements

## Downloaded macOS preview

The packaged application supports **Apple Silicon (M1 or later) and macOS 15 or later**. The downloadable release is arm64-only; it does not support Intel Macs. The bundle includes the server, clients, Granite Embedding 311M multilingual R2 model and vmlx-swift host. Installing and running the download does not require Xcode, Swift, Python, Java or a separate model download. Installation requires normal macOS administrator authorization.

## Memory planning

There is **no validated hard minimum for RAM**. As a provisional recommendation for running Tractanda alongside ordinary desktop applications, use a Mac with **16 GiB of unified memory**. Treat 8 GiB as constrained and untested, not as a certified minimum. 24–32 GiB provides additional room for heavier multitasking, imports and agent workloads; that is a comfort tier, not a measured requirement.

This recommendation applies to a Mac running the Tractanda server and bundled embedding service. Remote clients do not host that model. If you also run a local generative model, budget its memory separately.

The included model has 311 million parameters. Its on-disk weight file is BF16; the serving host converts model parameters to FP32. Storing all parameter values in FP32 alone is roughly 1.2 GiB, before tokenizer data, inference activations, MLX/Metal workspaces, allocator caches, the operating system and other applications. This arithmetic is not a peak-memory measurement. We do not have controlled 8 or 16 GiB tests or a measured MLX/Metal peak. A process RSS snapshot does not capture the complete unified-memory footprint, so it should not be used as the model's RAM requirement.

The application indexes stored text in 384-byte passages with 64-byte overlap. The host accepts up to 16 inputs per request and caps the aggregate batch at 32,768 tokens; it evaluates each input separately. These are serving limits, not a promise to index a 32,768-token document in one passage. See [embedding runtime details](embedding-runtime.md).

## Storage planning

For the `0.1.0-poc.13` Apple Silicon release, the signed installer and tar archive were each about 499 MiB. The installed release directory was about 736 MiB, including the approximately 627 MiB model asset set. For a download and install or upgrade, **plan for roughly 5 GiB of free disk space**. This is a practical headroom recommendation, not an enforced installer limit or a measured minimum; an upgrade can retain earlier release directories until safe cleanup. Canonical records, SQLite indexes, logs and backups use additional space that depends on the store. Back up canonical stores separately.

The pending attachment feature copies originals into the canonical store. Its runtime payload/export writes retain a 1 GiB reserve of genuine filesystem-available bytes, in addition to the bytes being written. That working-data guard is separate from the roughly 5 GiB installation recommendation. Development attachment fixtures retain a separate conservative 10 GiB reserve; this is not a product disk requirement. The feature has not been deployed in poc13.

The pending native Docling payload adds exactly 640,444,815 bytes (about 610.8 MiB) of pinned
model assets per retained release, plus its converter/resources and document working data.
This is a measured asset-size total, not a final installer size or peak-memory estimate. The
combined embedding/document runtime has no controlled unified-memory peak measurement;
the provisional RAM guidance above has not been revalidated for simultaneous conversion.
Document scratch/preparation and durable job state survive uninstall independently of unused
release cleanup. See [bundled document installation](install.md#bundled-native-document-extraction).

## Source builds and Linux

Building the core from source requires Swift 6.4. The complete macOS application targets macOS 15 or later. The embedding host can be built separately; on macOS it uses Apple's developer toolchain and Metal, while the portable Linux host uses a CPU backend. Linux embedding inference has been functionally checked in a Debian 12 container, but there is no supported Linux installer or managed runtime package, so these checks do not define an end-user Linux system requirement. See [embedding runtime build and checks](embedding-runtime.md).

On 1 October 2026, a separate source validation passed on Debian 12 ARM64 with Swift 6.4.0: the package build, 93 focused Core tests, all 189 TUI tests, 20 portable client tests, and native attachment lifecycle and UTF-8 extraction checks. This run did not rebuild or exercise the currently selected `osaurus-ai/vmlx-swift` embedding host. Linux installer and managed-runtime packaging, and x86_64 validation, remain unproven.

On 2 October 2026, the current portable source passed a second validation on Debian 13 (Trixie) ARM64 with official Swift 6.4.0. It built the package and passed 98 focused Core tests, 23 MCP tests, all 189 TUI tests, 20 portable client tests, and guarded native attachment and extracted-text CLI fixtures. The pinned official multiarch image index is `sha256:c90a484cbd45ff768e05bfdb2a73c4cc8978de0d940d8eb2cf68fcede6bad8f8`; only its ARM64 variant was executed. This validates the portable source toolchain, not the `osaurus-ai/vmlx-swift` embedding host or Linux installer/managed-runtime packaging. Linux x86_64 validation remains unproven.
