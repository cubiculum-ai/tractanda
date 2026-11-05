# Linux payload producer

`scripts/produce-linux-payload.py` is the tracked bridge from a frozen source tree and reviewed native ML components to the complete `package-linux.py` bundle. It builds the five core executables, stages resources and both local ML components, and invokes the full assembler. The default output is slim: pinned model metadata and worker binaries are included, while weights are omitted. Add `--include-model-weights` and supply both complete local model roots for an offline package. It never installs a package, creates a store/account, starts a service or publishes anything. `VERSION` is unchanged.

The input registry keeps separate approvals for Kali rolling and Debian 13. Kali rolling is the default. Its embeddings and documents entries are currently empty on both architectures, so `produce` stops before tool discovery, model work or compilation. Existing Debian 13 approvals retain their original identities and require explicit selection.

```
python3 -B scripts/produce-linux-payload.py plan --arch amd64
python3 -B scripts/produce-linux-payload.py plan --arch amd64 --build-os debian13
```

The registry is packaging input provenance, separate from the finite runtime identity table and actual Setup admission. A reviewed component's stable normalized manifest SHA-256 may later replace its null entry through a source change. A diagnostic receipt containing timestamps, PIDs and temporary paths is not that manifest. Rebuilding identical approved artifacts does not require pinning a new diagnostic run receipt.

## Component supply contract

Supply one real artifact directory and a separate JSON manifest for each of the fixed roles `embeddings` and `documents`. The directory contains **only** that manifest's entire final-payload-relative file inventory, including the helper, full private Swift/MLX/runtime closure, resources and notices. Model roots are optional for the standard slim package and required together with `--include-model-weights` for a full offline package; they remain separate read-only inputs. A component cannot replace core executables, models or public documentation. Shared final paths are allowed only with identical bytes, sizes and modes.

The manifest has exactly these fields; JSON object ordering/whitespace is immaterial. Its registry commitment is SHA-256 of UTF-8 JSON with sorted keys, `ensure_ascii=False`, separators `(',', ':')`, and no trailing newline. Duplicate keys, extra fields, unlisted files, links, special files, writable/special modes, oversized/count-exceeding files and normalization collisions are rejected.

| Field | Contract |
| --- | --- |
| `profile` | `tractanda.linux-component-artifacts.v1` |
| `component`, `arch` | Fixed role; `amd64` or `arm64` |
| `baseline` | Exactly `{buildOS: "kali-rolling" or "debian13", minimumCPU: "x86-64" or "armv8-a", swiftABI: "6.4"}`. The OS must match the selected registry and native producer. |
| `modelRevision` | Embeddings `44399559930365213510b1ee2eb15ded83374f0e`; documents `a8b999991fe8c521a0cec749973414eaaf823731` |
| `runtimeRevision` | `61a4b20d4ad01b10466e8fc94c50402a9f994430` |
| `sourceInputsSHA256` | Stable normalized source/dependency/actual patch and recipe/ISA/ABI commitments, excluding diagnostic run fields and generated expected-digest/identity-table source |
| `recipe` | `{path, sha256}` of the tracked component build recipe under `scripts/` or `Packages/` |
| `patches` | Array of additional `{path, sha256}` tracked recipe/patch inputs; include every applied runtime/native recipe and patch, not only its name |
| `toolchain` | Exactly `version`, `swiftSHA256`, `swiftFrontendSHA256`, `clangSHA256`; first line of Swift version must start `Swift version 6.4`; hashes are concrete tool bytes |
| `files` | Sorted, unique array of existing manifest entries `{path, sha256, size, mode}`; mode decimal 420 or 493 (0644/0755) |
| `dynamicLoads` | Explicit final-relative runtime `dlopen` roots present in `files`; empty only after actual full-component audit |
| `runtimeNotices` | Nonempty final-relative `licenses/` paths, all in `files` |
| `documentExtraction` | Null for embeddings; the exact approved existing document descriptor for documents |

Swift, Swift frontend and **Swift toolchain Clang** must match the core compiler and both supplied ML components. PDFium's independent pinned Chromium LLVM24 compiler is behind the private C ABI; its vendor compiler/sysroot/flags belong in the native provenance, not the Swift Clang field. The baseline object identifies build sysroot/ISA. It does **not** claim Debian13 inference or native ARM execution; those need separate actual receipts before registry/runtime admission.

The Docling component owns `bin/tractanda-document-converter`, `lib/tractanda/document-native-closure.json`, and both `lib/tractanda/document-native/libtractanda_docling_{pdf,images}.so.1`. Its private closure schema/authority stays in the reviewed R2 `LinuxNativeAdmission.swift`; the wrapper does not replace it. The versioned DSOs, exact closure bytes, original license/runtime patch/model provenance and exact existing descriptor must be included. No `--describe` endpoint is invented for Docling. Converter RUNPATH needs `$ORIGIN/../lib` and `$ORIGIN/../lib/tractanda/document-native`; raster DSO RUNPATH is `$ORIGIN`. The producer does not rewrite approved component bytes.

Native dependencies must be rebuilt or supplied using their reviewed **tracked** recipes and complete normalized artifact/provenance manifests. The R2 source candidate supplies `scripts/build-docling-linux-native.py` plus existing converter/runtime-patch recipes; source integration and real component artifact creation are still pending. R1 archive receipts alone are insufficient: thin archive members, native dependency sources/tools/patches, private/OS provider closure, licenses, and final runtime/model behavior must be accounted for. No downloading, automatic gclient sync or arbitrary input command is performed by this producer. Future approved components must not depend on manually recreating an untracked `work/` layout. The initial registry intentionally prevents using the staged R2 source receipt as runtime approval.

## Native invocation after admission

Run on native Kali rolling once per architecture after its component admission. The producer and component compiler accept `--build-os debian13` for secondary Debian 13 work. Assembly and packaging enforce the native baseline bound in the input and receipt. Use a concrete Swift toolchain path. `--mirrors` maps every root `Package.resolved` identity to an absolute, real offline bare Git mirror. Each locked commit and version tag must match. The producer operates offline.

```
python3 -B scripts/produce-linux-payload.py produce --arch amd64 \
  --swift /approved/swift/usr/bin/swift --mirrors /inputs/root-mirrors.json \
  --embeddings-manifest /inputs/embeddings.json --embeddings-root /inputs/embeddings \
  --documents-manifest /inputs/documents.json --documents-root /inputs/documents \
  --work /isolated/tractanda-build-new --output /isolated/tractanda-bundle-new \
  --max-work-bytes OPERATOR_CAP --build-allowance-bytes COMPILER_ESTIMATE
```

The two numeric placeholders must be positive byte estimates authorized for that environment, not literal strings. For a full/offline bundle, add `--include-model-weights --embeddings-model /models/granite-embedding-311m-multilingual-r2 --documents-model /models/granite-docling-258m-mlx`; both directories must be complete and pass the fixed manifest checks. Work/output must be fresh and disjoint from each other, the repository, supplied components and any supplied model roots. No active checkout is compiled or altered. The source snapshot includes actual dirty/untracked contents of `Sources`, `Tests`, local `Packages`, all `scripts` (including custom development test paths), root manifest/lock/version/registry and the same reviewed Git-index public assets as macOS. Generated `.build`, `.swiftpm`, `.git` and Python caches are excluded only from source capture. Sources have a 128 MiB logical cap; this does not lower or expand clustering fixture/production limits. Component recipe/patch commitments must agree with that snapshot. The repository source set is rechecked after compilation and final admission.

The fixed recipe builds `tractanda`, `tractanda-tui`, `tractanda-mcp`, `tractanda-auth-helper`, `tractanda-setup`, release configuration, jobs=1, locked versions, skip-update, local dependency URLs, private scratch/cache/config/security/home/module/temp directories and a finite environment. Host compiler/loader injection variables are not inherited. Normalized global C ISA is x86-64/armv8-a and Swift target CPU is generic. Relevant Debian development package versions, concrete compiler/Clang/patcher/Git bytes, source inputs and global flags are recorded. This is build provenance, not a claim that every compiler-used system header was independently captured.

Native SwiftPM release output uses `scratch/x86_64-unknown-linux-gnu/release` or `scratch/aarch64-unknown-linux-gnu/release`. Debian's library tuples (`x86_64-linux-gnu` and `aarch64-linux-gnu`) are used only for OS library resolution. The fixed output mapping is checked with both-architecture tiny fixtures, and the staged executable still undergoes actual ELF architecture validation.

The producer sets RUNPATH on its own freshly built executables and retains before/after hashes and patcher bytes. Supplied components keep their approved bytes. SwiftPM resources, approved component files, optional verified model weights and reviewed public assets follow the existing inventory checks. The `tractanda.linux-bundle-input.v2` commitment binds the native distribution/release, architecture, glibc and tools alongside the source, component, ISA and build environment. Recursive ELF/provider inspection and actual Setup bundle admission remain mandatory.

## Capacity, failure and acceptance

The estimate reserves source, the selected payload copies, compiler allowance, bounded directory allocation and metadata; full/offline mode includes the extra weight bytes in its estimate. Genuine filesystem-available capacity must preserve 10 GiB; purgeable space is not counted. Owned allocation/count/type and genuine reserve are checked before/through/after children and staging; the output allowance is withheld from work's cap and final combined allocation is checked. The soft child guards are not filesystem quotas. Later native execution still needs its environment/resource approval and sole-owner isolation.

`operation.json` is flushed before every child, with its command/log and then PID. The foreground runner owns timeout, termination and wait/reap, including failed/fast children; log growth is limited to 2 MiB. HUP/TERM uses the same failure cleanup. A host/runner SIGKILL is not a guarantee of child termination: retain the checkpoint and inspect the exact process group before recovery. No model/canonical data is erased automatically. Failure retains the exact disposable work/output paths for diagnosis, and no successful `result.json` is produced. After a successful reviewed unit, remove only those exact generated paths while retaining concise receipts and useful approved inputs/caches; measure real reclaimed space separately.

Both actual embedding `--describe` calls (input validation and the final reused D3 assembler probe) use that same owned-child path after capacity checks and private work creation: controlled environment, 60-second timeout, separate stdout capped at 64 KiB, bounded stderr log, durable command/PID checkpoints and process-group termination/wait. The temporary capture is removed after success or failure; an existing capture path is refused and retained. The existing exact pinned worker descriptor validation is unchanged. Standard slim builds validate the worker asset inventory against the checked-in fixed-revision catalog without copying weights; full/offline builds also verify every staged file size and hash. The shared descriptor helper and standalone assembler accept an optional runner solely for this call path; their default invocation behavior remains unchanged. No Docling describe API is introduced.

`result.json`, `source-inputs.json`, `bundle-input.json` and the admitted bundle feed `build-linux-deb.py`. Before releasing Kali packages, qualify the native components and producer on amd64 and arm64, run the required runtime/model checks, and verify actual package lifecycle in an isolated guest. The published poc.17.1 Debian 13 packages retain their original build receipts.

The `--toolchain-probe-timeout-seconds` budget defaults to 1800 seconds and applies to the pre-build and post-build Swift version/hash capture. The producer records the selected budget. Short packaging metadata commands retain their 60-second default.
