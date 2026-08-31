<!--
created: 2026-08-26
updated: 2026-08-27
-->

# pup Recipes for Alert Triage

Command recipes for the Step 4 checks, plus the gotchas that have already cost real investigation
time. Service names, org hosts, team tags, and monitor IDs appear here as `<placeholders>`; the
real values for the environment under investigation live in agent memory under
`datadog-triage-environment` and `deploy-pipeline-topology`. Read those first, and if either is
absent, ask the user rather than guessing. Commands marked **verified 2026-08-26** were run
against a live Datadog org on that date and their output shape confirmed; the rest come from prior
triage sessions.

`pup` is the Datadog API CLI. Discovering its surface has a trap: in an agent session `--help`
auto-detects agent mode and returns a ~640 KB JSON schema, so `pup --help` alone floods the context.
Use `pup <command> --help --no-agent` for readable text (the top level is ~6 KB that way), or
`pup agent schema` deliberately when the full machine-readable command tree is what you want; if you
do take the JSON, redirect it to a file and query the file rather than piping.

## Wrapper scripts

Checks 1, 2, 3, 4, 5, 6, 7, 9, 10 and 14 have a fixed query shape on
every invocation - only the monitor_id, tags, service, resource, and window vary.
`$TRIAGE_SKILL_DIR/references/scripts/` holds **eight** wrappers covering **ten** checks - several
cover more than one, so the counts differ by design and there is no missing file. Each
bakes in `--output=json --no-agent --read-only`, the exact `jq` filter, and the gotchas below (the
`@`-prefixed `monitor_id` filter, the envelope differences, the offset-vs-`Z` timestamp trap, the
nanosecond-duration conversion). Every `pup` call inside these scripts is guarded - it errors
loudly, showing the raw output, rather than returning a silently empty or wrong result when `pup`'s
output shape doesn't match what the script expects. `deploy-pipeline-check.sh`'s `gh` calls have no
such guard - GitHub's API response shapes are stable and don't share the documented `pup`
envelope-drift gotcha, so there was nothing to guard against.

| Script | Checks | Usage |
| --- | --- | --- |
| `monitor-definition.sh` | 1 | `<monitor_id>` |
| `monitor-timeline.sh` | 2 | `<monitor_id> <from> <to> [org]` (with `org`, or `TRIAGE_DD_ORG` set, each event gains a ready-to-paste `link` for the report header) |
| `monitor-history-90d.sh` | 3 | `<monitor_id> [from] [to]` |
| `resource-metrics.sh` | 4, 5, 6 | `<service> <resource_name> <from> <to>` |
| `seasonality-check.sh` | 7 | `<service> <resource_name_or_dash> <window_start> <window_end>` |
| `related-monitors.sh` | 10 | `<team_tag> <window_start> [window_end]` |
| `blast-radius.sh` | 14 | `<service> <resource_name> <trigger_timestamp> <recovery_timestamp>` |
| `deploy-pipeline-check.sh` | 9 | `--service <name> --env <env> --from <ts> --to <ts> --org <org> --monorepo <repo> --gitops-repo <repo> --env-branch <branch> --service-path <path> --deploy-workflow <name>` (all required, any order, `--flag=value` also accepted), plus two optional flags: `--lookback <N>d\|<N>h` (default `7d`), which sets how far before `--from` to search for a deploy, and `--deploy-ref-prefix <prefix>`, which checks that the Deployment records actually belong to `--service` - without it step 7 can only ask you to confirm by eye |

`references/scripts/` also holds `_common.sh`, which is **not** a wrapper and covers no check: it
carries the one helper `monitor-timeline.sh` and `monitor-history-90d.sh` both need, and is sourced
by them rather than invoked. It is why the directory has nine files and this table has eight rows.
The wrappers must stay together in that directory; a copy moved out on its own exits 2.

Every wrapper uses the same exit-code contract, and the four failures mean different things. Exits
0, 1 and 2 are reachable from any wrapper; **exits 3 and 4 only from `monitor-timeline.sh` and
`monitor-history-90d.sh`**, the two that query the event stream and so are the only ones that can
come back legitimately empty. A metrics wrapper that returns no data returns exit 0 with an empty
series, which is a finding to read, not a code to catch.

| Exit | Meaning | How to report it |
| --- | --- | --- |
| 0 | The query ran and returned data. | Normal finding. |
| 1 | Wrong or missing arguments, or a rejected timestamp format. | Fix the invocation and re-run; this is not a finding about the service. |
| 2 | `pup` returned a response shape the script does not recognize, a prerequisite (`python3`) is missing, or the `monitor_id` does not resolve at all. The raw output is printed. | **The check did not run.** Say so in the report - do not record it as a clean result. Re-derive the filter from the raw output per gotcha 6, or fix the ID. |
| 3 | The query succeeded, the result set was empty, **and** the monitor's own `overall_state_modified` is outside the window - so the emptiness is consistent with a genuinely quiet monitor. | **This is a finding, not a failure**, but a soft one: confirm against the underlying metric before writing "no alerts". |
| 4 | The result set was empty **but** the monitor demonstrably changed state inside the window. The event stream is unavailable for this monitor. | **Not "it did not fire".** Reconstruct the timeline from the metric (see below), report the indexing gap, and treat any 90-day history as unavailable rather than empty. |

Exit 2 and exit 3 are the pair that matters most: one means the evidence is missing, the other means
the evidence is an absence. Reporting either as the other is the failure mode this skill exists to
prevent.

**Exit 4 exists because exit 3 used to absorb this case and got it wrong.** An empty events-search
result has three causes, not two - the monitor was quiet, the ID is wrong, or *the monitor fired and
its events are not indexed* - and the third is indistinguishable from the first unless you ask the
monitor itself. Worked example, with illustrative figures (`<monitor-A>` below; real monitor IDs
are kept out of this repo, per SKILL.md's placeholder rule, and stay in the reports themselves): a
high-priority monitor created three months earlier transitions at `08:17:26Z` off the back of a
sustained error rate, and returns **zero** events over 90 days via `@monitor_id` and via title
search. Under the old contract both `monitor-timeline.sh` and `monitor-history-90d.sh` would exit 3
with "may not have fired in the window, or the monitor_id is wrong" - both readings false.
Accepting that at face value closes a real incident as a non-event.

Both scripts now cross-check `pup monitors get` before concluding anything, which is why the
distinction is mechanical rather than a thing to remember. Two consequences worth carrying into the
report:

- On exit 4, Step 3's evidence-depth gate **cannot be evaluated** (its first criterion needs cycle
  and distinct-day counts from check 3), so the full Step 4 checklist is mandatory. A monitor with
  no retrievable history superficially resembles a quiet, healthy one; it is not the same thing.
- A high-priority monitor with no indexed events may also mean **the notification never fired**.
  That is worth chasing on the notification target's side, independently of Datadog's event index,
  and it is usually the most consequential finding available.

To reconstruct a timeline without the event stream: pull the monitor's own query expression over
the window (check 4), and for a `sum(last_Nm)` monitor recompute the rolling sum from the raw
component series - the threshold crossings are what the trigger and recovery timestamps would have
been. Worked through on `<monitor-A>` above, that recovers a `08:05:50Z` crossing and a
`08:15:50Z` recovery crossing against a recorded transition of `08:17:26Z` - i.e. roughly a
minute and a half of evaluation lag.

Two options exist only in the scripts, not in the raw recipes below:

- `--from`/`--to` on `deploy-pipeline-check.sh` are the **incident** window, taken from check 2's
  trigger and recovery timestamps - not "today", and not a relative window (both are rejected).
  Every step of that script is scoped from them. `--lookback` then widens the search backwards into
  a *correlation* window, because a release that caused a 14:00 incident may well have shipped at
  09:00; each record comes back tagged `IN-INCIDENT` or `PRE-INCIDENT` so the two never read the
  same. An empty result is a finding, and it means "nothing shipped in the correlation window" - so
  always report which window was searched, since the identical sentence over one hour and over one
  week carry very different weight. - `TRIAGE_CACHE_DIR` (`monitor-history-90d.sh`) - a scratch
  directory in which the 90-day pull is cached, keyed on `<monitor_id, from, to>`. The pull is slow
  and is wanted once per group; a re-run with the same arguments reads the cache instead of
  re-querying. Only a validated response is cached, so an error envelope is never replayed as data.
  Delete the cache file, or point the variable elsewhere, to force a fresh pull. -
  `TRIAGE_METRIC_NAME` (`resource-metrics.sh`, `seasonality-check.sh`, `blast-radius.sh`) - the APM
  metric to query, defaulting to `trace.http.request`. Set it to `trace.servlet.request` for a Java
  servlet service (gotcha 5).

Run a script's bare invocation (or `--help`, where the usage block itself explains the check and
its gotchas) before falling back to the raw recipe below it - the raw recipe is what the script is
built from and stays as the reference for anything the script doesn't cover (an unfiltered scope
query, a variant of the same check, or the case where `pup`'s output shape has changed since the
script was written and needs re-deriving by hand).

Check 8 (per-resource breakdown, grouped by whichever facet the investigation calls for) and checks
11-13 have no wrapper: the query genuinely varies per investigation (which dependency, which log or
trace query, which recovery baseline), so scripting them would just move the judgment call into
script arguments rather than removing it.

## Setup and conventions

```bash
pup auth status --no-agent --read-only          # confirm auth; OAuth tokens expire hourly and auto-refresh
```

On a 401 (token expired) or 403 (account missing the scope), **stop and surface it to the user**,
naming the query that hit it. Do not run `pup auth login` or any other credential command
unprompted, and do not silently drop the check.

- **On a 429 (rate limited), back off and retry** the single query - wait, then retry once or
  twice with an increasing delay (for example 5s, then 15s) - before treating it as a failure. One
  429 on one query is normal API behavior, not an outage, and does not need to be surfaced.
  If 429s recur across **several different queries** in the same investigation, the account's rate
  budget is likely being exhausted by concurrent load - most plausibly several groups' gathering
  subagents querying in parallel (see SKILL.md's "Orchestration" section). When that happens,
  switch the remaining gathering to **sequential** - one group's subagent at a time - rather than
  keep retrying in parallel; sequential gathering is slower but each query gets a full retry budget
  instead of competing for it. Say in the report (or to the user, if it happens before any report
  exists) that the investigation was serialized because of rate limiting, and which groups were
  affected.
- **Output shape.** In an agent session `pup` auto-detects agent mode and wraps responses in a
  `{status, data, metadata}` envelope. Append `--output=json --no-agent --read-only` to get the raw
  payload, which is what every recipe here and every `jq` filter below assumes. Always record
  `--no-agent` in a report appendix, so the user running it by hand sees the same shape.
- **Pass `--read-only` on every call.** It is a global flag that blocks create, update, and delete
  at the CLI layer. Every recipe here is a read, so there is no case where omitting it helps, and it
  makes an accidental write impossible rather than merely disallowed. Verified against `pup` 1.6.4.
- **`--jq '<expr>'` is a global flag** that filters output before formatting, so it replaces piping
  `pup` into `jq`. Prefer it where it fits: a pipe puts `jq`'s exit status in `$?` instead of
  `pup`'s, so a failed query reads as a successful empty result. The worked recipes below still use
  a pipe where the filter runs to several lines and reads better that way - when one of those
  returns empty, re-run the `pup` half alone before concluding there was no data.
- **Multi-org.** `pup auth status` reports the authenticated site. If the org differs from the one
  in the monitor link the user pasted, pass `--org <name>`. Build web links from the org host in
  the user's link (for example `https://<org>.datadoghq.com/monitors/<id>`), not from a
  hardcoded `app.datadoghq.com`.
- **Time arguments** accept relative (`1h`, `18h`, `90d`), RFC3339 (`2026-08-26T12:00:00Z`), Unix
  seconds, or `now`. Prefer explicit RFC3339 in UTC for anything that goes in a report - relative
  windows are not reproducible later.
- **Start small.** Use small `--limit` values first and widen once the query shape is right.
- **APM durations are nanoseconds**, not seconds or milliseconds. `@duration:>1000000000` is one
  second.
- **Count with `aggregate`, not by fetching rows.** `pup logs aggregate --compute=count` instead of
  pulling raw logs and counting them.

## Gotchas that have already burned an investigation

1. **`@monitor_id:<id>` filters; `monitor_id:<id>` does not.** The `@`-prefixed facet form works.
   A bare `monitor_id:<id>` (and the plural `sources:alert`) returns unfiltered, org-wide
   results that *look* like a successful filtered query. Verified 2026-08-26: `@monitor_id` on
   the monitor tested returned 66 events, all belonging to it; the bare form returned an
   empty set for a monitor that had fired that same day.
2. **`pup events list --filter=...` does not filter.** It returns identical org-wide results
   regardless of the filter passed. Use `pup events search --query=...` instead.
3. **Monitor tag `resource_name` and the APM span facet `resource_name` are different strings.**
   Monitor tags and metrics queries use a lowercased HTTP-ish form
   (`post_/example.v1.exampleservice/getthing`); trace search and aggregate need the
   real RPC form (`/example.v1.ExampleService/GetThing`). Using the wrong one returns
   zero results rather than an error.
4. **An empty trace search does not mean nothing happened.** APM sampling drops most spans; a
   low-traffic resource can legitimately have no sampled spans in a 15-minute window. Fall back to
   metrics, which are not sampled, and say in the report that the trace-level check was
   inconclusive rather than treating it as evidence of absence.
5. **The metric name differs by instrumentation.** Go and gRPC services report
   `trace.http.request`; Java servlet services (a Spring Boot or Tomcat application, say) report
   `trace.servlet.request`. Confirm with `pup metrics search` or `pup metrics tags list` before
   concluding a metric is flat. The metrics wrapper scripts default to `trace.http.request`; pass
   the other name via `TRIAGE_METRIC_NAME` rather than editing them.
6. **The JSON envelope differs per command, even with `--no-agent`.** Verified 2026-08-26:
   `pup monitors list` returns a bare array (filter with `.[]`), while `pup events search` returns
   an object carrying `data`, `links`, and `meta` (filter with `.data[]`). The wrong filter returns
   nothing rather than an error, which looks identical to a monitor that never fired. Run any new
   query once with `--limit=1` and check `jq -r 'type'` before writing a filter against it.

7. **`pup metrics query` picks its own rollup interval, and never tells you what it picked.**
   The response carries no interval field; the only way to know is to subtract two adjacent
   `pointlist` timestamps. The interval is derived from the query span, so it changes as you
   change `--from`/`--to`, and it is **not consistent across services in the same sweep** - a
   single multi-service sweep can come back with 10-second buckets for some services and
   20-second buckets for another, from identical query spans.

   This is the single most expensive mistake in this file, because nothing about the output looks
   wrong. Reading a 10-second bucket as a per-minute total understates every count by ~6x, and it
   turns a continuous 60-second event into what looks like a spike in one isolated bucket with
   quiet buckets on either side. The errors it produces: a blast radius reported at under a third
   of the requests that actually failed; a per-minute traffic baseline stated at roughly a sixth of
   the real rate; a "1-minute" incident that was 60 seconds straddling a minute boundary; and
   **wrong rule-outs**, where single low-valued 10-second buckets on `p95` make a flat dependency
   look like it stepped.

   Two rules, both cheap:

   - **Pin the interval** with `.rollup(<aggregator>, <seconds>)` on every metrics query whose
     numbers will appear in a report - `.rollup(sum, 60)` for counts, `.rollup(avg, 60)` or
     `.rollup(max, 60)` for percentiles. Then the interval is a fact you chose, not one you have
     to infer. Note that `.rollup()` on a `p95:` query re-aggregates already-computed percentiles,
     so prefer `max` over `avg` when you want the worst value in each minute, and say which you
     used.
   - **Otherwise, measure it before quoting anything.** Either way the interval is stated
     alongside the figure in the report and in the appendix command that produced it (see
     `report-template.md`'s Style section). To measure it:

     ```bash
     # interval, in seconds, of a metrics response already saved to out.json
     jq '.series[0].pointlist | (.[1][0] - .[0][0]) / 1000' out.json
     # points and span, as a sanity check on what you think you asked for
     jq '.series[0].pointlist | {points: length, span_minutes: ((last[0] - first[0]) / 60000)}' out.json
     ```

   A p95 at 10-second resolution on a service with a wide latency distribution is a noisy
   statistic in its own right: at a few thousand requests per bucket, individual buckets can
   swing by more than 2x while the service is perfectly healthy. Comparing one bucket to another
   manufactures step changes that are not there. Aggregate to at least 1-minute before comparing
   anything across time.

## Check 1: Monitor definition

Prefer `$TRIAGE_SKILL_DIR/references/scripts/monitor-definition.sh <monitor_id>`. Raw recipe:

```bash
pup monitors get <monitor_id> --output=json --no-agent --read-only
```

Read: `query` (the whole investigation follows from the monitor type), `type`, `priority`,
`message` (notification targets), `tags`, `creator`, `created`/`modified`, `overall_state`,
`overall_state_modified`, `draft_status`, `matching_downtimes`, `options.thresholds`.

For an anomaly query - `avg(last_4h):anomalies(p95:...{...}, 'agile', 5, direction='both',
interval=60, alert_window='last_15m', seasonality='weekly') > 1` - note that `> 1` means "left the
predicted band", not "exceeded 1 second". `direction='both'` fires on abnormally *low* values too.
A recently `created` or `modified` monitor that is already firing may simply be miscalibrated.

## Check 2 and 3: Alert timeline and 90-day history

Prefer `$TRIAGE_SKILL_DIR/references/scripts/monitor-history-90d.sh <monitor_id> [from] [to]` for
the 90-day stats and `$TRIAGE_SKILL_DIR/references/scripts/monitor-timeline.sh <monitor_id> <from>
<to>` for one cycle's exact timeline (it also emits `evt.id` for the deep-link in "Datadog web
links" below). Raw recipes:

**Verified 2026-08-26.** The alert event stream is the monitor's transition history:

```bash
pup events search --query='@monitor_id:<monitor_id>' \
  --from="90d" --to="now" --limit=500 --output=json --no-agent --read-only
```

Each event's `attributes.attributes` carries `monitor_id`, `status`, `priority`, `title`,
`timestamp`, `duration`, `monitor_groups`. `status: error` is a trigger, `status: success` is a
recovery, so cycles are trigger/recovery pairs. A 90-day pull on a monitor that cycles regularly
comes back balanced - an equal count of each status - which is a quick sanity check that the filter
is working and no cycle is half-indexed.

**Pairing them is not as simple as zipping the two statuses together**, and getting it wrong
silently produces both a wrong cycle count and a wrong investigation window. Three rules, all
verified against live data on 2026-08-26 and all implemented in `monitor-history-90d.sh`:

- **A trigger row normally carries `duration: null`.** The cycle length lives on the **recovery**
  row, measured back from it. An implementation that looks for durations on the trigger rows finds
  none and reports "0 self-recovered cycles, no durations" for a monitor whose every cycle
  self-recovered - which inverts the entire noise-versus-real judgment.
- **A non-OK row that DOES carry a `duration` is not a new cycle.** It is a re-trigger or an
  escalation (Warn to Alert, or a re-notify) inside an episode that is already open, and its
  duration also measures back to that episode's start. Counting it as a cycle inflates the count.
- **The real episode start can precede every event row in the response.** Take it from
  `recovery_ts - duration`, not from the earliest visible trigger.

The third rule is the expensive one, so here is a worked example (`<monitor-B>` - a different
monitor from the `<monitor-A>` of the exit-4 case above), again with illustrative figures. It
returns exactly two rows for its second cycle: a non-OK row at `10:05:03Z` with `duration`
19,620 s, and a recovery at `12:08:03Z` with `duration` 27,000 s. Trigger-to-recovery is
7,380 s, which matches neither.
Both durations subtract to **`04:38:03Z`** - the true start, which has **no event row at all**. An
investigation that takes `10:05:03Z` as the trigger queries a window in which the metric is flat
and concludes "no cause found", 5.5 hours after the thing it was looking for.

Derive and report: total cycles, distinct days, cycles per day, min/median/mean/max cycle duration,
whether every cycle self-recovered, and whether the firings cluster (a bad week) or spread evenly
(a chronically noisy monitor). `monitor-history-90d.sh` also emits
`cycles_starting_before_any_event_row` and
`cycles_where_duration_disagrees_with_visible_trigger`; a non-zero value in either means the window
you would have read off the trigger row is the wrong window.

```bash
# cycle timestamps and statuses, oldest first
pup events search --query='@monitor_id:<monitor_id>' --from="90d" --to="now" \
  --limit=500 --output=json --no-agent --read-only \
| jq -r '.data | sort_by(.attributes.timestamp)
         | .[] | "\(.attributes.timestamp)\t\(.attributes.attributes.status)"'
```

Narrow the window for the timeline of the specific cycle under investigation:

```bash
pup events search --query='@monitor_id:<monitor_id>' \
  --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only
```

## Checks 4-8: Metrics

Unlike the events-search and monitors-list envelopes in gotcha 6, `pup metrics query`'s response
shape has no filter verified against a live org, so neither the wrapper scripts nor the recipes
below pipe it through `jq` - read the numbers from the raw response rather than trusting a filter
that would silently return nothing on a shape mismatch. The same applies to the metrics queries in
checks 13 and 14.

Prefer `$TRIAGE_SKILL_DIR/references/scripts/resource-metrics.sh <service> <resource_name> <from>
<to>` for checks 4-6 in one shot (resource p95, whole-service p95, traffic, and error rate over the
same window), and `$TRIAGE_SKILL_DIR/references/scripts/seasonality-check.sh <service>
<resource_name_or_dash> <window_start> <window_end>` for check 7's day-over-day and week-over-week
comparison (pass `-` for `resource_name` to run the whole-service query instead of one resource).
Check 8's breakdown has no wrapper - the `by {...}` facet genuinely varies per investigation. Raw
recipes:

```bash
# absolute p95 for the alerting resource, across the alert window.
# .rollup(max, 60) is not optional dressing: without it the interval is whatever pup decides from
# the span, and is not reported anywhere in the response. See gotcha 7.
pup metrics query \
  --query="p95:trace.http.request{env:prod,service:<service>,resource_name:post_/example.v1.exampleservice/getthing}.rollup(max, 60)" \
  --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only

# whole-service p95 - if this is flat while one resource moved, the cause is not infra-wide
pup metrics query --query="p95:trace.http.request{env:prod,service:<service>}.rollup(max, 60)" \
  --from="2026-08-26T11:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only

# traffic / sample volume (check 5) - sum, not max, so the per-minute figure is a real total
pup metrics query \
  --query="sum:trace.http.request.hits{env:prod,service:<service>}.as_count().rollup(sum, 60)" \
  --from="2026-08-26T11:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only

# error rate as a percentage (check 6). Roll up each side before dividing -- a ratio of two
# differently-bucketed series is meaningless, and a per-bucket ratio is not the per-minute rate.
pup metrics query \
  --query="(sum:trace.http.request.errors{env:prod,service:<service>}.as_count().rollup(sum, 60)/sum:trace.http.request.hits{env:prod,service:<service>}.as_count().rollup(sum, 60))*100" \
  --from="2026-08-26T11:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only

# 90-day daily shape, hourly rollup (check 7) - this is the "pattern or anomaly" metric view
pup metrics query \
  --query="p95:trace.http.request{env:prod,service:<service>,resource_name:...}.rollup(avg, 3600)" \
  --from="90d" --to="now" --output=json --no-agent --read-only

# week-over-week: same clock window, seven days earlier (check 7). Pin the SAME rollup as the
# current-window query, or you are comparing two different aggregations and the difference you
# find may be entirely an artifact of the interval.
pup metrics query --query="p95:trace.http.request{env:prod,service:<service>}.rollup(max, 60)" \
  --from="2026-08-19T12:00:00Z" --to="2026-08-19T14:00:00Z" --output=json --no-agent --read-only

# per-resource breakdown - finds a bimodal endpoint mix dragging a service aggregate (check 8)
pup metrics query --query="p95:trace.http.request{env:prod,service:<service>} by {resource_name}.rollup(max, 60)" \
  --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only
```

A 90-day query is slow; run it once per group, not per variant. Use `.rollup()` so the response is
a few hundred points rather than tens of thousands.

Every recipe above pins `.rollup()` deliberately. Do not strip it to "get more detail" without
reading gotcha 7 first: an unpinned query does not give you a known finer resolution, it gives you
an unknown one, and the numbers it returns are not the per-minute counts they look like.

The relative `--from="90d"` above is convenient while investigating, but resolve it to the literal
UTC timestamps it actually covered before recording the command in a report appendix - a relative
window returns different data every day it is re-run.

## Check 9: Release pipeline and configuration change

Prefer `$TRIAGE_SKILL_DIR/references/scripts/deploy-pipeline-check.sh` for the change-stories query
below plus all seven GitHub-side pipeline-verification calls further down, in order, in one shot -
running the raw change-stories command by hand first and then also running the script duplicates
that call. The script does not cover the separate `source:deployment` cross-check just below it; run
that one on its own. It takes ten named flags (see the wrapper-scripts table above, or `--help`);
they are named rather than positional because transposing `--monorepo` with `--gitops-repo`, or
`--env-branch` with `--service-path`, returns plausible data from the wrong place instead of an
error. Raw recipes, starting with Datadog's own change feed:

```bash
pup change-stories list --service <service> --env prod \
  --from="2026-08-26T00:00:00Z" --to="2026-08-26T15:00:00Z" --output=json --no-agent --read-only
```

`--service` and `--from`/`--to` are required and `--service` takes no wildcards, so run it once per
service in the group, including dependencies. `--story-types` filters to any of `deployment`,
`feature_flag`, `configuration`, `database`, `kubernetes`, `scale`, `crashloopbackoff`,
`traffic_anomaly`, `schema`, `watchdog`; omit it to get all of them. An empty
`{"stories": [], "truncated": false}` is meaningful evidence - no deploy, no k8s change, no scale
event, no flag flip - but only for a service change-stories has ever covered; if this service has no
change-story history at all across the full 90-day window, that is a coverage gap, not evidence of
absence, so check the 90-day history has *some* story before trusting a narrow window's absence.

```bash
# Datadog deployment events as a cross-check
pup events search --query='source:deployment service:<service>' \
  --from="24h" --to="now" --output=json --no-agent --read-only
```

Then verify against the real pipeline, because Datadog change stories and GitHub Deployment records
both report *intent*, not what is running. (The wrapper script named above covers the seven calls
below, not the `source:deployment` cross-check above it - run that one by hand either way.)

```bash
# 1. GitHub Deployment records (written on workflow success, even if it only opened a GitOps PR)
#    -- id and sha are needed by steps 2 and 4 below, not just created_at/ref/description
gh api "repos/<org>/<monorepo>/deployments?environment=<env>&per_page=15" \
  --jq '.[] | {id, created_at, ref, sha, description}'

# 2. Deployment statuses -- a Deployment record alone is intent, not fact. success/failure/pending/
#    in_progress and environment_url come from its statuses sub-resource, not the record itself.
#    "pending" here usually means an environment protection rule is waiting on manual approval.
gh api "repos/<org>/<monorepo>/deployments/<deployment_id>/statuses" \
  --jq '.[] | {created_at, state, environment_url, description}'

# 3. what the deploy workflow actually ran
gh run list --repo <org>/<monorepo> --workflow="<deploy-workflow>.yaml" --limit 15 \
  --json databaseId,displayTitle,status,conclusion,createdAt,event

# 4. job-level detail for a run -- catches a green overall run whose deploy job itself failed
#    or was skipped (for example a gated approval job that timed out)
gh api "repos/<org>/<monorepo>/actions/runs/<run_id>/jobs" \
  --jq '.jobs[] | {name, status, conclusion, started_at, completed_at}'

# 5. the GitOps repo commits that actually changed the running manifest
gh api "repos/<org>/<gitops-repo>/commits?sha=<env-branch>&path=<service-path>&per_page=10" \
  --jq '.[] | {sha, date: .commit.committer.date, msg: (.commit.message | split("\n")[0])}'

# 6. exact-SHA cross-check -- does the newest Deployment's sha (from step 1) match the newest
#    env-branch commit's sha (from step 5) touching service_path? Compare them directly:
#      newest_deployment_sha=<sha from step 1's most recent record>
#      newest_gitops_sha=<sha from step 5's most recent commit>
#      [[ "$newest_deployment_sha" == "$newest_gitops_sha" ]] && echo MATCH || echo MISMATCH
#    A mismatch means the Deployment's stated ref and what actually shipped disagree, so do not
#    assume the Deployment's ref is what is running.

# 7. open, unmerged deploy PRs - these have NOT reached the cluster
gh pr list --repo <org>/<gitops-repo> --state open --limit 10
```

Some monorepos carry a mapping file naming each service's GitOps repo, path, and branch; the
cluster changes only when that branch changes, so a Deployment record whose GitOps PR is still
open means the version never shipped. Confirm the mapping for the service under investigation
rather than assuming another service's. The mapping file, repo, and workflow names for the
environment under investigation are in agent memory under `deploy-pipeline-topology`.

All GitHub API timestamps above are already UTC (`Z`-suffixed ISO 8601) - report them as-is, do not
convert them.

## Check 10: Related monitors

Prefer `$TRIAGE_SKILL_DIR/references/scripts/related-monitors.sh <team_tag> <window_start>
[window_end]` - it runs the state-snapshot listing and the event-stream cross-check below in one
shot, guards the offset-vs-`Z` timestamp trap, separates `No Data` monitors from genuinely firing
ones, and scopes the event query by `@monitor_id` rather than running it org-wide. That last one
matters: the bare `source:alert` form in the raw recipes below is **org-wide**, and on a busy org
it can spend its whole row limit on other teams' alerts before reaching this team's - a 200-row
limit consumed by well under two minutes of a 24-hour window, none of it the requested team's. Use
the raw form only to inspect one narrow window, and scope it by `@monitor_id` the moment the
answer has to be complete. Raw recipes:

```bash
# every monitor in the scope, with state and last transition
pup monitors list --tags="team:<team-tag>" --limit=500 --output=json --no-agent --read-only \
| jq -r '.[] | select(.overall_state_modified >= "2026-08-26T00:00:00")
         | "\(.id)\t\(.overall_state)\t\(.overall_state_modified)\t\(.name)"'
```

**Verified 2026-08-26:** `monitors list` returns `id`, `name`, `type`, `query`, `tags`, `priority`,
`overall_state`, `overall_state_modified`, `creator`, `created`, `modified`, `draft_status`,
`matching_downtimes`, `options`, `message`. `--tags` filters correctly.

`overall_state_modified` comes back as `2026-08-24T01:38:22+00:00` - a `+00:00` offset, not a `Z`
suffix - so a lexicographic comparison must be against an offset-free prefix like
`"2026-08-26T00:00:00"`. Appending a `Z` to the comparison value silently matches nothing.

It is also only a snapshot of the last transition, so a monitor that fired and recovered
inside the window shows only its recovery. Cross-check the event stream for the window:

```bash
pup events search --query='source:alert' --from="18h" --to="now" \
  --limit=200 --output=json --no-agent --read-only \
| jq -r '.data[] | "\(.attributes.timestamp)\t\(.attributes.attributes.monitor_id)\t\(.attributes.attributes.status)\t\(.attributes.attributes.title)"'
```

`pup monitors search --query=...` is available for name/tag text search when the scope tag is not
known.

## Check 11: Upstream and downstream services

```bash
pup apm dependencies list --env prod --output=json --no-agent --read-only          # full service graph
pup apm dependencies list --env prod --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" \
  --output=json --no-agent --read-only                                            # graph as of the window
pup apm flow-map --env prod --output=json --no-agent --read-only                   # request-path view
pup apm services list --env prod --output=json --no-agent --read-only
pup apm services stats --env prod --output=json --no-agent --read-only             # fleet-wide latency/errors
```

Take the alerting service's callee list, then run the check-4 metrics query against each callee
across the same window. A dependency whose p95 stepped at the same minute is the strongest
non-deploy lead available. Confirm the edge is on the *alerting resource's* path, not just
service-to-service, before calling it causal - `pup traces search` on the resource, or reading the
handler in the repo, is what turns a co-timed graph edge into a mechanism.

When APM cannot settle the call path, read the code (the handler and its clients) or search
Confluence for the service's architecture page. `pup service-catalog get <service>` and
`pup software-catalog relations list` carry ownership and declared relationships.

## Check 12: Logs, spans, and traces

```bash
# log volume by status - cheap first look
pup logs aggregate --query='service:<service> env:prod' \
  --from="2026-08-26T08:00:00Z" --to="2026-08-26T08:20:00Z" \
  --compute=count --group-by=status --output=json --no-agent --read-only

# the actual error text
pup logs search --query='service:<service> env:prod status:error' \
  --from="2026-08-26T08:03:00Z" --to="2026-08-26T08:07:00Z" \
  --limit=20 --sort=desc --output=json --no-agent --read-only

# which resources and status codes the errors landed on
pup traces aggregate --query='service:<service> status:error' \
  --compute=count --group-by=resource_name \
  --from="2026-08-26T08:03:00Z" --to="2026-08-26T08:07:00Z" --output=json --no-agent --read-only

pup traces aggregate --query='service:<service> status:error' \
  --compute=count --group-by='@http.status_code' \
  --from="2026-08-26T08:03:00Z" --to="2026-08-26T08:07:00Z" --output=json --no-agent --read-only

# span-level p95 for one resource (RPC form of resource_name - see gotcha 3)
pup traces aggregate \
  --query='service:<service> resource_name:"/example.v1.ExampleService/GetThing"' \
  --compute="percentile(@duration, 95)" \
  --from="2026-08-26T13:00:00Z" --to="2026-08-26T13:30:00Z" --output=json --no-agent --read-only

# individual slow spans, to see the downstream calls inside them
pup traces search --query='service:<service> @duration:>400000000' \
  --from="2026-08-26T13:00:00Z" --to="2026-08-26T13:15:00Z" \
  --limit=5 --output=json --no-agent --read-only
```

Trace `percentile(@duration, 95)` returns nanoseconds. Cross-check it against the metrics p95 for
the same window; a large divergence usually means sampling, not a real discrepancy.

When a log or span names a code path, resolve it to `file:line` in the repo and quote it in the
report - that is what makes the finding actionable rather than descriptive.

## Check 13: Monitor recovery trustworthiness

No dedicated command - this is the check-4 metrics query re-run after the recovery event, compared
against the **pre-alert baseline** rather than against the alert peak.

```bash
# Pin the SAME rollup the check-4 query used, or the post-recovery level and the pre-alert baseline
# are two different aggregations and the comparison this check exists for is meaningless. Gotcha 7
# records two wrong rule-outs that came from comparing unpinned p95 buckets.
pup metrics query --query="p95:trace.http.request{env:prod,service:<service>}.rollup(max, 60)" \
  --from="<recovery_timestamp>" --to="now" --output=json --no-agent --read-only
```

If the post-recovery level sits above the pre-alert baseline, the monitor recovered and the
regression did not. For an anomaly monitor that is the expected mechanism rather than a surprise: an
agile or seasonal model re-baselines onto the new level within a few evaluation windows. For a
`sum(last_Nm)` monitor, recovery means only that the burst aged out of the window. Report monitor
state and metric state as two separate facts - the report header has a field for each.

## Check 14: Blast radius and customer impact

Counts, not rates. "How many requests were affected" is the question a ticket decision turns on, and
a rate hides it.

Prefer `$TRIAGE_SKILL_DIR/references/scripts/blast-radius.sh <service> <resource_name>
<trigger_timestamp> <recovery_timestamp>` - it runs all four queries below in one shot: affected
volume, the same clock window one day earlier for scale, failed requests, and distinct endpoints
touched. Raw recipes (the day-earlier baseline is the first query again with both timestamps shifted
back 24 hours, which is what the script's `python3` shift does):

```bash
# affected request volume across the cycle, and the same window a day earlier for scale.
# .rollup(sum, 60) is mandatory here of all places: this is the figure gotcha 7 was written about.
# Unpinned, it reported under a third of the requests that actually failed.
pup metrics query \
  --query="sum:trace.http.request.hits{env:prod,service:<service>,resource_name:<resource>}.as_count().rollup(sum, 60)" \
  --from="<trigger_timestamp>" --to="<recovery_timestamp>" --output=json --no-agent --read-only

# failed requests only
pup logs aggregate --query='service:<service> env:prod status:error' \
  --from="<trigger_timestamp>" --to="<recovery_timestamp>" \
  --compute=count --output=json --no-agent --read-only

# how many distinct endpoints were touched
pup traces aggregate --query='service:<service>' --compute=count --group-by=resource_name \
  --from="<trigger_timestamp>" --to="<recovery_timestamp>" --output=json --no-agent --read-only
```

For a user-facing service, `pup rum sessions search` or `pup rum aggregate` converts request counts
into affected sessions. A latency alert with no error-rate movement often has a blast radius of
"slower for N requests, zero failures" - which is exactly the finding that keeps a ticket from being
filed.

## Useful extras

```bash
pup rum sessions search --query='...' --output=json --no-agent --read-only   # frontend/user-facing alerts
pup incidents list --output=json --no-agent --read-only          # is there already an incident open?
pup dashboards list --output=json --no-agent --read-only     # existing dashboards for the service
pup cicd pipelines list --output=json --no-agent --read-only     # CI-side correlation
pup metrics search --query='trace.' --output=json --no-agent --read-only     # find the right metric name
pup metrics tags list <metric> --output=json --no-agent --read-only          # available tag keys for a metric

# endpoint enumeration for a service (--service, --name, and --env are all required)
pup apm services operations --service <service> --env prod --output=json --no-agent --read-only
pup apm services resources --service <service> --name <operation> --env prod \
  --output=json --no-agent --read-only
```

## Datadog web links

Every metric, log query, trace, event, or dashboard cited in a report should carry a link to the
UI, placed inline where it is cited. Build all of them against the **org host from the monitor link
the user supplied** (for example `<org>.datadoghq.com`), never a hardcoded `app.datadoghq.com` -
a link to the wrong org 404s for the reader.

**Verified shapes** (taken from links that resolve in prior reports):

```
# Monitor
https://<org>.datadoghq.com/monitors/<monitor_id>

# Monitor scoped to a specific alert cycle, with the event selected
# This is the link the report's header block hangs its trigger/recovery timestamps on -- it is
# what makes the report open with the ALERT rather than only with the monitor. Required; see
# "Alert event" in report-template.md. monitor-timeline.sh emits it per event when given an org.
https://<org>.datadoghq.com/monitors/<monitor_id>?from_ts=<ms>&to_ts=<ms>&event_id=<evt_id>

# APM service page for an environment
https://<org>.datadoghq.com/apm/entity/service%3A<service-name>?env=prod
```

`from_ts`/`to_ts` are **milliseconds**, not seconds. Pad the alert window by ten minutes either
side so the reader can see the approach and the recovery.

The `event_id` comes from the alert event itself - `attributes.attributes.evt.id`, a numeric
string, which is the value shape that appears in working monitor links. The event's own top-level
`id` is a different, opaque base64 value; use `evt.id`. Verified 2026-08-26:

```bash
pup events search --query='@monitor_id:<monitor_id>' \
  --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" --output=json --no-agent --read-only \
| jq -r '.data[] | "\(.attributes.timestamp)\t\(.attributes.attributes.status)\t\(.attributes.attributes.evt.id)\t\(.attributes.attributes.duration)"'
```

The same event carries `duration` in **nanoseconds**, but read the pairing rules under check 3
before using it as a cycle length: it is populated on **recovery** rows (where it does measure the
episode just ended), is normally `null` on trigger rows, and when it *is* present on a non-OK row
that row is an escalation inside an already-open episode rather than a fresh trigger. In both
non-null cases it measures back to the episode start, which may precede every event row in the
response - so `recovery_ts - duration` is the reliable way to get the episode start, and
subtracting the two visible timestamps is not.

**Conventional shapes** (standard Datadog URL patterns; confirm one resolves before pasting a
report full of them):

```
# Log Explorer, scoped query and window
https://<org>.datadoghq.com/logs?query=<url-encoded query>&from_ts=<ms>&to_ts=<ms>&live=false

# APM trace/span search
https://<org>.datadoghq.com/apm/traces?query=<url-encoded query>&start=<ms>&end=<ms>

# Metric Explorer
https://<org>.datadoghq.com/metric/explorer?exp_metric=<metric>&exp_scope=<tag:value>&from_ts=<ms>&to_ts=<ms>&live=false
```

URL-encode the query: `:` stays readable in practice but spaces must become `%20`, and quotes in a
`resource_name:"..."` filter must be encoded.

For a dashboard, let `pup` build the link rather than hand-assembling it:

```bash
pup dashboards url <dashboard_id> --from="2026-08-26T12:00:00Z" --to="2026-08-26T14:00:00Z" \
  --live=false --no-agent --read-only
```

Its `--from`/`--to` take Datadog time expressions - the default is `now-1w` - **not** the
millisecond epochs the hand-assembled URLs above use.

Monitor notification emails and the event payload also reference `snapshot.datadoghq.com` PNG
snapshots of the graph at trigger and recovery time. When an event carries one, link it - a static
image of the moment the monitor fired survives even after the live window scrolls away.

## Querying the report directory

Every report carries a YAML frontmatter block (see `report-template.md`), which makes the report
directory queryable rather than merely readable. Two tiers, and the first is the one to rely on.

### Tier 1: grep, which always works

`grep` needs no tooling beyond what a shell already has, and it answers every *which reports*
question. **Verified 2026-08-26** against the three reports in the directory:

```bash
cd <report-directory>

# Reports covering a specific monitor - this is Step 1's prior-report check.
grep -l "monitors:.*123456789" triage-*.md   # 123456789 stands in for a real monitor ID

# Everything handed to another team; likewise for the other four action values.
grep -l "^action: HAND OFF" triage-*.md

# Everything that reached a customer.
grep -l "customer_visible: true" triage-*.md

# Has this monitor been written off as noise before?
grep -l "^classification: monitor noise" triage-*.md
```

Because `monitors:` is a flat array on one line, `monitors:.*<id>` matches whether the report
covers one monitor or six. Beware only the substring case: `123456789` would also match a
hypothetical `1123456789`, so anchor with a word boundary (`monitors:.*\b123456789\b`) if the org
ever has IDs where one is a suffix of another.

### Tier 2: yq, when it is installed

`grep` cannot aggregate, sort, or read a nested field, so it cannot answer *how much* or *which
was worst*. `yq` can. It is **optional** - nothing in this skill requires it, and every recipe
above works without it.

**Two different programs are called `yq`, and a recipe written for one fails confusingly on the
other:** mikefarah's Go implementation (v4, `-o=json`, its own expression language) and kislyuk's
Python wrapper around jq (`-r`, jq syntax). Rather than pick one, convert to JSON with `yq` and do
all the actual work in `jq` - which is already a hard dependency of every wrapper script in this
skill, so it is guaranteed present. That form works under either `yq`.

Check first, and fall back rather than failing:

```bash
command -v yq >/dev/null 2>&1 || echo "yq not installed - use the grep recipes above"
```

Extract one report's frontmatter (**verified 2026-08-26**; this half needs no `yq`):

```bash
# Print the frontmatter of a report: skip the opening ---, stop at the closing one.
awk 'NR==1{next} /^---$/{exit} {print}' triage-2026-08-26-<slug>.md
```

Then, with `yq` present. **Verification status, precisely:** the `awk` extraction above and every
`jq` filter below were run on 2026-08-26 against this directory's reports and return correct
answers (the `jq` filters were fed the equivalent JSON directly, since `yq` is not installed on
this machine). **The only untested link is the `yq -o=json` bridge in the middle.** Run one of
these against a single known report and eyeball the output before trusting a directory sweep:

```bash
# One report as JSON.
awk 'NR==1{next} /^---$/{exit} {print}' <file> | yq -o=json

# Rank every report by requests affected, worst first.
for f in triage-*.md; do
  awk 'NR==1{next} /^---$/{exit} {print}' "$f" \
  | yq -o=json \
  | jq -r --arg f "$f" '[.impact.requests_affected, .action, (.services[0]), $f] | @tsv'
done | sort -rn

# Total requests affected by customer-visible events in a month.
for f in triage-2026-08-*.md; do
  awk 'NR==1{next} /^---$/{exit} {print}' "$f" | yq -o=json
done | jq -s 'map(select(.impact.customer_visible)) | map(.impact.requests_affected) | add'

# Which monitors have been classified noise more than once.
for f in triage-*.md; do
  awk 'NR==1{next} /^---$/{exit} {print}' "$f" | yq -o=json
done | jq -s 'map(select(.classification | startswith("monitor noise")) | .monitors[])
              | group_by(.) | map(select(length > 1) | {monitor: .[0], reports: length})'
```

`jq -s` slurps the per-file objects into one array, which is what makes the aggregate forms work
over a whole directory.

A report written before the frontmatter existed has none, and `awk` yields an empty string for it
rather than an error - so a sweep silently under-counts. Compare the file count against the object
count when a total needs to be right:

```bash
ls triage-*.md | wc -l   # reports on disk
# ...versus the number of objects the sweep produced.
```

## Recording commands in the report

Every number in a report must trace to a command in its appendix. Record them with
`--no-agent --read-only`,
with the literal timestamps used (not relative windows), and grouped under the check they served.
If a command was tried and did not work, record that too with the reason - it saves the next
investigation from repeating it.
