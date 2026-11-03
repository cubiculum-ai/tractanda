# Layout17 private migration and fixture tools

The `.17` bridge changes canonical paths only. It preserves revision bytes and identifiers, payload names and bytes, and the item schema. `canonical-layout.json` marks completion; the reader requirement is raised to floor 19 with `tractanda.physical-layout.flat-items.v1`. Ordinary readers refuse an incomplete migration and never convert old paths. A normal standalone `.17` installation runs the one-time migration automatically. Later releases require the `.17` completion marker and do not carry legacy-path conversion code.

## Coordinated cluster CLI

Existing clusters use administrator-directed coordinated maintenance; there is no distributed migration protocol and the operator flag does not prove remote peers are stopped. Stop and prepare every member, install `.17` on every member while all remain stopped, then complete each member after all upgrades are done.

```text
sudo tractanda-layout17 prepare --instance NAME --bundle ABSOLUTE_CANDIDATE --coordinated-maintenance
sudo tractanda-layout17 complete --instance NAME --all-members-upgraded
```

`prepare` binds the installed and candidate manifests and StoreID, records a root-owned one-time intent, and stops only the selected local managed instance. `complete` verifies that local `.17` completion, consumes that local intent, and starts that local instance. `--all-members-upgraded` is an administrator assertion, not cryptographic evidence of remote package or service state. A macOS installer may stage unused candidate software before a safe refusal; refusal precedes canonical migration and service disruption.

Older enterprise/bootstrap maintenance workflows refuse preflight. Complete or recover them on `0.1.0-poc.16.2` before using the normal standalone `.17` installer. The coordinated commands and converter are in the unpublished candidate; package and cluster rollout qualification remains separate.

## Produce the genuine 16.2 fixture

The producer requires explicit paths. It opens only a new private store at `--output`, connects through a short private socket, verifies the running server reports exactly `0.1.0-poc.16.2`, and never resolves a user connection profile. It refuses an existing output directory, requires at least 10 GiB free on the output filesystem, and caps fixture data at 128 MiB. It records StoreID/ReplicaID, item and payload hashes/modes, ordinary `get`/`history` baselines, and an incomplete resumable upload.

```sh
python3 Tools/Layout17Bridge/produce_fixture.py \
  --binary /path/to/tractanda-0.1.0-poc.16.2 \
  --output /path/to/private-temp/layout17-poc16.2-fixture
```

The output parent must be a temporary directory or an owned private directory (mode `0700`). Do not pass a production store, existing fixture, or connection profile. The fixture itself is generated locally and is not committed.

## Run the private fixture suite

Pass `--fixture` explicitly; a missing or incomplete fixture is an actionable error, never a skipped passing test. On macOS, the harness builds the private fault-instrumented converter in the platform's temporary directory. On Linux and other non-macOS hosts, pass an already-built executable helper compiled with `LAYOUT17_PRIVATE_FIXTURE` and the platform's configured Swift Crypto/SPM dependencies. Without that binary the harness stops with an error and claims no Linux test coverage.

```sh
python3 Tools/Layout17Bridge/test_fixture.py \
  --fixture /path/to/private-temp/layout17-poc16.2-fixture

python3 Tools/Layout17Bridge/test_fixture.py \
  --fixture /path/to/private-temp/layout17-poc16.2-fixture \
  --binary /path/to/tractanda-layout17-instrumented
```

The suite checks interruption/retry boundaries, metadata and path corruption, ENOSPC recovery, candidate staging validation, journal identity separation for local replicas, and content/path/mode preservation. It copies the fixture to disposable temporary directories and leaves the supplied fixture unchanged. It requires 10 GiB free on the temporary filesystem. The suite is focused migration evidence; it is not package, host, full-suite, or cluster-rollout qualification.

The harness resolves the platform temporary directory to its real path before creating test copies. This avoids handing the no-follow converter a symlinked alias such as macOS `/var/folders/...` when its real path is under `/private/var/folders/...`.
