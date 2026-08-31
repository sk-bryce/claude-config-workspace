#!/usr/bin/env bash
# Checks 4-6: absolute value, service comparison, traffic, and error rate. See
# references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: resource-metrics.sh <service> <resource_name> <from> <to>

Checks 4-6: pulls, for one resource and one window --
  1. absolute p95 for the resource   (check 4 - was the raw value actually bad?)
  2. whole-service p95, same window  (check 4 - flat here + moved above = resource-isolated,
                                       not infra-wide)
  3. traffic / sample volume         (check 5 - rules out a load spike and a low-sample artifact)
  4. error rate as a percentage      (check 6 - separates latency-with-failures from
                                       latency-alone)

<resource_name> must be the metrics-tag form (lowercased, HTTP-ish, e.g.
post_/example.v1.exampleservice/getthing), NOT the APM trace-search RPC form
(/example.v1.ExampleService/GetThing) -- see pup-recipes.md gotcha 3. The
wrong form returns an empty series, not an error.

The underlying metric defaults to trace.http.request (Go/gRPC services).
Java servlet services report trace.servlet.request instead -- set
TRIAGE_METRIC_NAME=trace.servlet.request if `pup metrics tags list` shows
the default metric is flat for this service (gotcha 5).

<from>/<to> should be literal UTC RFC3339 timestamps (e.g.
2026-08-26T12:00:00Z), not a relative window -- a relative window is not
reproducible when re-run later for a report appendix. All output is UTC;
record it as such.

Bakes in --output=json --no-agent --read-only. Prints each query's raw
response labeled by check. pup's metrics-query response shape has no
verified fixed jq filter in this skill (unlike the events-search and
monitors-list envelopes, which are verified), so this script does not guess
one -- read the numbers from the raw output rather than trusting a filter
that could silently return nothing on a shape mismatch.
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
from=$3
to=$4
metric=${TRIAGE_METRIC_NAME:-trace.http.request}
# Rollup interval, in seconds, pinned on every metrics query below. Not optional: `pup metrics
# query` otherwise picks its own interval from the query span, reports it nowhere in the response,
# and does not even keep it consistent between services in one sweep. Reading a 10-second bucket as
# a per-minute figure understates counts ~6x -- see pup-recipes.md gotcha 7, which this default
# exists to prevent. Raise it for long windows (3600 for a multi-day view); do not lower it below
# 60 unless you have a specific reason and will state the interval in the report.
rollup_seconds=${TRIAGE_ROLLUP_SECONDS:-60}

echo "Metric: $metric (override with TRIAGE_METRIC_NAME if this service is flat -- see gotcha 5). Rollup: ${rollup_seconds}s (override with TRIAGE_ROLLUP_SECONDS)." >&2
echo "Window: $from..$to (UTC)." >&2

echo "== 1/4 (check 4): absolute p95 for resource_name=$resource_name ==" >&2
pup metrics query \
  --query="p95:${metric}{env:prod,service:${service},resource_name:${resource_name}}.rollup(max, ${rollup_seconds})" \
  --from="$from" --to="$to" --output=json --no-agent --read-only

echo "== 2/4 (check 4): whole-service p95, same window (isolates resource-level vs infra-wide) ==" >&2
pup metrics query \
  --query="p95:${metric}{env:prod,service:${service}}.rollup(max, ${rollup_seconds})" \
  --from="$from" --to="$to" --output=json --no-agent --read-only

echo "== 3/4 (check 5): traffic / sample volume for resource_name=$resource_name ==" >&2
pup metrics query \
  --query="sum:${metric}.hits{env:prod,service:${service},resource_name:${resource_name}}.as_count().rollup(sum, ${rollup_seconds})" \
  --from="$from" --to="$to" --output=json --no-agent --read-only

echo "== 4/4 (check 6): error rate as a percentage for resource_name=$resource_name ==" >&2
pup metrics query \
  --query="(sum:${metric}.errors{env:prod,service:${service},resource_name:${resource_name}}.as_count().rollup(sum, ${rollup_seconds})/sum:${metric}.hits{env:prod,service:${service},resource_name:${resource_name}}.as_count().rollup(sum, ${rollup_seconds}))*100" \
  --from="$from" --to="$to" --output=json --no-agent --read-only
