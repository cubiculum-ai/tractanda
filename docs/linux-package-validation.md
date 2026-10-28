# Reproducible Linux package lifecycle validation

`scripts/verify-linux-deb.py` is a fixed package-test sequence for an explicitly isolated disposable Debian13 systemd guest. It consumes complete D3 `.deb` artifacts and their adjacent `.deb.inventory.json` receipts; it does not build a package, copy model trees, create an account/guest or change a canonical format. Its default command prints a plan and performs no package/service mutation.

This source unit has **no actual package result**. Complete packages, admitted Linux runtime/model identities and suitable native guests are still required. Its small tests use synthetic metadata and mocked commands; they do not count as a package, older binary, readiness or installer pass.

## One bounded command after the artifact/resource gate

From the same reviewed source snapshot, copy this script and mount/copy the already approved package files and D3 receipts read-only into the guest. Select one native architecture per invocation. The external controller owns native-host architecture proof, pinned guest image/identity, actual backing-filesystem capacity and memory/CPU/deadline supervision. Guest virtual free space alone is insufficient. Reuse the existing native-guest controller pattern; this validator does not create another controller framework.

Plan, without reading or installing the unavailable package:

```sh
python3 scripts/verify-linux-deb.py --package /inputs/tractanda_BASE_ARCH.deb
```

Execute only in the admitted guest:

```sh
python3 /inputs/verify-linux-deb.py --execute \
  --package /inputs/tractanda_BASE_ARCH.deb \
  --upgrade /inputs/tractanda_NEW_ARCH.deb \
  --older-refusal /inputs/tractanda_OLD_ARCH.deb \
  --older-manifest /inputs/OLD-bundle-manifest.json
```

The optional upgrade/older arguments are omitted when genuinely distinct complete artifacts do not exist. Their cases are then recorded as **NOT EXERCISED**, rather than passed. An older manifest must be the actual D3 bundle-manifest commitment of that old package. A changed package filename, Debian revision or copied capability declaration with identical server bytes is rejected as older/upgrade binary evidence. Debian version ordering identifies the scenario; the actual quiescent canonical requirement and hash-bound reader declaration determine whether a refusal is applicable. The validator never writes a made-up future floor or edits retained history to force refusal.

## Controller contract

The controller must first verify the native architecture outside the guest, start only its exact disposable image, prepare existing dependencies and retain an external absolute deadline/kill/reap owner. Python3, dpkg, systemd system tools and the package's declared external dependencies must already be available; `dpkg --install` intentionally does not fetch dependencies. Existing `daemon` and the selected owner account must exist. The validator provisions neither users nor groups. It requires systemd as PID1, a `podman`/`other` systemd-container marker and Debian13 userspace. The controller binds these checks to its actual isolated guest, not a production machine. The script cannot independently authenticate a root-created marker or prove native rather than emulated CPU execution.

Write `/run/tractanda-package-validation.json` as a root-owned, single-link, regular mode0600 file. It contains:

| Field | Meaning |
| --- | --- |
| `schema` | `tractanda.package-validation.v1` |
| `runID` | Unique twelve lowercase hex characters; the instance is always `d5-RUNID` |
| `guestMachineID` | Exact `/etc/machine-id` of this controller-owned fresh guest |
| `expiresAt` | Unix admission expiry, in the future by at most one hour |
| `owner` | An existing isolated guest OS user; no password is logged or account created |
| `selection` | `first-source` or `prepared`, chosen explicitly |
| `storeID`, `replicaID` | For prepared mode, independently pinned actual activated/prepared target UUIDv1 identities |
| `port` | Free local fixture port in49152–65535 |
| `softwareAllowanceBytes` | Positive precomputed software/dpkg temporary-unpack allowance, separate from data fixtures |
| `fixtureCapBytes` | Exactly134217728 (128 MiB) |
| `reserveBytes` | Exactly10737418240 (10 GiB genuine available space) |

The external controller estimates installed model/runtime payloads, package files, temporary dpkg replacement, memory and logs before creating the guest. It continuously checks **each actual backing filesystem** for package input/staging, container/VM storage and evidence; differing filesystem devices are measured independently. Do not count purgeable space or attribute concurrent unrelated free-space changes to these fixtures. No new disk allocation, tmpfs workaround, lowered reserve or unrelated cleanup is implied.

The validator separately checks genuine guest availability before/during/after commands, reserves its declared software allowance plus128MiB fixtures at entry, and keeps canonical/index/credential/log files within the128MiB fixture cap. Models and immutable package payloads remain software allowance, never data fixtures. These checks are soft monitors, not filesystem quotas. The whole sequence has a30-minute deadline after artifact admission, individual commands at most300seconds, and each captured command log at most4MiB. The controller's outer deadline also covers package hashing/admission and hard interruption; SIGKILL is not a child-termination guarantee. Preserve the exact work directory, package state and logs before destroying the guest.

Use a fresh guest with no installed Tractanda software/receipts, unrelated canonical store/service, or existing `/usr/sbin/policy-rc.d`. Prepared mode is a separate invocation whose controller supplies a small **already approved and activated** target at `/var/lib/tractanda/stores/d5-RUNID`, with appropriate existing daemon custody and current authority/credential originals. Parent preparation/enrollment tooling must produce it under its own authorization. The validator neither manufactures approval nor bootstraps an existing joining target; missing/pending/disposed/wrong-pin target rejection remains governed by actual Setup. A first-source invocation instead explicitly requests Setup's existing small sample fixture.

## Finite sequence and evidence

1. Hash each `.deb` against its real D3 receipt and require the complete seven-binary/two-model inventory and native architecture. Compare installed source bundle identity, actual dpkg version/architecture/state and fixed active file ownership. Actual shipped Setup `plan --bundle` remains mandatory; a sidecar assertion cannot admit an unsupported payload. The model bytes are streamed/hash-verified by the existing package/Setup paths without a second extracted model tree for this test.
2. Install the base package. Require the selected canonical/private paths unchanged, no unrelated store creation and no Tractanda unit registration/start. Explicitly select first-source sample initialization or pinned prepared adoption. Check native `TractandaStore/info` over the real Unix connection, exact executable SHA/version/PID and process instance, administrator/multi-user readiness, and all three system services. The root caller's fixed explicit-socket probe uses the supported `TRACTANDA_SERVER_USER=daemon` environment binding to authenticate the daemon peer; it retains the root caller identity and inherits no ambient environment. Setup's ordinary readiness also checks canonical, peer/document configuration and HTTP. No password/PAM challenge is invented by the test: actual PAM credential-login coverage is an additional test gate, distinct from this existing-UID native/broker service check.
3. When a distinct compatible upgrade is supplied, use real `dpkg --unpack`, check all services quiescent with boot startup blocked, then temporarily occupy only the guest fixture HTTP port. Real `dpkg --configure` must fail, leave the actual new payload/half-configured dpkg state and stopped/boot-blocked services, preserving canonical/private bytes. Release the port and retry the same real configure; require actual new executable/process identity. This checks phase-boundary stop/readiness/retry behavior, not a kernel trace of every replacement write or an abrupt host-kill/reboot test.
4. When a distinct older artifact and its actual manifest are supplied, obtain the real quiescent reader requirement through the shipped daemon-custody helper. If the old declaration can read the actual data, do not force or claim refusal. Otherwise attempt its real installation, require a nonzero status and stopped services with disabled boot startup, and preserve canonical/private inventory. Repair through real current-package reinstall and verify readiness. The failed install is always **REVIEW_REQUIRED**: its log must establish the actual compatibility guard separately, because current hook output has no reliable structured discriminator. Generic words or an echoed package filename never prove a compatibility refusal. The overall result remains REVIEW_REQUIRED and exits2, even when subsequent recovery succeeds; it is not an automatic downgrade-refusal PASS or a claim to restore old program bytes.
5. Remove the package and require active binaries gone, all owned services stopped and exact canonical identity/history/credential file set, bytes and custody retained. Reinstall the same full package under an exclusively created temporary `policy-rc.d` returning101: configuration must remain truthfully stopped. Restore only that exact owned policy file, explicitly start, then verify readiness. Purge, reinstall from the retained state, verify readiness/preservation, and purge again. No canonical/private data is erased by the validator; appended tombstones/history are not treated as preservation merely because old files survived.

The fixed result path is `/var/tmp/tractanda-package-validation-RUNID/RESULT.json`, beside bounded numbered command logs. It includes each real command/status/PID, native runtime identity, protected file digests/custody, applicable/not-exercised/review-required cases and verified service-stop cleanup. Secret bytes are never copied into the receipt. Snapshot comparison covers the selected canonical root including hidden identity/bootstrap/activation/history and credentials, plus the actual regular `/etc/tractanda/peer-runtime/d5-RUNID.json` leaf and its parent. Regular-file bytes/size and file/directory mode, UID and GID must match; explicit absence is recorded so creation or deletion is detected. Inodes, timestamps and directory sizes are excluded from equality because normal use may change them. Derived indexes, logs and runtime state are outside the preservation snapshot. `privateCoverage` reports whether the managed configuration and canonical credential files actually existed; an absent configuration/key is not credential-retention coverage. Externally referenced credentials must be placed within that fixture scope or separately verified by the parent. Initial/final artifact hashes, context, guest image, software/resource estimates and OS/tool/provider versions belong in the parent receipt.

On failure the child process group is killed/reaped, owned services are stopped and checked where possible, and the exact data/package/log state is retained. A cleanup failure makes the result fail; it never authorizes deleting the guest's only evidence. After evidence capture the parent removes only its exact disposable guest/generated fixtures, confirms no owned process/guest remains and records measured actual available capacity without a speculative reclaimed-space claim. No production, live enrollment, host account/service, signing/DNS/hosting, release or publication action is part of this command.

Actual full runtime/model inference/extraction parity, both native architectures, PAM credential login, policy/boot behavior across actual restart, abrupt configure-owner loss, multi-instance/fleet coordination and real incompatible/older artifacts remain separate acceptance evidence where this bounded invocation has not exercised them. Preserve these limitations rather than promoting source mocks or a missing optional scenario into finished Linux delivery.

## Installer-owned uuidd normal clock

The Debian package requires `uuid-runtime` and `init-system-helpers`. During `postinst configure`, after fixed Setup-helper admission and before Setup can resume Tractanda, its embedded hook removes continuous-clock mode through `/etc/systemd/system/uuidd.service.d/90-tractanda-normal-clock.conf`. It retains the effective supported executable, socket activation and other unambiguous command arguments. Quoted/escaped/custom executable forms and ambiguous continuous-clock arguments require administrator review. An already normal configuration is left unowned. Vendor units, unrelated administrator drop-ins, `uuidd.socket`, OS accounts and libuuid clock/state files are preserved. Existing item IDs and history are never rewritten.

The root-owned mode0600 `/etc/tractanda/uuidd-normal-clock.json` receipt records exact owned content before publication. Protected-directory/file checks, atomic unique temporary files and parent fsync order allow configure retries after owner loss. A reload/restart failure retains owned intent for retry and prevents Setup configure; it does not report a working clock. Restart uses `deb-systemd-invoke try-restart`, honoring `policy-rc.d` without starting an inactive daemon. A still-running continuous-clock process is refused even if policy returned success. A higher-priority conflicting drop-in is also refused. `TRACTANDA_UUIDD_TIMEOUT_SECONDS` sets the finite service-operation budget (default1800seconds; maximum604800seconds).

Upgrade retains the policy; remove, purge and package disappearance remove only the exact receipt-matching leaf and reload/try-restart the active daemon against the remaining host configuration. Cleanup failures retain the ownership receipt for retry. Administrator-modified content is retained and reported for review. Shared parent directories remain in place. If Python/systemd is unavailable and an owned leaf/receipt remains, postrm fails with retained policy instead of falsely reporting cleanup. An ordinary postrm upgrade/failed-upgrade/abort does not discard installed policy.

Focused private checks: `python3 scripts/test-uuidd-package-policy.py`, `python3 scripts/test-linux-package-hooks.py`, and `python3 scripts/test_build_linux_deb.py`. These doubles establish policy/lifecycle behavior; installed CLI UUID timestamps and normal API peer recovery must still be checked after a separately authorized native package upgrade.
