---
name: pr-review-md
description: Wraps the native `review` skill so a PR review lands as a persisted, consistently formatted Markdown report in a memory-recorded directory instead of transient chat output - findings rated Impact (Blocker/High/Medium/Low/Nit) and Confidence (High/Medium/Low), sorted highest-impact-and-confidence first, each led by a copy-paste-ready PR comment written respectfully and from curiosity, not judgment, with a Summary (including PR state: draft/open/merged/closed) and a Recommendation (Approve/Comment/Request changes) derived from a fixed rule. Wherever a PR touches documentation content - a dedicated doc file (ADR/RFC/design doc/README) or docstring/comment-block changes inside otherwise code-focused files, even in a mixed-content PR - also asks `review` to evaluate that content's substance, not just mechanical correctness. Use when a PR review request also carries a filing/logging qualifier - "review PR #123 and log/doc/file/record it", "/pr-review-md 123". Does not trigger on a bare "review PR #123" with no such qualifier - that stays with the native `review` skill. Does not perform its own code analysis (delegates to `review`), does not wrap `security-review` or the pr-review-toolkit plugin, and never posts anything back to GitHub.
---

<!--
created: 2026-08-05
updated: 2026-08-27
spec: specs/skills.md (pr-review-md section)
generated-by: claude-sonnet-5 (main agent, no skill-author pass)
model: claude-sonnet-5
harness: Claude Code
-->

# PR Review (Markdown report)

Wrap the native `review` skill so its analysis lands as one persisted Markdown report - a fixed
Impact/Confidence rating per finding, sorted, each led by a copy-paste-ready PR comment, plus a
Summary and a rule-derived Recommendation. This skill does
not review code itself; `review` does the judgment, this skill steers its output vocabulary and
files the result.

## Hard rule: local file only, never a GitHub action

**This skill's entire output is a local Markdown file. It never touches GitHub.** That means:
no `gh pr comment`, no `gh pr review`, no posting any finding text, and no submitting an
`APPROVE`/`REQUEST_CHANGES`/`COMMENT` review state - regardless of what the computed
Recommendation says, and regardless of how confident the findings are. The "copy-paste-ready PR
comment" text (step 7) exists so a human can paste it; this skill pastes nothing itself. The
Recommendation (step 8) is a label written into the report, not an instruction to execute.

Do this even when it would be easy to also post while you're already looking at the PR - a
prior run of this skill did exactly that, more than once, without being asked. Posting or
landing a review state is a separate, explicit request the user makes afterward, in a later
message, after reading the report. If the user's original request for this skill also asked to
post the review, stop before step 10 and confirm that's really wanted, since it falls outside
what this skill does - don't infer it from a recommendation of "Request changes" or from the
severity of the findings.

## When this fires

Only when the request pairs a PR review with an explicit filing/logging qualifier - "review
PR #123 and log it", "review this PR and file/doc/record it", "/pr-review-md 123". A bare
"review PR #123" with no such qualifier is out of scope: let it go to the native `review`
skill rather than competing for that phrasing.

## Report directory

Reports go to a directory recorded in agent memory under the key `pr-review-docs-location`, referred
to below as `<report-directory>`. Resolve it before step 4, where the expensive `review` run
happens - filename resolution at step 9 is just the last place the value is used.

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

## Steps

1. **Resolve the PR.** Identify the PR number/URL and repo the same way `fetch-pr` does. If no
   repo is named and none can be inferred from the working directory's git remote, ask which
   repo rather than guessing.

2. **Fetch metadata.** Call `../fetch-pr/scripts/fetch-pr.sh <target> [--repo owner/repo] --json`
   (no `--diff` - this skill doesn't analyze code). Reuse this instead of re-deriving `gh pr view`
   calls. From the returned JSON, take `pr.number`, `pr.title`, `pr.state`, `pr.isDraft`. Also
   keep `pr.comments` (general comments), `pr.reviews` (review bodies), and `inline_comments`
   (per-line review comments) - this is everything already said on the PR, needed for step 4's
   duplicate-avoidance instruction.

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
   "Hard rule" above.

9. **Derive the filename.**
   - `<pr-id>` is the PR number (e.g. `482`).
   - Short title: at most 8 words, literal or paraphrased from the PR's actual title. If the
     title contains a JIRA ticket matching the team's project pattern (`<PREFIX>-\d+`; the real
     prefix is in agent memory under `jira-ticket-prefix`), the short title begins with that ticket
     ID (kept uppercase). Slugify the rest: lowercase, non-alphanumeric characters become hyphens.
   - **Before writing**, check for an existing file matching
     `<report-directory>/<pr-id>-*.md`. If one exists, reuse that exact filename (overwrite
     it) instead of generating a fresh filename from a new paraphrase - this keeps re-reviews of
     the same PR overwriting one file rather than accumulating duplicates.

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

11. **Report back.** Tell the user the file path written and relay the Recommendation line so
    they don't have to open the file to see it. Stop there - do not follow up by posting the
    comments, approving, or requesting changes on the PR. If the user then asks to post it, that
    is a new, separate request to act on.

## Non-goals

Do not perform independent code analysis - all review judgment stays with `review`. Do not wrap
`security-review` (it reviews the local current branch's pending changes, not an arbitrary PR by
number - it doesn't fit this skill's PR-by-reference model) or the `pr-review-toolkit` plugin. Do
not fire on a bare "review PR #N" with no filing/logging qualifier.

**Never post anything back to GitHub without explicit user authorization - see "Hard rule"
above**, including the bundled case where the original request already asked for it: that still
goes through the confirm-first step there rather than being executed straight through.
