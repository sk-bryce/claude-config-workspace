<!--
created: 2026-07-16
updated: 2026-08-31
-->
# Workspace AI agents config

Personal Claude Code config for this workspace. Lives at `~/workspace/.claude`.

This repo follows the same **spec-anchored architecture** as the main Claude config it supplements
(a separate repository, not published, `~/.claude` on this machine): intent lives in `specs/`, and
the generated artifact - the actual skill Claude Code loads - lives in `skills/`, committed
separately, so a change of intent is made in the spec and the artifact regenerated from it rather
than hand-edited. This repo currently uses the minimal two-layer slice of that pattern (`specs/` +
generated artifact) rather than the full four-layer version (`decisions/`, `reference/`,
`evals/`) - that heavier machinery isn't needed yet at this repo's current scale of a handful
of skills.

Pointers to that main config appear in this README and in `CLAUDE.md`, always as `~/.claude`. They
describe this machine's own setup and resolve to nothing in a fresh clone. Nothing here needs them
in order to be read, copied, or run: the skills in `skills/` are self-contained, and the one
section that genuinely depends on that repo (`Setup after cloning`) says so and can be skipped.

## What is reusable

Not all of this travels, so three tiers:

- **Works on clone.** `fetch-pr` needs only `gh` and `jq`. `specs/skills.md` and
  `skills/triage-datadog/references/` read on their own as craft material - the report skeleton and
  the `pup` gotchas do not depend on whose org they were learned in.
- **Works once configured.** `pr-review-md` needs the report-directory memory key below and the
  native `review` skill it wraps. `triage-datadog` needs a Datadog org, authenticated `pup`, its
  two environment memory keys, and - for the release-correlation check to mean anything - a deploy
  pipeline that is actually GitOps-shaped.
- **Specific to this machine.** `CLAUDE.md`. Its Verifying Commands section is general advice, but
  Lint And Test Gates assumes a monorepo whose target names live in agent memory, the CLI list is
  what happens to be installed here, the Cursor twin it points at lives outside this repo, and the
  default report paths sit under `~/workspace`. Read it as a worked example rather than dropping it
  into another workspace as-is.

## Prerequisites

The skills shell out to CLIs rather than bundling their own clients, so a clone needs these on
`PATH`:

- `gh` (GitHub CLI), authenticated - used by `fetch-pr` and `pr-review-md`, and by
  `triage-datadog`'s deploy-pipeline check.
- `jq` - the formatting and filtering pipeline in every bundled script.
- `pup` (Datadog API CLI, `datadog-labs/pup`) - `triage-datadog` only. Its recipes and wrapper
  scripts were verified against `pup` 1.6.4, and later releases have not been re-verified: treat a
  flag or response-shape mismatch on a newer build as a recipe to re-check rather than as a bug in
  the skill.
- `python3` - `triage-datadog` only, for reproducible UTC date arithmetic in `blast-radius.sh`,
  `seasonality-check.sh`, and `deploy-pipeline-check.sh`. Each checks for it and fails with a
  named error rather than silently shifting a window, since BSD and GNU `date(1)` disagree on how
  they parse RFC3339.
- `yq` is optional. It adds only the aggregate queries over a directory of triage reports (rank by
  impact, total a month); every *which reports* question is answerable with `grep` alone, and the
  recipes fall back to that tier rather than failing when `yq` is absent.

## Layout

- `CLAUDE.md` - workspace-scoped agent guidance: how to verify a command actually passed, and a
  `Lint And Test Gates` section on picking a lint target that shows what a branch changed rather
  than what was already broken, plus the reminder that some test targets mutate the dependency
  manifest. The concrete target names live in agent memory rather than here, so this file stays
  shareable. Supplements the main Claude config's global instructions rather than restating them.
  Also names the CLIs installed on this machine that agents should prefer over web workflows, and
  carries a `Repository Maintenance` section scoped to this checkout alone - this repo's opt-in to
  the same public-remote hygiene stance the main config takes, pointing at that repo's public-repo
  hygiene policy rather than restating it, with the commit-time half described under Setup after
  cloning below. Its Verifying Commands section has a Cursor-facing twin at
  `~/workspace/.cursor/rules/verifying-commands.mdc` (outside this repo, since Cursor reads
  workspace rules from `.cursor/rules/`, not `.claude/`); keep the two in step.
- `specs/skills.md` - per-skill intent and acceptance criteria; the source a regeneration reads.
- `skills/` - generated skills:
  - `fetch-pr` - fetches and formats GitHub PR data (metadata including draft status, CI/check
    status, review decision, general and inline comments, optionally the diff) via the `gh` CLI,
    so PR-review work gets one clean summary instead of re-deriving raw `gh` calls each time.
    Fetch/format only - no review judgment, no posting back to GitHub. See `specs/skills.md`'s
    `fetch-pr` section for intent and `skills/fetch-pr/SKILL.md` for the generated artifact.
  - `pr-review-md` - wraps the native `review` skill so a PR review lands as a persisted,
    consistently formatted Markdown report in a directory read from agent memory key
    `pr-review-docs-location`, prompting once if unset
    (Impact/Confidence-rated findings, sorted, each with a copy-paste-ready PR comment written
    respectfully and from a perspective of curiosity rather than judgment, a Summary with PR
    state, and a rule-derived Recommendation) instead of transient chat output. Also asks
    `review` to judge documentation substance when a PR touches docs, and to skip
    restating feedback already posted on the PR. Fires only when a filing/logging qualifier is
    present ("review PR #N and log/doc/file it") - a bare "review PR #N" still goes to the
    native `review` skill. Delegates all code judgment to `review`; never posts to GitHub. See
    `specs/skills.md`'s `pr-review-md` section for intent and `skills/pr-review-md/SKILL.md` for
    the generated artifact.
  - `triage-datadog` - investigates one or more Datadog monitors to a defensible root cause via
    the `pup` CLI and files a structured Markdown report per root cause. Accepts monitor links/IDs
    or an ambiguous scoped framing ("alerts for my team over the last 12 hours"), groups related
    alerts into one report and unrelated ones into separate cross-linked reports, and runs a fixed
    check set of fourteen checks - all mandatory unless a high-confidence evidence-depth gate
    explicitly releases seven of them - among them the 90-day trigger history, deploy and
    config change correlation, upstream/downstream dependencies, and whether the monitor's recovery
    can be trusted. Falls back to a ranked candidate-cause list rather than "cause unknown", links
    the Datadog UI inline at each point of reference (the alert event, not only the monitor), and
    proofreads the report before hand-off. Each report is layered so that a reader who stops at any
    depth has not been misled - YAML frontmatter that makes the directory queryable with `grep`
    alone, a BLUF with a closed five-value action vocabulary, a plain-text paste block for Slack
    and Jira, a summary that argues in named blocks, then the teaching evidence sections and the
    raw appendices - and is written incrementally as the checks return, so an interrupted
    investigation still leaves a usable artifact. Report directory and every environment-specific
    value (org host, team scope tags, service and metric names, monitor IDs, deploy repo and
    workflow names) come from agent memory rather than the repo, so a missing entry makes it ask
    instead of guess; report files are named `triage-YYYY-MM-DD-<slug>.md`. Read-only against
    Datadog - no ack, mute, resolve, ticket, or Slack post, with `--read-only` on every `pup` call
    so a write is blocked at the CLI layer. See `specs/skills.md`'s `triage-datadog` section for
    intent, `skills/triage-datadog/SKILL.md` for the generated artifact, and its `references/` for
    the `pup` recipes, the eight executable wrapper scripts that cover the ten fixed-shape checks
    (alongside a sourced `_common.sh`, which is not a wrapper and covers no check), and the report
    skeleton.
- `settings.local.json` - local Claude Code permissions for this workspace (untracked - personal
  to this machine, not committed).

## Agent memory keys

Nothing environment-specific is committed here - report directories, org host, team scope tags,
service and metric names, deploy topology, and the JIRA project prefix all come from agent memory,
so a missing entry makes a skill ask rather than guess. A fresh clone therefore starts with none of
them, and each is written on first use. What they hold:

- `pr-review-docs-location` (`pr-review-md`) - the directory PR review reports are written to.
  Prompted for on first use, before the expensive half of the run.
- `triage-report-directory` (`triage-datadog`) - the directory triage reports are written to.
  Inferred when the recommended default already holds prior reports, prompted for otherwise.
- `datadog-triage-environment` (`triage-datadog`) - Datadog org host, team scope tags, service
  names, and APM metric names.
- `deploy-pipeline-topology` (`triage-datadog`) - deploy repo, GitOps repo and environment branch,
  deploy workflow and mapping-file names, and the service ref prefix.
- `jira-ticket-prefix` (`pr-review-md`) - the team's JIRA project prefix, used when a PR title
  carries a ticket ID.

The five above are named by the skills that read them, so those spellings matter. `CLAUDE.md`'s
Lint And Test Gates section expects one more - an entry holding this machine's lint and test target
names - but deliberately names no key for it, so any spelling your own memory index uses is fine.

Memory is scoped per project directory in Claude Code, so the first run from a new project root
asks again even on a machine where the same key was already answered elsewhere.

## Setup after cloning

**This section is the maintainer's own setup and depends on a repository that is not published.**
A clone can skip all of it: nothing in `skills/`, `specs/`, or `CLAUDE.md` calls into any of it,
and the commit gate it describes is a safeguard on how this repo is maintained rather than a step
in using what it holds. Bring your own gate, or none.

This repository targets a public remote, so no committed file may carry a client, employer,
personal, or machine-specific identifier. The gate that enforces that lives entirely in the main
Claude config repo (`~/.claude` on this machine) - the detector (`scripts/scrub-check.sh`), the
policy it enforces (`reference/public-repo-hygiene.md`), its decision record (`decisions/0009`),
and two gitignored machine-local files it reads from its own checkout: `scrub-patterns.local`,
the client and engagement tokens it matches against, and `scrub-test.local`, the fixture lines
whose continued matching the self-test proves. This repository holds no copy of any of it, because
a second copy drifts the first time one is fixed and the other is not - and drifts silently, since
a scrub check that has stopped matching still exits 0.

What a clone does need is the registration, since `.git/hooks` is never tracked by git. Create it
by hand - deliberately a human step, not something a script or an agent does for you:

```sh
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
exec "$HOME/.claude/scripts/pre-commit-check.sh" --repo "$(git rev-parse --show-toplevel)"
HOOK
chmod +x .git/hooks/pre-commit
```

If your config checkout is somewhere other than `~/.claude`, use that path. Don't resolve it
through `CLAUDE_CONFIG_DIR`: that names whichever profile Claude Code is running under, which is
often a replicated copy carrying a `scripts/` directory that lags its source.

That is the same line the main config repo installs for itself, so there is one shape to keep right
rather than two, and `--repo` is a stable interface on that side rather than an internal detail.

It scans the staged content for leaks, self-tests the detector's own patterns so one that has
silently stopped matching gets caught, and validates `settings.json` as JSON if this repository has
one. It does not run that repo's projection check: the gate may inspect a borrowed repository but
never execute anything out of one, and running that check would execute whatever sat at
`scripts/sync.sh` here.

Failures are loud, and the gate fails closed rather than open. A finding blocks the commit with
`path:line`. So does a main config repo that has moved, since the hook cannot exec a script that
is not there - and so does one still in place whose detector is missing or not executable, which
the gate reports as "no gate ran" rather than treating it as nothing to check. Either
machine-local file being absent behaves the same way: the scan and the self-test each refuse to
run (exit 2) rather than vouch for a tree they could not actually check, so commits here stay
blocked until that repo's own setup is whole. `~/.claude/scripts/setup.sh --check` names which
piece is missing.

What is silent is a hook that was never installed: there is no gate then, and nothing here will say
so. That is the cost of keeping the mechanism in one place. To audit the whole tracked tree at any
time:

```sh
~/.claude/scripts/scrub-check.sh --repo .
```

## License

MIT - see `LICENSE`.
