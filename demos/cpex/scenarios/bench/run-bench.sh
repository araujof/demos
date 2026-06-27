#!/usr/bin/env bash
# CPEX benchmark driver.
#
# Drives one scenario against the ALREADY-RUNNING gateway under load,
# then reports:
#   * end-to-end latency percentiles (p50/p90/p99) + throughput, from
#     curl's own timing — the "as-deployed" client view, and
#   * the per-stage / per-plugin / PDP breakdown, aggregated from the
#     `cpex.timing` and `cpex.pdp` tracing records the gateway emits
#     during the run (requires the gateway built with the timing work,
#     `emit_timing_records: true` on the filter, and
#     `plugin_settings.capture_timings: true` in the policy).
#
# The gateway is NOT managed here — bring it up with the config you want
# to measure (Cedar: praxis.yaml, CEL: praxis-cel.yaml, no-policy:
# praxis-baseline.yaml) before running. Compare runs across configs for
# Cedar-vs-CEL and overhead-vs-baseline.
#
# Usage:
#   ./scenarios/bench/run-bench.sh <scenario> [requests] [concurrency] [warmup]
#
#   scenario    one of: bob-allow | eve-redact | alice-internal | alice-external
#   requests    measured requests (default 200)
#   concurrency parallel in-flight requests (default 8)
#   warmup      un-measured warmup requests, to fill JWKS + route caches
#               (default 50)
#
# Example:
#   ./scenarios/bench/run-bench.sh alice-internal 300 16 100

set -euo pipefail
cd "$(dirname "$0")/.."          # → scenarios/
DEMO_DIR="$(cd .. && pwd)"
GATEWAY="${GATEWAY:-http://localhost:8090}"
GATEWAY_LOG="${GATEWAY_LOG:-$DEMO_DIR/gateway.log}"

SCENARIO="${1:?usage: run-bench.sh <scenario> [requests] [concurrency] [warmup]}"
REQUESTS="${2:-200}"
CONCURRENCY="${3:-8}"
WARMUP="${4:-50}"

mint() { "$DEMO_DIR/mint-token.sh" "$1"; }

# Resolve (persona, JSON-RPC body) for the scenario.
case "$SCENARIO" in
  bob-allow)
    PERSONA=bob
    BODY='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_compensation","arguments":{"employee_id":"EMP-001234","include_ssn":true,"ssn":"x"}}}' ;;
  eve-redact)
    PERSONA=eve
    BODY='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_compensation","arguments":{"employee_id":"EMP-001234","include_ssn":true,"ssn":"x"}}}' ;;
  alice-internal)
    PERSONA=alice
    BODY='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_repos","arguments":{"repo_name":"web-app","visibility":"internal"}}}' ;;
  alice-external)
    PERSONA=alice
    BODY='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_repos","arguments":{"repo_name":"web-app","visibility":"external"}}}' ;;
  *) echo "unknown scenario '$SCENARIO'" >&2; exit 1 ;;
esac

echo "[bench] scenario=$SCENARIO persona=$PERSONA requests=$REQUESTS concurrency=$CONCURRENCY warmup=$WARMUP"
echo "[bench] minting tokens…"
USER_TOK="$(mint "$PERSONA")"
CLIENT_TOK="$(mint hr-copilot)"

# One request: prints curl's total time in seconds. -o /dev/null so the
# body never touches disk; --fail-with-body kept off so policy denies
# (HTTP 200 + JSON-RPC error) still count as completed requests.
fire() {
  curl -s -o /dev/null -w '%{time_total}\n' --max-time 30 -X POST "$GATEWAY/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $CLIENT_TOK" \
    -H "X-User-Token: $USER_TOK" \
    --data "$BODY"
}
export -f fire
export GATEWAY CLIENT_TOK USER_TOK BODY

echo "[bench] warmup ($WARMUP)…"
seq "$WARMUP" | xargs -P "$CONCURRENCY" -I{} bash -c 'fire >/dev/null' || true

# Mark the gateway-log position so aggregation only sees this run.
LOG_START=$(wc -l < "$GATEWAY_LOG" 2>/dev/null || echo 0)

echo "[bench] measuring ($REQUESTS)…"
TIMES_FILE="$(mktemp)"
WALL_START=$(date +%s.%N)
seq "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} bash -c 'fire' >> "$TIMES_FILE"
WALL_END=$(date +%s.%N)

# ---- end-to-end latency percentiles (seconds → ms) ----
sort -n "$TIMES_FILE" > "${TIMES_FILE}.sorted"
pct() { # pct <p> ; reads sorted file
  awk -v p="$1" 'NR==FNR{a[NR]=$1;n=NR;next} END{
    if(n==0){print "n/a";exit} idx=int((p/100)*n); if(idx<1)idx=1; if(idx>n)idx=n;
    printf "%.2f", a[idx]*1000 }' "${TIMES_FILE}.sorted" "${TIMES_FILE}.sorted"
}
COUNT=$(wc -l < "${TIMES_FILE}.sorted" | tr -d ' ')
WALL=$(awk -v a="$WALL_START" -v b="$WALL_END" 'BEGIN{printf "%.3f", b-a}')
RPS=$(awk -v c="$COUNT" -v w="$WALL" 'BEGIN{ if(w>0) printf "%.1f", c/w; else print "n/a" }')

# ---- per-stage / per-plugin / PDP breakdown from gateway.log ----
# Strip ANSI, take only lines emitted after LOG_START, pull the records.
RUNLOG="$(mktemp)"
sed -E 's/\x1b\[[0-9;]*m//g' "$GATEWAY_LOG" | tail -n +"$((LOG_START + 1))" > "$RUNLOG"

# cpex.timing records → JSON stream; median of each stage + per plugin.
TIMING_JSON="$(mktemp)"
grep -F 'cpex request timing' "$RUNLOG" | sed -E 's/.*record=//' > "$TIMING_JSON" || true
N_TIMING=$(wc -l < "$TIMING_JSON" | tr -d ' ')

median_us() { # median of a jq-extracted numeric stream (ns → µs)
  jq -rs 'if length==0 then "n/a" else (sort|.[length/2|floor]/1000|.*100|round/100|tostring) end' 2>/dev/null || echo n/a
}

echo
echo "=================== CPEX BENCH: $SCENARIO ==================="
echo "End-to-end (client-observed):"
printf "  requests=%s  concurrency=%s  wall=%ss  throughput=%s req/s\n" "$COUNT" "$CONCURRENCY" "$WALL" "$RPS"
printf "  latency ms  p50=%s  p90=%s  p99=%s  max=%s\n" "$(pct 50)" "$(pct 90)" "$(pct 99)" "$(pct 100)"

if [ "$N_TIMING" -gt 0 ]; then
  echo
  echo "Per-stage (median µs, from $N_TIMING cpex.timing records):"
  for stage in build_extensions parse cmf_dispatch reserialize; do
    val=$(jq ".stage_ns.$stage" "$TIMING_JSON" | median_us)
    printf "  %-16s %s\n" "$stage" "$val"
  done
  echo "  $(jq '.executor_total_ns' "$TIMING_JSON" | median_us | sed 's/^/cmf executor_total /')"

  echo
  echo "Per-plugin (median µs):"
  for pl in $(jq -r '.plugins[].plugin' "$TIMING_JSON" | sort -u); do
    val=$(jq --arg p "$pl" '.plugins[]|select(.plugin==$p)|.duration_ns' "$TIMING_JSON" | median_us)
    printf "  %-40s %s\n" "$pl" "$val"
  done
else
  echo
  echo "(no cpex.timing records this run — is emit_timing_records + capture_timings on?)"
fi

# cpex.plugin records → median per effect (delegation / audit / PII /
# field mutators), broken out from inside the route handler.
if grep -qF 'plugin invoke' "$RUNLOG"; then
  echo
  echo "Per-effect (median µs, from cpex.plugin records — inside the route handler):"
  for pl in $(grep -F 'plugin invoke' "$RUNLOG" | grep -oE 'plugin=[^ ]+' | cut -d= -f2 | sort -u); do
    val=$(grep -F 'plugin invoke' "$RUNLOG" | grep -F "plugin=$pl " | grep -oE 'duration_ns=[0-9]+' | cut -d= -f2 \
          | jq -rs 'if length==0 then "n/a" else (sort|.[length/2|floor]/1000|.*100|round/100|tostring) end')
    printf "  %-24s %s\n" "$pl" "$val"
  done
fi

# cpex.pdp records → median per dialect.
if grep -qF 'pdp evaluate' "$RUNLOG"; then
  echo
  echo "PDP engine (median µs, from cpex.pdp records):"
  for dia in $(grep -F 'pdp evaluate' "$RUNLOG" | grep -oE 'dialect=[^ ]+' | sort -u); do
    val=$(grep -F 'pdp evaluate' "$RUNLOG" | grep -F "$dia" | grep -oE 'duration_ns=[0-9]+' | cut -d= -f2 \
          | jq -rs 'if length==0 then "n/a" else (sort|.[length/2|floor]/1000|.*100|round/100|tostring) end')
    printf "  %-24s %s\n" "$dia" "$val"
  done
fi
echo "============================================================"

rm -f "$TIMES_FILE" "${TIMES_FILE}.sorted" "$RUNLOG" "$TIMING_JSON"
