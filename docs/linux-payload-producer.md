# Linux payload producer

`scripts/produce-linux-payload.py` is the tracked bridge from a frozen source tree and reviewed native ML components to the complete `package-linux.py` bundle. It builds the five core executables, stages resources and both local ML components, and invokes the full assembler. The default output is slim: pinned model metadata and worker binaries are included, while weights are omitted. Add `--include-model-weights` and supply both complete local model roots for an offline package. It never installs a package, creates a store/account, starts a service or publishes anything. `VERSION` is unchanged.

The checked-in `debian/linux-runtime-inputs.json` starts with **null embeddings and documents entries for both architectures**. `plan` reports those missing inputs. `produce` refuses them before discovering tools, hashing/copying models, creating work directories or launching a compiler. The slim mode changes only whether model files are included; it is not a core-only mode or runtime-admission bypass. This source unit is not a native producer execution result.

```
python3 -B scripts/produce-linux-payload.py plan --arch amd64
```

The registry is packaging input provenance, separate from the finite runtime identity table and actual Setup admission. A reviewed component's stable normalized manifest SHA-256 may later replace its null entry through a source change. A diagnostic receipt containing timestamps, PIDs and temporary paths is not that manifest. Rebuilding identical approved artifacts does not require pinning a new diagnostic run receipt.

## Component supply contract

Supply one real artifact directory and a separate JSON manifest for each of the fixed roles `embeddings` and `documents`. The directory contains **only** that manifest's entire final-payload-relative file inventory, including the helper, full private Swift/MLX/runtime closure, resources and notices. Model roots are optional for the standard slim package and required together with `--include-model-weights` for a full offline package; they remain separate read-only inputs. A component cannot replace core executables, models or public documentation. Shared final paths are allowed only with identical bytes, sizes and modes.

The manifest has exactly these fields; JSON object ordering/whitespace is immaterial. Its registry commitment is SHA-256 of UTF-8 JSON with sorted keys, `ensure_ascii=False`, separators `(',', ':')`, and no trailing newline. Duplicate keys, extra fields, unlisted files, links, special files, writable/special modes, oversized/count-exceeding files and normalization collisions are rejected.

| Field | Contract |
| --- | --- |
| `profile` | `tractanda.linux-component-artifacts.v1` |
| `component`, `arch` | Fixed role; `amd64` or `arm64` |
| `baseline` | Exactly `{buildOS: "debian13", minimumCPU: "x86-64" or "armv8-a", swiftABI: "6.4"}` |
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

Run natively on Debian13, once for each architecture; Kali/cross-build evidence is supplementary. The actual Swift toolchain entry point is explicit. `--mirrors` is a JSON object mapping **exactly** every root `Package.resolved` identity to an absolute real offline bare Git mirror directory. Full strict Git object validation must pass; each locked commit must exist and its version tag (`VERSION` or `vVERSION`) must match. Mirrors can be acquired separately under the existing acquisition/resource gates; this script never fetches them from the network.

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

Only the five newly built core binaries have RUNPATH set to `$ORIGIN/../lib` using Debian `patchelf`; before/after hashes and patcher bytes are retained. No supplied component is patched. SwiftPM resource directories are copied, exact approved component files merge, when requested, complete model roots are validated against the checked-in fixed-revision artifact catalog and the existing Granite helper/source Docling validators, and reviewed public assets use the same macOS projection. Any duplicate must remain byte/mode identical. The final D3 input is the existing exact `tractanda.linux-bundle-input.v1`; it binds stable source/component/tool/ISA/build-environment commitments. Actual recursive ELF/provider closure, licenses/model hashes, canonical capability declaration and the shipped Setup `plan --bundle` remain mandatory. No registry or descriptor assertion substitutes for them.

## Capacity, failure and acceptance

The estimate reserves source, the selected payload copies, compiler allowance, bounded directory allocation and metadata; full/offline mode includes the extra weight bytes in its estimate. Genuine filesystem-available capacity must preserve 10 GiB; purgeable space is not counted. Owned allocation/count/type and genuine reserve are checked before/through/after children and staging; the output allowance is withheld from work's cap and final combined allocation is checked. The soft child guards are not filesystem quotas. Later native execution still needs its environment/resource approval and sole-owner isolation.

`operation.json` is flushed before every child, with its command/log and then PID. The foreground runner owns timeout, termination and wait/reap, including failed/fast children; log growth is limited to 2 MiB. HUP/TERM uses the same failure cleanup. A host/runner SIGKILL is not a guarantee of child termination: retain the checkpoint and inspect the exact process group before recovery. No model/canonical data is erased automatically. Failure retains the exact disposable work/output paths for diagnosis, and no successful `result.json` is produced. After a successful reviewed unit, remove only those exact generated paths while retaining concise receipts and useful approved inputs/caches; measure real reclaimed space separately.

Both actual embedding `--describe` calls (input validation and the final reused D3 assembler probe) use that same owned-child path after capacity checks and private work creation: controlled environment, 60-second timeout, separate stdout capped at 64 KiB, bounded stderr log, durable command/PID checkpoints and process-group termination/wait. The temporary capture is removed after success or failure; an existing capture path is refused and retained. The existing exact pinned worker descriptor validation is unchanged. Standard slim builds validate the worker asset inventory against the checked-in fixed-revision catalog without copying weights; full/offline builds also verify every staged file size and hash. The shared descriptor helper and standalone assembler accept an optional runner solely for this call path; their default invocation behavior remains unchanged. No Docling describe API is introduced.

`result.json`, `source-inputs.json`, `bundle-input.json` and the complete admitted bundle feed `build-linux-deb.py`. Maintainer email remains an explicit operator input there; none is fabricated here. Actual native producer executions, Debian13 amd64/arm64 raster/inference/semantic parity, final finite runtime identity admission, complete `.deb` assembly, disposable dpkg/systemd lifecycle tests and package-size measurement remain required. Apt hosting and release/publication remain deferred.

Toolchain discovery has its own finite operator budget: `--toolchain-probe-timeout-seconds` defaults to 1800 seconds and applies to both pre-build and post-build Swift version/hash capture. The selected budget is recorded in source/final operation receipts. This accommodates slow machines without changing compiler identities, Debian13 baseline, closure validation, build deadline, locale or loader sanitization. Short packaging metadata commands retain their existing 60-second default.
