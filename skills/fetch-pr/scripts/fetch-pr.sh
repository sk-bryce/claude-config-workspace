#!/usr/bin/env bash
# Fetch and format GitHub PR data (metadata, comments, checks, optionally the diff) via gh + jq.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fetch-pr.sh <pr-number-or-url> [--repo owner/repo] [--diff] [--json]

  <pr-number-or-url>  PR number (e.g. 123) or a full PR URL. Required.
  --repo owner/repo   Target repo. Omit to let gh infer it from the current
                       working directory's git remote.
  --diff              Also fetch and include the PR diff (gh pr diff).
  --json              Emit raw merged JSON instead of a Markdown summary.
  -h, --help          Show this help.
EOF
}

target=""
repo=""
want_diff=false
json_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --diff)
      want_diff=true
      shift
      ;;
    --json)
      json_mode=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$target" ]]; then
        echo "fetch-pr.sh: unexpected extra argument '$1'" >&2
        usage >&2
        exit 2
      fi
      target="$1"
      shift
      ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "fetch-pr.sh: missing <pr-number-or-url>" >&2
  usage >&2
  exit 2
fi

repo_args=()
if [[ -n "$repo" ]]; then
  repo_args=(--repo "$repo")
fi

view_json=$(gh pr view "$target" ${repo_args[@]+"${repo_args[@]}"} --json \
  number,title,state,isDraft,author,url,baseRefName,headRefName,additions,deletions,changedFiles,createdAt,updatedAt,reviewDecision,statusCheckRollup,comments,reviews)

# The comments endpoint (inline review comments) needs owner/repo/number, which we can
# always recover from the PR's own url field rather than requiring --repo up front.
read -r owner repo_name pr_number < <(
  echo "$view_json" | jq -r '.url | capture("/(?<o>[^/]+)/(?<r>[^/]+)/pull/(?<n>[0-9]+)$") | "\(.o) \(.r) \(.n)"'
)

comments_json=$(gh api "repos/$owner/$repo_name/pulls/$pr_number/comments" --paginate --jq '.[]' | jq -s '.')

diff_text=""
if $want_diff; then
  diff_text=$(gh pr diff "$target" ${repo_args[@]+"${repo_args[@]}"})
fi

if $json_mode; then
  if $want_diff; then
    jq -n --argjson pr "$view_json" --argjson inline_comments "$comments_json" --arg diff "$diff_text" \
      '{pr: $pr, inline_comments: $inline_comments, diff: $diff}'
  else
    jq -n --argjson pr "$view_json" --argjson inline_comments "$comments_json" \
      '{pr: $pr, inline_comments: $inline_comments}'
  fi
  exit 0
fi

field() { echo "$view_json" | jq -r "$1"; }

echo "## PR #$(field '.number'): $(field '.title')"
echo
draft_suffix=""
if [[ "$(field '.isDraft')" == "true" ]]; then
  draft_suffix=" (draft)"
fi
echo "- State: $(field '.state')$draft_suffix (author: $(field '.author.login // "unknown"'))"
echo "- URL: $(field '.url')"
echo "- Branch: $(field '.headRefName') -> $(field '.baseRefName')"
echo "- Changes: +$(field '.additions') -$(field '.deletions') across $(field '.changedFiles') files"
echo "- Created: $(field '.createdAt'), Updated: $(field '.updatedAt')"
echo "- Review decision: $(field '.reviewDecision // "none"')"
echo

echo "### CI / Checks"
checks=$(echo "$view_json" | jq -r '.statusCheckRollup // [] | .[] | "- \(.name // .context // "unnamed"): \((.conclusion // "") as $c | if $c != "" then $c else (.status // .state // "unknown") end)"')
if [[ -z "$checks" ]]; then
  echo "- No checks reported."
else
  echo "$checks"
fi
echo

echo "### Reviews"
reviews=$(echo "$view_json" | jq -r '.reviews // [] | .[] | "- \(.author.login // "unknown") (\(.state)): \(.body // "" | split("\n")[0])"')
if [[ -z "$reviews" ]]; then
  echo "- No reviews yet."
else
  echo "$reviews"
fi
echo

echo "### General Comments"
general_comments=$(echo "$view_json" | jq -r '.comments // [] | .[] | "- \(.author.login // "unknown") (\(.createdAt)): \(.body)"')
if [[ -z "$general_comments" ]]; then
  echo "- No general comments."
else
  echo "$general_comments"
fi
echo

echo "### Inline Review Comments (by file)"
inline_by_file=$(echo "$comments_json" | jq -r '
  group_by(.path)[] |
  "#### \(.[0].path)\n" +
  (map("- Line \(.line // .original_line // "?") - \(.user.login // "unknown"): \(.body)") | join("\n"))
')
if [[ -z "$inline_by_file" ]]; then
  echo "- No inline review comments."
else
  echo "$inline_by_file"
fi

if $want_diff; then
  echo
  echo "### Diff"
  echo '```diff'
  echo "$diff_text"
  echo '```'
fi
