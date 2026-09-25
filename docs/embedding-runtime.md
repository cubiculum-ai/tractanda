# Local embedding runtime

The bundled model is **IBM Granite Embedding 311M multilingual R2**, using a
separately built Swift host backed by vmlx-swift. The native server sends bounded
requests to its loopback `/v1/embeddings` endpoint. The server keeps the Vec1 index
separate from its metadata/FTS index; model work does not change canonical item
files or block keyword/category access.

The model is pinned to `44399559930365213510b1ee2eb15ded83374f0e`. The runtime uses
upstream `osaurus-ai/vmlx-swift` main `e07bd67becffb4718004c3db076ee8c153ef7f92`,
plus tokenizer fixes [#487](https://github.com/osaurus-ai/vmlx-swift/pull/487) and
[#514](https://github.com/osaurus-ai/vmlx-swift/pull/514), through the exact
`rcfa/vmlx-swift` commit `b7a2b97efc2d8ed44ddf3c4b7af25766b372339f`.

The host verifies all nine original model/tokenizer/configuration files before
loading. It computes in FP32, uses CLS pooling and L2 normalization, and returns
768 dimensions without adding query or document prefixes. `--describe` prints the
exact model/runtime identity, input limits and asset hashes without loading the
model. The model's 32,768-token limit is distinct from the server's initial
384-byte passages with 64-byte overlap. Longer passage tuning, adaptive MRL
retention and representative retrieval-quality benchmarks remain separate work.

## Build and check

The source requires Swift 6.4. On macOS use Apple's full command-line developer
toolchain with Metal support. On Debian-family Linux, install the CPU build and
check prerequisites (in addition to Swift):

```sh
sudo apt-get install g++ gfortran libopenblas-dev liblapack-dev liblapacke-dev \
    libsqlite3-dev libpam0g-dev pkg-config curl jq python3
```

From the repository root, choose a new local model directory:

```sh
sh scripts/download-granite-runtime-assets.sh /path/to/granite-model
swift build -c release --package-path Packages/TractandaEmbeddings
sh scripts/validate-granite-runtime.sh \
    Packages/TractandaEmbeddings/.build/release/TractandaEmbeddingsHost \
    /path/to/granite-model
```

The validation script uses a temporary loopback listener, checks its process
identity, and tests multilingual retrieval, dimensions and normalization. It uses
public sample texts, never the production store. A successful smoke check is not
a production-quality benchmark. For container builds, keep SwiftPM scratch data
and checkouts on the container's own filesystem, rather than a host-shared mount.

The macOS release pipeline rebuilds this host from the sealed release source and
runs its model checks before packaging. A downloaded macOS package needs neither
a compiler nor another model download. Linux uses the portable CPU backend; a
supported Linux installer and runtime dependency bundle remain in development.

## Verification for this integration

The same pinned model passed real HTTP inference on macOS/Metal and in a Debian
aarch64 CPU container using Swift 6.4.2-dev. The ten-input check includes
English/German/Japanese retrieval pairs, Devanagari and Bengali combining text,
and indented code. Native Tractanda/Vec1 integration also passed on both systems:
three disposable items indexed, English and German queries found the expected
item, citations verified and canonical files were unchanged. This is functional
validation; physical NAS/x86_64 performance and broader quality remain unmeasured.

## Upgrade and permissions

The macOS installer can replace its own Qwen pilot configuration with the pinned
Granite profile. It uses a fresh UUIDv1 configuration identity and a guarded
update; derived vectors are rebuilt for the new embedding space. It refuses to
overwrite a custom configuration. Failed recovery retains its configuration
snapshot and blocks normal managed startup until an explicit installer retry.
Semantic status reports the current model, profile and indexing coverage.

Weights use Apache License 2.0. IBM identifies the tokenizer as Gemma 3-derived,
with separate terms and use restrictions. The package includes those notices and
shows the tokenizer terms in Installer. See [component notices](../LICENSES/Granite/README.md)
and [third-party components](../THIRD_PARTY_NOTICES.md).
