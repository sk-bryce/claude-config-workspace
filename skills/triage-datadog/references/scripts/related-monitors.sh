#!/usr/bin/env bash
# Check 10: related-monitor correlation. See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: related-monitors.sh <team_tag> <window_start> [window_end]

Check 10: enumerates monitors in scope, sorts them into three buckets, and
then cross-checks the alert event stream for the ones that matter.

Buckets, emitted under state_snapshot:

  transitioned_in_window                 the investigation set
  still_firing_from_before_window        also the investigation set (Alert/Warn only)
  no_data_or_unknown_from_before_window  excluded as non-alerts, but listed and counted

The third bucket exists because "still firing" cannot be spelled
`overall_state != "OK"` -- that also matches "No Data", and a chronically
dataless monitor is not an alert. On a scope of a few hundred monitors that
one clause can turn a handful of genuine transitions into a set of dozens.

What the event cross-check is for: NOT "catching a monitor that fired and
recovered inside the window". A state snapshot cannot miss that case -- the
recovery IS the last transition, so it lands in the window by definition.
What the snapshot genuinely cannot show is intermediate history: a monitor
that cycled three times inside the window looks identical to one that cycled
once, and only the event stream carries the individual trigger and recovery
timestamps that check 2 needs. It also reports
monitors_with_no_indexed_events, which is how an event-indexing gap becomes
visible rather than being mistaken for a quiet monitor.

The cross-check is scoped to the investigation set by @monitor_id, not run
org-wide. An unscoped `source:alert` query burns its row limit on other
teams' alerts: on a busy org a 200-row limit can be consumed by well under
two minutes of a 24-hour window, none of it the requested team's.

<team_tag> is the Datadog tag value, e.g. "team:<team-tag>" (see agent memory
under datadog-triage-environment for the tag in use).

<window_start> MUST be an offset-free UTC prefix, e.g. "2026-08-26T00:00:00".
pup returns overall_state_modified with a "+00:00" suffix, not "Z" -- a
"Z"-suffixed comparison value silently matches nothing. The script appends
the "Z" that `pup events search` requires itself; do not pass both forms.

<window_end> defaults to "now" and only bounds the event-stream cross-check;
the state-snapshot listing has no upper bound by design (a monitor still
firing today is kept regardless of when it last transitioned).

Output is a single JSON object on stdout (scope, window, monitors_in_scope,
state_snapshot, event_cross_check), so it can be piped to jq directly.
Progress and counts go to stderr.
EOF
}

# usage() prints to stdout and does not exit, so `--help` is a success: `script --help | less`
# works and CI does not read it as a failure. Argument errors go through die_usage, which keeps
# the exit 1 documented in pup-recipes.md's wrapper exit-code table.
die_usage() { usage >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || die_usage
team_tag=$1
window_start=$2
window_end=${3:-now}

if [[ "$window_start" == *Z || "$window_start" == *+* ]]; then
  echo "ERROR: window_start must be an offset-free UTC prefix (e.g. 2026-08-26T00:00:00), not '$window_start'." >&2
  echo "overall_state_modified compares as a plain string; a Z suffix or +00:00 offset will not match." >&2
  exit 1
fi

echo "== Monitors tagged '$team_tag' with a state transition since $window_start (or currently non-OK) ==" >&2

list_raw=$(pup monitors list --tags="$team_tag" --limit=500 --output=json --no-agent --read-only)

list_type=$(echo "$list_raw" | jq -r 'type')
if [[ "$list_type" != "array" ]]; then
  echo "ERROR: pup monitors list returned unexpected top-level type '$list_type' (expected a bare array)." >&2
  echo "$list_raw" >&2
  exit 2
fi

total=$(echo "$list_raw" | jq 'length')

# Three buckets, not one. SKILL.md Step 2 says to keep monitors that transitioned in the window
# AND monitors still firing from before it -- but "still firing" cannot be spelled
# `overall_state != "OK"`, because that also matches "No Data", and a chronically dataless monitor
# (a decommissioned env:qa check, say) is not firing. On a scope of a few hundred monitors that
# one clause can turn a handful of genuine transitions into a set of dozens, the surplus being
# No Data monitors whose last transition was months earlier. Separating the buckets keeps the
# real set small without dropping anything silently -- the No Data monitors are still counted
# and sampled below, they are just not presented as alerts.
# shellcheck disable=SC2016
# The single quotes are required, not an oversight: `$since` and `$s` below are jq variables, and
# the shell must not touch them. `$since` is bound by the --arg on each jq invocation that uses this
# filter; double quotes here would expand both to empty strings and the bucketing would silently
# classify every monitor into the last branch.
bucket_filter='
  def bucket($since):
    if .overall_state_modified >= $since then "transitioned_in_window"
    elif (.overall_state | ascii_downcase) as $s
         | ($s == "alert" or $s == "warn" or $s == "warning") then "still_firing_from_before_window"
    elif (.overall_state | ascii_downcase) == "ok" then "quiet"
    else "no_data_or_unknown_from_before_window"
    end;
'

state_snapshot=$(echo "$list_raw" | jq --arg since "$window_start" "$bucket_filter"'
  map(. + {_bucket: bucket($since)})
  | {
      transitioned_in_window: (
        map(select(._bucket == "transitioned_in_window"))
        | sort_by(.overall_state_modified)
        | map({id, name, overall_state, overall_state_modified})
      ),
      still_firing_from_before_window: (
        map(select(._bucket == "still_firing_from_before_window"))
        | sort_by(.overall_state_modified)
        | map({id, name, overall_state, overall_state_modified})
      ),
      no_data_or_unknown_from_before_window: (
        map(select(._bucket == "no_data_or_unknown_from_before_window"))
        | sort_by(.overall_state_modified)
        | {
            count: length,
            note: "Not alerts. Excluded from the investigation set; listed so the exclusion is visible.",
            oldest_transition: (first | .overall_state_modified),
            newest_transition: (last | .overall_state_modified),
            monitors: map({id, name, overall_state, overall_state_modified})
          }
      )
    }
')

counts=$(echo "$list_raw" | jq -r --arg since "$window_start" "$bucket_filter"'
  map(bucket($since))
  | [
      (map(select(. == "transitioned_in_window")) | length),
      (map(select(. == "still_firing_from_before_window")) | length),
      (map(select(. == "no_data_or_unknown_from_before_window")) | length)
    ]
  | @tsv
')
IFS=$'\t' read -r n_transitioned n_firing n_nodata <<<"$counts"
kept=$((n_transitioned + n_firing))

echo "Of $total monitors tagged '$team_tag': $n_transitioned transitioned in the window, $n_firing were" >&2
echo "already firing before it (investigation set = $kept), and $n_nodata were No Data or Unknown from" >&2
echo "before the window and are excluded as non-alerts (they are still listed in the output)." >&2
echo "State these counts in the report; never silently truncate." >&2

# The two APIs disagree on timestamp format, and reusing one value for both is a bug that kills
# this half of the check outright: `pup monitors list` returns overall_state_modified with a
# "+00:00" offset, so the jq string comparison above needs an offset-free value; `pup events
# search --from` requires an explicit zone and fails with "Error: premature end of input" when
# given one without. So convert here rather than asking the caller for two spellings of the same
# instant.
events_from="${window_start}Z"
if [[ "$window_end" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+$ ]]; then
  events_to="${window_end}Z"
else
  events_to="$window_end"   # 'now', or already zone-qualified
fi

# Scope the event query to the monitors we actually care about. An unscoped `source:alert` query
# is org-wide, and on a busy org the 200-row limit can be consumed by other teams' alerts within
# seconds of the window edge -- a 24-hour window truncating after well under two minutes of it,
# none of it this team's. That is not a usable cross-check at any limit. An OR'd @monitor_id
# filter returns only this scope's events, so the limit stops being the binding constraint: a
# window that truncates org-wide comes back in tens of rows when scoped.
ids=$(echo "$state_snapshot" | jq -r '
  [(.transitioned_in_window[].id), (.still_firing_from_before_window[].id)] | .[]
')

if [[ -z "$ids" ]]; then
  echo "== Cross-check skipped: no monitors in the investigation set to query ==" >&2
  event_cross_check='{"skipped": "investigation set is empty", "events": []}'
else
  id_query="@monitor_id:($(echo "$ids" | paste -sd '|' - | sed 's/|/ OR /g'))"
  echo "== Cross-check: alert events for the $(echo "$ids" | wc -l | tr -d ' ') monitors in the investigation set ==" >&2

  events_raw=$(pup events search --query="$id_query" --from="$events_from" --to="$events_to" \
    --limit=500 --output=json --no-agent --read-only)

  if ! echo "$events_raw" | jq -e 'has("data")' >/dev/null 2>&1; then
    echo "ERROR: pup events search did not return the expected {data:[...]} envelope." >&2
    echo "$events_raw" >&2
    exit 2
  fi

  event_count=$(echo "$events_raw" | jq '.data | length')
  if [[ "$event_count" -eq 500 ]]; then
    echo "WARNING: hit the 500-event --limit exactly -- the cross-check may be truncated. Narrow the window." >&2
  fi

  # A monitor in the investigation set with zero events here is worth surfacing rather than
  # inferring from an absence: it is the same event-indexing gap that monitor-timeline.sh exits 4
  # on, and it means this monitor's intermediate cycles cannot be recovered from the stream.
  event_cross_check=$(echo "$events_raw" | jq --arg ids "$ids" '
    ($ids | split("\n") | map(select(length > 0) | tonumber)) as $wanted
    | (.data | sort_by(.attributes.timestamp) | map({
        timestamp: .attributes.timestamp,
        monitor_id: .attributes.attributes.monitor_id,
        status: .attributes.attributes.status,
        title: .attributes.attributes.title
      })) as $events
    | {
        query_scope: "investigation set only, not org-wide",
        event_count: ($events | length),
        events: $events,
        monitors_with_no_indexed_events: (
          # Both sides are coerced through tonumber so the set subtraction cannot be defeated by a
          # type mismatch: `pup monitors list` gives integer ids, and whether the event stream
          # spells monitor_id as 12345678 or "12345678" is undocumented. Compared untouched, a
          # string-vs-number stream would match nothing and report EVERY monitor in the set as
          # having no indexed events -- a fabricated indexing gap on every run, in the one field
          # whose whole job is to make a real gap visible. tonumber? drops a null rather than
          # aborting the filter.
          ($wanted - ($events | map(.monitor_id | tonumber?) | unique))
        ),
        note: "monitors_with_no_indexed_events did transition (that is why they are in the set) but have no events in the stream. Reconstruct their timeline from the metric; see monitor-timeline.sh exit code 4."
      }
  ')
fi

jq -n \
  --arg scope "$team_tag" \
  --arg window_start "$window_start" \
  --arg window_end "$window_end" \
  --argjson total "$total" \
  --argjson state_snapshot "$state_snapshot" \
  --argjson event_cross_check "$event_cross_check" \
  '{
     scope: $scope,
     window: {start: $window_start, end: $window_end, note: "UTC; state snapshot has no upper bound by design"},
     monitors_in_scope: $total,
     state_snapshot: $state_snapshot,
     event_cross_check: $event_cross_check
   }'
