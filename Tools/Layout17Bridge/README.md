# Layout17 private migration and fixture tools

The unpublished `.17` bridge converts 16.2 item files to the message encoding and changes their canonical paths. Serialized item bytes change; ItemID, RevisionID, logical revision format (1 or 2), typed fields, ordinary history and permissions remain. Attachment payload names and bytes remain unchanged. The converter preserves canonical files' owner, group and mode; it does not claim to preserve filesystem extended attributes or ACLs. The visible `canonical-layout.json` records both the layout and `message-v1` encoding. The reader requirement is raised directly to floor 20 with `tractanda.physical-layout.flat-items.v1` and `tractanda.message-items.v1` before conversion. Ordinary readers refuse an incomplete migration and do not run legacy conversion.

The one-time helper reads the old envelope, calls the shared message codec and semantic validator, and uses a durable per-operation journal plus a temporary descriptor work queue. A normal standalone `.17` installer is intended to run it automatically; later releases must require completion of this bridge. These are source/private-validation results, not a published or deployed release. If an opaque request-identity receipt is present, conversion preserves it exactly. The new format permits it to be absent for raw-content recovery; without the receipt, an exact duplicate-operation retry fails closed rather than inventing a prior result.

## Coordinated cluster CLI

Existing clusters use administrator-directed coordinated maintenance; there is no distributed migration protocol and the operator flag does not prove remote peers are stopped. Prepare each member, install `.17` on every member while all remain stopped, then complete each member after all upgrades are done.

```text
sudo tractanda-layout17 prepare --instance NAME --bundle ABSOLUTE_CANDIDATE --coordinated-maintenance
sudo tractanda-layout17 complete --instance NAME --all-members-upgraded
```

`prepare` binds the installed and candidate manifests, StoreID, ReplicaID, current membership and reader requirement, records a root-owned one-time intent, and stops only the selected local managed instance. `complete` verifies that local `.17` completion, consumes that local intent, and starts that local instance. `--all-members-upgraded` is an administrator assertion, not cryptographic evidence of remote package or service state. A macOS installer may stage unused candidate software before a safe refusal; refusal precedes canonical migration and service disruption.

Older enterprise/bootstrap maintenance workflows refuse preflight. Complete or recover them on `0.1.0-poc.16.2` before using the normal standalone `.17` installer. The coordinated commands and converter are in the unpublished candidate; package and cluster rollout qualification remains separate.

Complete retained peer revision stages and associated reviews are converted without promoting the staged revision; review IDs, dispositions and source context remain. Partial or malformed peer revision stages cannot be converted safely and refuse preflight with the available revision and stage IDs. Restore the 16.2 peer synchronization or recover the retained state before retrying; there is no claimed general abort command. Original/document transfers and attachment uploads retain their own payload bytes and bindings.

## Produce the genuine 16.2 fixture

The producer requires explicit paths. It opens only a new private store at `--output`, connects through a short private socket, verifies the running server reports exactly `0.1.0-poc.16.2`, and never resolves a user connection profile. It refuses an existing output directory, requires at least 10 GiB free on the output filesystem, and caps fixture data at 128 MiB. It records StoreID/ReplicaID, item and payload hashes/modes, ordinary `get`/`history` baselines, and an incomplete resumable upload.

```sh
python3 Tools/Layout17Bridge/produce_fixture.py \
  --binary /path/to/tractanda-0.1.0-poc.16.2 \
  --output /path/to/private-temp/layout17-poc16.2-fixture
```

The output parent must be a temporary directory or an owned private directory (mode `0700`). Do not pass a production store, existing fixture, or connection profile. The fixture itself is generated locally and is not committed.

## Run the private fixture suite

Pass `--fixture` and `--binary` explicitly; a missing or incomplete fixture or helper is an error, never a skipped passing test. The helper links the same Core semantic validator as peer intake, so build a private instrumented SwiftPM helper with `LAYOUT17_PRIVATE_FIXTURE` and the project's configured dependencies. Use an isolated scratch path and existing cached dependencies; the instrumented helper is a test artifact, not a release executable. For example, with an appropriately configured local SwiftPM cache:

```sh
swift build --product tractanda-layout17 \
  --scratch-path /path/to/private-scratch \
  -Xswiftc -D -Xswiftc LAYOUT17_PRIVATE_FIXTURE
python3 Tools/Layout17Bridge/test_fixture.py \
  --fixture /path/to/private-temp/layout17-poc16.2-fixture \
  --binary /path/to/tractanda-layout17-instrumented
```

The suite checks interruption/retry boundaries, metadata and path corruption, ENOSPC recovery, candidate staging validation, journal identity separation, logical revision preservation, pending review/stage handling and payload preservation. It copies the fixture to disposable temporary directories and leaves the supplied fixture unchanged. Its 10 GiB free-space reserve and 128 MiB fixture cap are development safeguards, not product-wide minimums. The suite is focused migration evidence; it is not package, host, full-suite, or cluster-rollout qualification.

The harness resolves the platform temporary directory to its real path before creating test copies. This avoids handing the no-follow converter a symlinked alias such as macOS `/var/folders/...` when its real path is under `/private/var/folders/...`.
