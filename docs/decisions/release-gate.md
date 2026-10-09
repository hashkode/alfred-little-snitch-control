---
type: decision
title: "Release gate: require the commit's own ci-required pass instead of re-running the checks"
description: A release proceeds only for a commit on main whose latest ci-required check run from GitHub Actions succeeded; revisit if CI slows down, the required check changes, or the release moves to a Linux runner.
tags: [ci, releases, github-actions, rulesets]
sources:
  - { name: "scripts/release-gate.zsh run against four commits of this repository, 2026-10-09", credibility: verified-firsthand }
  - { name: "Push-to-ci-required times of every CI run on main since the check existed, 2026-10-09", credibility: verified-firsthand }
  - { name: "GitHub REST API: check runs, compare two commits, workflow runs", credibility: documented }
verified: true
verified_on: 2026-10-09
stale_after: 2027-04-09
status: active
---

# Release gate: require the commit's own ci-required pass instead of re-running the checks

## Decision

`release.yml` runs `scripts/release-gate.zsh` before it builds anything. The gate refuses unless
the commit is reachable from the default branch **and** the latest `ci-required` check run on that
exact commit, from the GitHub Actions integration, concluded `success`.

The release does not re-run the linters or the secret scan, and there is no shared `make check`
target. Those were tasks 3 and 4 of #27, superseded by this decision.

## Why

**Both conditions are needed.** Run against real commits on 2026-10-09:

| commit | on `main` | `ci-required` | gate |
| --- | --- | --- | --- |
| `f526280`, tip of `main` | identical | success | allowed |
| `aad4386`, earlier on `main` | behind | success | allowed |
| `36083f5`, tagged `v0.2.0` | behind | none | refused: CI never ran on it |
| `b5804db`, head of PR #36 | diverged | success | refused: not on `main` |

A green `ci-required` alone would have allowed the pull request's head. Ancestry alone would have
allowed `v0.2.0`, whose commit was created by the August history rewrite and has only ever run
the Release workflow, twice, when the tag was re-cut.

**Reading the evidence instead of repeating it.** The same commit with the same pinned tools gives
the same result, so re-running adds nothing but a second gate definition that can drift from
`ci.yml`, which is the problem the `make check` task existed to prevent. It would not fit the
runner either: MegaLinter is a Docker action, and the release builds on macOS, where Docker is
unavailable. Push runs on `main` lint the whole codebase (`VALIDATE_ALL_CODEBASE` is true outside
pull requests), so the evidence the gate reads is a full run, not a changed-files one.

**Integration 15368 only.** That is GitHub Actions on github.com, the integration the `main`
ruleset requires `ci-required` from. A check run of the same name from another app is ignored.

**Absent is not failed.** A tag pushed straight after a merge can arrive before CI has created
`ci-required`. The `ci.yml` workflow run on the commit tells the cases apart: still running means
wait; finished means refuse; none at all means wait out a short grace period, then refuse. Runs of
other workflows on the commit are ignored. Dependabot's and Release's runs say nothing about CI.

**The wait bound.** Time from a push to `main` until `ci-required` completed, for every CI run on
`main` since the check existed:

| commit | minutes |
| --- | --- |
| `46f2980` | 2.3 |
| `d845590` | 1.9 |
| `bec3d55` | 2.1 |
| `aad4386` | 2.1 |
| `f526280` | 2.8 |

Median 2.1, worst 2.8. The gate waits up to 10 minutes, about 3.5 times the worst case, polling
every 20 seconds, with a 2-minute grace period for CI to start. A timeout spends nothing: the tag
exists, nothing is published, and re-running the workflow retries.

## Consequences

- `release.yml` needs `checks: read` and `actions: read`, and its job timeout rises from 15 to 30
  minutes to cover the wait.
- Only a commit CI ran on can be released. Merging a stack runs CI on its tip only, so the
  intermediate squash commits are not releasable: tag the tip.
- `workflow_dispatch` rehearses the gate, the build and the package check from any ref without
  attesting or publishing. The attestation and release steps still first run on a real tag.
- The gate trusts GitHub's check-run record. A flaky pass in the original run is not caught a
  second time.
- The job holds write, `id-token` and attestation permissions while it builds, including during a
  rehearsal. Tracked by #39.

## Re-check triggers

- The worst push-to-`ci-required` time on `main` exceeds 5 minutes, half the bound.
- `ci-required` is renamed, or the `main` ruleset requires a different check or integration.
- The release moves to a Linux runner, where re-running MegaLinter becomes cheap.
- The `main` ruleset turns on strict mode (#37). The gate does not depend on it, but it changes
  what "passed on `main`" implies about the commits around it.
