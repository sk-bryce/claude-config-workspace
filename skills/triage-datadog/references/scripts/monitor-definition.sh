#!/usr/bin/env bash
# Check 1: monitor definition. See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: monitor-definition.sh <monitor_id>

Check 1: fetches a monitor's definition -- query, type, priority, notification
targets, tags, creator, created/modified, overall_state, draft_status,
matching_downtimes, thresholds. Bakes in --output=json --no-agent --read-only.
EOF
}

# usage() prints to stdout and does not exit, so `--help` is a success: `script --help | less`
# works and CI does not read it as a failure. Argument errors go through die_usage, which keeps
# the exit 1 documented in pup-recipes.md's wrapper exit-code table.
die_usage() { usage >&2; exit 1; }

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || die_usage
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
