#!/usr/bin/env bash
# Check 3: 90-day cycle history and stats. See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: monitor-history-90d.sh <monitor_id> [from] [to]

Check 3: pulls a monitor's alert-event history, pairs the events into
trigger/recovery episodes, and derives cycle stats -- total cycles, distinct
days, self-recovered count, and cycle-duration min/max/mean/median in
seconds. Defaults to the trailing 90 days. A monitor that fires 30 times a
quarter and always self-recovers is a monitor problem, not a service
problem; this is the check that tells you which.

Emits a `cycles` array alongside the aggregates, one entry per episode, with
`start`, `start_source`, `trigger_ts`, `recovery_ts`, `escalations`,
`duration_seconds`, and `trigger_to_recovery_seconds`. Read it, not just the
aggregates: `start_source` tells you whether the episode start came from an
event row or had to be derived from a duration field, and three aggregate
counters flag the cases where the raw events mislead --

  still_open_cycles                                    no recovery row yet
  cycles_starting_before_any_event_row                 start derived, not observed
  cycles_where_duration_disagrees_with_visible_trigger duration != trigger..recovery

A non-zero value in either of the last two means the window you would have
taken from the visible trigger row is the wrong window. Use `start`.

Exit codes: 0 ok; 1 bad arguments; 2 unrecognized response shape or an
unresolvable monitor_id (the check did NOT run); 3 no events AND the
monitor's own last transition is outside the window; 4 no events BUT the
monitor changed state inside the window -- an indexing gap, not a quiet
monitor. On 4, Step 3's evidence-depth gate cannot be evaluated at all,
so the full Step 4 checklist is mandatory.

Bakes in: the @-prefixed monitor_id filter, --output=json --no-agent
--read-only, the events-search {data:[...]} envelope, nanosecond-to-second
duration conversion, and the trigger/recovery pairing rules documented in
the jq block below (the duration field lives on the recovery row, not the
trigger row, and a trigger row that has one is an escalation rather than a
new cycle). Median is the true median: the middle element for an odd-length
array, the mean of the two middle elements for an even-length one.

This pull is slow and, per SKILL.md, should run once per group even if
grouping is later revisited. Set TRIAGE_CACHE_DIR to a scratch directory to
cache the raw pull keyed on <monitor_id, from, to>; a re-run with the same
arguments reads the cache instead of re-querying. Delete the cache file (or
point TRIAGE_CACHE_DIR elsewhere) to force a fresh pull.
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -ge 1 && $# -le 3 ]] || usage
monitor_id=$1
from=${2:-90d}
to=${3:-now}

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

cache_file=""
if [[ -n "${TRIAGE_CACHE_DIR:-}" ]]; then
  mkdir -p "$TRIAGE_CACHE_DIR"
  # printf, not echo: echo's trailing newline is not alphanumeric, so tr would map it to a
  # trailing '_' in every cache key.
  safe_from=$(printf '%s' "$from" | tr -c 'A-Za-z0-9' '_')
  safe_to=$(printf '%s' "$to" | tr -c 'A-Za-z0-9' '_')
  cache_file="$TRIAGE_CACHE_DIR/monitor-history-90d_${monitor_id}_${safe_from}_${safe_to}.json"
fi

from_cache=0
if [[ -n "$cache_file" && -f "$cache_file" ]]; then
  echo "Using cached 90-day pull: $cache_file (delete it, or unset/change TRIAGE_CACHE_DIR, to force a re-pull)" >&2
  raw=$(cat "$cache_file")
  from_cache=1
else
  raw=$(pup events search --query="@monitor_id:${monitor_id}" \
    --from="$from" --to="$to" --limit=500 --output=json --no-agent --read-only)
fi

if ! echo "$raw" | jq -e 'has("data")' >/dev/null 2>&1; then
  echo "ERROR: pup events search did not return the expected {data:[...]} envelope." >&2
  echo "$raw" >&2
  exit 2
fi

count=$(echo "$raw" | jq '.data | length')
if [[ "$count" -eq 0 ]]; then
  echo "No events for monitor $monitor_id in $from..$to." >&2
  # Do not stop here. An empty 90-day history does not establish that the monitor never fires --
  # it is also what an event-indexing gap looks like, and the difference decides whether Step 3's
  # evidence-depth gate is even evaluable.
  empty_result_verdict "$monitor_id" "$from" "$to" || exit $?
  exit 3
fi
if [[ "$count" -eq 500 ]]; then
  echo "WARNING: hit the 500-event --limit exactly -- history may be truncated. Narrow the window or paginate." >&2
fi

# Only cache a validated response -- an error envelope or empty result must never be replayed as if it were data.
if [[ -n "$cache_file" && "$from_cache" -eq 0 ]]; then
  echo "$raw" > "$cache_file"
fi

echo "$raw" | jq '
  # Cycle derivation. Read this before trusting the numbers, because the "duration" field on an
  # alert event does not mean what its name suggests:
  #
  #   * A TRIGGER row (status "error") normally carries duration: null.
  #   * A RECOVERY row (status "success") carries the duration of the episode that just ended,
  #     in nanoseconds, measured from the episode start -- so recovery_ts minus duration is the
  #     true episode start. This is where cycle durations come from; an earlier version of this
  #     script looked for them on the trigger rows and so always reported
  #     self_recovered_cycles: 0 and cycle_duration_seconds: null.
  #   * A non-OK row with a NON-NULL duration is not a fresh cycle. It is a re-trigger or an
  #     escalation inside an episode that is already open (Warn -> Alert, or a re-notify), and
  #     its duration also measures back to that episode start. Counting such rows as cycles
  #     inflates cycle_count and reports a window start later than the real one.
  #   * The true episode start can therefore precede every event row in the response. The live
  #     example (<monitor-B>): trigger 10:05:03Z (duration 19620s) and recovery
  #     12:08:03Z (duration 27000s) both subtract to 04:38:03Z, which has no event row at all.
  #     Investigating from 10:05:03Z looks at a flat series and concludes "no cause found".
  #
  # So: pair events into episodes, take the episode start from the duration field when no event
  # row shows it, and report both the authoritative duration and the visible trigger-to-recovery
  # interval, with a counter for cycles where the two disagree.
  .data
  | sort_by(.attributes.timestamp)
  | map(.attributes.attributes + {timestamp: .attributes.timestamp}) as $all
  | ($all
      | reduce .[] as $e (
          {episodes: [], open: null};
          if $e.status == "success" then
            (if .open == null then
               .open = {
                 start: (
                   if $e.duration != null
                   then ((($e.timestamp | fromdateiso8601) - ($e.duration / 1000000000)) | todateiso8601)
                   else null end
                 ),
                 start_source: "derived_from_recovery_duration_no_trigger_row",
                 trigger_ts: null,
                 escalations: 0
               }
             else . end)
            | .open.recovery_ts = $e.timestamp
            | .open.duration_seconds = (
                if $e.duration != null then ($e.duration / 1000000000)
                elif .open.start != null then (($e.timestamp | fromdateiso8601) - (.open.start | fromdateiso8601))
                else null end
              )
            | .open.trigger_to_recovery_seconds = (
                if .open.trigger_ts != null
                then (($e.timestamp | fromdateiso8601) - (.open.trigger_ts | fromdateiso8601))
                else null end
              )
            | .episodes += [.open]
            | .open = null
          elif $e.duration == null then
            (if .open == null then . else .episodes += [.open] end)
            | .open = {
                start: $e.timestamp,
                start_source: "trigger_event",
                trigger_ts: $e.timestamp,
                escalations: 0,
                recovery_ts: null,
                duration_seconds: null,
                trigger_to_recovery_seconds: null
              }
          else
            (if .open == null then
               .open = {
                 start: ((($e.timestamp | fromdateiso8601) - ($e.duration / 1000000000)) | todateiso8601),
                 start_source: "derived_from_trigger_duration_no_start_row",
                 trigger_ts: null,
                 escalations: 0,
                 recovery_ts: null,
                 duration_seconds: null,
                 trigger_to_recovery_seconds: null
               }
             else . end)
            | .open.escalations += 1
          end
        )
      | (if .open == null then .episodes else .episodes + [.open] end)
    ) as $cycles
  | ($cycles | map(select(.duration_seconds != null) | .duration_seconds)) as $durs
  | {
      total_events: ($all | length),
      cycle_count: ($cycles | length),
      distinct_days: ($cycles | map(select(.start != null) | .start[0:10]) | unique | length),
      self_recovered_cycles: ($cycles | map(select(.recovery_ts != null)) | length),
      still_open_cycles: ($cycles | map(select(.recovery_ts == null)) | length),
      cycles_starting_before_any_event_row:
        ($cycles | map(select(.start_source != "trigger_event")) | length),
      cycles_where_duration_disagrees_with_visible_trigger:
        ($cycles
         | map(select(
             .trigger_to_recovery_seconds != null
             and .duration_seconds != null
             and ((.duration_seconds - .trigger_to_recovery_seconds) | fabs) > 60
           ))
         | length),
      cycle_duration_seconds: (
        if ($durs | length) == 0 then null else {
          min: ($durs | min),
          max: ($durs | max),
          mean: (($durs | add) / ($durs | length)),
          median: (
            ($durs | sort) as $s
            | ($s | length) as $n
            | if $n % 2 == 1
              then $s[($n - 1) / 2]
              else ($s[$n / 2 - 1] + $s[$n / 2]) / 2
              end
          )
        } end
      ),
      first_cycle: ($cycles | first | .start),
      last_cycle: ($cycles | last | .start),
      cycles: $cycles
    }
'
