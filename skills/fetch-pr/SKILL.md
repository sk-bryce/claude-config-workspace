---
name: fetch-pr
description: |
  This skill should be used when the user asks for a GitHub pull request's status, comments, or
  metadata - "what's the status of PR #123", "get me the comments on PR #123",
  "fetch PR info for <url>" - when a bare PR URL is pasted, or as the first step before any
  review judgment starts. Returns one formatted summary via the `gh` CLI: metadata including
  draft status and the head commit SHA, CI/check status, review decision, general comments, and
  inline review comments grouped by file, plus the diff on request, so PR-review work does not
  re-derive raw `gh` calls each time. Fetch and format only - it does not judge or score the
  code, and never posts anything back to GitHub. Scope: workspace.
---

<!--
created: 2026-08-05
updated: 2026-09-14
spec: specs/skills.md (fetch-pr section)
generated-by: claude-sonnet-5 (main agent, no skill-author pass)
model: claude-sonnet-5
harness: Claude Code
-->

# Fetch PR

Fetch GitHub PR data via `gh` and hand back one formatted summary - metadata (including draft
status, the author login, and the head commit SHA, `headRefOid`), CI/check status, review
decision, general comments, and inline review comments grouped by file, plus the diff when asked.
This skill only fetches and formats; it never judges the code and never posts anything back to
GitHub.

## Resolving the request

1. Identify the PR: a number (`123`), a full PR URL, or a reference like "PR #123 in
   owner/repo". Extract the repo if one is named or a URL is given.
2. If no repo is named, just call the script without `--repo` - it relies on `gh`'s own
   inference from the current working directory's git remote. If that inference fails, the
   script exits non-zero with `gh`/git's real error text (e.g. "not a git repository" or
   "unable to determine current repository"); when you see that specific failure, ask the user
   which repo rather than guessing one, then retry with `--repo`.
3. Map natural-language asks to script flags:
   - Mentions of "diff", "changes", "what changed" -> add `--diff`.
   - A request that wants to parse or chain the result programmatically -> add `--json`.
   - Otherwise, no extra flags - the default Markdown summary covers metadata, checks, review
     decision, general comments, and inline comments.

## Running the script

Call `scripts/fetch-pr.sh` with the resolved arguments:

```
scripts/fetch-pr.sh <pr-number-or-url> [--repo owner/repo] [--diff] [--json]
```

Relay its stdout back to the user largely as-is - the script already formats the summary, so
this is a relay step, not a re-fetch. Do not re-run individual `gh` commands manually to
double-check or re-derive what the script already returned.

## Error handling

If the script exits non-zero (auth failure, rate limit, PR or repo not found), surface its
stderr text verbatim rather than swallowing it or guessing at the cause.

## Non-goals

Do not use this skill to review or judge the PR's code, to score findings, or to post comments
or reviews back to GitHub - it is a fetch/format step only. Existing review workflows can layer
on top of what this skill returns, but performing that review is out of scope here.
