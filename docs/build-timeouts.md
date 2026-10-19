# Build and validation time budgets

Long local builds, package compression, native validation, document conversion and CI use explicit finite budgets suitable for slower machines. Long build/package/test operations default to 24 hours. The wrapper and validator integer timeout options accept positive seconds up to seven days. The Swift producer/component build timeout accepts finite positive floating-point seconds up to `2^31-1`; it is not subject to the wrapper's seven-day ceiling. Document runtime values are finite positive `Double` seconds constrained by the core's addressable nanosecond range, with termination grace additionally capped at 60 seconds.

| Operation | Option | Default | Scope |
|---|---|---:|---|
| Linux core payload build | `scripts/produce-linux-payload.py --build-timeout-seconds` | 86,400 s | Shared finite wall budget for each core-product compiler child and its same-argument binary-path query. The producer's accepted maximum is `2^31-1` seconds. |
| Linux ML component build | `scripts/build-linux-ml-component.py --build-timeout-seconds` | 86,400 s | Applies to locked dependency resolution, component compile, and the same-command output-path query. Uses the producer's finite/addressable timeout validator, not the Debian wrapper's seven-day cap. |
| Debian package compression | `scripts/build-linux-deb.py --build-timeout-seconds` | 86,400 s | Bounds the `dpkg-deb` compression child. Storage, closed-inventory verification, and cleanup checks remain separate. |
| Debian lifecycle validation | `scripts/verify-linux-deb.py --timeout-seconds` | 86,400 s | Whole validation operation. |
| D5 lifecycle command | `scripts/verify-linux-deb.py --command-timeout-seconds` | 86,400 s | Long dpkg/Setup lifecycle commands are limited by this value and remaining whole-run time; short probes keep their smaller bounds. |
| Native Linux cluster validation | `scripts/verify-cluster-linux.py --timeout-seconds` | 86,400 s | Whole test operation; the host owner receives derived cleanup headroom. |
| Native XCTest child | `scripts/verify-cluster-linux.py --command-timeout-seconds` | 86,400 s | Each long test child, capped by the whole operation. Short inspection and container-management probes retain their separate limits. |
| Stash native validation | `scripts/verify-stash-cluster.py --timeout-seconds` | 86,400 s | Whole remote native test operation. |
| Stash XCTest child | `scripts/verify-stash-cluster.py --command-timeout-seconds` | 86,400 s | Each long XCTest scope, capped by the whole operation. |
| GitHub source verification | `.github/workflows/verify.yml` job timeout | 360 min | Finite outer CI job budget. The runner provider may impose its own maximum. |

## Native document runtime phases

The daemon's `DocumentJobResources` can override these five resource phases on macOS or Linux. Pass values to `tractanda daemon` as positive finite seconds; a missing option uses its default. Each `--document-*` option can be set independently.

| CLI option | Default | Budget scope |
|---|---:|---|
| `--document-inspect-seconds` | 1,800 s | Weight-free worker inspection/hello and page-count acquisition. |
| `--document-model-load-seconds` | 3,600 s | First-page model loading, until validated `modelReady` progress. |
| `--document-page-seconds` | 21,600 s | Absolute limit for each page operation, beginning at page work or after `modelReady`. |
| `--document-no-progress-seconds` | 1,800 s | Limit from the last validated meaningful progress when the worker is in a progress-reporting phase. |
| `--document-termination-grace-seconds` | 15 s | TERM-to-KILL wait for the owned worker after timeout or cancellation; core validation caps it at 60 seconds. |

Each document inspection, page, and finish operation has its own absolute phase limit. A page also has a no-progress limit; when it is active, the effective deadline is the earlier of the phase limit and last meaningful progress plus the no-progress budget. Validated worker phases `modelLoad`, `render`, `prepare`, and `prefill` are treated as silent compute: the no-progress watchdog is disabled during those phases, but the absolute inspect/model-load/page limit still applies. Validated progress can reset the no-progress clock, not the absolute phase clock. `modelReady` starts the page phase with a fresh absolute page budget.

There is no whole-document deadline. The producer creates a new page deadline for each requested page, so a 100-page document can continue across 100 separately bounded pages. This keeps slow silent prefill distinguishable from a stalled worker without multiplying a single page timeout across the entire document. Operational budgets do not change converter, model, parser, or semantic identity.

The five flags are parsed by [`DaemonCommand.swift`](../Sources/TractandaCLI/DaemonCommand.swift#L91), assembled as [`DocumentJobResources`](../Sources/TractandaCore/DocumentJobProducer.swift#L4), and checked for finite, positive, nanosecond-addressable values by [`DocumentWorkerBudgets`](../Sources/TractandaCore/DocumentWorkerBudgets.swift#L10). The phase/no-progress behavior is implemented by [`DocumentWorkerDeadline`](../Sources/TractandaCore/DocumentWorkerBudgets.swift#L31) and applied once per page in [`DocumentNativeSession.convert`](../Sources/TractandaCore/DocumentNativeSession.swift#L122). The compile timeout defaults and addressable range are defined by [`produce-linux-payload.py`](../scripts/produce-linux-payload.py#L273) and consumed by the component builder.

## Semantic provider and query deadlines

The optional operational `SemanticConfiguration.providerTimeoutSeconds` key defaults to 21,600 seconds (six hours). It bounds both `URLSession` request/resource timeouts and each embedding `URLRequest`. The finite pending-query allowance is `65 × providerTimeoutSeconds + 120 seconds`, covering the bounded 64-query set processed serially plus one provider-interval margin before completed-result retention. Configuration validation also requires this derived duration to remain finite and addressable.

Pending `expiresAt` is set when the query is accepted. When the server consumes a successful or failed provider completion, it changes `expiresAt` to 120 seconds after that consumption time. Polling does not extend or otherwise change expiry. A completion consumed after the pending deadline is discarded, so late work cannot revive an expired query. The provider timeout is operational configuration and is deliberately excluded from `SemanticProfileIdentity`; changing it does not change vector identity.

These values are implemented by [`SemanticConfiguration`](../Sources/TractandaCore/SemanticConfiguration.swift#L20), applied to the session and individual request by [`SemanticProvider`](../Sources/TractandaCore/SemanticProvider.swift#L30), and used for one-at-a-time query scheduling and completion-time retention by [`SemanticService`](../Sources/TractandaCore/SemanticService.swift#L551).

For D5, long dpkg/Setup lifecycle commands use the configurable command budget, clamped to the remaining whole-run time. Short package inventory, systemd status, and readiness probes retain their existing smaller budgets; cleanup continues under its existing bounded stop/reap paths.

The local Linux cluster wrapper reserves `max(120 seconds, min(3600 seconds, 1% of the operation budget))` for owned-container shutdown and evidence closure. The Stash wrapper adds that headroom to the systemd unit runtime, then derives another bounded SSH-owner grace from the unit budget. This keeps the whole native operation, systemd owner, and SSH supervisor ordered without changing SSH liveness, connection, or protocol timers. With the default 24-hour budget, every layer remains finite and the outer owner is longer than the child it supervises.

Short limits remain for protocol operations and tests designed to fail quickly: SSH connect/lease freshness, systemd and container-manager queries, loopback probes, short fixture-proof checks, and TERM/stop/reap grace periods. The D5 context's one-hour expiry remains an admission-validity window, not a validation runtime cap. These are not build or model-runtime deadlines. The package build archive scanner's short post-stream child-exit check likewise applies after the archive has been read, not to the compression operation.

The existing disk reserve, storage allowances, 128 MiB fixture cap, memory limits, ISA checks, serial package-job choices, and integrity guards are unchanged. The 2-CPU test containers, four Swift frontend threads, and one SwiftPM job remain explicit resource profiles; raising wall time does not silently raise memory, disk, CPU or parallelism. `scripts/test.sh` has no local suite-wide timeout; its CI caller is now bounded by the workflow job limit. The macOS release pipeline's `--ci-timeout` remains an already-configurable external CI wait and is not a local compiler deadline.
