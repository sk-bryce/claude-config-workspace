#!/usr/bin/env bash
# Check 7: day-over-day and week-over-week comparison. See references/pup-recipes.md's
# "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: seasonality-check.sh <service> <resource_name_or_dash> <window_start> <window_end>

Check 7: re-runs the alerting metric AND the traffic query over the same
clock window one day earlier and seven days earlier, so "is this abnormal"
can be answered against "normal for this day and hour" instead of a single
snapshot. Distinguishes an alert that is abnormal from one that recurs every
Tuesday at 06:00 UTC.

<resource_name_or_dash>: the metrics-tag resource_name (lowercased HTTP-ish
form, see pup-recipes.md gotcha 3), or "-" to run the whole-service query
instead of scoping to one resource.

<window_start>/<window_end> must be literal UTC RFC3339 timestamps (e.g.
2026-08-26T12:00:00Z) -- the script shifts them by -1 day and -7 days, so a
relative window cannot be shifted reproducibly. Requires python3 for the
date arithmetic (RFC3339 in, RFC3339 out, no timezone conversion -- every
timestamp stays UTC).

The underlying metric defaults to trace.http.request (Go/gRPC services); set
TRIAGE_METRIC_NAME=trace.servlet.request for Java servlet services (gotcha
5). Bakes in --output=json --no-agent --read-only. Prints each query's raw
response labeled by offset and check -- see resource-metrics.sh's usage for
why this script does not guess a jq filter for the metrics-query response.
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
window_start=$3
window_end=$4
metric=${TRIAGE_METRIC_NAME:-trace.http.request}
# Rollup interval, in seconds, pinned on every metrics query below. Not optional: `pup metrics
# query` otherwise picks its own interval from the query span, reports it nowhere in the response,
# and does not even keep it consistent between services in one sweep. Reading a 10-second bucket as
# a per-minute figure understates counts ~6x -- see pup-recipes.md gotcha 7, which this default
# exists to prevent. Raise it for long windows (3600 for a multi-day view); do not lower it below
# 60 unless you have a specific reason and will state the interval in the report.
rollup_seconds=${TRIAGE_ROLLUP_SECONDS:-60}

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for reproducible UTC date-shifting and was not found." >&2
  echo "Shift window_start/window_end by -1 day and -7 days manually and re-run per offset." >&2
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

scope="env:prod,service:${service}"
if [[ "$resource_name" != "-" ]]; then
  scope="${scope},resource_name:${resource_name}"
fi

echo "Metric: $metric (override with TRIAGE_METRIC_NAME). Rollup: ${rollup_seconds}s (override with TRIAGE_ROLLUP_SECONDS). Scope: {$scope}. All timestamps UTC." >&2

for offset_days in 0 -1 -7; do
  from=$(shift_ts "$window_start" "$offset_days")
  to=$(shift_ts "$window_end" "$offset_days")
  label="current window"
  [[ "$offset_days" == "-1" ]] && label="day-over-day (-1d)"
  [[ "$offset_days" == "-7" ]] && label="week-over-week (-7d)"

  echo "== $label: $from..$to (UTC) ==" >&2

  echo "-- alerting metric (p95) --" >&2
  pup metrics query --query="p95:${metric}{${scope}}.rollup(max, ${rollup_seconds})" \
    --from="$from" --to="$to" --output=json --no-agent --read-only

  echo "-- traffic / sample volume --" >&2
  pup metrics query --query="sum:${metric}.hits{${scope}}.as_count().rollup(sum, ${rollup_seconds})" \
    --from="$from" --to="$to" --output=json --no-agent --read-only
done
