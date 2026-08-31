#!/usr/bin/env bash
# Check 2: exact timeline for one alert cycle. See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: monitor-timeline.sh <monitor_id> <from> <to> [org]

Check 2: exact trigger/recovery timestamps for one alert cycle, plus a
ready-to-paste deep-link per event. [org] is the Datadog org subdomain (or
set TRIAGE_DD_ORG); supply it and each event gains a `link` field pointing at
that exact alert event, which is what the report's header block requires --
see "Alert event" in report-template.md. Without it you get `evt_id` alone
and have to assemble the URL by hand (see "Datadog web links" in
pup-recipes.md). <from>/<to> must be Z-suffixed UTC RFC3339 timestamps
(2026-08-26T09:55:00Z) padded ~10 minutes either side of the cycle -- checked,
and rejected with exit 1 otherwise. A "+00:00" offset is not accepted, and
neither is a relative window: a relative window is not reproducible when
re-run later for a report appendix.

Bakes in: the @-prefixed monitor_id filter (a bare monitor_id: silently
returns unfiltered, org-wide results), --output=json --no-agent --read-only,
and the events-search {data:[...]} envelope.

Exit codes: 0 ok; 1 bad arguments; 2 unrecognized response shape or an
unresolvable monitor_id (the check did NOT run -- do not read it as "no
alerts"); 3 no events AND the monitor's own last transition is outside the
window, i.e. legitimately quiet; 4 no events BUT the monitor did change
state inside the window, meaning the event stream is unavailable for this
monitor and the timeline has to be reconstructed from the metric.
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -eq 3 || $# -eq 4 ]] || usage
monitor_id=$1
from=$2
to=$3
org=${4:-${TRIAGE_DD_ORG:-}}

# Reject a timestamp jq cannot parse, here, as exit 1 ("bad arguments"). The link-building filter
# below calls fromdateiso8601, which accepts ONLY the Z-suffixed form -- given "+00:00" it aborts
# with a jq error and the script would exit 5, a code the documented contract does not define and
# a gathering subagent has no rule for.
for ts_label in "from:$from" "to:$to"; do
  ts_name=${ts_label%%:*}
  ts_value=${ts_label#*:}
  if [[ ! "$ts_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "ERROR: <$ts_name> must be a Z-suffixed UTC RFC3339 timestamp (e.g. 2026-08-26T09:55:00Z)," >&2
    echo "not '$ts_value'. A '+00:00' offset and a relative window ('12h') are both rejected: this" >&2
    echo "check's output goes into a report appendix and has to be reproducible." >&2
    exit 1
  fi
done

# Shared helpers. Sourced rather than duplicated: empty_result_verdict() is 45 lines and is needed
# identically by monitor-timeline.sh and monitor-history-90d.sh. dirname handles the case where
# this script is invoked by bare name from its own directory, which ${BASH_SOURCE[0]%/*} does not.
_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -r "$_script_dir/_common.sh" ]]; then
  echo "ERROR: _common.sh not found next to this script (looked in $_script_dir). The wrapper" >&2
  echo "scripts must stay together in references/scripts/; a lone copy cannot run." >&2
  exit 2
fi
# shellcheck source=_common.sh
source "$_script_dir/_common.sh"

raw=$(pup events search --query="@monitor_id:${monitor_id}" \
  --from="$from" --to="$to" --output=json --no-agent --read-only)

if ! echo "$raw" | jq -e 'has("data")' >/dev/null 2>&1; then
  echo "ERROR: pup events search did not return the expected {data:[...]} envelope." >&2
  echo "$raw" >&2
  exit 2
fi

count=$(echo "$raw" | jq '.data | length')
if [[ "$count" -eq 0 ]]; then
  echo "No events for monitor $monitor_id in $from..$to." >&2
  # Do not stop here. An empty result does not establish that the monitor did not fire.
  empty_result_verdict "$monitor_id" "$from" "$to" || exit $?
  exit 3
fi

# from_ts/to_ts are milliseconds. jq's fromdateiso8601 does the conversion so this stays portable
# -- BSD date(1) and GNU date(1) disagree on how to parse an RFC3339 string, and this workspace has
# both. It requires exactly the Z-suffixed form the usage above already mandates.
echo "$raw" | jq --arg org "$org" --arg mid "$monitor_id" --arg from "$from" --arg to "$to" '
  ($from | fromdateiso8601 * 1000 | floor) as $from_ms
  | ($to   | fromdateiso8601 * 1000 | floor) as $to_ms
  | .data
  | sort_by(.attributes.timestamp)
  | map({
      timestamp: .attributes.timestamp,
      status: .attributes.attributes.status,
      duration_seconds: (
        .attributes.attributes.duration as $d
        | if $d == null then null else $d / 1000000000 end
      ),
      evt_id: .attributes.attributes.evt.id,
      title: .attributes.attributes.title,
      # The link the report header block is built from -- one per event, so the trigger and the
      # recovery each get their own. Null when no org was supplied; assemble it by hand then.
      link: (
        if $org == "" then null
        else "https://\($org).datadoghq.com/monitors/\($mid)"
             + "?from_ts=\($from_ms)&to_ts=\($to_ms)&event_id=\(.attributes.attributes.evt.id)"
        end
      )
    })
'
