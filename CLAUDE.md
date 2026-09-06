# CLAUDE.md — DiscVault Launcher

Instructions for Claude Code (and any AI agent) working in this repository.

## About this repository

DiscVault Launcher is a small deployment manager for DiscVault Docker channels, running
the PostgreSQL-backed DiscVault 26 stack. It is deliberately separate from the DiscVault
application image and from the standalone Compose stack: `helmerznl/discvault` is the app
image, `helmerznl/discvault-launcher` is this optional management/proxy image, and
`stack/docker-compose.yml` can be used without the launcher at all. Keep that separation
intact — a change that makes the stack depend on the launcher removes a supported way of
running DiscVault.

## Branches

`main` is the integration branch and there is no promotion model here. Branch feature and
fix work off `main`, open a pull request into `main`, and never commit to `main` directly.

## Deployment files are the operator's problem, so spell them out

This repository ships Compose files and an image. A change touching a Compose file or an
environment template must state in the pull request body, explicitly and in one place,
what the operator has to change in their own files: the exact variable name and its
default, the exact Compose mapping line, and whether an existing deployment keeps working
untouched. Those files are templates; the `.env` and overrides that actually run a
deployment are untracked and live on the host, so a diff that looks complete can still
leave a running deployment missing a setting, and nothing fails until it is needed. "No
deployment-file changes in this PR" is a fine answer when true — silence is not.

## The shared instructions live in App-Guidance

The engineering guidance for every Flux76 project lives in
**[`Flux76HQ/App-Guidance`](https://github.com/Flux76HQ/App-Guidance)**, not in this
repository. Read it before starting work here; this file records only what is specific
to this repo.

| What you need | Where it is |
|---|---|
| The enforceable baseline — versioning, CI guardrails, secrets, release discipline, PR workflow | [`shared/guidelines/project-baseline.md`](https://github.com/Flux76HQ/App-Guidance/blob/main/shared/guidelines/project-baseline.md) |
| Which document leads per domain, and where that document lives | [`AUTHORITY.md`](https://github.com/Flux76HQ/App-Guidance/blob/main/AUTHORITY.md) |
| How to work inside App-Guidance itself (branch, PR, when the `VERSION` bump applies) | [`CLAUDE.md`](https://github.com/Flux76HQ/App-Guidance/blob/main/CLAUDE.md) |
| DiscVault specs, the normative sync contract, and cross-repo change specs | [`projects/discvault/`](https://github.com/Flux76HQ/App-Guidance/tree/main/projects/discvault) |

Two baseline rules apply here from the first commit, so they are worth naming rather
than leaving to be discovered:

- **A new feature gets a fresh worktree and a separate session**
  ([§16](https://github.com/Flux76HQ/App-Guidance/blob/main/shared/guidelines/project-baseline.md#16-feature-work-gets-its-own-workspace-and-its-own-session)).
  One feature, one workspace, one session. A checkout is on one branch at a time, so two
  features in one directory share a working tree and an index, and the first `git add -A`
  mixes them into a single commit that nothing can separate afterwards. Say so *before*
  the first edit, not after. It is a warning, not a veto, and it is about features — a
  fix, a refactor or a chore inherits the workspace it is given.
- **An agent carries its own PR to merge**
  ([§8](https://github.com/Flux76HQ/App-Guidance/blob/main/shared/guidelines/project-baseline.md#8-agent-pull-requests-standing-authorisation-to-merge)).
  Standing authorisation across every Flux76 repository, bounded and revocable: watch the
  PR, drive failing checks to green, merge once every check passes — without asking again
  at the green light. "All green" is the condition, not a formality.

**Precedence.** On anything shared — versioning, CI, secrets, the PR workflow, the
DiscVault contracts — App-Guidance leads and this file must not contradict it. On this
repository's own branch topology, build and release flow, this file leads. When a session
settles something that outlives its own PR — a contract between systems, an ownership or
precedence rule, a deliberate policy and why — write it up in App-Guidance in the same
change set, on a branch and through a pull request, never straight onto its `main`.
