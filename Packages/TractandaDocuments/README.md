# Native Docling package

Build the source-only macOS converter through the reproducible entry point:

```sh
python3 scripts/build-docling-native.py \
  --scratch work/docling-smoke-20261001/.build \
  --cache work/docling-smoke-20261001/.cache/spm \
  --config work/docling-smoke-20261001/.config/spm \
  --security work/docling-smoke-20261001/.security/spm
```

The helper resolves all supplied paths against the invoking working directory before calling Swift. It retains upstream vmlx revision `61a4b20d4ad01b10466e8fc94c50402a9f994430` and applies only the exact source patch in [RuntimePatches/manifest.json](RuntimePatches/manifest.json). It refuses unknown revisions, changed patch bytes and foreign target-source changes, and preserves the checkout file's mode. Repeated application is idempotent. A plain Swift build of an untouched upstream checkout intentionally fails: the converter references the patch's public marker, preventing an unpatched binary from claiming the patched identity.

Converter identity `tractanda.docling-native.v2-idefics3-gelu-f32` identifies this patched inference implementation. `runtimeRevision` identifies its upstream base; it does not claim that runtime source is unmodified. The patch hash and before/after source hashes provide the exact additional provenance. Canonical readers retain the known prior converter identities; current output admission requires this identity.

The patch promotes only low-precision Idefics3 vision GELU arithmetic to Float32, then casts back to the input dtype. Model weights, configuration, preprocessing profile, decoder and parser remain fixed. The controlled PNG regression restored its title/spaces and all four original exact facts; this does not imply backend bit equivalence or general OCR/table readiness.

No build here installs, restarts or modifies the deployed application. The operator-selected converter/model/scratch configuration remains opt-in.
