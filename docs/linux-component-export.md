# Offline Linux ML component export

`python3 scripts/export-linux-ml-component.py --arch amd64 --component documents --manifest debian/components/amd64/documents.json --component-root <verified-artifact-root> --output <fresh-export-root>` exports an already built and behavior-verified component. Use the corresponding architecture/component for embeddings. It does not compile, relocate, execute, download, copy models, install or update the approval registry.

This exporter and the existing Docling binding and assembly recipes are for the approved Debian 13 components. They use the Debian 13 registry entries and retain their original recipe bytes and ABI checks. Export requires the approved normalized wrapper digest, verifies the entire input inventory, copies unchanged artifact bytes and modes, adds the six tracked outer Docling files, and reruns the component validator. An interrupted export remains an unapproved partial directory. Each output has an 8 GiB allocation cap and preserves a 10 GiB free reserve.

The wrapper's `recipe` commits this projection recipe. `sourceInputsSHA256` and the component's existing provenance retain the actual compiler/source/patch/ABI/model commitments that built its bytes. A later tracked build-script timeout fix does not retroactively become the recipe of an older artifact. New builds still need exact new artifact and behavior approval; this exporter provides no broad admission.

The finite current identities correspond to the verified AMD64/ARM64 descriptor bytes. Historical readability follows supported stored schemas and parser/preprocessing semantics rather than a finite build-fingerprint list; it never selects a historical runtime for execution. Setup accepts only the current finite identity for the declared platform/architecture and the exact native closure inventory entry; converter/Core checks still verify private file bytes at runtime. OS provider hashes remain build/test evidence, not deployed OS security-update pins.

Kali rolling has separate registry entries for amd64 and arm64. Before admitting either architecture, build and qualify its native components, record the actual Swift and system provider provenance, and bind the verified Docling closure to the corresponding runtime identity. Review the normalized manifests before recording their digests in the Kali registry. The producer stops before compilation when either required Kali component is missing. Package assembly and isolated lifecycle verification follow component admission. [Linux payload producer](linux-payload-producer.md) · [Docling compiler-input provenance](linux-docling-provenance.md)

For a first Kali admission, use the compile-only recipe with `--build-os kali-rolling`. Keep the native compiler receipt and its source-input receipt in the original scratch directory. Prepare a separate support root with the intended final `bin/`, `lib/`, and `licenses/` paths. Its files include the actual SwiftPM resource bundles, private toolchain/runtime libraries, and matched notices. The compiler executable, native descriptor, and generated provenance are supplied by the staging recipe. Keep model weights separate. For documents, include the two independently verified raster supplier DSOs under `lib/tractanda/document-native/`. Preserve their original supplier descriptor and build provenance, and the historical component manifest that commits their exact bytes.

```sh
python3 -B scripts/prepare-kali-linux-component.py \
  --component documents --arch arm64 --swift /approved/swift/usr/bin/swift \
  --compile-work /work/owned-compiler --runtime-root /inputs/qualified-support \
  --supplier-manifest /inputs/original-component.json \
  --supplier-descriptor /inputs/original-descriptor.json \
  --supplier-provenance /inputs/original-provenance.json \
  --output /work/unadmitted-component --report /work/first-component-review
```

The command above is for the first, unadmitted pass. On the second document pass (`--expected-descriptor`), `prepare-kali-linux-component.py` runs the compiled helper's `protocols-v1` probe. On Linux that real probe first checks the compiled trusted prefix at `/opt/tractanda/current` and its exact descriptor/private closure. An output directory under `/work` therefore fails the probe by design. Run this pass only in a fresh isolated rootless build container or disposable root guest where `/opt/tractanda/current` is a fresh protected prefix owned as UID 0 inside that environment; never use or replace the host's production `/opt/tractanda/current`. Do not use symlinks, environment overrides, or probe bypasses.

After the probe and the recipe's exact component-inventory validation pass, copy/export the verified tree to its artifact directory only while checking each relative path, byte hash, size and mode against the emitted `component.json`. Retire the temporary prefix only after that comparison succeeds. The probe is a capability check, not registry admission or model-behavior evidence.

For embeddings, omit the supplier arguments. The staging recipe checks the complete component against actual native loader/provider facts, then emits a review manifest and a result with no runtime admission. For documents, review the proposed descriptor, bind its digest in both finite generated slots for the same baseline and architecture, rebuild, and run the same staging recipe in fresh output directories with `--expected-descriptor SHA256`. The second pass checks exact descriptor reproduction and verifies that the new executable includes the selected commitment. Run real model behavior and minimum-CPU checks before recording either registry digest.
