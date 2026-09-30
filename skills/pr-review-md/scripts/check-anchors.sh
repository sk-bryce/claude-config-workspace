#!/usr/bin/env bash
# Report which side and line of a PR's diff each finding location can anchor an inline comment
# to, without printing the diff itself. See references/phase-2.md, P2 and P4.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-anchors.sh <pr-number-or-url> [--repo owner/repo] <path:line | path:start-end>...

Fetches the PR diff (gh pr diff) and prints one tab-separated row per anchor
candidate for each location, in the order given:

  <location>  <side>  <kind>  <text of the line in the diff>

  side  RIGHT (head file) or LEFT (pre-image), or - when nothing is commentable.
  kind  added | context | removed for a single line; range for a start-end span
        that sits inside one hunk on one side; or, with side -, one of
        file-not-in-diff, line-not-in-diff, range-not-in-one-hunk.

RIGHT is reported for an added or context line at that head-file number, and
LEFT for a removed line at that pre-image number, so one location can print two
rows (a RIGHT and a LEFT); pick the one whose text matches the finding. The
split is on the last colon, so a path may itself contain colons.
EOF
}

# usage() prints to stdout and does not exit, so `--help` is a success. Argument errors go
# through die_usage; exit 2 matches fetch-pr.sh, the sibling script this one is used alongside.
die_usage() { usage >&2; exit 2; }

target=""
repo=""
locations=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die_usage
      repo="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "check-anchors.sh: unknown flag '$1'" >&2
      die_usage
      ;;
    *)
      if [[ -z "$target" ]]; then
        target="$1"
      elif [[ "$1" =~ ^.+:[0-9]+(-[0-9]+)?$ ]]; then
        locations+=("$1")
      else
        echo "check-anchors.sh: '$1' is not path:line or path:start-end" >&2
        die_usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$target" || ${#locations[@]} -eq 0 ]]; then
  echo "check-anchors.sh: need a PR and at least one location" >&2
  die_usage
fi

repo_args=()
if [[ -n "$repo" ]]; then
  repo_args=(--repo "$repo")
fi

diff_text=$(gh pr diff "$target" ${repo_args[@]+"${repo_args[@]}"})

# Locations travel through the environment rather than awk -v, which would expand backslash
# escapes in a path. The awk sticks to POSIX features so BSD awk on macOS runs it unchanged.
queries=$(printf '%s\n' "${locations[@]}")
printf '%s\n' "$diff_text" | QUERIES="$queries" awk '
function record(side, line, kind, text,    k) {
  k = side SUBSEP path SUBSEP line
  hunk_of[k] = hunk
  kind_of[k] = kind
  gsub(/\t/, " ", text)
  if (length(text) > 100) text = substr(text, 1, 100) "..."
  text_of[k] = text
}
function count(spec,    parts, n) {
  n = split(spec, parts, ",")
  return (n > 1) ? parts[2] + 0 : 1
}
function start(spec,    parts) {
  split(spec, parts, ",")
  return substr(parts[1], 2) + 0
}
function row(loc, side, kind, text) {
  printf "%s\t%s\t%s\t%s\n", loc, side, kind, text
}

# Inside a hunk, the header counts decide where it ends, so a removed line reading "-- x"
# is never mistaken for a "--- " file header.
old_left > 0 || new_left > 0 {
  c = substr($0, 1, 1)
  text = substr($0, 2)
  if (c == "+") {
    record("R", new_n, "added", text); new_n++; new_left--
  } else if (c == "-") {
    record("L", old_n, "removed", text); old_n++; old_left--
  } else if (c == " " || $0 == "") {
    record("R", new_n, "context", text); record("L", old_n, "context", text)
    new_n++; old_n++; new_left--; old_left--
  }
  next
}
/^diff --git / { path = ""; old_path = ""; next }
/^--- / { old_path = substr($0, 5); sub(/^a\//, "", old_path); next }
/^\+\+\+ / {
  p = substr($0, 5)
  if (p == "/dev/null") { path = old_path } else { sub(/^b\//, "", p); path = p }
  in_diff[path] = 1
  next
}
/^@@ / {
  split($0, h, " ")
  old_n = start(h[2]); old_left = count(h[2])
  new_n = start(h[3]); new_left = count(h[3])
  hunk++
  next
}

END {
  nq = split(ENVIRON["QUERIES"], q, "\n")
  for (i = 1; i <= nq; i++) {
    loc = q[i]
    if (loc == "") continue
    cut = 0
    for (j = length(loc); j > 0; j--) if (substr(loc, j, 1) == ":") { cut = j; break }
    fpath = substr(loc, 1, cut - 1)
    spec = substr(loc, cut + 1)
    if (!(fpath in in_diff)) { row(loc, "-", "file-not-in-diff", ""); continue }

    dash = index(spec, "-")
    if (dash == 0) {
      n = spec + 0
      found = 0
      kr = "R" SUBSEP fpath SUBSEP n
      kl = "L" SUBSEP fpath SUBSEP n
      if (kr in hunk_of) { row(loc, "RIGHT", kind_of[kr], text_of[kr]); found = 1 }
      if ((kl in hunk_of) && kind_of[kl] == "removed") { row(loc, "LEFT", "removed", text_of[kl]); found = 1 }
      if (!found) row(loc, "-", "line-not-in-diff", "")
      continue
    }

    s = substr(spec, 1, dash - 1) + 0
    e = substr(spec, dash + 1) + 0
    found = 0
    split("R L", sides, " ")
    for (x = 1; x <= 2; x++) {
      ks = sides[x] SUBSEP fpath SUBSEP s
      ke = sides[x] SUBSEP fpath SUBSEP e
      if ((ks in hunk_of) && (ke in hunk_of) && hunk_of[ks] == hunk_of[ke]) {
        row(loc, (sides[x] == "R") ? "RIGHT" : "LEFT", "range", text_of[ks])
        found = 1
        break
      }
    }
    if (!found) row(loc, "-", "range-not-in-one-hunk", "")
  }
}'
