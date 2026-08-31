---
name: triage-datadog
description: This skill should be used when the user asks to triage, investigate, or root-cause a Datadog monitor or alert - e.g. "triage this alert <monitor URL>", "why did monitor 12345678 fire?", "root cause these two alerts", "what alerts fired for my team in the last 12 hours?", or pasting one or more Datadog monitor links. Runs a fixed evidence checklist via the `pup` Datadog CLI (monitor definition, 90-day trigger history, absolute-value sanity check, deploy and config change correlation, related-monitor correlation, upstream/downstream dependencies, logs/spans/traces) and writes one Markdown report per root cause to the directory recorded in agent memory under `triage-report-directory`, named `triage-YYYY-MM-DD-<slug>.md`. Groups related alerts into one report and unrelated ones into separate reports. Read-only - it never acknowledges, mutes, closes, or edits a monitor, files a ticket, or posts to Slack. Scope: workspace.
model: opus
---

<!--
created: 2026-08-26
updated: 2026-08-27
spec: specs/skills.md (triage-datadog section)
generated-by: claude-opus-5[1m] (main agent, skill-author pass)
model: claude-opus-5[1m]
harness: Claude Code
-->

# Triage Datadog Alerts

Investigate one or more Datadog monitors to a defensible root cause, then file a structured
Markdown report. Evidence comes from the `pup` Datadog CLI. Command recipes are in
`references/pup-recipes.md` (which marks which ones were verified against a live Datadog org and
which carry over from prior triage sessions), ready-to-run wrappers for the fixed-shape checks are
in `references/scripts/`, and the report skeleton is in `references/report-template.md`.

**Resolve `$TRIAGE_SKILL_DIR` first, before running any wrapper.** Every `references/...` path in
this file and in `pup-recipes.md` is relative to **this skill's own directory**, which is not the
working directory and not necessarily under `$CLAUDE_CONFIG_DIR` - this is a workspace-scoped skill,
so it may live under a project's `.claude/skills/` instead. Skills are injected without their path,
so a bare `bash references/scripts/foo.sh` (no base) works only by accident of where the shell
happens to be. Pin the directory once, then use it everywhere:

```bash
# 1. If the harness named this skill's directory when it loaded the skill, use that verbatim.
TRIAGE_SKILL_DIR=""

# 2. Otherwise, find it. Walk up from the working directory looking for a `.claude/skills/` copy:
#    this skill lives wherever its repository was cloned, so no path is hardcoded here.
if [[ ! -d "$TRIAGE_SKILL_DIR" ]]; then
  d=${CLAUDE_PROJECT_DIR:-$PWD}
  while [[ "$d" != "/" && "$d" != "." ]]; do
    if [[ -d "$d/.claude/skills/triage-datadog" ]]; then
      TRIAGE_SKILL_DIR="$d/.claude/skills/triage-datadog"
      break
    fi
    d=$(dirname "$d")
  done
fi

# 3. Last resort: a user-scope install.
[[ -d "$TRIAGE_SKILL_DIR" ]] \
  || TRIAGE_SKILL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/triage-datadog"

# Verify before relying on it -- a wrong base fails as "No such file", which reads like a missing
# script rather than a wrong path. If this prints, ask the user where the skill is installed rather
# than guessing further.
[[ -x "$TRIAGE_SKILL_DIR/references/scripts/monitor-definition.sh" ]] \
  || echo "TRIAGE_SKILL_DIR is wrong: '$TRIAGE_SKILL_DIR'" >&2
```

Then invoke wrappers as `bash "$TRIAGE_SKILL_DIR/references/scripts/<name>.sh" ...`, and pass the
resolved absolute path to any subagent you dispatch - a subagent inherits neither this file's
context nor your shell state, so it cannot repeat the resolution above.

Below, a `references/...` path written bare is a pointer for a human reader; one written with the
`$TRIAGE_SKILL_DIR/` prefix is meant to be executed or handed to a subagent as-is. Both name the
same file.

**This skill is read-only against Datadog.** Never acknowledge, mute, resolve, edit, or delete a
monitor, never create a downtime, never file a ticket, and never post to Slack. It reads,
concludes, and writes a local report. Recommending those actions is in scope; taking them is not.

Pass `--read-only` on every `pup` invocation. It is a global flag that blocks create, update, and
delete at the CLI layer, so the boundary above is enforced mechanically rather than by intention
alone (verified against `pup` 1.6.4).

**On an auth failure, stop and ask.** A 401 means the token expired; a 403 means the account lacks
the scope. Say which one it was and which query hit it, and ask the user how to proceed - do not run
`pup auth login` or any other credential command unprompted, and do not drop the check and carry on.
A silently skipped check reads in the finished report exactly like a check that passed.

## Step 0: Resolve the report directory

Reports go to a directory recorded in agent memory under the key `triage-report-directory`.

1. Check the session's memory for `triage-report-directory` (the harness surfaces `MEMORY.md` at
   session start; the backing file is `triage-report-directory.md` in the session's memory
   directory). If it names a directory, use it.
2. If it is absent, **look before asking.** Check whether `~/workspace/workbench/alerts` (the
   recommended default) already exists and already contains `triage-*.md` files. If it does, that
   is the answer - adopt it, state the inference in one line ("no memory entry; using
   `<path>`, which already holds N prior triage reports"), and continue to step 4 to record it.
   A question whose answer is sitting on disk is not a real question, and in a background or
   headless run it blocks the entire investigation on something unanswerable.
3. **Only if that directory does not exist or is empty, ask the user** where reports should go,
   before doing any investigation work, using `AskUserQuestion`. Offer
   `~/workspace/workbench/alerts` as the recommended option alongside an option to name a different
   path. If the harness cannot
   prompt at all (a headless or scheduled run), create the recommended default, say clearly in the
   report where the reports went and that the location was assumed, and do **not** write the memory
   entry - an assumed path should not silently become the recorded one for every later session.
4. Once the directory is settled - whether inferred in step 2 or answered by the user in step 3 -
   write the memory entry so later sessions do not re-ask. The one exception is step 3's headless
   path: a location nobody confirmed does not get recorded. Create
   `<memory-dir>/triage-report-directory.md`:

   ```markdown
   ---
   name: triage-report-directory
   description: Datadog alert triage reports are written to <path>
   metadata:
     type: project
   ---

   Datadog alert triage reports written by the `triage-datadog` skill go to `<path>`, named
   `triage-YYYY-MM-DD-<descriptive-kebab-case-slug>.md`. Check there before re-investigating a
   monitor - a prior report may already cover it.
   ```

   Then add the one-line pointer to that same memory directory's `MEMORY.md` (the link below is
   relative to `<memory-dir>`, not to this skill):
   `- [Triage report directory](triage-report-directory.md) - where triage-datadog writes reports`

Memory is scoped per project directory in this harness, so a first run from a new project root has
no entry. That is expected: step 2's inference usually settles it without a question, and the entry
is then written for that project too.

Environment-specific values - org host, team scope tags, service and metric names, deploy repo and
workflow names - are deliberately absent from this skill and its references, which use
`<placeholders>` instead. They live in agent memory under `datadog-triage-environment` and
`deploy-pipeline-topology`. Read those before querying; if one is missing, ask the user for the
value and offer to write it to memory, exactly as Step 0 does for the report directory.

## Step 1: Intake

Three shapes of request, all valid:

| Shape | Example | What to do |
| --- | --- | --- |
| Explicit monitor(s) | one or more `https://<org>.datadoghq.com/monitors/<id>` links, or bare IDs | Take the IDs as given. Confirm each resolves via `pup monitors get`. |
| Ambiguous scope | "alerts for my team over the last 12 hours" | Enumerate candidates (Step 2), then state the resulting list and its size before investigating. |
| Mixed | "triage monitor 12345678 and anything related from this morning" | Start from the named IDs, expand per Step 2's correlation sweep. |

Resolve the time window explicitly and state it in UTC. If the request has no window, default to
the trailing 24 hours for a scope sweep, or - for a named monitor - the window bounding its most
recent trigger/recovery cycle plus two hours either side.

If the request names a team, service, or product area rather than a monitor, resolve the Datadog
scope tag from agent memory under `datadog-triage-environment`, which also holds the org host,
service names, and APM metric names for the environment under investigation. If that entry is
missing or does not cover the area named, ask the user for the tag rather than guessing one - a
wrong tag returns a confidently empty result set.

### Check for prior reports on these monitors

Before investigating, search the report directory resolved in Step 0 for each candidate monitor
ID. Reports carry a YAML frontmatter block whose `monitors:` array lists every ID the report
covers, so that array is the authoritative index - `grep -l "monitors:.*<id>"` finds the report
even though the filename is a root-cause slug. Fall back to a plain grep for the bare ID or its
`/monitors/<id>` link for any older report written before the frontmatter existed. This is a
different check than Step 6's same-date dedup: it looks across **all** prior reports, any date,
not just today's.

The frontmatter is also what makes the cross-report questions answerable without reading, at two
tiers. **Plain `grep` is the baseline and needs no tooling at all** -
`grep -l "^action: HAND OFF"`, `grep -l "customer_visible: true"`,
`grep -l "^classification: monitor noise"` - and it answers every *which reports* question,
including "has this monitor been classified noise before". **If `yq` is installed**, the same
frontmatter also answers the *how much* and *which was worst* questions that `grep` structurally
cannot - ranking reports by requests affected, totalling customer-visible impact for a month,
finding monitors classified noise more than once. Both tiers, with the `yq` recipes routed through
`jq` so they work under either of the two programs named `yq`, are in
`$TRIAGE_SKILL_DIR/references/pup-recipes.md` ("Querying the report directory").

`yq` is optional; check for it with `command -v yq` and fall back to the `grep` tier rather than
failing or skipping the question. Consult either tier when the answer would change how this
investigation is scoped.

If one or more prior reports mention a monitor in scope, **do not silently reuse them and do not
silently ignore them.** Summarize what was found - file path, report date, classification, and
one-line root cause for each - and ask the user via `AskUserQuestion` how to proceed, offering at
least: investigate fresh (recommended if the classification was anything other than settled noise,
or if real time has passed since), or treat the prior classification as still current and produce a
lighter confirmatory pass rather than a full re-investigation. Let the user's answer decide; do not
default to either without asking. If no prior report mentions any monitor in scope, say so briefly
and proceed - no need to ask when there is nothing to weigh.

## Step 2: Build the alert set

For an ambiguous or scoped request, enumerate rather than guess:

1. List monitors for the scope tag (`pup monitors list --tags=...`), then keep those whose
   `overall_state_modified` falls inside the window. That is the set that changed state.
2. Also keep any monitor currently in a non-`OK` state even if it last transitioned *before* the
   window. A monitor that has been firing since yesterday is still firing, and a window-bounded
   state filter is precisely the filter that hides it.
3. Cross-check with the alert event stream for the same window so a monitor that fired *and*
   recovered inside the window is not missed by a state-modified snapshot alone.
4. Report the count you started from and the count you kept ("<N> monitors tagged <tag>; <k> had a
   state transition in the window, <j> were already firing before it"). Never silently truncate -
   if you cap the set, say what was dropped and why.

Recipes for both queries: `references/pup-recipes.md`.

## Step 3: Group the alerts

Decide grouping **before** writing anything, and revisit it after evidence gathering if the
evidence changes the picture.

Default to one report per alert. **Merge two alerts into one report only when a relatedness signal
is confirmed, not merely suspected:**

- Same resource or endpoint observed at two layers (BFF and backend, gateway and service) whose
  metrics track each other point-for-point.
- Confirmed caller/callee edge on the request path (`pup apm dependencies list`), plus co-timed
  movement in both services' metrics.
- Same underlying change event (one deploy, one config push, one k8s event) demonstrably in both
  windows.
- Same shared downstream dependency whose own metric moved at the same time.

Timing coincidence alone is **not** confirmation. When alerts look related but the link is
circumstantial, write **separate reports and cross-link them**, saying plainly in each that the
correlation is unconfirmed and what would confirm it. Do not merge on a hunch: a merged report
asserts a shared root cause, and asserting one that does not exist sends the reader down the wrong
path.

Name each group by its root cause, not by its monitor IDs - that name becomes the report slug.

**If grouping yields more than about four independent reports,** stop and tell the user the count
and a one-line subject for each before investigating, then ask which to pursue. A dozen shallow
reports is worth less than three thorough ones, and the user usually knows which of the twelve they
were actually paged for.

### Evidence-depth gate: when a group may skip the deep checks

Every check in Step 4's table is mandatory by default, for every group, regardless of how the
group looks on first glance. The single exception below exists because a monitor that has fired
and self-recovered dozens of times with an unchanged definition does not need the same
resource/dependency/log excavation as a first-time page - but the bar for skipping anything is
**very high confidence**, not a hunch, and the default if any criterion is unmet or unverifiable is
to run the full checklist.

A group may skip checks 4-8 and 11-12 (the absolute-value, traffic, error-rate, seasonality and
resource-level metrics, plus the dependency and log/trace excavation) **only if all four hold, each
backed by the check that establishes it:**

1. **Check 3 (90-day history):** at least 8 self-recovered cycles across at least 20 distinct days,
   not clustered into a single incident window, and this cycle's duration falls inside the
   historical min-max range - i.e., this firing looks like the others, not a longer or different
   one. If `monitor-history-90d.sh` exited 4 - no indexed events for a monitor that
   demonstrably did change state, one of the exit codes tabulated in `pup-recipes.md`'s "Wrapper
   scripts" section, and reachable only from the two wrappers that query the event stream - there
   are no cycle counts to test this against, so the gate is not merely unmet but **unevaluable**:
   run the full Step 4 checklist. A monitor with no retrievable history superficially resembles a
   quiet, healthy one and is not the same thing.
2. **Check 1 (monitor definition):** the monitor's `modified` timestamp predates several of the
   prior cycles counted in (1) - ruling out "this is a recently miscalibrated monitor, and the
   history above doesn't apply to the monitor as it exists now."
3. **Check 10 (related monitors):** no other monitor in the same scope transitioned inside this
   cycle's window - ruling out a shared incident that this monitor is merely one symptom of.
4. **A fast blast-radius sanity check** (one `resource-metrics.sh`/`blast-radius.sh`-style hits and
   error-count query for this cycle, not the full check 14) shows no material customer-facing
   impact - a request-count spike or an error-rate move on the SAME query that would otherwise
   feed check 6/14 disqualifies the skip.

If all four hold, run checks 1, 2, 3, 9, 10, 13, and 14 in full (the deploy-pipeline and
blast-radius checks stay mandatory even under the gate - noise classification does not exempt "did
anything ship" or "was anyone actually affected"), skip 4-8 and 11-12, and write **one paragraph
in the report** naming the four criteria and the specific numbers that satisfied each. Classify the
group as monitor noise or misconfiguration only on that basis, never as "real and resolved" or
better - a skipped-check investigation cannot support a stronger conclusion than that.

If any criterion is unmet, ambiguous, or would take real judgment to confirm, do not skip
anything - run the full Step 4 checklist. Getting this wrong in the direction of "ran too much"
costs time; getting it wrong in the direction of "skipped and missed a real regression" costs
correctness, and correctness is what this skill exists to protect.

## Step 4: Gather evidence

Every check below is mandatory for each group, unless Step 3's evidence-depth gate applies (checks
4-8 and 11-12 only, and only under that gate's four-criteria bar). Record the finding *and* whether
it turned out to be relevant, so the report shows what was ruled out as well as what was ruled in.
Interpretation guidance and the exact commands are in `references/pup-recipes.md`.

**Eight wrapper scripts in `$TRIAGE_SKILL_DIR/references/scripts/` cover ten of the checks** -
some cover more than one, so do not go looking for a file per check:

| Script | Checks it covers |
| --- | --- |
| `monitor-definition.sh` | 1 |
| `monitor-timeline.sh` | 2 |
| `monitor-history-90d.sh` | 3 |
| `resource-metrics.sh` | 4, 5, 6 |
| `seasonality-check.sh` | 7 |
| `deploy-pipeline-check.sh` | 9 (its step 1 runs the change-stories query too; only the separate `source:deployment` cross-check stays a raw recipe) |
| `related-monitors.sh` | 10 |
| `blast-radius.sh` | 14 |

Each bakes in the correct flags, `jq` filters, pinned `.rollup()` intervals, and the known `pup`
gotchas - prefer the script over hand-rolling the equivalent query.
`references/pup-recipes.md`'s "Wrapper scripts" section lists each one's arguments and its
exit-code contract; the corresponding check section there still has the raw recipe for anything a
script doesn't cover. **Checks 8, 11, 12, and 13 have no wrapper** - their query shape varies too
much per investigation to script, so they are raw recipes by design, not an oversight. Which checks
have a wrapper and which the evidence-depth gate can release are unrelated lists that happen to
overlap: check 8 is in both (no wrapper, gate-skippable), check 13 in neither's expected half (no
wrapper, yet mandatory even under the gate).

| # | Check | Report | The question it answers |
| --- | --- | --- | --- |
| 1 | Monitor definition and type | 2.1 | What does "alert" even mean here? An anomaly monitor asks "was the deviation real?"; a threshold monitor asks "was the value high?". Also capture priority, notification targets, creator, created/modified dates, `draft_status`, and `matching_downtimes`. |
| 2 | Alert timeline | 2.2 | Exact trigger and recovery timestamps in UTC, cycle duration, self-recovered or not. Bounds every other query. Also yields each event's `evt.id`, which is what makes the report's header link to the *alert* and not just to the monitor - pass the org as the script's 4th argument and it emits the finished link. |
| 3 | **90-day monitor history** | 2.13 | Was this an anomaly or a pattern? How often has it fired, on how many distinct days, with what median cycle duration, and is it clustered or spread? A monitor that fires 30 times a quarter and always self-recovers is a monitor problem, not a service problem. |
| 4 | Absolute-value sanity check | 2.3 | Even for an anomaly monitor: was the raw value actually bad? Compare against the same service's normal daily range, not just the anomaly band. |
| 5 | Traffic and sample volume | 2.4 | Rules out both a load spike and the opposite failure mode - a percentile computed over 1-2 requests per bucket, where "anomalies" are pure noise. |
| 6 | Error rate | 2.5 | APM errors and log-status breakdown, to separate latency-with-failures from latency-alone. |
| 7 | Seasonality | 2.6, 2.7 | Same window one day and one week earlier, for **both** the alerting metric and request volume - "is this traffic consistent with previous days and weeks?" is a separate question from "is this latency consistent", and either can be the one that explains the alert. Also capture the daily shape. Distinguishes "abnormal" from "normal for a Tuesday at 06:00 UTC". |
| 8 | Resource-level breakdown | 2.8 | Is a service-level aggregate being dragged by a bimodal endpoint mix, or is one resource genuinely regressed? Also discriminates resource-isolated from infra-wide. |
| 9 | **Release pipeline and config change** | 2.9 | Did anything actually ship? Check change-stories (deployment, feature_flag, configuration, database, kubernetes, scale, crashloopbackoff, traffic_anomaly, schema, watchdog), then verify against the real pipeline - see the pipeline caveat below. |
| 10 | **Related monitor correlation** | 2.10 | Other monitors in the same scope with transitions in the window, including ones the user did not mention. Feeds back into Step 3. |
| 11 | **Upstream and downstream services** | 2.11 | Enumerate dependencies, then pull each one's latency and error rate across the same window. Read service code or Confluence when the call path is not obvious from APM alone. |
| 12 | **Logs, spans, and traces** | 2.12 | What was the service actually doing at the time - which resources, which status codes, which error messages, which downstream calls. Name the file and line when a log points into the codebase. |
| 13 | Monitor recovery trustworthiness | 2.14 | An `OK` state is not proof of resolution. A seasonal/agile anomaly model adapts to a new elevated level and recovers the monitor while the regression continues; a `sum(last_Nm)` monitor recovers when a burst ages out of the window. Always check whether the underlying metric actually returned to baseline. |
| 14 | Blast radius and customer impact | 2.15 | How many requests, which endpoints, what user-visible effect. Drives whether anything needs a ticket. |

The "Report" column is the `references/report-template.md` subsection each check is written up in.
The two orders differ deliberately: investigate in check order - the 90-day history early, because
it decides how seriously to treat everything after it - but write up in report order, with the
90-day history late at 2.13, because a reader needs the specific incident before the pattern. Check
7 splits across two subsections: the day-over-day and week-over-week comparison in 2.6, the daily
shape in 2.7.

Add checks freely when a specific alert calls for them - RUM sessions for a frontend alert,
DynamoDB or Redis metrics for a datastore-shaped error, `apm services stats` for a fleet-wide view,
`pup dashboards`/`notebooks` for existing investigation context. The table is a floor, not a
ceiling. Say in the report which extra checks were run and why.

**Pipeline caveat (load-bearing).** A GitHub Deployment record, a green deploy workflow run, or a
merged PR does **not** mean the code is running. This check assumes a GitOps-style pipeline, which
is the shape its recipes are written for: a deploy workflow writes a Deployment record on success
even when all it did was open a pull request against a separate manifest repo, and the cluster only
changes when that repo's environment branch changes. Confirm the pipeline under investigation
actually has that shape before trusting the distinction, then verify what is running by checking
the environment branch's commits for the service path, and check for open, unmerged deploy PRs.
Recipes are in `references/pup-recipes.md`; the repo, workflow, and mapping-file names for the
environment under investigation are in agent memory under `deploy-pipeline-topology`.

**Window caveat, same check.** Pass `deploy-pipeline-check.sh` the *incident* window - check 2's
trigger and recovery timestamps, not today's date and not a relative window, both of which it
rejects. It widens that backwards by `--lookback` (default 7d) into a correlation window, because a
release that broke something at 14:00 may have shipped at 09:00, and tags every record
`IN-INCIDENT` or `PRE-INCIDENT` so "shipped while it was broken" and "shipped five hours earlier"
never read the same in the report. Narrow `--lookback` for a service that deploys constantly; widen
it when nothing shipped recently and the report still has to name what *is* running. An empty
result is a finding - "nothing shipped in the 7 days before the incident" - and the window it was
searched over is part of the finding, not context you can leave out.

## Step 5: Determine root cause

Hold conclusions to this standard:

- **Confirmed** - direct evidence (a trace showing the slow call, a change event inside the window
  with matching metric movement, a log line naming the failing operation). Say so plainly.
- **Circumstantial** - timing correlation without a demonstrated mechanism. Label it as such,
  state what would confirm it, and do not let it become the headline conclusion.
- **Ruled out** - checked and eliminated. Worth writing down; it is what makes the report
  trustworthy and stops the next person re-running the same query.
- **Unknown** - if the evidence does not support a root cause, say that. A report concluding
  "real, unexplained, needs an owner" is more useful than a confident guess.

**When no single root cause is confirmed, do not stop at "unknown".** Enumerate the candidate
causes as a ranked list, and for each one give: the evidence that supports it, the evidence that
argues against it, and the specific check that would confirm or eliminate it. Rank by how well the
evidence fits, not by how easy the check would be. A reader handed three ranked candidates plus the
query that discriminates between them can finish the investigation; a reader handed "cause unknown"
has to start it over.

Separate two distinct questions and answer both: *what caused the metric to move*, and *what
caused the monitor to fire*. They are often different, and for a noisy monitor the second answer is
the actionable one.

Classify each group's outcome as one of: real and ongoing, real and resolved, monitor noise or
misconfiguration, benign/expected behavior, or real with cause not yet established. That
classification drives the recommendations.

## Step 6: Write the report

One report per group. Follow `$TRIAGE_SKILL_DIR/references/report-template.md` exactly so every
report is comparable - same headings, same order.

**Write it incrementally, as the checks complete - not in one pass at the end.** Create the file
after Step 3's grouping, with the skeleton and the metadata header filled in, and append each
check's subsection as that check returns. Two reasons, and the second is the important one:

1. An investigation that is interrupted at check 11 then leaves a usable artifact rather than
   nothing at all. Someone else can pick it up, and a later session can resume from what is
   already written instead of re-querying.
2. **Figures written down while the raw output is still in front of you are the ones that stay
   correct.** Numbers reconstructed at write-up time, from memory or from a summary, are where
   errors enter - a bucket interval misremembered at the end of a long investigation silently
   rescales every count in the report.

Write the BLUF **last**, after section 3's root cause is settled. It is the one part that must not
be drafted early: an action and a classification committed to before the evidence is in becomes an
anchor the rest of the investigation writes toward.

- **Directory:** the path resolved in Step 0.
- **Filename:** `triage-YYYY-MM-DD-<descriptive-kebab-case-slug>.md`, where the date is the
  investigation date and the slug describes the root cause or the alert subject in at most 8 words
  (e.g. `triage-2026-08-26-getthing-p95-step-change.md`, using this skill's placeholder endpoint;
  the real slug names the real resource).
- Before writing, glob the directory for an existing report covering the same monitors and date.
  Update that file in place rather than creating a near-duplicate, and note the revision.
- Every non-obvious number in the report must be reproducible from the commands recorded in its
  appendix. If a command's output cannot be reproduced, do not state the number.
- **The report opens with a YAML frontmatter block**, before the title: `report`, `date`,
  `monitors` (every ID, as integers), `services`, `env`, `window`, `action`, `classification`,
  `confidence`, `owner`, an `impact` map (`requests_affected`, `peak_error_rate`,
  `duration_seconds`, `customer_visible`), and `related`. This is what makes a directory of
  reports queryable rather than merely readable - "every `HAND OFF` this month", "which monitors
  have been classified noise more than once" - and it is what Step 1's prior-report check reads,
  so `monitors:` must be complete. Every value restates something from the prose; keep the two in
  step, including on a revision.
- **The report opens with a BLUF block, above the metadata.** Its `ACTION REQUIRED:` line takes
  one of exactly five values - `NONE`, `TUNE MONITOR`, `HAND OFF`, `OWN AND FIX`,
  `KEEP INVESTIGATING` - and never an invented sixth; the closed vocabulary is what lets a reader
  scan a directory of these side by side. It answers "what do I do", where the **Classification**
  field answers "what was it"; fill in both, and do not let one restate the other. Then five
  one-line rows: what happened, impact, still happening, owner, urgency.
  **Density is the failure mode these reports actually have** - a thorough investigation written
  so densely that a reader in a time crunch cannot extract the action from it has failed at the
  only moment that mattered. `references/report-template.md` carries hard caps for the BLUF, the
  section 1 headline, the at-a-glance timeline, and the section 1 bullets. Treat them as caps, not
  targets, and cut to fit rather than negotiating with them.
- **The BLUF is followed by an eight-line plain-text `### Paste` block.** These reports are
  consumed in Slack and Jira far more than in a Markdown viewer, and neither renders the BLUF
  table. The paste block restates it as copyable plain text and adds nothing; where the two
  disagree, the BLUF is authoritative.
- **Section 1 argues in four named blocks, not a flat list of signals**: **What moved**, **What
  did not move**, **Ruled out** (a table of hypothesis / verdict / the subsection that establishes
  it), and **Still unknown**. The grouping *is* the argument. A reader in a time crunch reads the
  Ruled out table first, because knowing what this is NOT is what lets them stop worrying about
  four hypotheses at once - and left ungrouped, that reassurance is scattered across four separate
  subsections. Section 1 also carries a one-line ASCII **causal chain** for any alert that
  propagated across a service boundary, and a **What would break this conclusion** line stating
  the observation that would falsify it, required even when confidence is `confirmed`.
- **Every figure has one canonical home, and everywhere else cites it.** Establish a number once,
  in the subsection whose check produced it, with its derivation and units; elsewhere write the
  figure and point at that subsection (`48.4 percent (2.3)`). A figure living in five places gets
  corrected in four of them. Exactly four places are licensed to duplicate - the frontmatter, the
  BLUF, the paste block, and the at-a-glance table - because a skimmer must not have to jump and an
  index has to carry its own values.
- **A check that did not apply gets one row in section 2's `### Checks not run` table, not a
  subsection of prose explaining its own absence.** Keep the numbered heading with its
  `**Finding:** ... [N/A]` line so the numbering stays contiguous, and put the reasoning in the
  table. Its third column - "could it have changed the conclusion?" - is the load-bearing one: any
  answer other than a flat "No" means this was a gap rather than a skip, and it belongs in
  **Still unknown** and in the next steps.
- **Every 2.N subsection opens with a bolded `**Finding:**` sentence and an outcome tag** -
  `[Relevant]`, `[Ruled out]`, `[Inconclusive]`, or `[N/A]` - before any prose. Reading only those
  lines gives the whole investigation in fifteen lines, which is what keeps a 900-line report
  usable.
- **The report opens with a link to the alert, not only to the monitor.** The header's
  **Alert event** bullet hyperlinks each trigger and each recovery timestamp to that specific
  event (`?from_ts=<ms>&to_ts=<ms>&event_id=<evt_id>`); the **Monitor** bullet above it links the
  monitor definition. These answer different questions - "what could fire" versus "the firing this
  report is about" - so one never substitutes for the other. `monitor-timeline.sh <id> <from> <to>
  <org>` emits each event's `link` ready to paste. When no alert event is indexed (check 2 exit 4)
  there is no `event_id`: link the window-scoped monitor instead and say in the bullet why the
  per-event link is missing. Exact shapes and the fallback are in `references/report-template.md`.
- **Link to the Datadog UI wherever a metric, log query, trace, dashboard, or event is
  referenced** - inline at the point of reference, not only collected in an appendix, so a reader
  can open the exact panel behind a claim. Build links against the org host from the monitor link
  the user supplied, scoped to the investigation window. Shapes are in
  `$TRIAGE_SKILL_DIR/references/pup-recipes.md` ("Datadog web links").
- **Section 1's recommendations are a table with an owner and an effort estimate per row**, not a
  bare ranked list - a recommendation without those two reads as a wish list, and the reader has
  to re-derive both before they can act on it. Rank by value rather than by effort, but state the
  effort, so a reader can choose to take a cheap third item now. Section 4 expands each row into
  enough detail for someone who was not part of the investigation to pick it up.
- Section 2 is written to teach, not just to record: each subsection should say why that check
  matters for this *class* of alert and how to read its output, so the section doubles as the
  manual runbook for the next person who gets paged for something similar.

## Step 7: Proofread the report

The report is an artifact someone else reads, often under time pressure, so review it before
handing it over. Re-read the written file and check:

- **Accuracy** - every number matches the command output it came from, and every claim's confidence
  label matches the evidence actually gathered.
- **Consistency** - the summary conclusion, the Root Cause section, and the recommended next steps
  agree with each other and with the classification in the header. A summary saying "no action
  needed" above a next-step saying "open a ticket" means one of them is wrong.
- **Omissions** - every mandatory check has a subsection, and any check that could not be completed
  says so rather than being quietly absent.
- **Clarity** - a reader who was not in the investigation can follow the reasoning from evidence to
  conclusion, and the units, timezones, and baselines for each number are stated.
- **Links** - the Datadog links resolve to the right org host and carry the intended time window.
- **Frontmatter agrees with the prose** - `action`, `classification`, `confidence`, `owner`, and
  every `impact` figure match what the body says. The frontmatter is an index over the report, so
  a disagreement is not a cosmetic slip: it is what a cross-report query will return.
- **Each figure appears in one canonical place**, with the derivation, and is cited rather than
  re-derived elsewhere. Where a number does appear more than once - the BLUF, the at-a-glance
  table, the frontmatter - confirm all copies agree. This is the check that catches a late
  correction applied in four places out of five.

Fix what the pass finds, in the file, before Step 8.

## Step 8: Report back

Tell the user, per report: the file path, the one-line root cause, the classification from Step 5,
and whether anything needs an owner. If several reports were written, say why they were kept
separate. Surface any check that could not be completed and why (auth scope, sampling, missing
data) rather than leaving a silent gap.

## Orchestration, models, and context management

Datadog JSON is voluminous and mostly worthless once read - a single 90-day metrics query can run
to tens of thousands of tokens of raw series data. Keeping that out of the main context is the
difference between finishing an investigation and running out of room mid-way.

**Do directly in the main agent** (these need conversation state, user interaction, or
cross-group judgment):

- Step 0 intake and the report-directory prompt.
- Step 1-3 scoping and grouping decisions.
- Step 5 root-cause synthesis - the judgment this skill exists for. Run it at the Opus tier; the
  `model: opus` pin covers Claude Code, and if the harness ignores the pin, ask the user to switch
  to Opus rather than synthesizing at a lower tier.
- Step 6-8 report writing, the proofread pass, and reporting back. The proofread stays in the main
  agent deliberately: a gathering subagent cannot judge whether the conclusion it never made is
  consistent with the evidence.

**First, check whether you are allowed to delegate at all.** Some harness configurations forbid
subagent dispatch outright (a system prompt saying "do not call the AgentTool unless the user
requested it", a tool allow-list without the Agent tool, a headless or cron invocation). The
mandatory rows below then cannot be satisfied, and the correct response is neither to dispatch
anyway nor to abandon the checks. **Run Step 4 in the main agent, and protect the context
manually:**

- Write every raw pull to a scratch file (`$CLAUDE_JOB_DIR/tmp` when the harness sets it, otherwise
  a session scratch directory) and read back only the aggregate you need - `jq` the interval, the
  per-minute table, the min/max, not the series. This is exactly what a gathering subagent would
  have returned; you are just doing the distillation inline.
- Set `TRIAGE_CACHE_DIR` for the same reason the subagent guidance gives, so the slow 90-day pull
  survives a re-run.
- Expect to touch the wrapper scripts more, not less: they are the only thing keeping the flags and
  `jq` filters correct once there is no subagent to carry that knowledge.
- **Say so in every report the constraint affected**, naming which mandatory delegations were
  skipped and why. A reader has to be able to tell "ran without a second opinion because the
  harness forbade it" from "ran without a second opinion because nobody bothered".

For the mandatory second opinion specifically: if the harness forbids subagents and the headline is
circumstantial, do not silently promote it. Either hold the classification at circumstantial and
state that no refutation pass was possible, or ask the user to run the refutation in a separate
session. Do not self-refute and call it a second opinion - the point of the row is independence,
and a refutation authored by the same context that produced the conclusion does not provide it.

**Delegate to a subagent** (high-volume output, no conversation state needed):

| Work | Agent | Model | Effort | Mandatory? |
| --- | --- | --- | --- | --- |
| Per-group evidence gathering: run the Step 4 recipes, return a distilled table of findings plus the exact commands used | `general-purpose` | `sonnet` | medium | Yes, once per group |
| Monitor enumeration for a broad scope sweep (Step 2) | `general-purpose` | `sonnet` | low | Only for an ambiguous/scoped request |
| One enormous raw pull (a 90-day metrics query, a wide log search) where only summary statistics need to come back | `runner` | `sonnet` | low | Only if not already covered by a gathering subagent using the wrapper scripts |
| Repo or Confluence lookups for a call path (check 11) | `Explore` | `sonnet` | medium | Only when APM alone can't settle the call path |
| **Second opinion, prompted to refute, on a circumstantial root cause** | fresh `general-purpose` | `opus` | high | **Yes, whenever Step 5's headline classification is circumstantial** - see below |

**The second-opinion row is not optional garnish.** If Step 5 lands on circumstantial as the
headline conclusion, dispatch the refutation pass before writing the report - do not treat it as a
nice-to-have that only happens when there's time. Skip it only when the group's own evidence
already forces "unknown" or a ranked-candidate list instead of a single circumstantial headline (in
which case there is no single claim yet for a refuter to attack), and say explicitly in the report
that a second opinion was skipped and why. Prompt the refuter to argue against the conclusion, not
to independently re-derive it - give it the evidence gathered and ask what would have to be true
for the conclusion to be wrong. If it surfaces a case the circumstantial conclusion doesn't survive,
downgrade the classification and say so; a rescued circumstantial conclusion the refuter also
signed off on is worth reporting as such.

Rules:

- **One gathering subagent per group**, dispatched in parallel when there are several. Do not fan
  out one subagent per check - the checks share context within a group and splitting them means
  re-deriving the same window and tags repeatedly.
- **Use `general-purpose` for gathering, not `runner`.** `runner` exists to absorb verbose output
  and report failures verbatim, and is explicitly not chartered to decide what the output means.
  Per-group gathering does need that judgment - which of forty series points matter, whether a
  dependency actually moved - so it belongs to an agent meant for it. Keep `runner` for a single
  huge pull whose summary is all you want back.
- **A gathering subagent returns findings, never raw JSON.** Require it to return: per check, the
  finding in one or two sentences, the specific numbers that matter, and the verbatim commands it
  ran. Its report belongs in the main context; its stdout does not.
- **Tell a gathering subagent to use the `$TRIAGE_SKILL_DIR/references/scripts/` wrappers** (give
  it the resolved absolute path, not the relative one) for checks 1, 2, 3, 4, 5,
  6, 7, 9, 10 and 14, falling back to the raw `pup-recipes.md` recipe only
  where a script doesn't cover what's needed (check 8's facet breakdown, checks 11-13). This keeps
  the subagent's own reconstruction of flags and `jq` filters - and the errors that come with it -
  out of the loop for the checks that don't need it.
- **Give a gathering subagent the wrappers' exit-code contract** (tabulated in
  `pup-recipes.md`'s "Wrapper scripts" section) and require it to report the exit code alongside
  each finding. Exit 3 means the query worked and the result was legitimately empty - a monitor
  that did not fire in the window - which is a finding. Exit 2 means `pup` returned an
  unrecognized shape, so the check *did not run* and must be reported as incomplete rather than
  as a clean result. Exit 4 is a third outcome and the easiest to lose: the result was empty *but*
  the monitor did change state in the window, so the event stream is unavailable for it - report
  the indexing gap, not "it did not fire", and reconstruct the timeline from the metric. A subagent
  that collapses any of the three into "the check failed", or worse into silence, reproduces
  exactly the gap this skill's auth rule warns about.
- **Point a gathering subagent at `TRIAGE_CACHE_DIR`** (a directory under the session's scratchpad)
  before it runs `monitor-history-90d.sh`, and reuse the same directory if Step 3's grouping is
  later revisited and the same monitor's 90-day history is needed again. The script itself skips
  the re-query when a matching cache file already exists; the subagent only needs to be told to set
  the variable, not to implement caching itself.
- **If a gathering subagent reports repeated 429s across more than one of its own queries,** that
  is normal single-subagent behavior for `pup-recipes.md`'s auth section to handle (retry with
  backoff) and does not need to change how subagents are dispatched. If 429s are reported by
  **more than one gathering subagent at the same time**, the parallel dispatch across groups is
  likely exhausting the account's rate budget; switch remaining groups to sequential dispatch (one
  gathering subagent at a time) rather than continuing to launch them in parallel, and note in the
  report that the investigation was serialized because of rate limiting.
- **Dispatch fresh subagents, not forks, for gathering.** A fork inherits this conversation's full
  history for work that needs none of it. Fork only to continue analysis already underway here.
- **Never delegate the conclusion.** A subagent that gathers evidence should not also decide the
  root cause; that merges the two things this skill deliberately keeps apart.
- **When a single monitor is the whole scope and the queries are few,** running Step 4 directly in
  the main agent is fine - narrow output, and it saves a round trip. Delegate once the group needs
  more than roughly a dozen queries or any 90-day pull.
- Write intermediate pulls to files in the scratchpad directory and read back only what is needed,
  rather than letting large outputs land in context.
- **If the harness ignores a `model:` pin on a delegated call** (as Step 5's top-level note already
  anticipates for the main agent's own `opus` pin), dispatch at whatever model the harness actually
  uses rather than blocking on it - the tier in the table is a cost/quality guide for gathering and
  second-opinion work, not a correctness gate the way the `opus` pin is for Step 5's synthesis
  itself.

## Non-goals

No writes to Datadog of any kind - no ack, mute, resolve, downtime, monitor edit, or delete. No
ticket creation, no Slack or Rootly posts, no PR. No changes to service code or monitor
configuration; recommend them in the report instead. No triage of an alert with no Datadog monitor
behind it - if the page came from somewhere else, say so and stop rather than inventing a monitor
to investigate.
