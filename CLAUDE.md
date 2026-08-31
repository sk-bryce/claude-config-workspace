<!--
created: 2026-08-05
updated: 2026-08-31
-->
# Workspace Agent Configuration

Workspace-scoped guidance for `~/workspace`. This supplements the main Claude config's global
instructions (under `~/.claude` on this machine) rather than restating them. A Cursor-facing twin
of the Verifying Commands section lives in `~/workspace/.cursor/rules/verifying-commands.mdc`;
keep the two in step when either changes.

## Verifying Commands

- **Judge a command by its exit status and its output body, never by a summary line.** `$?` after
  `cmd | tail` reports the last stage of the pipe rather than `cmd`, and `PIPESTATUS` comes back
  empty in this workspace's zsh, so a failing command reads as success. Redirect output to a file,
  check `$?` on the unpiped command, then read the file.

- **A clean total can mean nothing ran.** When a linter or compiler hits a parse or type error it
  abandons the remaining checks for that unit, so "0 issues" can mean the unit was never analyzed.
  Read the output body, and confirm the run actually covered what you claim it covered before
  reporting a pass.

- **Separate your own findings from pre-existing ones with a baseline, not by eye.** Where a tool
  reports both, establish a baseline: a detached worktree at the base commit
  (`git worktree add .worktrees/<name> --detach <base>`, removed when finished), or a diff-scoped
  mode such as golangci-lint's `--new-from-rev`.

## Lint And Test Gates

- **Pick the lint target that answers the question being asked.** Where a repository offers both a
  whole-repo strict target and one scoped to lines changed since the merge-base with the default
  branch, the scoped one is the branch gate. The whole-repo strict target reports pre-existing
  findings by the hundred, so it cannot show whether a branch added anything.

- **Check whether a test target mutates the dependency manifest** as a side effect before reporting
  the working tree state; some can, which reads afterwards as an unexplained local change.

Check memory for an entry with the derived targets for this machine.

## Available CLI Tools

The following CLIs are installed and may be used to interact with external services:

- `acli` (Atlassian CLI): interact with Jira and Confluence.
- `gh` (Github CLI): interact with Github.
- `pup` (Datadog CLI): interact with Datadog.

Prefer these CLIs over manual or web-based workflows when a task involves Github, Jira, Confluence,
or Datadog.

## Repository Maintenance

Applies only when the working directory is this repo's own checkout (`~/workspace/.claude`) - not
to the rest of `~/workspace`, which this file also covers.

- **This repository targets a public remote.** Never write a client, employer, personal, or
  machine-specific identifier into a tracked file: no home-directory paths, usernames, hostnames,
  email addresses, session UUIDs, or credentials. The full policy - the categories, the neutral
  substitutes to reach for instead, and where a real value goes when one is genuinely needed - is
  the main Claude config's `reference/public-repo-hygiene.md` (under `~/.claude` on this machine;
  that repository is not published, so the pointer resolves here and nowhere else). That document
  describes its own repository; this repository has opted into the same stance and borrows its
  detector, so the policy is pointed at rather than restated, and keeping that opt-in current is
  this repo's job, not that one's. The mechanically recognizable half runs at commit time (see the
  README's Setup after cloning); it catches shapes, never a name, so the judgment half stays yours
  at review time.
