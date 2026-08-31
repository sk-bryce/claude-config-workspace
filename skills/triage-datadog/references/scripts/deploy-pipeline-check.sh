#!/usr/bin/env bash
# Check 9: release verification (change-stories plus the GitHub-side pipeline checks). See references/pup-recipes.md's "Wrapper scripts" section.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-pipeline-check.sh \
  --service <name> --env <env> --from <ts> --to <ts> \
  --org <org> --monorepo <repo> --gitops-repo <repo> \
  --env-branch <branch> --service-path <path> --deploy-workflow <name>

All ten named flags below are required; --lookback and --deploy-ref-prefix are optional.
Each accepts either "--flag value" or "--flag=value". Order does not matter. Named flags are deliberate: the
previous positional form made it possible to transpose --monorepo with
--gitops-repo, or --env-branch with --service-path, and get a plausible
wrong answer instead of an error.

  --service          Datadog/APM service name
  --env              deployment environment (e.g. prod)
  --from, --to       the INCIDENT window: Z-suffixed UTC RFC3339 bounds taken
                     from check 2's trigger and recovery timestamps, padded a
                     few minutes either side. Not a relative window, and not
                     "today" -- every step below is scoped from these, so a
                     wrong window here silently correlates the wrong deploys.
                     Rejected with exit 1 if not RFC3339.
  --org              GitHub org
  --monorepo         repo holding the service source and its Deployment records
  --gitops-repo      repo whose environment branch drives the cluster
  --env-branch       branch in --gitops-repo that the cluster tracks
  --service-path     path within --gitops-repo whose commits deploy this service
  --deploy-workflow  workflow file basename, without the .yaml extension

Optional:

  --lookback           how far BEFORE --from to search for a deploy, as <N>d or
                       <N>h. Default 7d. A deploy does not have to land inside
                       the incident window to have caused the incident -- a bad
                       release ships at 09:00 and the monitor fires at 14:00 --
                       so the correlation window is [--from minus --lookback,
                       --to] while the incident window stays [--from, --to].
                       Every record below is tagged with which of the two it
                       falls in, so "shipped during the incident" and "shipped
                       five hours earlier" never read the same. Narrow it to a
                       few hours for a service that deploys constantly; widen
                       it when the last deploy is older than a week and you
                       need to name what IS running.
  --deploy-ref-prefix  the prefix this service's Deployment refs and workflow
                       run titles use (e.g. "<prefix>" for a record like
                       "<prefix>/v0.1.125"). Deployment records
                       are looked up by --env, NOT by --service, so without
                       this the step-7 ownership check can only tell you to
                       confirm by eye. Where the pipeline maps a service to an
                       image via a manifest, the prefix is typically that image
                       name; the mapping for the environment under investigation
                       is in agent memory under deploy-pipeline-topology.

Check 9: a GitHub Deployment record, a green deploy workflow
run, or a merged PR does NOT mean the code is running -- the cluster only
changes when --gitops-repo's --env-branch changes, and a Deployment can also
sit "pending" behind an environment protection rule that requires manual
approval. Runs, in order:
Every step except 8 is scoped to the correlation window described under
--lookback; step 8 reports current state, which has no window. Runs, in order:
  1. pup change-stories               -- did Datadog see a deploy/config/k8s event at all
  2. GitHub Deployment records        -- for --env, written on workflow success (intent, not fact)
  3. Deployment statuses per record   -- success/failure/pending/in_progress, and environment_url
  4. deploy workflow run history      -- what the workflow actually ran
  5. workflow run job-level detail    -- catches a green run whose deploy job itself failed/skipped
  6. GitOps env-branch commits        -- what actually changed the running manifest
  7. correspondence check             -- did the newest in-window Deployment record actually reach
                                          the env branch? Judged by time ordering, NOT by comparing
                                          SHAs: the two SHAs are from different repos and never
                                          match
  8. open, unmerged deploy PRs        -- these have NOT reached the cluster (not windowed)

An empty step 2 or step 6 is a FINDING, not a failure: nothing shipped in the
correlation window, so a release did not cause this. Say which window was
searched when reporting it -- "no deploy in the 7 days before the incident" and
"no deploy today" are very different claims.

The --org/--monorepo/--gitops-repo/--env-branch/--deploy-workflow/--service-path
values come from agent memory under deploy-pipeline-topology -- ask the user if
that entry is missing or does not cover this service, rather than guessing.

All timestamps from every step are UTC (GitHub's API returns ISO 8601 UTC
`Z`-suffixed timestamps; do not convert them). State that explicitly in the
report rather than relying on the `Z` suffix alone to carry it.
EOF
}

# usage() prints to stdout and does not exit, so `--help` is a success: `script --help | less`
# works and CI does not read it as a failure. Argument errors go through die_usage, which keeps
# the exit 1 documented in pup-recipes.md's wrapper exit-code table.
die_usage() { usage >&2; exit 1; }

service=""; env=""; from=""; to=""; org=""
monorepo=""; gitops_repo=""; env_branch=""; service_path=""; deploy_workflow=""
deploy_ref_prefix=""   # optional
lookback="7d"          # optional; see --help

while [[ $# -gt 0 ]]; do
  arg=$1
  val=""
  has_eq=0
  case "$arg" in
    --*=*) val=${arg#*=}; arg=${arg%%=*}; has_eq=1 ;;
  esac

  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --service|--env|--from|--to|--org|--monorepo|--gitops-repo|--env-branch|--service-path|--deploy-workflow|--deploy-ref-prefix|--lookback)
      if [[ $has_eq -eq 0 ]]; then
        [[ $# -ge 2 ]] || { echo "ERROR: $arg requires a value." >&2; die_usage; }
        val=$2
        shift
      fi
      [[ -n "$val" ]] || { echo "ERROR: $arg requires a non-empty value." >&2; die_usage; }
      ;;
    -*)
      echo "ERROR: unknown flag '$arg'." >&2
      die_usage
      ;;
    *)
      echo "ERROR: unexpected positional argument '$arg'. This script takes named flags only;" >&2
      echo "the previous ten-argument positional form is no longer accepted. See --help." >&2
      die_usage
      ;;
  esac

  case "$arg" in
    --service)         service=$val ;;
    --env)             env=$val ;;
    --from)            from=$val ;;
    --to)              to=$val ;;
    --org)             org=$val ;;
    --monorepo)        monorepo=$val ;;
    --gitops-repo)     gitops_repo=$val ;;
    --env-branch)      env_branch=$val ;;
    --service-path)    service_path=$val ;;
    --deploy-workflow) deploy_workflow=$val ;;
    --deploy-ref-prefix) deploy_ref_prefix=$val ;;
    --lookback)        lookback=$val ;;
  esac
  shift
done

# Collected as a string rather than an array: bash 3.2 (the macOS default, and what
# `#!/usr/bin/env bash` resolves to here) treats "${arr[@]}" on an empty array as an
# unbound variable under `set -u`.
missing=""
[[ -n "$service"         ]] || missing="$missing --service"
[[ -n "$env"             ]] || missing="$missing --env"
[[ -n "$from"            ]] || missing="$missing --from"
[[ -n "$to"              ]] || missing="$missing --to"
[[ -n "$org"             ]] || missing="$missing --org"
[[ -n "$monorepo"        ]] || missing="$missing --monorepo"
[[ -n "$gitops_repo"     ]] || missing="$missing --gitops-repo"
[[ -n "$env_branch"      ]] || missing="$missing --env-branch"
[[ -n "$service_path"    ]] || missing="$missing --service-path"
[[ -n "$deploy_workflow" ]] || missing="$missing --deploy-workflow"

if [[ -n "$missing" ]]; then
  echo "ERROR: missing required flag(s):$missing" >&2
  die_usage
fi

# --from/--to are now load-bearing arithmetic, not just two strings forwarded to one query, so a
# malformed one is rejected here rather than producing a silently wrong correlation window.
for ts_label in "from:$from" "to:$to"; do
  ts_name=${ts_label%%:*}
  ts_value=${ts_label#*:}
  if [[ ! "$ts_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "ERROR: --$ts_name must be a Z-suffixed UTC RFC3339 timestamp (e.g. 2026-08-26T08:17:26Z)," >&2
    echo "not '$ts_value'. Take it from check 2's alert timeline: --from is the trigger and --to the" >&2
    echo "recovery. A relative window ('24h') cannot be reproduced from a report appendix." >&2
    exit 1
  fi
done

if [[ ! "$lookback" =~ ^[0-9]+[dh]$ ]]; then
  echo "ERROR: --lookback must be <N>d or <N>h (e.g. 7d, 12h), not '$lookback'." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to derive the correlation window from --from and --lookback," >&2
  echo "and was not found. Compute (--from minus --lookback) by hand and pass it as --from with" >&2
  echo "--lookback 0h, accepting that the in-window/pre-window tagging below then reads everything" >&2
  echo "as pre-window." >&2
  exit 2
fi

# Correlation window start: the incident start, moved back by --lookback. Kept separate from the
# incident window rather than replacing it, because "shipped while it was broken" and "shipped
# hours before it broke" support different conclusions and must not collapse into one range.
correlation_from=$(python3 -c "
import re, sys
from datetime import datetime, timedelta
ts, lb = sys.argv[1], sys.argv[2]
n, unit = int(lb[:-1]), lb[-1]
delta = timedelta(days=n) if unit == 'd' else timedelta(hours=n)
print((datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ') - delta).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$from" "$lookback")
correlation_to=$to

echo "Resolved arguments: service=$service env=$env org=$org monorepo=$monorepo gitops_repo=$gitops_repo env_branch=$env_branch service_path=$service_path deploy_workflow=$deploy_workflow deploy_ref_prefix=${deploy_ref_prefix:-<unset>}" >&2
echo "Incident window:    $from..$to (UTC) -- from check 2's alert timeline" >&2
echo "Correlation window: $correlation_from..$correlation_to (UTC) -- incident window widened back by --lookback $lookback" >&2
echo "(All timestamps below are UTC. Records are tagged IN-INCIDENT or PRE-INCIDENT against the two windows above.)" >&2

echo "== 1. Datadog change-stories for $service ($env), $from..$to (UTC) ==" >&2
change_stories_raw=$(pup change-stories list --service "$service" --env "$env" \
  --from="$from" --to="$to" --output=json --no-agent --read-only)

if ! echo "$change_stories_raw" | jq -e 'has("stories")' >/dev/null 2>&1; then
  echo "ERROR: pup change-stories list did not return the expected {stories:[...]} envelope." >&2
  echo "$change_stories_raw" >&2
  exit 2
fi
echo "$change_stories_raw" | jq .

echo "== 2. GitHub Deployment records for $env ($org/$monorepo), $correlation_from..$correlation_to ==" >&2
# The deployments endpoint takes no time parameters -- environment, ref, sha and task only -- so
# the window has to be applied client-side. per_page is 100 rather than 15 for exactly that reason:
# a 15-record page can be entirely newer than the correlation window on a service that deploys
# often, which would read as "nothing shipped" when the truth is "the page never reached back that
# far". The page-exhaustion warning below is what keeps that failure visible.
deployments_all=$(gh api "repos/${org}/${monorepo}/deployments?environment=${env}&per_page=100")
fetched=$(echo "$deployments_all" | jq 'length')
if [[ "$fetched" -eq 100 ]]; then
  oldest_fetched=$(echo "$deployments_all" | jq -r 'sort_by(.created_at) | first | .created_at // "unknown"')
  if [[ "$oldest_fetched" > "$correlation_from" ]]; then
    echo "WARNING: fetched the full 100-record page and its OLDEST record ($oldest_fetched) is still" >&2
    echo "newer than the correlation window start ($correlation_from). The window is not fully" >&2
    echo "covered -- paginate with --paginate, or narrow --lookback -- and do not report an empty or" >&2
    echo "short result as 'nothing shipped'." >&2
  fi
fi

# Tag rather than merely filter: a record just outside the window is often the one that explains
# the incident, and dropping it silently is how "no deploy correlates" gets written down wrongly.
deployments_raw=$(echo "$deployments_all" | jq \
  --arg cf "$correlation_from" --arg ct "$correlation_to" --arg f "$from" --arg t "$to" '
  map(select(.created_at >= $cf and .created_at <= $ct))
  | map({id, created_at, ref, sha, description,
         window: (if .created_at >= $f and .created_at <= $t then "IN-INCIDENT" else "PRE-INCIDENT" end)})
')
in_window=$(echo "$deployments_raw" | jq 'length')
in_incident=$(echo "$deployments_raw" | jq '[.[] | select(.window == "IN-INCIDENT")] | length')
echo "$fetched records fetched, $in_window inside the correlation window, of which $in_incident landed during the incident itself." >&2
if [[ "$in_window" -eq 0 ]]; then
  echo "FINDING (not an error): no Deployment record for $env in $correlation_from..$correlation_to." >&2
  echo "Report it as 'nothing shipped in the N-day window before the incident', naming the window." >&2
fi
echo "$deployments_raw" | jq '.[]'

echo "== 3. Deployment statuses (success/failure/pending/in_progress; a Deployment record alone is intent, not fact) ==" >&2
deployment_ids=$(echo "$deployments_raw" | jq -r '.[].id')
if [[ -z "$deployment_ids" ]]; then
  echo "No Deployment records inside the correlation window, so there are no statuses to check." >&2
else
  while IFS= read -r dep_id; do
    echo "-- deployment $dep_id --" >&2
    gh api "repos/${org}/${monorepo}/deployments/${dep_id}/statuses" \
      --jq '.[] | {created_at, state, environment_url, description}'
  done <<< "$deployment_ids"
fi

echo "== 4. Deploy workflow run history: $deploy_workflow, $correlation_from..$correlation_to ==" >&2
# gh filters this one server-side. The date-only range is deliberately wider than the correlation
# window (gh --created takes dates, not timestamps); the jq pass below narrows it back to the exact
# bounds and tags each run, so the loose server-side filter never reaches the report.
runs_raw=$(gh run list --repo "${org}/${monorepo}" --workflow="${deploy_workflow}.yaml" --limit 100 \
  --created "${correlation_from%T*}..${correlation_to%T*}" \
  --json databaseId,displayTitle,status,conclusion,createdAt,event \
  | jq --arg cf "$correlation_from" --arg ct "$correlation_to" --arg f "$from" --arg t "$to" '
    map(select(.createdAt >= $cf and .createdAt <= $ct))
    | map(. + {window: (if .createdAt >= $f and .createdAt <= $t then "IN-INCIDENT" else "PRE-INCIDENT" end)})
  ')
if [[ "$(echo "$runs_raw" | jq 'length')" -eq 0 ]]; then
  echo "FINDING (not an error): the deploy workflow did not run in the correlation window." >&2
fi
echo "$runs_raw" | jq .

echo "== 5. Job-level detail for the most recent run (catches a green run whose deploy job itself failed or was skipped) ==" >&2
latest_run_id=$(echo "$runs_raw" | jq -r 'sort_by(.createdAt) | last | .databaseId // empty')
if [[ -z "$latest_run_id" ]]; then
  echo "No workflow runs inside the correlation window -- nothing to inspect at job level." >&2
else
  gh api "repos/${org}/${monorepo}/actions/runs/${latest_run_id}/jobs" \
    --jq '.jobs[] | {name, status, conclusion, started_at, completed_at}'
fi

echo "== 6. GitOps commits touching $service_path on $env_branch, $correlation_from..$correlation_to (what actually changed the running manifest) ==" >&2
# This endpoint does take since/until, so the window is applied server-side and no client-side
# filter is needed. per_page stays high so a busy path cannot truncate inside the window.
gitops_commits_raw=$(gh api "repos/${org}/${gitops_repo}/commits?sha=${env_branch}&path=${service_path}&since=${correlation_from}&until=${correlation_to}&per_page=100")
gitops_count=$(echo "$gitops_commits_raw" | jq 'length')
if [[ "$gitops_count" -eq 0 ]]; then
  echo "FINDING (not an error): nothing changed $service_path on $env_branch in the correlation" >&2
  echo "window, so the running manifest is unchanged across it -- whatever is deployed predates" >&2
  echo "$correlation_from. To name the running version, re-run with a wider --lookback." >&2
fi
echo "$gitops_commits_raw" | jq --arg f "$from" --arg t "$to" '.[] | {sha, date: .commit.committer.date,
  window: (if .commit.committer.date >= $f and .commit.committer.date <= $t then "IN-INCIDENT" else "PRE-INCIDENT" end),
  msg: (.commit.message | split("\n")[0])}'

echo "== 7. Correspondence check: did the newest in-window Deployment record actually reach $env_branch? ==" >&2
# Deliberately NOT an exact-SHA comparison. An earlier version of this script compared the newest
# Deployment record's sha against the newest GitOps commit's sha -- but those are commits in two
# DIFFERENT repositories ($monorepo and $gitops_repo), so they can never be equal and the check
# reported MISMATCH unconditionally, with alarming wording, on every healthy pipeline. There is no
# shared identifier between the two repos to compare, so correspondence has to be established by
# time ordering: a Deployment record that reached the cluster is followed within minutes by a
# commit to the environment branch's service path. A Deployment with NO such following commit is
# the real failure mode this step exists to catch.
# Both sets are already scoped to the correlation window by steps 2 and 6, so "newest" here means
# newest IN THE WINDOW. An all-time newest pair would always correspond -- a healthy deploy from
# three weeks ago says nothing about this incident, and letting it answer step 7 is what made the
# old version of this check unable to distinguish "shipped and reached the cluster" from
# "irrelevant to the window we are investigating".
newest_deployment=$(echo "$deployments_raw" | jq -c 'sort_by(.created_at) | last // empty')
newest_gitops=$(echo "$gitops_commits_raw" | jq -c 'sort_by(.commit.committer.date) | last // empty')

if [[ -z "$newest_deployment" && -z "$newest_gitops" ]]; then
  echo "Nothing to cross-check: neither a Deployment record nor a GitOps commit exists in" >&2
  echo "$correlation_from..$correlation_to. That is a finding, and a clean one -- no release" >&2
  echo "correlates with this incident within --lookback $lookback of it. Say which window was" >&2
  echo "searched, since the same sentence over a 1-hour window would mean almost nothing." >&2
elif [[ -z "$newest_deployment" ]]; then
  echo "A GitOps commit changed $service_path in the window but NO Deployment record accompanies it." >&2
  echo "The manifest moved without the deploy pipeline recording it -- a hand-applied or" >&2
  echo "out-of-band change. This is the more interesting direction of the two; chase it." >&2
elif [[ -z "$newest_gitops" ]]; then
  echo "A Deployment record exists in the window but NOTHING changed $service_path on $env_branch." >&2
  echo "The Deployment did not reach the cluster: it is intent, not fact. Check step 3 for a pending" >&2
  echo "environment-protection approval and step 8 for an open, unmerged GitOps PR." >&2
else
  jq -n \
    --argjson dep "$newest_deployment" \
    --argjson git "$newest_gitops" \
    --arg env_branch "$env_branch" \
    --arg service_path "$service_path" \
    --arg monorepo "$monorepo" \
    --arg gitops_repo "$gitops_repo" \
    --arg incident_from "$from" \
    --arg incident_to "$to" \
    --arg correlation_from "$correlation_from" \
    --argjson tolerance_seconds 3600 \
    '
    ($dep.created_at | fromdateiso8601) as $dep_t
    | ($git.commit.committer.date | fromdateiso8601) as $git_t
    | ($git_t - $dep_t) as $lag
    | {
        newest_deployment: {repo: $monorepo, sha: $dep.sha, ref: $dep.ref, created_at: $dep.created_at,
                            window: $dep.window, description: $dep.description},
        newest_gitops_commit: {repo: $gitops_repo, branch: $env_branch, path: $service_path,
                               sha: $git.sha, date: $git.commit.committer.date,
                               window: (if $git.commit.committer.date >= $incident_from
                                        and $git.commit.committer.date <= $incident_to
                                        then "IN-INCIDENT" else "PRE-INCIDENT" end),
                               msg: ($git.commit.message | split("\n")[0])},
        windows: {incident: "\($incident_from)..\($incident_to)",
                  correlation: "\($correlation_from)..\($incident_to)"},
        note: "SHAs are from different repositories and are not comparable. Correspondence is judged by time ordering.",
        gitops_commit_lag_seconds: $lag,
        verdict: (
          # The tolerance band is SYMMETRIC on purpose. Which of the two events lands first is a
          # property of the pipeline, not a health signal: where the workflow pushes the manifest
          # first and writes the record on success, the GitOps commit PRECEDES the Deployment
          # record by a few seconds, so an "env branch must change AFTER the Deployment" rule
          # reports NOT SHIPPED on a perfectly healthy deploy. What matters is whether the two
          # are close enough in time to be the same deploy.
          if (($lag | fabs) <= $tolerance_seconds) then
            "CORRESPONDS -- the env branch and this Deployment record are \($lag | fabs)s apart, so they are the same deploy and it reached the cluster. (Sign is not meaningful: either order is normal.)"
          elif ($lag > $tolerance_seconds) then
            "LATER COMMIT -- the newest env-branch commit is \($lag)s AFTER the newest Deployment record. The env branch was changed by something later than this record, so this record is not the most recent thing to ship. Read step 6 and step 4 together to identify what did."
          else
            "NOT SHIPPED -- the newest env-branch commit PREDATES the newest Deployment record by \(-$lag)s, far outside the \($tolerance_seconds)s tolerance. The Deployment did not change what is running. Check step 3 for a pending environment-protection approval and step 8 for an open, unmerged GitOps PR. Also re-read the ownership line below: if these records belong to another service, this verdict is meaningless."
          end
        )
      }
    '
  # Whose Deployment records are these? They are looked up by --env, not by --service, so in a
  # monorepo whose services share an environment name this step can silently return a DIFFERENT
  # service's history. The failure mode: a service queried with its own --service name and a
  # shared --env comes back with refs and descriptions belonging to a DIFFERENT service that
  # shares that environment, with no indication anything is wrong.
  #
  # There is no reliable way to derive the deploy ref prefix from a Datadog service name -- the
  # mapping is generally neither the identity nor a common truncation, and the pairs for the
  # environment under investigation are in agent memory under deploy-pipeline-topology, not
  # here -- so this is not guessed.
  # Pass --deploy-ref-prefix to have it checked; otherwise confirm by eye.
  dep_ref=$(echo "$newest_deployment" | jq -r '.ref // ""')
  dep_desc=$(echo "$newest_deployment" | jq -r '.description // ""')
  echo "" >&2
  if [[ -n "$deploy_ref_prefix" ]]; then
    if [[ "$dep_ref" == "$deploy_ref_prefix"* || "$dep_desc" == "$deploy_ref_prefix"* ]]; then
      echo "Deployment record ownership OK: ref '$dep_ref' matches --deploy-ref-prefix '$deploy_ref_prefix'." >&2
    else
      echo "WARNING: the newest Deployment record's ref ('$dep_ref') and description ('$dep_desc')" >&2
      echo "do not start with --deploy-ref-prefix '$deploy_ref_prefix'. Deployment records are looked" >&2
      echo "up by --env, not --service, so this is very likely ANOTHER service's history sharing the" >&2
      echo "'$env' environment. Do not quote these records for $service. Establish its deploy history" >&2
      echo "from step 4's workflow run titles and step 6's GitOps commits instead, and say so in the" >&2
      echo "report." >&2
    fi
  else
    echo "CONFIRM BY EYE: the newest Deployment record is ref '$dep_ref', description '$dep_desc'." >&2
    echo "These records were selected by --env '$env', NOT by --service '$service'. If that ref does" >&2
    echo "not name $service, you are looking at another service's deploy history -- steps 2, 3 and 7" >&2
    echo "are then all about the wrong service. Pass --deploy-ref-prefix <prefix> to have this" >&2
    echo "checked instead of eyeballed (the prefixes for this environment are in agent memory" >&2
    echo "under deploy-pipeline-topology, typically the image name in the deploy manifest)." >&2
  fi
fi

echo "== 8. Open, unmerged deploy PRs against $gitops_repo (NOT yet shipped) ==" >&2
gh pr list --repo "${org}/${gitops_repo}" --state open --limit 10
