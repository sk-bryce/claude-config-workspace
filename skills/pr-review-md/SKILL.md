---
name: pr-review-md
description: |
  This skill should be used when the user asks to review a GitHub PR and also file, log, doc, or
  record the result - "review PR #123 and log it", "review this PR and file it",
  "/pr-review-md 123" - or to post a review that already exists as a report,
  "post the review for PR #123". Writes one Markdown report per PR into a directory recorded in
  agent memory: findings rated Impact and Confidence, sorted, each led by a copy-paste-ready PR
  comment, plus a Summary and a Recommendation. Code judgment is delegated to the native `review`
  skill. Filing is the whole job by default; posting the comments and submitting an
  APPROVE/COMMENT/REQUEST_CHANGES review is an opt-in posting phase that confirms first and walks
  every finding. A bare "review PR #123" with no filing qualifier does not trigger this - that
  stays with `review`. Scope: workspace.
---

<!--
created: 2026-08-05
updated: 2026-09-30
spec: specs/skills.md (pr-review-md section)
generated-by: claude-sonnet-5 (main agent, no skill-author pass)
model: claude-sonnet-5
harness: Claude Code
-->

# PR Review (Markdown report)

Wrap the native `review` skill so its analysis lands as one persisted Markdown report per PR - a
fixed Impact/Confidence rating per finding, sorted, each led by a copy-paste-ready PR comment,
plus a Summary and a rule-derived Recommendation. This skill does not review code itself;
`review` does the judgment, this skill steers its output vocabulary and files the result.

The skill has two phases:

- **Phase 1 - review and file.** Always runs. Ends with written reports and nothing sent anywhere.
- **Phase 2 - post the review.** Runs only when the user explicitly asks for the review to be
  posted, and only through the gates in `references/phase-2.md`.

## Hard rule: filing is the default, posting is opt-in and gated

**Phase 1's entire output is a local Markdown file per PR. It never touches GitHub.** No
`gh pr comment`, no `gh pr review`, no `gh api ... /reviews`, no posting any finding text, and no
submitting an `APPROVE`/`COMMENT`/`REQUEST_CHANGES` state - regardless of what the computed
Recommendation says, and regardless of how confident or severe the findings are. The
"copy-paste-ready PR comment" text (step 7) exists so a human can paste it; Phase 1 pastes
nothing. The Recommendation (step 8) is a label written into the report, not an instruction to
execute.

Do this even when it would be easy to also post while you're already looking at the PR - a prior
run of this skill did exactly that, more than once, without being asked. None of these is
authorization: a `Request changes` recommendation, a Blocker finding, an obviously broken build,
or the fact that the PR is already open in front of you.

**Posting requires an explicit ask from the user**, and even then it runs only as Phase 2, which
confirms before it starts and asks per finding. Consequences worth stating plainly:

- If the user's original request bundled the posting ask with the review ("review PR #123, log it,
  and post the comments"), that does **not** skip the gates and does not license posting inline.
  Finish Phase 1 for every PR, then enter Phase 2 at its confirmation step like any other run.
- Never post outside Phase 2's single review submission. No ad hoc `gh pr comment` to "just flag
  one thing", no individually posted inline comments alongside a review.
- The own-PR path (F1 through F5, in `references/phase-2.md`) is Phase 2's only other write to
  GitHub: it pushes commits to the user's own PR branch, and only after the user answered yes to
  pushing.
- A subagent running Phase 1's steps 2 through 10 is bound by all of this exactly as this context
  is. It posts nothing and never enters Phase 2.
- Whatever Phase 2 does post or push carries no attribution of any kind, and a push is never
  forced.

## When this fires

Only when the request pairs a PR review with an explicit filing/logging qualifier - "review
PR #123 and log it", "review this PR and file/doc/record it", "/pr-review-md 123". A bare
"review PR #123" with no such qualifier is out of scope: let it go to the native `review`
skill rather than competing for that phrasing.

A request to post a review that already exists as a report - "post the review for PR #123",
"submit the comments from that PR review" - also lands here, entering at Phase 2 rather than
Phase 1. A request to review *and* post in one message still runs Phase 1 first.

## Report directory

Reports go to a directory recorded in agent memory under the key `pr-review-docs-location`, referred
to below as `<report-directory>`. Resolve it before step 4, where the expensive `review` run
happens - filename resolution at step 9 is just the last place the value is used. A Phase 2 run
entered on its own resolves it the same way, first, since it has no report to read without it.

1. Check memory for `pr-review-docs-location` (the harness surfaces `MEMORY.md` at session start).
   If it names a directory, use it.
2. If it is absent, **ask the user where reports should go** using `AskUserQuestion`, offering
   `~/workspace/workbench/prs` as the recommended option alongside one to name a different path.
   Ask before running `review`, not after - a completed review with nowhere to file it wastes the
   expensive half of the run.
3. Once answered, write the memory entry so later sessions do not re-ask. Create
   `<memory-dir>/pr-review-docs-location.md`:

   ```markdown
   ---
   name: pr-review-docs-location
   description: PR review documents are written to <path>, outside the reviewed repo, one file per PR
   metadata:
     type: project
   ---

   **Report directory: `<path>`.** PR review documents written by the `pr-review-md` skill go there,
   named `<pr-number>-<ticket>-<slug>.md`, outside the reviewed repository - so nothing in that repo
   points at them. Check there before re-reviewing a PR.
   ```

   Then add the one-line pointer to that same memory directory's `MEMORY.md` (the link below is
   relative to `<memory-dir>`, not to this skill):
   `- [PR review docs location](pr-review-docs-location.md) - where pr-review-md writes reports`

If the user declines to name a directory, stop rather than guessing one - say the review was not
run and that it needs a destination first.

Memory is scoped per project directory in this harness, so a first run from a new project root will
ask again. That is expected; answer it and the entry is written for that project too.

## Phase 1 - review and file

Step 1 runs in this context for every PR the request names. Steps 2 through 10 then run once per
PR in a subagent, all PRs at once - see "Running steps 2 through 10" below. Steps 11 and 12 run
back in this context once every PR has its report.

### Running steps 2 through 10

Steps 2 through 10 fetch the PR, run `review`, and write the report - most of the run's tokens.
Run them in a subagent per PR so that bulk stays out of this context, which goes on to hold the
refinement pass and any posting walk. A subagent reading this file for its brief skips this
section and the "Report directory" section above, and starts at step 2, taking the report
directory and ticket prefix from its brief rather than from memory or the user.

- **Resolve everything the subagent cannot.** It cannot ask the user anything and may not see
  this session's memory. Before dispatching, have the report directory (above), each PR's target
  and repo (step 1), and the `jira-ticket-prefix` memory value, or the fact that none is recorded.
- **Say which path each PR takes, before it starts.** Print one line per PR, e.g.
  `PR #482: reviewing in a general-purpose subagent (sonnet)`, or on the fallback,
  `PR #482: reviewing inline (<this session's model>) - Agent tool unavailable`.
- **Dispatch every PR in one message**, one `Agent` call each, so they run in parallel:
  `subagent_type: "general-purpose"`, `model: "sonnet"`, and this brief, filled in:

  > Read `<skill-dir>/SKILL.md`, then run its Phase 1 steps 2 through 10 for one PR: `<target>`
  > in `<owner>/<repo>`. Report directory: `<report-directory>`. JIRA ticket prefix: `<prefix>`
  > (or: none recorded, so skip the ticket rule in step 9). Resolve the skill's relative paths
  > against `<skill-dir>`. The skill's hard rule binds you in full: post nothing to GitHub. Do not
  > ask the user anything; if a step needs a decision, stop and return the question instead.
  > Return only the report path, the Recommendation line, the finding count, and whether you
  > invoked `review` through the `Skill` tool.

  `<skill-dir>` is this skill's base directory, which the harness names when the skill loads.
- **Fall back to inline** when the `Agent` tool is not available here: run steps 2 through 10 in
  this context, one PR at a time. Also run a PR inline, and say so, when its subagent reports it
  could not invoke `review` - even if it wrote a report. A subagent that returns a question gets
  it answered here and is dispatched again with the answer in its brief. A subagent that errors,
  or returns a report path that is not on disk, is dispatched once more; if that also fails, run
  the PR inline and say so.

### Steps

1. **Resolve the PR.** Identify the PR number/URL and repo the same way `fetch-pr` does. If no
   repo is named and none can be inferred from the working directory's git remote, ask which
   repo rather than guessing.

2. **Fetch metadata.** Call
   `../fetch-pr/scripts/fetch-pr.sh <target> [--repo owner/repo] --compact` (no `--diff` - this
   skill doesn't analyze code). Reuse this instead of re-deriving `gh pr view` calls. From the
   returned JSON, take `number`, `title`, `state`, `isDraft`, `headRefOid` (the head commit SHA)
   and `author`. Also keep `comments` (general comments), `reviews` (review bodies), and
   `inline_comments` (per-line review comments, with `path` and `line`) - this is everything
   already said on the PR, with every body in full, needed for step 4's duplicate-avoidance
   instruction. Phase 2 does not reuse these values; its P2 fetches a fresh copy.

3. **Derive the PR state label:**
   - `state=OPEN` and `isDraft=true` -> `draft`
   - `state=OPEN` -> `open`
   - `state=MERGED` -> `merged`
   - `state=CLOSED` -> `closed`

4. **Invoke `review`.** Call the `Skill` tool with `skill: "review"` and `args` set to the PR
   reference plus an explicit rating request, e.g.:

   > `<PR reference>` - rate every finding with two explicit labels, Impact:
   > Blocker|High|Medium|Low|Nit and Confidence: High|Medium|Low, plus file/line and a concise
   > description of each, so they can be turned into standalone review comments afterward.

   `review` performs its own analysis as normal here; what follows steers its output vocabulary
   and, in the two cases below, what it evaluates - not its underlying judgment.

   **If the diff touches any documentation content** - a dedicated doc file (ADR, RFC, design
   doc, README, or similar), or docstring/comment-block additions, changes, or removals inside
   otherwise code-focused files - append a second instruction asking `review` to also evaluate
   that content's substance, not just mechanical correctness. This applies whether the PR is
   entirely documentation or only partly so; in a mixed-content PR the code portions still get
   ordinary code review alongside it. E.g.:

   > This PR includes documentation content (standalone docs and/or docstrings/comments within
   > code). For that content specifically, also evaluate it as a proposal/explanation, not just
   > for mechanical correctness (formatting, links, citations, structure): is the reasoning sound
   > and adequately supported, are alternatives and risks meaningfully addressed, are there gaps
   > or unaddressed edge cases, and does it accurately describe the accompanying code (if any).
   > Rate substance findings on the same Impact/Confidence scale as everything else.

   **Also append a third instruction so `review` doesn't repeat feedback already on the PR.**
   Format the comments/reviews/inline comments kept in step 2 into a short plain-text list -
   author, and file/line for inline items, plus each body - and include it in the same `args`,
   e.g.:

   > Here is feedback already posted on this PR - do not repeat a finding whose substance
   > duplicates one of these; skip it instead:
   > - @alice on src/auth.ts:42: "this doesn't handle the null case"
   > - @bob (general comment): "can you add a test for the retry path?"

   If there's nothing already on the PR, say so plainly instead of omitting this instruction:

   > No existing comments or reviews are on this PR yet.

5. **Extract findings.** Once `review` returns, read its output the same way a person would -
   pull out each finding's Impact, Confidence, file/line, and description via comprehension, not
   a rigid parser. Tolerate `review` not perfectly following the requested format. A finding with
   no discernible Impact/Confidence defaults to Low/Low rather than being dropped silently.

6. **Sort.** Order findings by Impact rank descending (Blocker > High > Medium > Low > Nit) as
   the primary key, Confidence rank descending (High > Medium > Low) as the tiebreak - highest
   impact and highest confidence first.

7. **Draft each finding.** For every finding, write:
   - A respectful, clear, concise fenced block of text ready to paste directly as a PR review
     comment - actionable, references the file/line. Write from a perspective of curiosity, not
     judgment: ask rather than accuse, assume the author had a reason even where it isn't stated,
     and frame the finding as a question or observation ("what happens if", "did you consider")
     rather than a verdict - while staying direct enough that the actionable ask is unambiguous.
   - Underneath the fence, any further context or detail that doesn't belong in the comment
     itself (rationale, alternatives, links).

8. **Decide the Recommendation.** Any Blocker or High finding -> `Request changes`. Only
   Medium/Low/Nit findings (no Blocker/High present) -> `Comment`. No findings at all ->
   `Approve`. Write a one-line rationale for whichever applies. A report label only - see
   "Hard rule" above. Phase 2 reuses it as the pre-selected default for the submission type,
   still subject to the user's answer there.

9. **Derive the filename.**
   - `<pr-id>` is the PR number (e.g. `482`).
   - Short title: at most 8 words, literal or paraphrased from the PR's actual title. If the
     title contains a JIRA ticket matching the team's project pattern (`<PREFIX>-\d+`; the real
     prefix is in agent memory under `jira-ticket-prefix`), the short title begins with that ticket
     ID (kept uppercase). Slugify the rest: lowercase, non-alphanumeric characters become hyphens.
   - **Before writing**, check for an existing file matching
     `<report-directory>/<pr-id>-*.md`. If one exists, reuse that exact filename (overwrite
     it) instead of generating a fresh filename from a new paraphrase - this keeps re-reviews of
     the same PR overwriting one file rather than accumulating duplicates. If that file has a
     `## Review submission` or `## Own-PR fixes` section from an earlier run, carry it forward
     into the rewrite rather than dropping it - it is the record of what was already said on, or
     changed in, the PR.

10. **Write the report.** Ensure `<report-directory>` exists, then write
    `<report-directory>/<pr-id>-<short-title-slug>.md`:

    ```markdown
    # PR Review: <PR title> (#<id>)

    ## Summary

    **State:** draft | open | merged | closed

    <one/two lines on what was reviewed.>

    ## Recommendation: Approve | Comment | Request changes
    <one-line rationale>

    ## Findings
    ### 1. <short finding title>
    - **Impact:** Blocker|High|Medium|Low|Nit
    - **Confidence:** High|Medium|Low
    - **Location:** <path>:<line> | <path>:<start>-<end> | none

    \`\`\`
    <respectful, curious, copy-paste-ready PR comment>
    \`\`\`

    <further context/detail not needed in the comment>

    ### 2. ...
    ```

    If there are no findings, state that plainly in the Findings section instead of leaving it
    empty.

11. **Refine the reports.** Once every PR in the request has its report written, and before
    anything is offered for posting, run one refinement pass per report:
    - If the `review-md` skill is available, invoke it via the `Skill` tool on each report path
      and apply what it returns.
    - If it is not available, fork instead - dispatch an `Agent` with `subagent_type: "fork"` per
      report, asking it to proofread and refine that file in place - so the read-through stays
      out of this context. Keep the fork in the foreground in case it needs to ask something.

    This pass is editorial only: fix accuracy, consistency, omissions, and wording, and tighten
    the fenced comment text without changing what it asks for. It does not re-litigate findings,
    ratings, or the Recommendation, and it does not add findings of its own.

12. **Report back.** Tell the user the file path written for each PR, which path it ran on
    (subagent and model, or inline and why), and relay each Recommendation line so they don't
    have to open the file to see it. If posting was not explicitly asked for, stop here - do not
    follow up by posting the comments, approving, or requesting changes. If the user then asks
    to post, that is Phase 2, starting at its confirmation step.

## Phase 2 - post the review

Runs only when the user explicitly asked for the review to be posted - in the original request,
in a later message, or as a request to post a review that already exists as a report. Its steps,
P1 through P7 and the own-PR path F1 through F5, live in `references/phase-2.md`. Read that file
in full before P1 and follow it. Nothing in this file is enough to post, submit, or push, so
never do any of those from memory of it.

## Non-goals

Do not perform independent code analysis - all review judgment stays with `review`. The own-PR
path changes code, but only to do what a finding the user chose already asks; it does not look
for new problems. Do not wrap
`security-review` (it reviews the local current branch's pending changes, not an arbitrary PR by
number - it doesn't fit this skill's PR-by-reference model) or the `pr-review-toolkit` plugin. Do
not fire on a bare "review PR #N" with no filing/logging qualifier.
