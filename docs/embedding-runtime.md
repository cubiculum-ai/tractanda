# Local embedding runtime

The model is **IBM Granite Embedding 311M multilingual R2**, using a
separately built Swift host backed by vmlx-swift. Standard packages include the host and its
pinned artifact manifest, but omit the large weight files. When a configured worker starts, it
obtains missing files from the exact pinned revision, verifies each file's size and SHA-256, and
stores verified files in Setup-managed service-owned model storage (`/Library/Tractanda/Models`
on macOS and `/opt/tractanda/var/lib/tractanda/Models` on Debian). The cache is reproducible and
separate from canonical records and indexes. A full/offline package may
include those same files and is checked against the same manifest. No package build step
downloads model weights or follows a moving upstream revision. The native server sends bounded
requests to its loopback `/v1/embeddings` endpoint. The server keeps the Vec1 index
separate from its metadata/FTS index; model work does not change canonical item
files or block keyword/category access.

The model is pinned to `44399559930365213510b1ee2eb15ded83374f0e`. The runtime is
pinned directly to upstream `osaurus-ai/vmlx-swift` commit
`61a4b20d4ad01b10466e8fc94c50402a9f994430`, which includes the merged tokenizer
fixes [#487](https://github.com/osaurus-ai/vmlx-swift/pull/487) and
[#514](https://github.com/osaurus-ai/vmlx-swift/pull/514). No fork or separate
patch application is required for this pin.

The checked-in `config/model-artifacts.json` pins every embedding and Docling model file by
repository, immutable revision, relative path, size and SHA-256; each release carries the same
bytes as `models/manifest.json`, bound by its bundle manifest. The host verifies all nine
model/tokenizer/configuration files before loading. It computes in FP32, uses CLS pooling and L2 normalization, and returns
768 dimensions without adding query or document prefixes. `--describe` prints the
exact model/runtime identity, input limits and asset hashes without loading the
model. The model's 32,768-token limit is distinct from the server's initial
384-byte passages with 64-byte overlap. Longer passage tuning, adaptive MRL
retention and representative retrieval-quality benchmarks remain separate work.

The checkpoint stores BF16 weights; the pinned host converts model parameters to
FP32 before inference. The parameter values alone would occupy roughly 1.2 GiB
in FP32, but that is not the complete or peak MLX/Metal memory footprint. We have
no controlled low-RAM tests or measured Metal allocation peak; see [system
requirements](system-requirements.md) for provisional end-user memory and disk
guidance and the limits of the available process RSS snapshot.

The application chunks stored text into 384-byte passages with 64-byte overlap.
The embedding endpoint permits at most 16 nonempty inputs, limits each input to
32,768 tokens, and caps the aggregate batch at 32,768 tokens. The HTTP body is
limited to 2 MiB and at most two embedding requests are admitted concurrently.
The host evaluates the batch rows separately to avoid padding every row to the
longest input. These ceilings are not a default document-size target.

## Build and check

The source requires Swift 6.4. On macOS use Apple's full command-line developer
toolchain with Metal support. Current Linux source/CI checks use the official
Swift 6.4.0 Debian 13 (Trixie) multiarch image, pinned to index digest
`sha256:c90a484cbd45ff768e05bfdb2a73c4cc8978de0d940d8eb2cf68fcede6bad8f8`,
with amd64 and arm64/v8 variants. The Debian 12 inference results below are
historical runtime validation; the Trixie source validation did not build or run
the selected MLX embedding host.
On Debian-family Linux, install the CPU build and
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

The macOS release pipeline rebuilds this host from the sealed release source. Normal package
assembly does not fetch model weights. Model provisioning controls model-worker readiness, separate
from core service readiness. Without network access, provide a verified local artifact or use
a full/offline package. Linux uses the portable CPU backend and follows the same artifact
manifest and missing-file provisioning contract.

## Model files and status

Setup stores activated artifacts in service-owned storage, separate from release files and the
item/vector indexes:

| Platform | Release catalog | Model storage |
| --- | --- | --- |
| macOS | `/Library/Tractanda/Software/current/models/manifest.json` | `/Library/Tractanda/Models` |
| Debian | `/opt/tractanda/current/models/manifest.json` | `/opt/tractanda/var/lib/tractanda/Models` |

The storage tree has `incoming/<artifact-identity>/payload` for resumable partial files and
`artifacts/<identifier>/<revision>` for activated model files. A partial transfer is never treated
as ready. Activation appears only after every catalogued file matches its pinned size and SHA-256;
the identity marker is the sibling `artifacts/<identifier>/<revision>.verified.json`, outside the
model-file directory. This keeps the metadata out of strict embedding and document asset
enumerators. A tiny `.lock` and status record may remain under `incoming` to coordinate concurrent
workers; they do not contain another copy of the model weights.

Run operator commands as the existing `daemon` service account so files keep the correct
ownership. `status` reads local artifact state and progress; it is not a full content rehash.
`prefetch` verifies all expected bytes and downloads missing files; `import` verifies a complete
local copy without network access. The source directory given to `--adopt` or `--from` must
contain the model directories named by artifact ID.

```sh
# macOS
sudo -u daemon /Library/Tractanda/Software/current/bin/tractanda models status \
  --manifest /Library/Tractanda/Software/current/models/manifest.json \
  --storage /Library/Tractanda/Models

sudo -u daemon /Library/Tractanda/Software/current/bin/tractanda models prefetch \
  --manifest /Library/Tractanda/Software/current/models/manifest.json \
  --storage /Library/Tractanda/Models --adopt /path/to/existing-models

# Debian
sudo -u daemon /opt/tractanda/current/bin/tractanda models status \
  --manifest /opt/tractanda/current/models/manifest.json \
  --storage /opt/tractanda/var/lib/tractanda/Models

sudo -u daemon /opt/tractanda/current/bin/tractanda models import \
  --manifest /opt/tractanda/current/models/manifest.json \
  --storage /opt/tractanda/var/lib/tractanda/Models --from /path/to/offline-models
```

For an offline import, use `models import --manifest PATH --storage PATH --from DIRECTORY`; the
parent directory must contain `<artifact-identifier>/<relative-file>` for every file in each
selected artifact. Run the importer as the service account. Its source must be a symlink-free,
root- or service-owned tree with regular files and no group/other write access; an administrator
must stage user-owned downloads accordingly. A full/offline package supplies suitable files
without this manual staging. To select one artifact, add
`--artifact granite-embedding-311m-multilingual-r2` or
`--artifact granite-docling-258m-mlx`. The `--include-model-weights` packaging option builds a
full/offline bundle containing both complete pinned artifacts.

The daemon also exposes the read-only, locally authenticated native method
`TractandaModel/status` with empty arguments. It returns artifact phase, transferred bytes,
current file, error code and observation time. This method is not a remote peer operation or a
standalone MCP tool; use the CLI command above when the connected adapter does not expose local
native methods. Older installed releases may not implement it.

Artifact readiness and semantic-vector coverage are separate. `tractanda_semantic_status` reports
`indexableItems`, `indexedItems`, `pendingItems` and `coverage`; when semantic indexing is
configured, the maintenance worker retries provider failures and scans for missing or stale
current revisions after the embedding worker becomes ready. `pendingItems` can therefore remain
nonzero while indexing catches up, without blocking ordinary item reads or keyword search.
Store info reports document processing as `awaitingModel` while Docling is unavailable. New
start/resume requests return `modelUnavailable` and can be retried after readiness; they are not
silently accepted as new queued work. Previously accepted jobs retain their state and eligible
startup recovery resumes after model activation. Job inspection, cancellation and discard remain
available while the model is missing.

## Verification for this integration

For poc.11, this model passed real HTTP inference on macOS/Metal and in a Debian
aarch64 CPU container using Swift 6.4.2-dev, with the then-unmerged fixes pinned
through fork commit `b7a2b97efc2d8ed44ddf3c4b7af25766b372339f`. The upstream
repin retains byte-identical embedding, tokenizer and MLX core sources; unrelated
language-model cache changes also entered upstream. Revalidate the newly built
provider with the script above when packaging or changing platforms. The ten-input check includes
English/German/Japanese retrieval pairs, Devanagari and Bengali combining text,
and indented code. Native Tractanda/Vec1 integration also passed on both systems:
three disposable items indexed, English and German queries found the expected
item, citations verified and canonical files were unchanged. This is functional
validation; physical NAS/x86_64 performance and broader quality remain unmeasured.

## Upgrade and permissions

The macOS installer can update its own Qwen pilot or earlier Granite runtime
configuration to the pinned Granite profile. It uses a fresh UUIDv1 configuration identity and a guarded
update; derived vectors are rebuilt for the new embedding space. It refuses to
overwrite a custom configuration. Failed recovery retains its configuration
snapshot and blocks normal managed startup until an explicit installer retry.
Semantic status reports the current model, profile and indexing coverage.

Weights use Apache License 2.0. IBM identifies the tokenizer as Gemma 3-derived,
with separate terms and use restrictions. The package includes those notices and
shows the tokenizer terms in Installer. See [component notices](../LICENSES/Granite/README.md)
and [third-party components](../THIRD_PARTY_NOTICES.md).
