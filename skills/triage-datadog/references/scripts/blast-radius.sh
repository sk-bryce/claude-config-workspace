#!/usr/bin/env bash
# Check 14: blast radius and customer impact. See references/pup-recipes.md's "Wrapper scripts"
# section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: blast-radius.sh <service> <resource_name> <trigger_timestamp> <recovery_timestamp>

Check 14: counts, not rates -- "how many requests were affected" is the
question a ticket decision turns on, and a rate hides it. Runs, for the
exact alert cycle:
  1. affected request volume for the resource across the cycle
  2. the same clock window one day earlier, for scale (is this cycle's
     volume large or small relative to a normal day?)
  3. failed requests only, service-wide, across the cycle
  4. distinct endpoints touched, service-wide, across the cycle (does this
     alert's failure mode spill past the one resource?)

<trigger_timestamp>/<recovery_timestamp> must be literal UTC RFC3339
timestamps (e.g. 2026-08-26T12:00:00Z) -- from the alert timeline (check 2).
Requires python3 for the -1 day shift in step 2 (RFC3339 in, RFC3339 out, no
timezone conversion -- stays UTC).

The underlying metric defaults to trace.http.request (Go/gRPC services); set
TRIAGE_METRIC_NAME=trace.servlet.request for Java servlet services (gotcha
5). Bakes in --output=json --no-agent --read-only. Prints each query's raw
response labeled by step -- see resource-metrics.sh's usage for why this
script does not guess a jq filter for the metrics-query response.
EOF
}

# usage() prints to stdout and does not exit, so `--help` is a success: `script --help | less`
# works and CI does not read it as a failure. Argument errors go through die_usage, which keeps
# the exit 1 documented in pup-recipes.md's wrapper exit-code table.
die_usage() { usage >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 4 ]] || die_usage
service=$1
resource_name=$2
trigger_ts=$3
recovery_ts=$4
metric=${TRIAGE_METRIC_NAME:-trace.http.request}
# Rollup interval, in seconds, pinned on every metrics query below. Not optional: `pup metrics
# query` otherwise picks its own interval from the query span, reports it nowhere in the response,
# and does not even keep it consistent between services in one sweep. Reading a 10-second bucket as
# a per-minute figure understates counts ~6x -- see pup-recipes.md gotcha 7, which this default
# exists to prevent. Raise it for long windows (3600 for a multi-day view); do not lower it below
# 60 unless you have a specific reason and will state the interval in the report.
rollup_seconds=${TRIAGE_ROLLUP_SECONDS:-60}

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for the -1 day baseline shift and was not found." >&2
  echo "Compute trigger_ts/recovery_ts minus one day manually and re-run the baseline query by hand." >&2
  exit 2
fi

shift_ts() {
  python3 -c "
import sys
from datetime import datetime, timedelta
ts, days = sys.argv[1], int(sys.argv[2])
dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ') + timedelta(days=days)
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1" "$2"
}

baseline_trigger=$(shift_ts "$trigger_ts" -1)
baseline_recovery=$(shift_ts "$recovery_ts" -1)

echo "Metric: $metric (override with TRIAGE_METRIC_NAME). Rollup: ${rollup_seconds}s (override with TRIAGE_ROLLUP_SECONDS). Cycle: $trigger_ts..$recovery_ts (UTC)." >&2

echo "== 1/4: affected request volume, resource_name=$resource_name, across the cycle ==" >&2
pup metrics query \
  --query="sum:${metric}.hits{env:prod,service:${service},resource_name:${resource_name}}.as_count().rollup(sum, ${rollup_seconds})" \
  --from="$trigger_ts" --to="$recovery_ts" --output=json --no-agent --read-only

echo "== 2/4: same clock window one day earlier ($baseline_trigger..$baseline_recovery UTC), for scale ==" >&2
pup metrics query \
  --query="sum:${metric}.hits{env:prod,service:${service},resource_name:${resource_name}}.as_count().rollup(sum, ${rollup_seconds})" \
  --from="$baseline_trigger" --to="$baseline_recovery" --output=json --no-agent --read-only

echo "== 3/4: failed requests only, service-wide, across the cycle ==" >&2
pup logs aggregate --query="service:${service} env:prod status:error" \
  --from="$trigger_ts" --to="$recovery_ts" \
  --compute=count --output=json --no-agent --read-only

echo "== 4/4: distinct endpoints touched, service-wide, across the cycle ==" >&2
pup traces aggregate --query="service:${service}" --compute=count --group-by=resource_name \
  --from="$trigger_ts" --to="$recovery_ts" --output=json --no-agent --read-only

echo "For a user-facing service, also consider 'pup rum sessions search'/'pup rum aggregate' to convert request counts into affected sessions." >&2
