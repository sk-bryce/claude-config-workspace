#!/usr/bin/env bash
# Check 1: monitor definition. See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: monitor-definition.sh <monitor_id>

Check 1: fetches a monitor's definition -- query, type, priority, notification
targets, tags, creator, created/modified, overall_state, draft_status,
matching_downtimes, thresholds. Bakes in --output=json --no-agent --read-only.
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -eq 1 ]] || usage
monitor_id=$1

raw=$(pup monitors get "$monitor_id" --output=json --no-agent --read-only)

type=$(echo "$raw" | jq -r 'type')
if [[ "$type" != "object" ]]; then
  echo "ERROR: pup monitors get returned unexpected top-level type '$type' (expected object). Raw output:" >&2
  echo "$raw" >&2
  exit 2
fi

echo "$raw" | jq '{
  id, name, type, query, tags, priority, creator, created, modified,
  overall_state, overall_state_modified, draft_status, matching_downtimes,
  message, options
}'
