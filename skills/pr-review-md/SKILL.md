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
updated: 2026-09-14
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
  posted, and only through the gates below.

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
confirms before it starts and asks per finding. Two consequences worth stating plainly:

- If the user's original request bundled the posting ask with the review ("review PR #123, log it,
  and post the comments"), that does **not** skip the gates and does not license posting inline.
  Finish Phase 1 for every PR, then enter Phase 2 at its confirmation step like any other run.
- Never post outside Phase 2's single review submission. No ad hoc `gh pr comment` to "just flag
  one thing", no individually posted inline comments alongside a review.

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

Steps 1 through 10 handle one PR. If the request names several, run them for each PR in turn
before moving on to step 11.

1. **Resolve the PR.** Identify the PR number/URL and repo the same way `fetch-pr` does. If no
   repo is named and none can be inferred from the working directory's git remote, ask which
   repo rather than guessing.

2. **Fetch metadata.** Call `../fetch-pr/scripts/fetch-pr.sh <target> [--repo owner/repo] --json`
   (no `--diff` - this skill doesn't analyze code). Reuse this instead of re-deriving `gh pr view`
   calls. From the returned JSON, take `pr.number`, `pr.title`, `pr.state`, `pr.isDraft`,
   `pr.headRefOid` (the head commit SHA) and `pr.author.login`. Also keep `pr.comments` (general
   comments), `pr.reviews` (review bodies), and `inline_comments` (per-line review comments) -
   this is everything already said on the PR, needed for step 4's duplicate-avoidance
   instruction. The head SHA and author login are what Phase 2 needs to anchor its comments and
   to tell whether the authenticated user is the PR author.

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
     `## Review submission` section from an earlier run, carry it forward into the rewrite rather
     than dropping it - it is the record of what was already said on the PR.

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

12. **Report back.** Tell the user the file path written for each PR and relay each Recommendation
    line so they don't have to open the file to see it. If posting was not explicitly asked for,
    stop here - do not follow up by posting the comments, approving, or requesting changes. If
    the user then asks to post, that is Phase 2, starting at its confirmation step.

## Phase 2 - post the review

Runs only when the user explicitly asked for the review to be posted, whether in the original
request or in a later message. P1 confirms once for the whole batch; P2 through P7 then repeat per
PR, in the order the user named them.

Phase 2 can also start on its own, without Phase 1, when the user asks to post a review from a
report that already exists (from an earlier session, say). In that case resolve
`<report-directory>`, glob `<report-directory>/<pr-id>-*.md` for the PR's report, and begin at
P1; P2 fetches the metadata either way. Do not re-run `review`. If no report exists for that PR,
say so and ask whether to review it first (Phase 1, then Phase 2) rather than reviewing and
posting on the assumption that is what was wanted.

P1. **Confirm before starting.** Use `AskUserQuestion`: name the PRs and the report files, and
    offer "Post the review - walk the findings" (recommended, since they asked) against "Don't
    post - stop here". A bundled ask in the original request still goes through this gate. If the
    user declines, stop and say nothing was posted.

P2. **Gather what the submission needs.** Before asking the user anything about findings,
    collect all three of these - a walk that runs to the end and then fails on a missing
    precondition wastes every answer the user gave:
    - **The report.** Read it from disk rather than working from memory of what was drafted:
      step 11's refinement may have changed the wording, and the file is the source of truth.
    - **Fresh PR metadata and the diff.** Re-run the step 2 fetch with `--diff` added:
      `../fetch-pr/scripts/fetch-pr.sh <target> [--repo owner/repo] --diff --json`. One call
      covers the head SHA (`pr.headRefOid`), which may have moved since Phase 1, the current
      state and reviews, and the diff - which P4 needs in order to know which lines GitHub will
      accept an inline comment on. Phase 1 skips the diff because it does not analyze code;
      Phase 2 needs it for anchoring, not for judgment.
    - **The authenticated user, and whether they can write.** `gh api user -q .login` for the
      duplicate check below and P5's own-PR rule, and
      `gh api repos/<owner>/<repo> -q .permissions.push` to confirm the submission can land at
      all.

    Then check for reasons not to proceed and raise them before the walk: the report already
    carries a `## Review submission` section, the fetch shows a review by the authenticated
    user on this PR (a second submission double-notifies the author), the PR is merged or closed
    (`APPROVE` and `REQUEST_CHANGES` are rejected on a closed PR, leaving `COMMENT` as the only
    usable event), or the login has no write access, in which case nothing can be submitted at
    all. Say what you found and ask whether to continue.

P3. **Walk each finding.** For every finding in the report, in report order:
    - **First, in the message before the tool call**, show the finding verbatim: its number and
      title, Impact, Confidence, file/line, the fenced comment text exactly as the report has it,
      and the context beneath the fence. The user is deciding on that exact text, so it has to be
      on screen - never summarize it into the question.
    - Then ask with `AskUserQuestion`, header naming the finding number, with these four options:
      - **Post as-is** (recommended) - goes into the review submission verbatim.
      - **Revise the wording before posting** - post it, but not in these words.
      - **Defer** - not this round; the finding stands and stays in the report as outstanding.
      - **Skip** - do not post it at all; the finding is withdrawn for this PR.
    - One finding per `AskUserQuestion` call. The point of the walk is that the user approves
      each comment's exact text before it lands on someone else's PR, and four comment bodies
      stacked above one call works against that.
    - On **Revise**, take the user's wording or steer (the tool's free-text option carries it),
      rewrite the comment, show the revised text verbatim, and ask again with the same four
      options until it resolves to Post, Defer, or Skip. Post exactly the text they last saw and
      accepted - no further polishing afterward.

P4. **Assemble the submission.** One review per PR, carrying every finding marked Post:
    - Each becomes an inline comment anchored with `path` and `line` from the finding's file/line,
      `side: RIGHT` for an added or unchanged line and `LEFT` for a removed one, with the comment
      text as `body`. Pin `commit_id` to the head SHA from P2 so the anchors do not drift.
    - `line` is numbered in the file the `side` names: the head file for `RIGHT`, the pre-image
      for `LEFT`. Read the number off the diff fetched in P2 rather than assuming a finding's
      cited line is a head-file line - a removed line numbered as if it were one lands on the
      wrong code or is rejected outright.
    - A finding covering a range of lines uses `start_line` plus `start_side` alongside `line`
      and `side`, which mark the end of the range. Without them a range finding silently
      collapses onto one line.
    - GitHub only accepts an inline comment on a line that appears in the diff. If a finding's
      location isn't in the diff - or the finding has no file/line at all, as with "there are no
      tests for this" - move it into the review body as a short note naming the file and line
      where it has one, and tell the user it was relocated rather than dropping it.
    - The review body is one or two sentences: factual, polite, respectful, summarizing what the
      review covers. **No attribution of any kind** - no "automated", "AI-assisted",
      "generated by", no tool or model name, no footer, no badge. It reads as an ordinary review
      left by the account submitting it, because that is what it is.
    - **If the walk left nothing marked Post, stop here.** Say that every finding was deferred or
      skipped and submit nothing - a body-only review the user did not ask for still notifies the
      author. Record the dispositions per P7 so a later run knows what was deferred. The one
      exception is a report with no findings at all, where `Approve` was the Recommendation and
      the user asked to post it: that submits as a body-only `APPROVE` with no comments.

P5. **Choose the submission type.** Show the assembled payload first - the exact body text, the
    count of inline comments with their file/line, anything relocated into the body, and how many
    findings were deferred or skipped. Then ask with `AskUserQuestion`, header "Review type":
    `APPROVE`, `COMMENT`, `REQUEST_CHANGES`. Mark as recommended whichever matches the report's
    Recommendation (Approve -> `APPROVE`, Comment -> `COMMENT`, Request changes ->
    `REQUEST_CHANGES`). If the authenticated user is the PR author, GitHub rejects `APPROVE` and
    `REQUEST_CHANGES` on their own PR - offer `COMMENT` alone and say why.

P6. **Submit.** Post everything in a single API call; never post the inline comments individually
    first, which double-notifies and leaves orphaned comments behind if the submit then fails.
    `gh pr review` cannot carry inline comments, so use the reviews endpoint with a JSON payload
    written to this session's scratchpad directory (`<scratch>` below):

    ```bash
    gh api --method POST repos/<owner>/<repo>/pulls/<pr-id>/reviews \
      --input "<scratch>/pr-<pr-id>-review.json" > "<scratch>/pr-<pr-id>-response.json"
    echo "exit: $?"
    ```

    The payload is `{"commit_id": "<head-sha>", "event": "<APPROVE|COMMENT|REQUEST_CHANGES>",
    "body": "<review body>", "comments": [{"path": ..., "line": ..., "side": ..., "body": ...}]}`,
    with `start_line`/`start_side` added to any comment covering a range, per P4.
    Build it with a tool that quotes for you (`jq`, or a written file) rather than interpolating
    comment text into a shell string. Judge the call by its exit status and the response body,
    not by the absence of visible output. On failure, report the error text verbatim, record in
    the report that the submission failed, and ask before retrying - do not silently re-anchor
    comments, downgrade the event, or fall back to posting comments one at a time.

P7. **Update the report.** Append a dated entry under a `## Review submission` section at the end
    of the report file - append, never replace: an earlier entry is the record of what was
    already said on this PR, and P2's existing-submission check and step 9's carry-forward both
    depend on it surviving.

    ```markdown
    ## Review submission

    ### Submitted <YYYY-MM-DD>

    - **Type:** APPROVE | COMMENT | REQUEST_CHANGES
    - **Review:** <html_url from the API response>
    - **Body:** <the one/two-sentence review body as submitted>

    | # | Finding | Disposition |
    |---|---------|-------------|
    | 1 | <short title> | Posted as-is |
    | 2 | <short title> | Posted (revised) |
    | 3 | <short title> | Deferred |
    | 4 | <short title> | Skipped |
    ```

    For a revised finding, also record the text actually posted, verbatim, beneath that finding in
    the Findings section - the report should show what the PR now says, not only what was drafted.

    Then report back: the review URL, how many comments were posted, and which findings were
    deferred or skipped. A later Phase 2 run against the same report brings deferred findings back
    into the P3 walk and leaves skipped ones out unless the user asks for them.

## Non-goals

Do not perform independent code analysis - all review judgment stays with `review`. Do not wrap
`security-review` (it reviews the local current branch's pending changes, not an arbitrary PR by
number - it doesn't fit this skill's PR-by-reference model) or the `pr-review-toolkit` plugin. Do
not fire on a bare "review PR #N" with no filing/logging qualifier.

**Never post anything back to GitHub outside Phase 2 - see "Hard rule" above.**
