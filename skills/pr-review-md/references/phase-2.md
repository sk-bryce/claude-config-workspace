<!--
created: 2026-09-30
updated: 2026-09-30
-->

# Phase 2 - post the review

Loaded from `SKILL.md` only when the user explicitly asked for a review to be posted. That file's
"Hard rule" section governs everything here. Script paths below are relative to the skill's own
directory, not to this file.

Runs only when the user explicitly asked for the review to be posted, whether in the original
request or in a later message. P1 confirms once for the whole batch; P2 through P7 then repeat per
PR, in the order the user named them. On a PR the user authored, P2 routes to the own-PR path (F1
through F5) instead of P3 through P7.

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
    collect all four of these - a walk that runs to the end and then fails on a missing
    precondition wastes every answer the user gave:
    - **The report.** Read it from disk rather than working from memory of what was drafted:
      `SKILL.md` step 11's refinement may have changed the wording, and the file is the source of
      truth.
    - **Fresh PR metadata.** Re-run the `SKILL.md` step 2 fetch:
      `../fetch-pr/scripts/fetch-pr.sh <target> [--repo owner/repo] --compact`. It covers the
      head SHA (`headRefOid`), which may have moved since Phase 1, and the current state and
      reviews.
    - **Where each finding can anchor.** Right after that fetch, so the diff it reads matches
      that head SHA, pass every finding's **Location** from the report in one call:
      `scripts/check-anchors.sh <target> [--repo owner/repo] <path:line>...`, a range as
      `path:start-end`. Leave out findings whose Location is `none`, and skip the call if every
      finding's is. The script reads the diff itself and prints one row per anchor candidate -
      location, side, kind, and that line's text - so the diff never enters this context. P3 and
      P4 work from those rows. Judge the call by its exit status and output body; on a non-zero
      exit, report its stderr verbatim and ask rather than guessing anchors.
    - **The authenticated user, and whether they can write.** `gh api user -q .login` for the
      own-PR and duplicate checks below, and
      `gh api repos/<owner>/<repo> -q .permissions.push` to confirm the submission can land at
      all.

    **If the authenticated user is the PR author, take the own-PR path.** GitHub rejects
    `APPROVE` and `REQUEST_CHANGES` on your own PR, and comments addressed to yourself are not the
    useful outcome - fixing the code is. Skip the continue question below and ask with
    `AskUserQuestion`, header "Own PR", offering **Fix findings** (recommended) and **Do
    nothing**. The `question` text carries, as in P3: the PR number, repo and title; that this is
    the user's own PR, so no review will be submitted; how many findings the report holds; and
    anything else P2 found that bears on fixing - a merged or closed PR, where pushed fixes land
    on a branch no longer under review; no write access, so a push cannot land; or an earlier
    `## Own-PR fixes` entry in the report, with its date. On **Do nothing**, stop and say nothing
    was changed or posted. On **Fix findings**, continue at F1.

    Otherwise, check for reasons not to proceed and raise them before the walk: the report already
    carries a `## Review submission` section, the fetch shows a review by the authenticated
    user on this PR (a second submission double-notifies the author), the PR is merged or closed
    (`APPROVE` and `REQUEST_CHANGES` are rejected on a closed PR, leaving `COMMENT` as the only
    usable event), or the login has no write access, in which case nothing can be submitted at
    all. Ask whether to continue with `AskUserQuestion`, and put what you found in the
    `question` text itself, not in a message before the call, which the dialog can cover (see
    P3): the PR number, repo and title, then each reason with its specifics - the date and type
    of the earlier submission, the existing review's state and when it was left, the PR's
    merged or closed state, or the missing write access for that login.

P3. **Walk each finding.** For every finding in the report, in report order:
    - **Put everything the decision needs inside the `AskUserQuestion` call's `question` text.**
      The question dialog can render over a message printed before the call, so the finding
      shown there may not be on screen when the user answers. The user is deciding on the exact
      comment text, so the question itself carries it, in this layout:

      ````text
      PR #<pr-id> (<owner>/<repo>): <PR title>
      Finding <n> of <total>: <finding title>
      Impact: <impact> | Confidence: <confidence> | <file>:<line>

      Comment to post, verbatim:
      ```
      <the fenced comment text exactly as the report has it>
      ```

      Context: <the context beneath the fence, verbatim>

      Post this comment on PR #<pr-id>?
      ````

      Copy the comment text and its context from the report character for character - never
      summarize, shorten, or paraphrase either one into the question. Add a line under the
      Impact line for anything else that bears on the choice: that P2's anchor check found no
      commentable line for the finding (a `-` side), or that it has no file/line at all, so it
      would go into the review body rather than inline (P4); that the finding was deferred on an
      earlier run, with that run's date; or that the text is a revision of the report's wording.
      Omit a line that has nothing to say, such as Context for a finding with none.
    - Set the header to the PR and finding number, e.g. `#482 F3` - the tool caps headers at 12
      characters - and offer these four options:
      - **Post as-is** (recommended) - goes into the review submission verbatim.
      - **Revise the wording before posting** - post it, but not in these words.
      - **Defer** - not this round; the finding stands and stays in the report as outstanding.
      - **Skip** - do not post it at all; the finding is withdrawn for this PR.
    - One finding per `AskUserQuestion` call. The point of the walk is that the user approves
      each comment's exact text before it lands on someone else's PR, and four comment bodies
      in one call works against that.
    - On **Revise**, take the user's wording or steer (the tool's free-text option carries it),
      rewrite the comment, and ask again with the same layout and four options, the revised text
      now in the comment block, until it resolves to Post, Defer, or Skip. Post exactly the text
      they last saw and accepted - no further polishing afterward.

P4. **Assemble the submission.** One review per PR, carrying every finding marked Post:
    - Each becomes an inline comment anchored with `path`, `line` and `side` from the finding's
      P2 anchor row, with the comment text as `body`. Pin `commit_id` to the head SHA from P2 so
      the anchors do not drift.
    - `RIGHT` is an added or unchanged line numbered in the head file; `LEFT` is a removed line
      numbered in the pre-image. When a location printed both a `RIGHT` and a `LEFT` row, use the
      one whose text is the code the finding is about - never assume a cited line is a head-file
      line, since a removed line numbered as if it were one lands on the wrong code or is
      rejected outright.
    - A `range` row covers a span inside one hunk on one side: set `start_line` to the span's
      start and `start_side` to the row's side, alongside the `line` and `side` that mark its
      end. Without them a range finding silently collapses onto one line.
    - GitHub only accepts an inline comment on a line that appears in the diff. A row with side
      `-` (`file-not-in-diff`, `line-not-in-diff`, `range-not-in-one-hunk`), or a finding with no
      file/line at all, as with "there are no tests for this", cannot anchor: move it into the
      review body as a short note naming the file and line where it has one, and tell the user
      it was relocated rather than dropping it.
    - The review body is one or two sentences: factual, polite, respectful, summarizing what the
      review covers. **No attribution of any kind** - no "automated", "AI-assisted",
      "generated by", no tool or model name, no footer, no badge. It reads as an ordinary review
      left by the account submitting it, because that is what it is.
    - **If the walk left nothing marked Post, stop here.** Say that every finding was deferred or
      skipped and submit nothing - a body-only review the user did not ask for still notifies the
      author. Record the dispositions per P7 so a later run knows what was deferred. The one
      exception is a report with no findings at all, where `Approve` was the Recommendation and
      the user asked to post it: that submits as a body-only `APPROVE` with no comments.

P5. **Choose the submission type.** Ask with `AskUserQuestion`, header "Review type":
    `APPROVE`, `COMMENT`, `REQUEST_CHANGES`. The assembled payload goes in the `question` text
    itself, not in a message before the call, for the reason P3 gives: the PR number, repo and
    title; the exact review body, verbatim; the count of inline comments with each one's
    file/line and finding title; anything relocated into the body; how many findings were
    deferred or skipped; and the report's Recommendation line with its rationale. Mark as
    recommended whichever option matches that Recommendation (Approve -> `APPROVE`, Comment ->
    `COMMENT`, Request changes -> `REQUEST_CHANGES`). The user's own PR never reaches this step:
    P2 routed it to the own-PR path.

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
    already said on this PR, and P2's existing-submission check and `SKILL.md` step 9's
    carry-forward both
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

## Own-PR path

Reached only from P2, when the authenticated user authored the PR and chose **Fix findings**.
Nothing is posted as a review; the findings are fixed in the code instead.

F1. **Walk each finding.** Same rules as P3 - report order, one finding per `AskUserQuestion`
    call, everything the decision needs in the `question` text, the same `#<pr-id> F<n>` header -
    with two changes to the layout: the fenced block is labelled "Finding, as the report words
    it:", since it says what to change rather than being text to post, and the last line asks
    "Fix this finding on PR #<pr-id>?". P3's note about a finding with no commentable line does
    not apply here, since nothing is anchored as a comment. Offer three options:
    - **Fix** (recommended) - change the code to do what the finding asks.
    - **Defer** - not this round; the finding stands and stays in the report as outstanding.
    - **Skip** - do not fix it; the finding is withdrawn for this PR.

    Deferred findings from an earlier run come back into this walk; skipped ones stay out unless
    the user asks for them. If the walk leaves nothing marked Fix, stop, record the dispositions
    per F5, and say nothing was changed.

F2. **Ask about committing and pushing.** Before any edit, ask with one `AskUserQuestion` call
    holding two questions, each with the PR number, the head branch (`headRefName` from P2),
    and the findings marked Fix, by number and title, in its `question` text:
    - "Commit the fixes?" - **Yes** (recommended) or **No**. On No, the edits stay uncommitted
      in the worktree for the user to review.
    - "Push the commits to `<headRefName>`?" - **Yes** (recommended) or **No**. Say in the
      question that this applies only if the fixes are committed, and repeat any P2 finding that
      bears on it: a merged or closed PR, or no write access.

    A Yes to push with a No to commit pushes nothing; say so rather than committing to make the
    push possible.

F3. **Set up a worktree.** Fixing needs a local clone of the PR's repo. Use the working
    directory when one of its remotes points at `<owner>/<repo>`; otherwise ask where the
    checkout is rather than cloning one. Use the remote whose URL matches the PR's repo - do not
    assume it is `origin`. Then:

    ```bash
    git fetch <remote> <headRefName>
    git worktree add --detach .worktrees/pr-<pr-id> <remote>/<headRefName>
    ```

    A detached worktree avoids clashing with a local branch of the same name, including one
    already checked out elsewhere. Confirm the worktree's `HEAD` matches the head SHA from P2;
    if it does not, the branch moved since the review, so say so and ask before fixing against
    code the review never saw. If the fetch fails because the head branch lives on a fork, say
    so and ask rather than guessing at a fork remote.

F4. **Fix, verify, commit, push.** Work in the worktree, one finding at a time in report order:
    - Make the smallest change that does what the finding asks. If the fix needs a decision the
      finding does not settle, or the code shows the finding is wrong, stop and ask about that
      finding rather than guessing.
    - Verify the change with the repo's own test and lint targets that cover it, per the
      workspace CLAUDE.md's Verifying Commands: judge by exit status and output body. If
      verification fails, do not commit that fix; report the failure text verbatim and ask.
    - If the user approved committing, commit each fix on its own, with a message saying what
      changed and why and naming the finding. No attribution trailer, for the same reason the
      review body carries none: the commit goes out under the user's own account.

    If the user approved pushing, push once, after the last commit:
    `git push <remote> HEAD:<headRefName>`. Never force-push. If the push is rejected because the
    branch moved, report the error verbatim and ask - do not rebase, merge, or force to make it
    land. After a successful push, remove the worktree with `git worktree remove`. If anything
    was left uncommitted or unpushed, keep the worktree and give the user its path.

F5. **Update the report.** Append a dated entry under a `## Own-PR fixes` section at the end of
    the report file - append, never replace, for the same reason as P7:

    ```markdown
    ## Own-PR fixes

    ### Fixed <YYYY-MM-DD>

    - **Committed:** yes | no
    - **Pushed:** yes, to <headRefName> | no
    - **Worktree:** removed | kept at <path>

    | # | Finding | Disposition |
    |---|---------|-------------|
    | 1 | <short title> | Fixed (<short SHA>) |
    | 2 | <short title> | Fixed, uncommitted |
    | 3 | <short title> | Deferred |
    | 4 | <short title> | Skipped |
    ```

    Then report back: which findings were fixed, the commit SHAs, whether they were pushed, the
    worktree path if it was kept, and which findings were deferred or skipped.
