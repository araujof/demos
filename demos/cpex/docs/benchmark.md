# CPEX Filter Performance Benchmark

How to measure where time goes in the CPEX filter — per stage, per
plugin, per PDP engine — and the overhead of the policy layer.

## What gets measured

Three instrumentation seams feed the benchmark (all opt-in, zero cost
when off):

| Layer | Source | Surfaced as |
|-------|--------|-------------|
| Per-plugin wall-clock | `cpex-core` executor wraps each plugin handler | `PipelineResult.timings` → `cpex.timing` tracing record |
| **Per-effect** (delegation / audit / PII / field mutators) | `apl-cpex` `CmfPluginInvoker::invoke` + `DelegationPluginInvoker::delegate` | `cpex.plugin` tracing record (`plugin`, `phase`, `duration_ns`) |
| Per-call PDP engine cost | `apl-cpex` `PdpRouter::evaluate` | `cpex.pdp` tracing record (`dialect`, `duration_ns`) |
| Praxis filter stages | `filter.rs` `StageTimer` pairs | `cpex.timing` record (`build_extensions`, `parse`, `cmf_dispatch`, `reserialize`) |

The per-effect layer is what breaks the route-handler total down into the
individual plugins it orchestrates (the executor upstream sees the route
handler as a single entry).

Enable with `plugin_settings.capture_timings: true` in the policy
(`cpex.yaml`) and `emit_timing_records: true` on the `cpex` filter
(`praxis.yaml`). Both are already set in the demo configs.

## Running it

The gateway is brought up with the config under test; the driver runs
load against it and aggregates the records emitted during the run:

```console
# Cedar (default)
GATEWAY_CONFIG=praxis.yaml ./restart.sh
./scenarios/bench/run-bench.sh alice-internal 300 16 100

# CEL
GATEWAY_CONFIG=praxis-cel.yaml ./restart.sh
./scenarios/bench/run-bench.sh alice-internal 300 16 100

# No-policy baseline (overhead reference)
praxis -c praxis-baseline.yaml          # cpex removed from the chain
./scenarios/bench/run-bench.sh alice-internal 300 16 100
```

Scenarios: `bob-allow`, `eve-redact` (redaction), `alice-internal`
(PDP allow), `alice-external` (PDP deny). Launch the gateway with
`NO_COLOR=1` so the driver parses the log cleanly.

> Isolating network: the live RFC 8693 delegation (workday/github) is a
> Keycloak round-trip and dominates "as-deployed" latency. The
> per-plugin route-handler total includes it; the `cpex.pdp` line and
> the per-stage numbers are compute-only. A `praxis-baseline.yaml` run
> gives the no-policy floor. (A `cpex-nodelegate.yaml` that drops the
> delegators is the planned cross-check for a delegation-free compute
> number.)

## Sample results

Scenario `alice-internal` (`search_repos`, visibility=internal — the
only `pdp(...)`-bearing allow path), 120 req @ concurrency 8, warm
caches, local Keycloak/MCP. Indicative single-host numbers, not a
tuned benchmark:

| Config | p50 | p90 | p99 | req/s |
|--------|-----|-----|-----|-------|
| Cedar  | 7.48 ms | 8.45 ms | 9.11 ms | 180 |
| CEL    | 6.99 ms | 8.02 ms | 8.38 ms | 189 |
| Baseline (no cpex) | 1.50 ms | 2.02 ms | 2.61 ms | 192 |

Per-stage median (Cedar run):

| Stage | median |
|-------|--------|
| build_extensions (identity rebuild) | 62 µs |
| parse (JSON-RPC → ContentPart) | 2.5 µs |
| **cmf_dispatch (whole plugin pipeline)** | **4.48 ms** |
| reserialize (request body rewrite) | 3.3 µs |
| route handler `apl::tool::search_repos::pre` | 4.47 ms |

PDP engine, isolated (`cpex.pdp`):

| Dialect | median |
|---------|--------|
| Cedar | 105 µs |
| CEL | 22 µs |

Per-effect, inside the route handler (`cpex.plugin`), `bob-allow` (the
delegation path):

| Effect | median | what it is |
|--------|--------|------------|
| workday-oauth | 2270 µs | RFC 8693 token exchange (live IdP round-trip) |
| audit-log | 608 µs | structured audit emission |

The remaining ~0.95 ms of that run's 3.83 ms route-handler total is
identity claim-mapping, redaction, and APL orchestration. The
delegation round-trip is clearly the thing to optimize (cache/pool the
token exchange), not CPEX/APL compute.

## Reading the numbers

- **The policy layer adds ~5.5 ms p50** here (1.5 → 7 ms), almost
  entirely the **github RFC 8693 delegation** — a live Keycloak token
  exchange inside the route handler — not CPEX/APL compute.
- **PDP compute is small and the Cedar↔CEL gap is real**: CEL's inline
  boolean predicate (~22 µs) is ~5× cheaper than Cedar's policy-set
  evaluation (~105 µs). At this scale neither moves end-to-end latency
  much (both ≪ the delegation round-trip), but the engine cost is
  isolated and measurable.
- **Sanity check holds**: Σ per-plugin ≈ `cmf_dispatch` ≈
  `executor_total`, and `build_extensions + parse + cmf_dispatch`
  ≈ the filter's request-phase cost.

## Granularity note

In routed configs the `cpex-core` executor sees the APL route handler as
**one** entry (`apl::tool::<tool>::pre`) — it invokes audit / PII /
delegation as APL *effects*, not as separate executor plugins. The
`cpex.plugin` records (from the `CmfPluginInvoker` / `DelegationPluginInvoker`
seams) break that total back down per effect, and `cpex.pdp` isolates the
PDP engine. So three record streams compose the full picture:

- `cpex.timing` — praxis stage durations + the route-handler total.
- `cpex.plugin` — each effect inside the handler (delegation, audit, PII, mutators).
- `cpex.pdp` — the Cedar/CEL evaluation.

Still folded together: identity claim-mapping / redaction / orchestration
glue inside the route handler (the residual after subtracting the effects
above) — fine-grained APL-step timing would need a seam in `apl-core`'s
evaluator, a future enhancement.
