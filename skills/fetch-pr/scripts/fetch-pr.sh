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
    -*)
      # Without this arm an unknown flag falls through to the positional case and becomes the PR
      # target, so gh rejects it with its own usage text and the caller has to guess whose error
      # it is. Matched after -h|--help so that arm still wins.
      echo "fetch-pr.sh: unknown flag '$1'" >&2
      usage >&2
      exit 2
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
  number,title,state,isDraft,author,url,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,createdAt,updatedAt,reviewDecision,statusCheckRollup,comments,reviews)

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

# Two jq traps this script kept hitting, fixed once here rather than per query.
#
# `//` substitutes only for null and false, so an empty string falls straight through it. gh
# returns "" - not null - for a reviewDecision that was never set and for a deleted account's
# login, both of which printed as a label with nothing after it. `blank_as` treats "" as missing.
# The statusCheckRollup query spells the same test out inline instead, because its fallback
# is a chain of sibling fields rather than a literal.
#
# `split("\n")` on an empty string returns [], not [""], so `split("\n")[0]` on a bodyless
# review yielded null and printed the literal text "null" - which every approval left without a
# comment hit. `first_line` indexes that safely.
jq_defs='def blank_as($fallback): if . == null or . == "" then $fallback else . end;
         def first_line: (. // "") | split("\n") | (.[0] // "");'

pr_query() { echo "$view_json" | jq -r "$jq_defs $1"; }
comments_query() { echo "$comments_json" | jq -r "$jq_defs $1"; }

echo "## PR #$(pr_query '.number'): $(pr_query '.title')"
echo
draft_suffix=""
if [[ "$(pr_query '.isDraft')" == "true" ]]; then
  draft_suffix=" (draft)"
fi
echo "- State: $(pr_query '.state')$draft_suffix (author: $(pr_query '.author.login | blank_as("unknown")'))"
echo "- URL: $(pr_query '.url')"
echo "- Branch: $(pr_query '.headRefName') -> $(pr_query '.baseRefName')"
echo "- Head SHA: $(pr_query '.headRefOid')"
changed_files=$(pr_query '.changedFiles')
file_noun="files"
if [[ "$changed_files" == "1" ]]; then
  file_noun="file"
fi
echo "- Changes: +$(pr_query '.additions') -$(pr_query '.deletions') across $changed_files $file_noun"
echo "- Created: $(pr_query '.createdAt'), Updated: $(pr_query '.updatedAt')"
echo "- Review decision: $(pr_query '.reviewDecision | blank_as("none")')"
echo

echo "### CI / Checks"
checks=$(pr_query '.statusCheckRollup // [] | .[] | "- \(.name // .context // "unnamed"): \((.conclusion // "") as $c | if $c != "" then $c else (.status // .state // "unknown") end)"')
if [[ -z "$checks" ]]; then
  echo "- No checks reported."
else
  echo "$checks"
fi
echo

echo "### Reviews"
reviews=$(pr_query '.reviews // [] | .[] | "- \(.author.login | blank_as("unknown")) (\(.state)): \(.body | first_line | blank_as("(no body)"))"')
if [[ -z "$reviews" ]]; then
  echo "- No reviews yet."
else
  echo "$reviews"
fi
echo

echo "### General Comments"
general_comments=$(pr_query '.comments // [] | .[] | "- \(.author.login | blank_as("unknown")) (\(.createdAt)): \(.body | blank_as("(no body)"))"')
if [[ -z "$general_comments" ]]; then
  echo "- No general comments."
else
  echo "$general_comments"
fi
echo

echo "### Inline Review Comments (by file)"
inline_by_file=$(comments_query '
  group_by(.path)[] |
  "#### \(.[0].path)\n" +
  (map("- Line \(.line // .original_line // "?") - \(.user.login | blank_as("unknown")): \(.body | blank_as("(no body)"))") | join("\n"))
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
