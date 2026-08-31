#!/usr/bin/env bash
# Shared helpers for the triage-datadog wrapper scripts.
#
# NOT a wrapper: it runs no query, covers no check, and is never invoked directly. It exists
# because monitor-timeline.sh and monitor-history-90d.sh need the same 45-line verdict function,
# and a byte-identical copy in each is a copy that diverges the first time one of them is fixed.
# The wrapper table in pup-recipes.md deliberately does not list it.

# --- distinguish "did not fire" from "fired but events are not indexed" ------------------------
# An empty events-search result has three very different causes, and the wrong reading closes a
# real incident as a non-event. Worked example, with illustrative figures (`<monitor-A>` in
# pup-recipes.md): a high-priority monitor transitions at 08:17:26Z off a sustained error rate and
# has ZERO alert events indexed across 90 days, via @monitor_id and via title search. So never
# conclude "did not fire" from an empty result alone -- ask the monitor itself.
#
# Normalizes to the first 19 chars (YYYY-MM-DDTHH:MM:SS) so a '+00:00' offset and a 'Z' suffix
# compare correctly as strings; every timestamp involved is UTC, so no date(1) arithmetic and no
# GNU/BSD portability problem.
#
# Returns: 2 unresolvable monitor_id; 3 empty and consistent with a quiet monitor; 4 empty but the
# monitor demonstrably transitioned inside the window (an indexing gap). Never returns 0.
empty_result_verdict() {
  local monitor_id=$1 win_from=$2 win_to=$3
  local mon state modified

  if ! mon=$(pup monitors get "$monitor_id" --output=json --no-agent --read-only 2>/dev/null); then
    echo "The monitor_id $monitor_id does not resolve via 'pup monitors get' either -- the ID is" >&2
    echo "probably wrong. Confirm it from the monitor URL before widening the window." >&2
    return 2
  fi

  state=$(echo "$mon" | jq -r '.overall_state // "unknown"')
  modified=$(echo "$mon" | jq -r '.overall_state_modified // ""')
  echo "Monitor $monitor_id resolves: overall_state=$state overall_state_modified=${modified:-none}" >&2

  if [[ -z "$modified" ]]; then
    echo "It reports no overall_state_modified, so whether it ever fired cannot be settled here." >&2
    echo "Cross-check the underlying metric over the window before concluding anything." >&2
    return 3
  fi

  # Only comparable when the caller passed literal RFC3339 bounds rather than a relative window.
  if [[ "$win_from" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && [[ "$win_to" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    local m_cmp f_cmp t_cmp
    m_cmp=${modified:0:19}; f_cmp=${win_from:0:19}; t_cmp=${win_to:0:19}
    if [[ "$m_cmp" > "$f_cmp" && "$m_cmp" < "$t_cmp" ]]; then
      echo "" >&2
      echo "*** The monitor DID change state inside this window ($modified) and yet has no indexed" >&2
      echo "*** alert events. This is not 'it did not fire'. Treat the event stream as unavailable" >&2
      echo "*** for this monitor and reconstruct the timeline from the underlying metric instead:" >&2
      echo "***   - pull the monitor's own query expression over the window (check 4)" >&2
      echo "***   - for a sum(last_Nm) monitor, recompute the rolling sum to find the threshold" >&2
      echo "***     crossings, which is what the trigger and recovery timestamps would have been" >&2
      echo "*** Report the gap in the write-up; a P1 with no indexed events may also mean the" >&2
      echo "*** notification never fired, which is worth chasing on the notification target's side." >&2
      return 4
    fi
    echo "Its last transition ($modified) is outside $win_from..$win_to, so the empty result is" >&2
    echo "consistent with the monitor genuinely not firing in this window. Still confirm against" >&2
    echo "the underlying metric before reporting 'no alerts' -- indexing gaps exist (see above)." >&2
    return 3
  fi

  echo "Window bounds are relative, so they cannot be compared against the transition timestamp." >&2
  echo "Re-run with literal RFC3339 bounds, or judge from the transition timestamp above." >&2
  return 3
}
