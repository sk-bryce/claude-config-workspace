---
created: 2026-08-05
updated: 2026-08-31
---

# Skill Specs

Per-skill intent and acceptance criteria: the source a regeneration reads. One section per
skill. Describes what each skill should do and how to tell it is correct; does not copy the
skill's body or restate authoring procedure. See the main Claude config's
`reference/spec-driven-architecture.md` for the rationale behind keeping intent here separate from
the generated artifact in `skills/`.

---

## Shared script conventions

Applies to every bundled script in every skill below, so a regeneration does not have to
rediscover them per skill.

- **`-h`/`--help` is a success, not an error.** It prints the usage block to stdout and exits 0,
  so `script --help | less` works and a CI step does not read it as a failure. Wrong or missing
  arguments print the same block to stderr and exit non-zero. One `usage()` holds the text and
  does not exit; a one-line `die_usage()` wraps it for the error path, so the two paths cannot
  drift apart.
- **An unrecognized `--flag` is rejected by the script itself**, never passed through to the
  underlying CLI. A flag that falls through to a positional slot surfaces as the wrapped tool's
  error about the wrong thing, and the caller then has to work out whose message it is reading.
- **Error exit codes are per-skill, not shared.** `triage-datadog`'s wrappers answer to the
  exit-code contract in `references/pup-recipes.md`, where 1 means bad arguments and 2, 3 and 4
  each carry a distinct evidence meaning; `fetch-pr` has no such contract and uses 2 for a usage
  error. Do not unify these - the contract is load-bearing on one side and absent on the other.

---

## fetch-pr

- Purpose: fetch and format GitHub PR data (metadata including draft status, general and inline
  review comments, CI check status, optionally the diff) via the `gh` CLI, so PR-review work gets
  one clean structured summary instead of re-deriving raw `gh`/JSON calls each time.
- Trigger phrases: "what's the status of PR #N", "get me the comments on PR #N", "fetch PR info
  for <url>", pasting a bare PR URL, or being asked to review a PR before any review judgment
  starts.
- Non-goals: no review judgment (no scoring, no flagging issues, no opinions on the code) - that
  stays with other review tooling. No posting comments or reviews back to GitHub. No diffing
  beyond what `gh pr diff` returns as-is. Composing with other review commands/plugins so they
  call this skill's script instead of inlining their own `gh pr view` calls is a natural
  follow-up, not covered here.
- Model/tier: no pin - this is a light fetch-and-relay utility; it inherits whatever model the
  calling session is already using.
- Knowledge source: none beyond the script's own `--help` usage line; no external reference doc
  is loaded.
- Behavior: identify the PR number/URL and repo from the request. Map natural-language asks to
  script flags explicitly (for example "including the diff" or "what changed" implies `--diff`).
  If no repo is named and none can be inferred from context, ask which repo rather than guessing.
  Call `scripts/fetch-pr.sh` with the resolved flags and relay its output - the script already
  formats it, so this is a relay, not a re-fetch. If the script exits non-zero (auth failure,
  rate limit, not found), surface its stderr verbatim rather than swallowing or reinterpreting it.
- Acceptance criteria:
  - Given a PR number/URL and a resolvable repo, produces one summary containing metadata,
    review-decision/CI-check status, general comments, and inline review comments grouped by
    file, with the diff included only when asked for.
  - Metadata includes draft status (`isDraft`); the Markdown summary's State line notes
    "(draft)" when true rather than only reporting the underlying OPEN/CLOSED/MERGED state.
  - An empty section (no comments, no checks) is reported as empty, not treated as an error.
  - Never posts anything back to GitHub.
  - A repo that cannot be inferred is asked about rather than guessed.
  - A non-zero exit from the script surfaces the real `gh`/`jq` error text to the user.
- Design notes: built as a skill with a bundled fetch/format script rather than a bare slash
  command (no auto-triggering, no place to put a bundled script) or an MCP tool (adds a server
  process on top of `gh`, a CLI that already runs locally and handles its own auth - not worth it
  unless something outside Claude Code needs to call this). Uses real `jq` (not `gh`'s embedded
  `--jq`) for the formatting pipeline since inline PR review comments need a second `gh api` call
  merged with `gh pr view`'s output - more than `--jq` alone comfortably expresses. Repo
  resolution deliberately has no separate fallback logic: it relies on `gh`'s own default-repo
  inference from the working directory's git remote, and lets `gh`'s own error surface verbatim
  when that fails, which the calling skill then treats as the cue to ask the user for a repo
  rather than guessing one.

---

## pr-review-md

- Purpose: wrap the native `review` skill so a PR review lands as a persisted, consistently
  formatted Markdown report in a memory-recorded directory instead of transient chat output only -
  findings rated on a fixed Impact/Confidence scale, sorted, each led by a copy-paste-ready PR
  comment written respectfully and from a perspective of curiosity rather than judgment, with a
  Summary (including PR state) and a rule-derived Recommendation. Also asks `review` to judge
  documentation substance when a PR touches docs, and to skip restating feedback already posted
  on the PR.
- Trigger phrases: a PR review request with an explicit filing/logging qualifier - "review PR #N
  and log/doc/file/record it", "/pr-review-md 123". A bare "review PR #N" with no such qualifier
  is out of scope and stays with the native `review` skill; this skill must not try to out-compete
  `review`'s own trigger on identical generic phrasing.
- Non-goals: no independent code analysis - all review judgment is delegated to the native
  `review` skill, this skill only steers its output vocabulary and persists/formats the result.
  Does not wrap `security-review` (operates on the local current branch's pending changes, not an
  arbitrary PR by number - doesn't fit this skill's PR-by-reference model) or the
  `pr-review-toolkit` plugin. Never posts anything back to GitHub, and that prohibition is
  unconditional: no `gh pr comment`, no `gh pr review`, no submitted
  `APPROVE`/`REQUEST_CHANGES`/`COMMENT` state, whatever the computed Recommendation says and
  however severe the findings. Where the user's own request bundles a posting ask with the review,
  the skill stops and confirms before writing rather than carrying it out inline - the ask is
  outside what this skill does, so it is confirmed rather than inferred.
- Model/tier: no pin - orchestration and formatting, not judgment-heavy or trivial; inherits
  whatever model the calling session is already using, same convention as `fetch-pr`.
- Knowledge source: none beyond this spec; no external reference doc is loaded.
- Behavior:
  0. Resolve the report directory from agent memory key `pr-review-docs-location`; if absent,
     prompt the user via `AskUserQuestion` (recommending `~/workspace/workbench/prs`) before
     running `review`, and write the memory entry plus its `MEMORY.md` pointer so later sessions do
     not re-ask. Prompting before the review rather than after it matters: a completed review with
     nowhere to file it wastes the expensive half of the run.
  1. Resolve the PR reference (number/URL/repo) the same way `fetch-pr` does; ask if the repo
     can't be inferred.
  2. Call `fetch-pr`'s script directly for metadata (no `--diff` - this skill doesn't analyze
     code itself): `scripts/fetch-pr.sh <target> [--repo owner/repo] --json`. Reuses `fetch-pr`
     instead of re-deriving `gh pr view` calls, per that skill's own composition invitation. From
     the same JSON, also extract what's already been said on the PR - general comments
     (`pr.comments`), review bodies (`pr.reviews`), and inline review comments
     (`inline_comments`) - for step 4's duplicate-avoidance instruction.
  3. Map to a PR state label for the Summary: `state=OPEN, isDraft=true` -> "draft";
     `state=OPEN` -> "open"; `state=MERGED` -> "merged"; `state=CLOSED` -> "closed".
  4. Invoke `Skill('review', args: "<PR reference> - rate every finding with two explicit labels,
     Impact: Blocker|High|Medium|Low|Nit and Confidence: High|Medium|Low, plus file/line and a
     concise description of each so they can be turned into standalone review comments
     afterward.")`. `review` performs its own analysis as normal; only its output vocabulary and
     scope are steered via `args`. When the diff touches documentation content (a dedicated doc
     file, or docstring/comment-block changes inside code, even in a mixed-content PR), append an
     instruction asking `review` to also judge that content's substance - reasoning,
     alternatives/risks, gaps, and accuracy against accompanying code - not just mechanical
     correctness, on the same scale. Also append the comments/reviews/inline comments gathered in
     step 2 as context, asking `review` to skip restating anything that duplicates them (or state
     plainly that none exist).
  5. In the same context, after `review` returns: extract each finding's Impact, Confidence,
     file/line, and description via reading comprehension, not a rigid parser - tolerant of
     `review` not perfectly following the requested format. A finding with no discernible
     Impact/Confidence defaults to Low/Low rather than being dropped.
  6. Sort findings by Impact rank descending (Blocker > High > Medium > Low > Nit) as the primary
     key, Confidence rank descending (High > Medium > Low) as the tiebreak.
  7. For each finding, draft a respectful, clear, concise fenced block of PR-comment-ready text
     (actionable, references file/line), followed by any further context or detail not needed in
     the comment itself. Comments are written from a perspective of curiosity, not judgment: ask
     rather than accuse, assume the author had a reason even where it isn't stated, and frame the
     finding as a question or observation rather than a verdict - while staying direct enough that
     the actionable ask remains unambiguous.
  8. Recommendation rule: any Blocker or High finding -> Request changes; only Medium/Low/Nit
     findings (no Blocker/High) -> Comment; no findings -> Approve. One-line rationale.
  9. Derive the filename: `<pr-id>` is the PR number. Short title is <=8 words, literal or
     paraphrased from the PR's actual title; if the title contains a JIRA ticket matching
     the team's JIRA project pattern (`<PREFIX>-\d+`, the prefix held in agent memory under
     `jira-ticket-prefix`), the short title begins with that ticket ID (kept uppercase); the rest is
     slugified (lowercase, non-alphanumeric -> hyphens). Before writing, glob
     `<report-directory>/<pr-id>-*.md` - if a file already exists for this PR id, reuse that
     exact filename (overwrite) instead of generating a fresh filename from a new paraphrase, so
     re-running the review on the same PR overwrites rather than duplicates.
  10. Ensure `<report-directory>` exists, then write the report (Summary with state,
      Recommendation with rationale, Findings sorted as above, or an explicit "No findings"
      note).
  11. Report back the file path written and the Recommendation line, then stop. Do not follow the
      report with a posted comment, an approval, or a requested-changes state; a later, explicit
      request to post is a separate action the user takes after reading the report.
- Acceptance criteria:
  - Given a filing-qualified PR review request, produces one Markdown file at
    `<report-directory>/<id>-<slug>.md` with a Summary (including PR state), a
    Recommendation matching the stated rule, and findings sorted by Impact then Confidence, each
    with explicit Impact/Confidence labels, a fenced PR-ready comment, and any extra context
    beneath it.
  - Every fenced PR comment in the report reads as respectful, clear, and concise, and is framed
    as a question or observation about the code rather than a judgment of the author - no
    accusatory or dismissive phrasing - while still naming a specific, actionable ask.
  - Re-running the same request against the same PR overwrites the existing file for that PR id
    rather than creating a second one, even if the paraphrased short title differs between runs.
  - A missing `pr-review-docs-location` memory key results in a prompt to the user and a written
    memory entry, not a guessed or hardcoded path, and the prompt comes before `review` runs.
  - No findings -> the file states "No findings" and Recommendation is Approve, rather than an
    empty Findings section.
  - A bare "review PR X" with no filing qualifier does not trigger this skill.
  - Nothing reaches GitHub on any path: not on a `Request changes` recommendation, not on a
    Blocker finding, and not when the user's original request also asked for the review to be
    posted - that last case stops and confirms before the report is written rather than posting.
  - Given a PR that touches documentation content (a dedicated doc file, or
    docstring/comment-block changes inside code), the report's findings for that content also
    cover substance - reasoning soundness, whether alternatives/risks are addressed, gaps or
    unaddressed edge cases, and accuracy against accompanying code - not just mechanical
    correctness, rated on the same Impact/Confidence scale.
  - Given a PR with existing open comments/review threads, a finding whose substance duplicates
    something already raised in one of those threads is not repeated in the report - `review` is
    told about the existing threads via `args` and asked to skip restating them.
- Design notes: `review`/`security-review` are native Claude Code skills with no file on disk
  anywhere under `~/.claude` - there is nothing to read or edit directly, so the only lever
  available to shape their output is the `Skill` tool's `args` at invocation time. Since `review`
  is itself LLM-driven, requesting a specific rating scale there is a normal
  instruction-following ask, not a code change, and extraction of its result afterward is done
  via the same LLM's reading comprehension rather than a brittle parser - tolerant of partial
  compliance. The Impact/Confidence scale is requested explicitly (rather than accepting whatever
  scale `review` natively produces) because some of the underlying `pr-review-toolkit` agents
  conflate severity and confidence into a single 0-100 number with no independent confidence axis
  to sort on, and a fixed vocabulary keeps sorting and the Recommendation rule well-defined
  regardless of which internal agent `review` happens to use. Documentation-substance evaluation
  is likewise delegated to `review` via a plain-text `args` instruction rather than a separate
  review pass in this skill, since judging whether a doc's reasoning holds up is the same kind of
  judgment call `review` already makes on code - folding it into the same invocation avoids a
  second review pipeline with its own rating scale to reconcile. Existing-thread duplicate
  avoidance is delegated to `review` itself via plain-text context in the same `args`, rather
  than a separate string-match step in this skill, because judging whether a new finding's
  substance overlaps an existing comment is a semantic call an LLM reviewer is suited to make -
  not a brittle text-matching heuristic here. `fetch-pr`'s `--json` call already returns general
  comments, review bodies, and inline comments in one round trip; this was previously fetched and
  discarded during the metadata step, so passing it forward needs no second fetch. Comment tone is
  specified here rather than left to the drafting model's default because the fenced blocks are
  meant to be pasted onto a real PR verbatim: a finding that is technically correct but reads as a
  verdict on the author costs more in review friction than it saves in words, and curiosity-framed
  phrasing also leaves room for the author to supply context the reviewer lacked. The no-posting
  rule is additionally restated as a hard rule in the artifact itself rather than living only here,
  because a prior run posted to a live PR without being asked, more than once. A prohibition that
  appears only in the spec an artifact was generated from is not load-bearing at run time, and an
  unrequested comment on someone else's PR is not undone by deleting it. The artifact therefore
  also names the two signals most likely to read as authorization - a `Request changes`
  recommendation and the severity of a Blocker finding - as explicitly not being it, and routes the
  one case that most resembles a licensed exception, the user asking for the review and the post in
  a single message, through a confirmation rather than through the skill's own inference about what
  was meant.

---

## triage-datadog

- Purpose: investigate one or more Datadog monitors to a defensible root cause via the `pup` CLI
  and file a structured Markdown report per root cause, so alert triage produces a consistent,
  reproducible artifact instead of transient chat output and so the same evidence checks run every
  time rather than being re-improvised per alert.
- Trigger phrases: "triage this alert <monitor URL>", "why did monitor 12345678 fire?", "root
  cause these two alerts", "what alerts fired for my team in the last 12 hours?", or pasting one
  or more bare Datadog monitor links.
- Non-goals: no writes to Datadog of any kind - no acknowledge, mute, resolve, downtime, monitor
  edit or delete. No ticket creation, no Slack or Rootly post, no PR. No changes to service code
  or monitor configuration (recommended in the report instead). No triage of a page with no
  Datadog monitor behind it. Does not own the report-posting or ticket-filing pass; that is a
  separate, later action if it ever exists. Never runs a credential command unprompted: an auth
  failure is surfaced to the user, naming the query that hit it, rather than worked around or
  quietly skipped.
- Model/tier: pinned `model: opus`. Unlike `fetch-pr` and `pr-review-md`, this skill's core output
  is a judgment call - deciding whether an anomaly was real, whether a correlation is causal, and
  whether a monitor's recovery can be trusted - which is the case the global config reserves Opus
  for. Evidence gathering is delegated to Sonnet subagents; only the synthesis needs the tier.
- Knowledge source: `references/pup-recipes.md` (command recipes per check, marked for whether
  they were verified against a live org or carried over from prior triage sessions, plus the CLI
  gotchas that have already cost investigation time), `references/scripts/` (eight executable
  wrappers covering ten checks - several cover a closely-related group - plus a sourced `_common.sh`
  that is not a wrapper and covers no check), and `references/report-template.md` (the report
  skeleton). All are loaded or invoked on demand rather than inlined, since the SKILL.md workflow is
  needed on every invocation and the recipe detail is only needed once gathering starts. Because a
  skill is injected without its own path, the body resolves and pins the skill's own directory as
  `$TRIAGE_SKILL_DIR` before running any wrapper, and passes that absolute path to every subagent
  it dispatches; a bare relative `references/...` invocation only works by accident of the shell's
  working directory.
- Behavior:
  1. Resolve the report output directory from agent memory key `triage-report-directory`. If the
     key is absent, look before asking: a recommended default that already exists and already holds
     `triage-*.md` files is the answer, adopted with the inference stated in one line. Only when
     that directory is missing or empty is the user prompted via `AskUserQuestion`. Either way the
     memory entry and its `MEMORY.md` pointer are written so later sessions do not re-ask - except
     on the headless path, where no prompt is possible: there the default is created and the report
     says the location was assumed, and nothing is recorded, since a location nobody confirmed
     should not become the recorded one for every later session.
  2. Intake: accept explicit monitor IDs/links, an ambiguous scoped framing ("alerts for my team
     over the last 12 hours"), or a mix. Resolve and state the time window in UTC.
  3. For a scoped framing, enumerate monitors by tag and keep those with a state transition in the
     window plus any still in an `Alert`/`Warn` state from before it. "Still firing" is not
     `overall_state != "OK"`: that also matches `No Data`, and a chronically dataless monitor is not
     an alert - those are counted and listed as an explicit third bucket rather than investigated or
     silently dropped. Cross-check the kept set against the alert event stream, scoped by
     `@monitor_id` to that set rather than run org-wide, since an unscoped `source:alert` query
     spends its row limit on other teams' alerts. Report every bucket's count and never truncate
     silently.
  4. Before investigating, search the whole report directory - not just today's files - for each
     candidate monitor ID. Each report's YAML frontmatter carries a `monitors:` array listing every
     ID it covers, which is the authoritative index and makes a plain `grep` sufficient even though
     filenames are root-cause slugs; a plain-ID grep is the fallback for reports written before the
     frontmatter existed. `grep` answers every *which reports* question and is the tier to rely on;
     `yq` is optional and adds only the aggregate questions (rank by impact, total a month, find a
     monitor classified noise twice), with a `grep` fallback rather than a failure when it is
     absent. If a prior report covers a candidate, summarize what was found and ask the user whether
     to investigate fresh or run a lighter confirmatory pass; do not default to either.
  5. Group alerts: default one report per alert, merging only on a confirmed relatedness signal
     (same resource across layers with metrics tracking point-for-point, a confirmed caller/callee
     edge with co-timed movement, a shared change event, or a shared downstream whose own metric
     moved). Timing coincidence alone does not merge; suspected-but-unconfirmed links produce
     separate cross-linked reports. Where grouping yields more than roughly four independent
     reports, state the count and each subject and ask which to pursue before investigating.
  6. Apply the evidence-depth gate: every check is mandatory by default, and a group may skip only
     checks 4-8 and 11-12 (the absolute-value, traffic, error-rate, seasonality and resource-level
     metrics plus the dependency and log/trace excavation), only when all four of a stated
     high-confidence criteria hold (a long, spread, self-recovering 90-day history; a monitor
     definition older than those cycles; no co-transitioning related monitor; and a fast
     blast-radius check showing no material customer impact). A gated group still runs checks 1, 2,
     3, 9, 10, 13 and 14, names the four satisfying numbers in the report, and cannot be classified
     more strongly than monitor noise or misconfiguration. Where the 90-day history is not merely
     unremarkable but unretrievable - an event-indexing gap rather than a quiet monitor - the gate's
     first criterion is unevaluable rather than unmet, and the full checklist is mandatory.
  7. Run the mandatory check set per group: monitor definition and type, alert timeline, 90-day
     monitor history, absolute-value sanity check, traffic and sample volume, error rate,
     seasonality, resource-level breakdown, release-pipeline and config change correlation,
     related-monitor correlation, upstream/downstream dependencies (reading code or Confluence
     where APM cannot settle the call path), logs/spans/traces, monitor-recovery
     trustworthiness, and blast radius. Run the fixed-shape checks via the `references/scripts/`
     wrappers, falling back to the raw recipes only where no wrapper covers what is needed. Every
     metrics query pins its rollup interval and every figure derived from one states that interval,
     since the CLI otherwise chooses an interval it reports nowhere and does not hold constant
     across services in one sweep. The deploy correlation check is scoped from the incident's own
     trigger and recovery timestamps, widened backwards by a lookback so a release that shipped
     hours before the alert is still in scope, with each record tagged for which of the two windows
     it fell in. Extra checks are encouraged and must be named in the report.
  8. Determine root cause against an explicit evidence standard (confirmed / circumstantial /
     ruled out / unknown), answering separately what moved the metric and what fired the monitor,
     and classify the outcome as real-and-ongoing, real-and-resolved, monitor noise, benign, or
     real-with-cause-not-established. Where no single root cause is confirmed, produce a ranked
     candidate-cause list instead of stopping at "unknown", each candidate carrying its supporting
     evidence, its contradicting evidence, and the specific check that would confirm or eliminate
     it.
  9. Write one report per group to the resolved directory as
     `triage-YYYY-MM-DD-<descriptive-kebab-case-slug>.md`, following the template exactly;
     update an existing same-date report for the same monitors in place rather than duplicating.
     Write it incrementally as the checks return rather than in one pass at the end - an interrupted
     investigation then leaves a usable artifact, and a figure recorded while its raw output is
     still in view is the one that stays correct - with the BLUF written last, after the root cause
     is settled, so a committed action cannot become an anchor the evidence is written toward.
     The report is layered for four readers, and each layer must stand alone: machine-readable YAML
     frontmatter (including a complete `monitors:` array, since step 4 reads it) that makes the
     directory queryable; a BLUF whose `ACTION REQUIRED` takes one of exactly five closed values and
     which answers "what do I do" separately from the classification's "what was it"; a plain-text
     paste block, because these reports are consumed in Slack and Jira where neither table renders;
     a summary section that argues in named blocks (what moved, what did not move, ruled out, still
     unknown) rather than a flat signal list, carrying a causal chain for any alert that crossed a
     service boundary and a falsifier line stating what would break the conclusion; an evidence
     section whose every subsection opens with a one-sentence finding and an outcome tag, with
     checks that did not apply recorded as one row in a table rather than a paragraph apiece; and a
     recommendations table carrying an owner and an effort estimate per row. Every figure has one
     canonical home with its derivation and is cited from elsewhere rather than re-derived, the four
     skimmable layers - frontmatter, BLUF, paste block, at-a-glance table - being the licensed
     exceptions. The investigation sections are written to teach -
     each explains why its check matters for this class of alert and how to read its output, so the
     section set doubles as the manual runbook for the next similar page - with concrete supporting
     material in appendices, and Datadog UI links placed inline at each point of reference rather
     than only collected in an appendix, including a link to the specific alert event and not only
     to the monitor.
  10. Proofread the written report for accuracy, consistency, omissions, clarity, and working
      links - including that the frontmatter agrees with the prose it indexes, and that a figure
      appearing in more than one licensed place agrees with itself - fixing what the pass finds
      before reporting back.
  11. Report back per file: path, one-line root cause, classification, whether it needs an owner,
      why any reports were kept separate, and any check that could not be completed.
- Acceptance criteria:
  - A single monitor link produces one report at the memory-recorded directory with the template's
    headings in order, and every number in it traceable to a command in Appendix F.
  - A scoped framing with no monitor named enumerates candidates, states the count of each bucket,
    and investigates the monitors with a transition in the window plus any still in `Alert`/`Warn`
    from before it. A `No Data` monitor from before the window is counted and listed but not
    investigated as an alert, so the investigation set stays the size of the real one.
  - Two alerts with a confirmed shared cause land in one report; two with only a timing
    coincidence land in two reports that cross-link each other and label the link unconfirmed.
  - The 90-day history section reports cycle count, distinct days, and cycle-duration statistics -
    enough to answer "was this an anomaly or a pattern".
  - A monitor showing `OK` while its underlying metric is still elevated is reported as unresolved,
    with the header's monitor state and metric state disagreeing rather than the `OK` being taken
    at face value.
  - Deploy evidence distinguishes what the pipeline recorded from what is actually running, and
    names any open unmerged GitOps PR. Correspondence between a Deployment record and the
    environment branch is established by time proximity, not by comparing SHAs from two different
    repositories, and either ordering of the two events is treated as normal. Deployment records
    selected by environment rather than by service are checked for whether they belong to the
    service under investigation, and flagged when they do not. The evidence is bounded by a window
    derived from the incident rather than by "the most recent N records": a deploy that shipped
    before the incident window but inside the lookback is reported and labelled as such, a deploy
    outside both is excluded, and "no deploy correlates" always names the window it searched. Where
    the record listing cannot reach back to the start of that window, the shortfall is reported
    rather than presented as an empty result.
  - Nothing is written to Datadog, no ticket is filed, and nothing is posted to Slack; every `pup`
    invocation carries `--read-only`, so a write is blocked at the CLI layer and not merely
    disallowed by instruction.
  - A monitor that was already firing before the window began is included in a scoped sweep rather
    than filtered out by the window-bounded state comparison.
  - A missing `triage-report-directory` memory key resolves to the existing default when that
    directory already holds prior reports - stated as an inference and then recorded - and to a
    prompt to the user otherwise. Neither path guesses silently, and a headless run that had to
    assume a path says so in the report and records nothing.
  - A monitor already covered by an earlier report in the directory surfaces that report and asks
    how to proceed, rather than being silently re-investigated or silently skipped.
  - A group that skips the deep checks under the evidence-depth gate names all four satisfying
    criteria and their numbers in the report, still carries the deploy-pipeline and blast-radius
    checks, and is classified no more strongly than monitor noise or misconfiguration.
  - A circumstantial headline conclusion is either put through a refutation pass whose outcome the
    report records, or carries an explicit note that the pass was skipped and why.
  - The fixed-shape checks are run via `references/scripts/`, and a wrapper given a `pup` response
    whose shape it does not recognize exits non-zero showing the raw output rather than reporting
    an empty result.
  - The three ways a check can come back without data stay distinct, and none collapses into
    another or into silence: a legitimately empty result (a monitor that did not fire in the window)
    is reported as a finding; an unrecognized `pup` response shape is reported as a check that did
    not run; and an empty result for a monitor that demonstrably did change state inside the window
    is reported as an event-indexing gap, with the timeline reconstructed from the underlying
    metric, never as "it did not fire".
  - An investigation that cannot confirm a single root cause produces a ranked candidate list with
    supporting evidence, contradicting evidence, and a discriminating check per candidate - never a
    bare "cause unknown".
  - Seasonality is checked for request volume as well as the alerting metric, so "is this traffic
    consistent with previous days and weeks" is answered explicitly.
  - Metrics, log queries, traces, and events cited in the report carry Datadog UI links built
    against the org host held in agent memory - confirmed against a supplied monitor link when the
    request came with one, since a scoped framing comes with none - and scoped to the investigation
    window, placed inline as well as indexed in the links appendix.
  - The report is proofread before hand-off: the summary, root cause, classification, and next
    steps do not contradict each other, and every mandatory check either has a section or an
    explicit note saying why it could not be completed.
  - The report carries YAML frontmatter whose `monitors:` array is complete and whose `action`,
    `classification`, `confidence`, `owner` and `impact` values match the prose they index, so a
    cross-report query returns what the report actually says.
  - A directory of reports answers the *which reports* questions with `grep` alone, on a machine
    with no `yq` installed.
  - The BLUF's `ACTION REQUIRED` is one of the five defined values and never an invented sixth, and
    it does not merely restate the classification.
  - Every metric figure in the report states the rollup interval it was computed at, and the
    appendix command that produced it pins that interval rather than leaving the CLI to choose one.
  - The report links the specific alert event, not only the monitor definition; where no alert event
    is indexed, the bullet says so and links the window-scoped monitor instead, so an unlinked
    timestamp is never merely unlinked.
  - A check that did not apply is one row in the checks-not-run table, with an explicit answer to
    whether it could have changed the conclusion - and any answer other than "no" is carried into
    "still unknown" and the next steps rather than left in the table as a skip.
  - An interruption partway through the checks leaves a readable partial report on disk rather than
    nothing, and no report has a BLUF drafted before its root cause was settled.
  - Where the harness forbids subagent dispatch, the mandatory delegations are not silently dropped:
    Step 4 runs in the main agent with raw pulls written to scratch files, a circumstantial headline
    is not promoted without the refutation pass it could not run, and the report names which
    mandatory delegations were skipped and why.
- Design notes: grouped by decision, since this skill has substantially more of them than the two
  above. Literal command syntax, flag spellings, magnitudes and version numbers deliberately stay in
  `references/pup-recipes.md` rather than being transcribed here - a spec is not the maintained copy
  of an artifact's details, and a copy it does not maintain goes stale silently.
  - **Why a skill, not a runbook.** A runbook has no trigger and no place for bundled reference
    material. The failure mode being solved is that the checks get skipped under time pressure,
    which only an auto-triggering artifact fixes.
  - **Provenance of the check set.** Derived from hand-written triage prompts used in prior triage
    sessions, and from the reports those produced - none of which is committed anywhere, so this
    spec is the recoverable source of the check list. The command recipes were validated against
    a live Datadog org on 2026-08-26 rather than transcribed from prior reports, which corrected
    two event-stream query errors an earlier triage session had derived.
  - **Read-only in the body, not via `disable-model-invocation`.** The value of auto-triggering on
    "we just got paged for X" is high, so every side-effectful step is an explicit non-goal instead;
    the skill writes only local report files. `--read-only` is mandated on every `pup` call, which
    turns the boundary from an instruction into a CLI-level guarantee. `--jq` is recommended rather
    than mandated: it avoids the exit-status masking the workspace config warns about, but the
    worked recipes still pipe into `jq` where a multi-line filter reads better, so the tradeoff is
    flagged rather than pretended away.
  - **`context: fork` deliberately not set**, even though the work is output-heavy: the skill must
    be able to stop and ask the user for a report directory, which a forked skill cannot do.
    Isolation comes from delegating evidence gathering to fresh subagents from the body instead.
  - **Scripting is deliberately partial**, which is where this skill differs from `fetch-pr`'s
    single pipeline script. Ten of the fourteen checks have a fixed query shape where only the
    monitor ID, tags, service, resource and window vary, so each gets a wrapper that bakes in the
    flag set, the verified `jq` filter and the known gotchas - which keeps a gathering subagent from
    re-deriving them and re-introducing the errors that come with that. The other four stay
    unscripted because their query genuinely branches on the previous answer, so a wrapper would
    only move the judgment call into script arguments. The set is eight scripts covering ten checks,
    and the counts are stated wherever the scripts are introduced, because the mismatch otherwise
    reads as two missing files. `_common.sh` is sourced rather than duplicated after the same
    verdict function landed byte-identically in two wrappers, where the first fix to either would
    have diverged them silently.
  - **Four gotchas were promoted from prose into the scripts**, each after costing real
    investigation time: an unpinned metrics rollup interval, which the CLI chooses, reports nowhere
    and does not hold constant across services in one sweep, so counts read at the wrong resolution
    understate by most of an order of magnitude and manufacture step changes that are not there; an
    empty event-search result, which has three causes rather than two, one of them a monitor that
    fired and whose events were never indexed, which the earlier two-way contract closed as a
    non-event; alert-event pairing, where the duration field lives on the recovery row and the true
    episode start can precede every event row in the response, so an investigation reading the
    visible trigger queries hours away from what it is looking for; and an exact-SHA cross-check
    between two different repositories, which could never match and so reported a failure on every
    healthy pipeline. A wrapper fails loudly on an unexpected response shape rather than returning a
    silently empty result, because a wrong `jq` filter returns nothing rather than an error and so
    is indistinguishable from a monitor that never fired.
  - **Deploy evidence is windowed, not newest-first.** The Deployment and commit listings are
    scoped to an explicit window derived from the incident's own trigger and recovery timestamps,
    widened backwards by a caller-set lookback, because a release that broke something in the
    afternoon may have shipped that morning - while an all-time-newest pair always corresponds and
    so answers nothing about the incident under investigation. Each record is tagged with which of
    the two windows it falls in, so "shipped while it was broken" and "shipped hours earlier" cannot
    collapse into one range, and an empty result is a finding that carries its window with it.
    Deployment records are looked up by environment rather than by service, so a monorepo whose
    services share an environment can silently return another service's history - checkable only
    against a prefix the caller supplies, since the service-name-to-ref mapping is neither the
    identity nor a common truncation.
  - **The report is layered because it serves four readers at once**, and it gained a
    machine-readable frontmatter block, a BLUF with a closed action vocabulary and a plain-text
    paste block once the directory held enough reports to be queried rather than merely read, and
    once it was clear these are consumed in Slack and Jira far more often than in a Markdown viewer.
    The density caps are caps rather than targets for the same reason: a thorough investigation a
    reader in a time crunch cannot extract the action from has failed at the only moment that
    mattered. The one-canonical-home rule for figures is a correctness rule wearing a style rule's
    clothes - a number living in five places gets corrected in four. Reports are written
    incrementally with the BLUF last, because a figure transcribed while its raw output is still in
    view stays correct, and a BLUF drafted early becomes an anchor the rest of the investigation
    writes toward.
  - **Report-directory querying is specified in two tiers** because `grep` is always available and
    answers every *which reports* question, while `yq` adds only the aggregates and is not installed
    everywhere; its recipes route through `jq` so they work under either of the two unrelated
    programs of that name.
  - **Evidence gathering is delegated per group, never per check**, since checks within a group
    share the window, tags and service set that a per-check split would force each subagent to
    re-derive. Gathering subagents must return distilled findings plus the verbatim commands they
    ran, never raw Datadog JSON, which is the whole reason for the delegation. It goes to
    `general-purpose` rather than `runner` despite `runner` being the output-absorbing agent,
    because deciding which of a metric series' points matter is interpretation, which `runner`'s
    charter excludes; `runner` is kept for a single enormous pull whose summary is all that needs to
    return. Groups are gathered in parallel, but concurrent 429s from more than one gathering
    subagent are read as the account's rate budget being exhausted and serialize the rest, which the
    report notes. A refutation pass - a fresh Opus subagent prompted to argue against the conclusion
    rather than re-derive it - is mandatory whenever the headline classification is circumstantial,
    on the reasoning that a circumstantial conclusion is exactly the one most likely to survive
    review by going unchallenged. Root-cause synthesis is never delegated, keeping the
    evidence/conclusion separation the report structure depends on. A fallback for harnesses that
    forbid subagent dispatch outright is written into the body rather than left implicit, because
    both behaviors an agent otherwise falls into are wrong: dispatching anyway against a stated
    prohibition, or quietly dropping the mandatory rows and producing a report that reads exactly
    like one that ran them.
  - **Nothing environment-specific or machine-specific is written into the repository.** Org host,
    team scope tag, service and metric names, deploy repo, workflow and mapping-file names, and real
    monitor IDs are all `<placeholder>`s, with the real values in agent memory under
    `datadog-triage-environment` and `deploy-pipeline-topology`; a missing entry makes the skill ask
    rather than guess, the same pattern Step 0 uses for the report directory. The skill's own
    directory is likewise resolved by searching upward from the working directory rather than from a
    hardcoded path, since a workspace-scoped skill lives wherever its repository was cloned.
