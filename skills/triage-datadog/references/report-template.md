<!--
created: 2026-08-26
updated: 2026-08-27
-->

# Triage Report Structure

Every report follows this skeleton, in this order, with these heading levels. Fill sections in;
do not reorder or rename them. Omit a numbered subsection only when the check genuinely did not
apply, and record it in the "Checks not run" table rather than deleting the heading silently.

Written to `<report-directory>/triage-YYYY-MM-DD-<descriptive-kebab-case-slug>.md`.

Two properties of the shape are worth understanding before filling it in, because they are the
reason several rules below look fussier than a style guide:

- **The report is one artifact serving four readers** - the person paged now, the team that owns
  the cause, whoever gets a similar alert next month, and whoever has to re-derive a number. The
  layering (BLUF, section 1, section 2, appendices) is what lets one file serve all four. Each
  layer must be correct and complete on its own, because each has readers who stop there.
- **Every figure has exactly one canonical home.** A number repeated in five places has to be
  corrected in five places, and the one that gets missed is the one someone quotes. Pick the
  subsection that establishes a figure, put the full derivation there, and elsewhere state the
  figure with a pointer (`48.4 percent (2.3)`) rather than re-deriving it. Four places are licensed
  to duplicate - the frontmatter, the BLUF, the paste block that restates it, and the at-a-glance
  table - because a skimmer must not have to jump and a machine-readable index has to carry its own
  values. That duplication is the price of the layering above; everywhere else, cite.

---

````markdown
---
report: triage
date: YYYY-MM-DD
monitors: [<monitor_id>, <monitor_id>]
services: [<service>, <service>]
env: <env>
window: <YYYY-MM-DDTHH:MM:SSZ>/<YYYY-MM-DDTHH:MM:SSZ>
action: <NONE | TUNE MONITOR | HAND OFF | OWN AND FIX | KEEP INVESTIGATING>
classification: <real and ongoing | real and resolved | monitor noise or misconfiguration | benign or expected behavior | real, cause not yet established>
confidence: <confirmed | circumstantial | unknown>
owner: <team or service that owns the cause, or "unassigned">
impact:
  requests_affected: <integer, or 0>
  peak_error_rate: <decimal fraction, or null for a latency-only event>
  duration_seconds: <integer - of the underlying event, not of the monitor cycle>
  customer_visible: <true | false>
related: [<other-report-slug>, ...]
---

<!-- Machine-readable header. This is what makes a directory of these reports queryable rather
     than merely readable: "every HAND OFF this month", "which monitors have been classified noise
     more than once", "the three largest customer-visible events this quarter". It is also what
     the skill's own prior-report check reads, so `monitors:` must list every monitor ID the report
     covers, as integers.

     Every value here is duplicated in prose below, deliberately - this block is an index, not the
     report. Keep the two in step; if a revision changes the classification or the action, change
     it in both places. `duration_seconds` measures the underlying event, which is frequently much
     shorter than the monitor cycle (a 60-second stall can hold a `sum(last_10m)` monitor open for
     eleven minutes) - record the event, since that is what the impact figures are scoped to. -->

# Investigation: <service> "<monitor name or alert subject>" (<env>)

> **ACTION REQUIRED: <NONE | TUNE MONITOR | HAND OFF | OWN AND FIX | KEEP INVESTIGATING>** -
> <one clause, 20 words maximum, naming the single next thing a reader would actually do. When the
> value is NONE, say what makes it NONE - "self-recovered, monitor behaved correctly, awareness
> only" - never leave the clause empty.>

| | |
| --- | --- |
| **What happened** | <one line, plain language, no metric names if a plain word will do> |
| **Impact** | <N requests affected \| <share> of traffic \| <duration> \| customer-visible: yes/no> |
| **Still happening?** | <`No - self-recovered HH:MM UTC` \| `Yes - ongoing as of HH:MM UTC`> |
| **Owner** | <this team \| another named team \| nobody yet> |
| **Urgency** | <page now \| this week \| backlog \| none> |

<!-- BLUF. This block is the whole report for a reader in a time crunch, and it is the reason the
     metadata below sits second rather than first: the first question is "do I have to do
     something", not "which monitor was it".

     ACTION REQUIRED takes one of exactly five values, no others and no invented variants - a
     closed vocabulary is what lets a reader scan a directory of these side by side:
       NONE               - awareness only; nothing to do
       TUNE MONITOR       - the monitor is wrong, the service is fine
       HAND OFF           - real, and it belongs to a team that is not this one
       OWN AND FIX        - real, and it is this team's to fix
       KEEP INVESTIGATING - real, cause not established, and the next check is named below
     It answers "what do I do". The Classification field below answers "what was it". They are
     different questions and one never substitutes for the other, so fill in both.

     The Impact row is FIXED-FORMAT, in that order, so impact is comparable across reports:
     requests affected, share of traffic, duration, customer-visible yes or no. "2.35M requests
     145 ms slower", "380 requests", and "12,000 failed" are three incomparable sentences; the
     same three as fixed fields can be ranked at a glance. Use `-` for a field that genuinely does
     not apply, never silence. Duration is the underlying event's, matching `duration_seconds`
     above.

     Hard caps, because a BLUF that grows into a paragraph has stopped being a BLUF: the action
     clause is one sentence, each table cell is one line, and the whole block stays under twelve
     lines. Anything that does not fit belongs in section 1. Do not add rows. -->

### Paste

```text
[<ACTION>] <service> - <one line: what happened>
Impact:  <N requests | share | duration | customer-visible yes/no>
Window:  <HH:MM:SS-HH:MM:SS UTC> (<over | ongoing>)
Cause:   <one line, and whether it is confirmed or circumstantial>
Owner:   <team>
Next:    <the single next action>
Monitor: <https://...>
Report:  <path to this file>
```

<!-- These reports are consumed in Slack and Jira far more often than in a Markdown viewer, and
     neither renders the table above. This block is the copy-paste artifact: plain text, no
     tables, no links except bare URLs, eight lines, wrapped in a `text` fence so it survives a
     copy intact. It restates the BLUF and adds nothing - if the two ever disagree, the BLUF is
     authoritative and this block is stale. Keep it to eight lines; a ninth line means something
     belongs in the report instead. -->

---

- **Monitor:** [<monitor name>](https://<org>.datadoghq.com/monitors/<monitor_id>) (ID `<monitor_id>`)
  <!-- one bullet per monitor when a group covers several -->
- **Alert event:** [triggered `YYYY-MM-DD HH:MM:SS UTC`](https://<org>.datadoghq.com/monitors/<monitor_id>?from_ts=<ms>&to_ts=<ms>&event_id=<trigger_evt_id>),
  [recovered `YYYY-MM-DD HH:MM:SS UTC`](https://<org>.datadoghq.com/monitors/<monitor_id>?from_ts=<ms>&to_ts=<ms>&event_id=<recovery_evt_id>);
  cycle duration ~N minutes
  <!-- MANDATORY: the trigger and recovery timestamps are each their own link to that specific
       alert event, not bare text. The monitor bullet above links the monitor - the thing that
       could fire - and this bullet links the firing the report is actually about; a reader who
       only has the first has to hunt the second by hand. One such bullet per alert cycle, and one
       set per monitor when a group covers several. `monitor-timeline.sh <id> <from> <to> <org>`
       emits each event's `link` field ready to paste; do not hand-assemble the URL when the
       script will give it to you. from_ts/to_ts are MILLISECONDS, padded ten minutes either side
       of the cycle so the reader can see the approach and the recovery. -->
  <!-- When the alert events are not indexed (see check 2's exit 4) there is no event_id and so no
       per-event link. Do not silently drop to plain text: link the window-scoped monitor instead,
       `https://<org>.datadoghq.com/monitors/<monitor_id>?from_ts=<ms>&to_ts=<ms>`, and say in the
       bullet that no alert event exists for this transition and where the timeline was
       reconstructed from. An unlinked timestamp must always be explained, never merely unlinked. -->
  <!-- every timestamp in this report is UTC; the `UTC` suffix is mandatory on every one, not
       just this bullet, so a reader skimming a single number is never left guessing the zone -->
- **Current monitor state:** `OK` | `Alert` | `No Data` (self-recovered / still firing)
- **Underlying metric state:** recovered to baseline | still elevated as of `HH:MM UTC`
- **Priority:** P<n>; notifies `<slack channel>`, `<other targets>`
- **Classification:** real and ongoing | real and resolved | monitor noise or misconfiguration |
  benign or expected behavior | real, cause not yet established
- **Report date:** YYYY-MM-DD
- **Revision:** <omit on a first write; on an update in place, the date and what changed>
- **Related reports:** `triage-YYYY-MM-DD-<other-slug>.md` - <one line on the suspected link and
  why it was kept separate>  <!-- omit if none -->

---

## 1. Summary Conclusion

**<One bold sentence stating the verdict and whether action is needed. 25 words maximum - if it
needs a fourth clause, the extra clause belongs in the paragraph below.>**

### At a glance

| Time (UTC) | What happened |
| --- | --- |
| `HH:MM:SS` | <the first thing that moved, in the underlying system - usually earlier than the alert> |
| `HH:MM:SS` | <monitor triggered> |
| `HH:MM:SS` | <peak, with the number> |
| `HH:MM:SS` | <the metric returned to baseline> |
| `HH:MM:SS` | <monitor recovered> |

<!-- Eight rows maximum, in time order, one line each. This exists so nobody has to reconstruct
     the sequence from three paragraphs of prose. Include the cause-side timestamps, not only the
     monitor's - the gap between "the system broke" and "the monitor noticed" is frequently the
     most informative number in the report. Omit the table only for an alert with no meaningful
     sequence (a flat, days-long condition), and say so in one line instead.

     This table is the one place the per-timestamp `UTC` suffix rule below is satisfied by the
     column header instead: the header reads "Time (UTC)" and the cells stay bare, because a
     suffix repeated down eight rows is noise in a table built for scanning. Everywhere else in
     the report, the suffix goes on the timestamp itself. -->

### Causal chain

```
<caller> --[<what it did: blocked, retried, gave up at Ns>]--> <callee> [<STATE>, <figure>, <duration>]
```

<!-- One line, ASCII, for any alert whose cause propagated across a service boundary. Section 2's
     dependency subsection takes thirty or forty lines to establish this; the diagram front-loads
     its conclusion so a reader knows the shape before reading the argument. Extend it leftward
     and rightward as far as the evidence actually reaches, and STOP where the evidence stops -
     an arrow into a service whose internals were never visible is a claim the report cannot
     support. Mark a circumstantial hop with `--?-->` rather than a solid arrow.

     Omit this block entirely when there is no chain - a monitor artifact, a self-inflicted
     regression, a threshold miscalibration - and say in one line that the cause is local. Do not
     draw a one-node diagram. -->

<One paragraph: what fired, what the evidence shows, and the shape of the conclusion.>

**What moved.**

- **<Signal name>.** <Finding, with the numbers that carry it, and the subsection that establishes them.>
- **<Signal name>.** <Finding.>

**What did not move.**

- **<Signal name>.** <What stayed flat, with the range that shows it. Exclusivity is what turns a
  co-timed correlation into a finding - the callee that moved matters far more when every other
  callee did not.>

**Ruled out.**

| Hypothesis | Verdict | Established by |
| --- | --- | --- |
| <Load spike> | Ruled out | <2.4 - the busier minute five minutes earlier was healthy> |
| <Bad release> | Ruled out | <2.9 - running the same version for 8 days> |
| <Infra-wide> | Ruled out | <2.8 - whole-service p95 fell while this resource rose> |
| <The neighbouring alert> | Ruled out | <2.10 - no request-path edge in either direction> |

**Still unknown.**

- <What the evidence does not reach, stated as plainly as the findings above. Omit the block only
  when nothing is unknown, which is rarer than it looks.>

<!-- These four blocks replace a flat list of "signals". The grouping is the argument: what moved,
     what did not, what it was not, what is still open. A reader in a time crunch reads the Ruled
     out table first - the compact list of what this is NOT is what lets them stop worrying about
     four hypotheses at once, and today that reassurance is otherwise scattered across four
     separate subsections.

     Caps: seven bullets total across "What moved" and "What did not move" combined, each opening
     with a bolded 3-6 word label and running at most two sentences. The Ruled out table takes six
     rows. Cite the subsection that establishes each claim rather than re-deriving it here. -->

**Root cause of the alert (as distinct from any outage):** <why the monitor fired, which is often
not the same as why the metric moved.>

**Confidence:** confirmed | circumstantial | unknown - <what evidence sets this level, and for
anything short of confirmed, what would raise it.>

**What would break this conclusion:** <the specific observation that would falsify it - "a second
callee moving in the same buckets", "a deploy record inside the window", "the same burst recurring
with the dependency flat". State it even when confidence is `confirmed`: a reader deciding how far
to trust a report needs to know what the author was watching for and did not see. If nothing could
falsify it, the claim is not an empirical one and should be rewritten until it is.>

### Recommended course of action

| # | Action | Owner | Effort | Ticket? |
| --- | --- | --- | --- | --- |
| 1 | <Most valuable action first. If none is needed, say that explicitly as item 1.> | <team or person> | <minutes \| hours \| days> | <yes \| no> |
| 2 | <...> | | | |

<!-- Owner and effort are what turn a recommendation into something someone picks up. A ranked
     list with neither reads as a wish list, and the reader has to re-derive both before they can
     act. Rank by value, not by effort - but state the effort, so a reader can choose to take the
     cheap third item now. -->

---

## 2. What was investigated, and why it mattered

Each subsection documents a check, its finding, and whether it was relevant to the conclusion.
Together they form a repeatable runbook for this class of alert. Reproducible commands are in
[Appendix F](#appendix-f-commands-used-reproducible).

The subsection order is reading order, which is not the order the checks were run in - SKILL.md's
check table carries the mapping in its "Report" column. Most visibly, the 90-day history is run
early and written up late, at 2.13, because a reader needs the specific incident before the pattern.

If Step 3's evidence-depth gate applied and checks 4-8/11-12 were skipped, say so here in one
paragraph before 2.3, naming all four gate criteria and the specific number that satisfied each
(cycle count and distinct days from 2.13, the monitor's `modified` date from 2.1, the related-monitor
result from 2.10, and the fast blast-radius sanity check's result) - do not just omit the
subsections silently.

<!-- SKIM SPINE. Every 2.N subsection below opens with exactly two lines before any prose:

       **Finding:** <one sentence, the answer this check produced.> `[Relevant]`

     The tag is one of `[Relevant]`, `[Ruled out]`, `[Inconclusive]`, or `[N/A]`, and it says what
     the check did to the conclusion, not how interesting it was. A reader who reads only the
     bolded Finding lines has the entire investigation in fifteen lines; the evidence underneath is
     for whoever needs to re-derive it. `[Ruled out]` is not a lesser result - an eliminated
     hypothesis nobody recorded is one the next person re-investigates.

     The stub is spelled out on 2.1 below as the exemplar. It is not special to 2.1 - repeat it on
     every subsection, including the ones added beyond 2.15. -->

### 2.1 Monitor definition and configuration (relevant: defines what "alert" means)

**Finding:** <one sentence.> `[Relevant]`

### 2.2 Alert timeline (relevant: bounds the investigation window)

### 2.3 Absolute value in the window (relevant: was the metric actually bad?)

### 2.4 Throughput and sample volume (relevant: rules out load spike and low-sample artifacts)

### 2.5 Error rate - APM and logs (relevant: separates failure-driven from latency-only)

### 2.6 Seasonality, day and week over week (relevant: is this metric AND this traffic level normal for this day and hour?)

### 2.7 Daily shape (relevant: explains flapping and recurring windows)

### 2.8 Resource-level breakdown (relevant: isolates the true source; infra-wide vs one endpoint)

### 2.9 Deployments and configuration changes (relevant: rules out a bad release)

### 2.10 Related monitors and alerts (relevant: scopes the event beyond this monitor)

### 2.11 Upstream and downstream dependencies (relevant: locates the cause off-service)

### 2.12 Logs, spans, and traces (relevant: what the service was actually doing)

### 2.13 90-day alert history (relevant: anomaly or pattern; is this monitor meaningful?)

### 2.14 Monitor recovery trustworthiness (relevant: is `OK` real, or a model artifact?)

### 2.15 Blast radius and customer impact (relevant: does this need an owner?)

<!-- Add further 2.N subsections for checks this alert specifically warranted, each with its own
     "(relevant: ...)" clause. Keep the numbering contiguous. -->

### Checks not run

| Check | Why not | Could it have changed the conclusion? |
| --- | --- | --- |
| <2.6 Seasonality> | <a 60-second excursion has no seasonal reading> | <No> |
| <2.8 Resource breakdown> | <the monitor is already scoped to one resource> | <No> |

<!-- A check that did not apply gets ONE ROW HERE, not a subsection of prose explaining its own
     absence. Four skipped checks written up as four apologetic paragraphs is forty lines of "we
     did not do this" in the middle of the evidence, and it reads as padding even though each
     sentence is defensible.

     Keep the numbered heading in place above (so the numbering stays contiguous and a reader
     looking for 2.6 finds it) with only its `**Finding:** ... [N/A]` line, and put the reasoning
     here. The third column is the one that matters: a skip whose answer is anything other than a
     flat "No" is not a skip, it is a gap - promote it back to a real subsection, or record it in
     "Still unknown" in section 1 and as a next step. -->

---

## 3. Root Cause

<The mechanism, stated plainly. Separate what moved the metric from what fired the monitor.
Mark each claim confirmed, circumstantial, or ruled out. Do not promote a circumstantial lead to a
conclusion.>

<!-- When no single root cause is confirmed, replace the paragraph above with a ranked candidate
     list instead of stopping at "unknown": -->

### Candidate causes (no single root cause confirmed)

1. **<Candidate>** - *Supports:* <evidence.> *Argues against:* <evidence.>
   *Would confirm or eliminate it:* <the specific query, trace, or code path to check next.>
2. **<Candidate>** - ...

<Rank by how well the evidence fits, not by how easy the check is. State plainly which candidate
you would chase first and why.>

**Second opinion:** <Required whenever the headline classification above is circumstantial: what
the refutation pass was asked to attack, what it argued, and whether the conclusion survived it or
was downgraded. If it was skipped - which is only permissible when the evidence already forces
"unknown" or the ranked list above, leaving no single claim to attack - say so and say why.>

---

## 4. Recommended Next Steps

<The section 1 table, expanded. One subsection or paragraph per action, in the same rank order,
saying what it needs, who it needs it from, and why it sits at that rank. Section 1's table is the
index; this is where an action gets enough detail to be picked up by someone who was not part of
the investigation.>

<!-- Distinguish: needs an owner and a ticket / monitor retuning / no action beyond awareness. -->

---

## Appendix A: Monitor definition

<Full monitor query verbatim in a fenced block, plus the options that matter: thresholds,
evaluation window, seasonality, direction, notification targets, creator, created and modified
dates, draft status, matching downtimes.>

## Appendix B: <primary metric> around the alert (check 4)

<Table or fenced series. Include the units.>

## Appendix C: Throughput

## Appendix D: Error rate

## Appendix E: Datadog web links

<The collected index of every link used inline above, plus the monitor, the trigger and recovery
event links and snapshots, and any dashboard or notebook consulted. Build hosts from the org in
the monitor link; scope each link to the investigation window.>

## Appendix F: Commands used (reproducible)

All timestamps are UTC. The CLI is `pup` (Datadog API CLI); `--no-agent` yields the raw payload
that matches what you see running these by hand, and `--read-only` blocks any write at the CLI
layer.

```bash
# <check number and name>
<command with literal timestamps, not relative windows>
```

<!-- Group by check. Include commands that were tried and did not work, with the reason. -->

## Appendix G: 90-day trigger history

<Total cycles, distinct days, per-day counts, min/median/mean/max cycle duration, whether all
cycles self-recovered, and whether firings cluster or spread.>

<!-- Appendices A-H cover checks 1, 3, 4, 5, 6, and 9. Add further lettered appendices, in
     check order, for any other check whose raw material a reader would need to re-derive the
     numbers in section 2 - seasonality (check 7), the resource-level breakdown (check 8),
     dependency metrics (check 11), log/span/trace output (check 12), the recovery baseline
     (check 13), or blast-radius counts (check 14).

     Lettering: continue contiguously from `I`. No letter is reserved for anything, including the
     monitor inventory in the "Multi-alert groups" section below - that inventory takes the next
     free letter AFTER the last check appendix, whatever letter that turns out to be. So a
     single-monitor report whose first extra appendix is dependency metrics calls it
     `Appendix I: <service> dependency metrics`; it neither leaves a gap at `I` nor renumbers
     anything. Never leave a gap in the sequence. -->

## Appendix H: Deploy pipeline evidence

<What the Deployment records claim (including their statuses - success/failure/pending/
in_progress, and whether any sat behind an environment-protection approval), what the deploy
workflow's run and job-level history shows, what the GitOps environment branch actually shows, the
exact-SHA cross-check result between the newest Deployment and the newest GitOps commit, any open
unmerged deploy PRs, and the net statement of which version has been running since when.>

````

---

## Multi-alert groups

When one report covers several related monitors, keep the same skeleton and adapt:

- List every monitor ID in the frontmatter's `monitors:` array and every affected service in
  `services:`, then give each monitor its own bullet in the header block with its own
  trigger/recovery times.
- In section 1, state the relatedness finding explicitly - which monitor is primary, which are
  inheriting, and what evidence establishes the link.
- Section 2 stays a single set of checks over the group, not one set per monitor; note per-monitor
  differences inside the relevant subsection.
- Add a `Monitor inventory` appendix when the group came from a scope sweep, recording how many
  monitors were in scope, how many had transitions in the window, and the filter used. Give it the
  next free letter after the last check appendix - it is not fixed at `I`, so a report that already
  used `I` and `J` for dependency metrics and blast-radius counts calls this one `Appendix K`.

## Style

- **The report is read at four depths, and each one must stand alone.** The BLUF answers "do I
  have to do something" in ten seconds. Section 1 answers "what happened and why" in two minutes.
  Section 2 is the runbook for someone working the same class of alert. The appendices are the raw
  material. A reader who stops after any one of them should not have been misled by stopping
  there - which means the BLUF cannot hedge, and section 1 cannot depend on section 2 to correct
  it.
- **Every figure has one canonical home; everywhere else cites it.** Establish a number once, in
  the subsection whose check produced it, with its derivation and its units. Elsewhere, state the
  figure and point at that subsection (`48.4 percent (2.3)`) instead of re-deriving it. This is a
  correctness rule before it is a style one: a figure living in five places gets corrected in four
  of them. The frontmatter, the BLUF, the paste block, and the at-a-glance table are the licensed
  exceptions, for the reasons given at the top of this file.
- **Length caps, and they are caps rather than targets.** Density is the failure mode these
  reports actually have, so where a rule below binds, cut rather than negotiate:
  - BLUF: under twelve lines, one line per table cell, five rows, no added rows.
  - Paste block: eight lines, plain text, no tables.
  - Section 1 headline: one sentence, 25 words.
  - At a glance: eight rows, one line each.
  - Causal chain: one line.
  - "What moved" plus "What did not move": seven bullets combined, each opening with a bolded 3-6
    word label, then at most two sentences. A bullet that needs a third sentence is a section 2
    subsection wearing a bullet.
  - Ruled out: six rows.
  - Any paragraph: four sentences.
- **Lead with the number, then explain it.** "p95 rose 0.024 s to 9.920 s, a ~410-fold increase,
  because ..." reads at a glance; the same fact arriving after two clauses of setup does not.
- **Section 2 teaches, section 3 concludes, appendices hold the raw material.** Each 2.N subsection
  should explain why that check matters for this class of alert and how to read its output, so
  someone paged for a similar alert later can follow it as a manual runbook. Keep the concrete
  supporting detail - full monitor definitions, series tables, command transcripts, pipeline
  evidence - in the appendices, so section 2 stays readable end to end.
- **Link to the Datadog UI inline, at the point of reference**, not only in Appendix E: a claim
  about a metric should link the panel that shows it, a claim about an error should link the log
  query that finds it. Build links against the org host from the monitor link supplied, scoped to
  the investigation window; see `pup-recipes.md` ("Datadog web links") for the shapes. Appendix E
  remains the collected index of them.
- Numbers carry the argument: give the value, the baseline it is compared against, and the units.
- **Every metric figure states its rollup interval**, in the subsection that establishes it and
  in the appendix command that produced it - for example "12,000 failed requests (60 s buckets,
  `.rollup(sum, 60)`)".
  `pup metrics query` picks its own interval when none is pinned, reports it nowhere, and does not
  keep it consistent between services in one sweep, so an unlabelled count is not a count: read as
  per-minute, a 10-second bucket understates by ~6x. See `pup-recipes.md` gotcha 7. A figure whose
  interval cannot be stated does not go in the report.
- Say what was ruled out, not only what was ruled in - an unrecorded eliminated hypothesis gets
  re-investigated by the next person.
- Mark uncertainty in the sentence that makes the claim, not in a caveat at the end.
- **Every timestamp is UTC, with the `UTC` suffix stated on the timestamp itself** (`14:32 UTC`
  or an ISO 8601 `Z`-suffixed form), not just once at the top of a section - a reader who copies
  one number out of context must still be able to tell the zone. Do not convert to or report any
  local time zone. When a human daily pattern (lunch rush, an overnight low-traffic window) is
  part of the reasoning, describe it by its UTC hour range (e.g. "<HH:MM>-<HH:MM> UTC, this
  service's usual overnight low") rather than converting to a local clock.
