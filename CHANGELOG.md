# Changelog

All notable changes to this project are documented here. Versions follow
[semantic versioning](https://semver.org/); releases before 1.0 may change
behaviour in a minor release.

## Unreleased

### Fixed

- Stop the privileged version check from being stricter than the unprivileged
  one. The elevated shell required `littlesnitch --version` to match an
  anchored pattern with nothing trailing, while the menu accepted any dotted
  version it could parse. On a build printing `Version 6.5 (7012)` the menu
  offered every action, the user approved an administrator prompt, and only
  then was the action refused — for every action, forever. A table test now
  asserts the two predicates agree.
- Make the signal handlers in `bin/action` terminate. zsh runs a trap handler
  and then resumes the script, so on `INT`/`TERM`/`HUP` the cleanup ran and the
  script carried on regardless — reading a stderr file it had just deleted, so
  a cancelled authorisation was reported as a rejected one. Note this does not
  stop an already-authorised `osascript` child: a signal aimed at `bin/action`
  alone still leaves that call in flight with the lock released.
- Replace the `mkdir`-and-PID-file lock with a kernel advisory lock
  (`zsystem flock`). Two processes that observed the same dead owner could each
  rename the other's freshly created lock aside, after which both believed they
  held it. The kernel releases the new lock on process death, including
  `SIGKILL`, so no stale-owner recovery exists to race. A lock directory left
  by an earlier release is cleared with `rmdir` — never `rm -rf`, which would
  unlink a live lock file a concurrent process had just created — and a path
  that is not a regular file is refused rather than blocking forever on it.
- Validate the privileged readback against its exact permitted shape. The
  previous guard rejected an embedded newline, but `do shell script` returns
  AppleScript text in which a line break arrives as CR, so it could never fire.
- Stop an inherited environment variable from disabling `common.zsh`. The
  re-entry guard tested a variable, so `LSCTL_COMMON_LOADED=1` in the
  environment turned the library into a no-op and `bin/menu` emitted malformed
  JSON with no error. It now tests for a function the file defines.

### Added

- MegaLinter, wired to the same configuration locally (`make lint`) and in CI,
  covering Markdown, YAML, Python, GitHub Actions, spelling, secret scanning and
  `.editorconfig` compliance. zsh is excluded deliberately — shellcheck and
  shfmt reject it — so `make test` syntax-checks every zsh file in the
  repository instead.
- A weekly link check over the documentation, kept off the pull-request path so
  an unrelated external outage cannot block a merge.
- Dependabot for the CI actions, which are the only third-party code here.

### Changed

- Say up front, on a first run, that Little Snitch's *Allow access via
  Terminal* setting must be enabled. Nothing unprivileged can detect whether it
  is on — reading any preference is itself privileged — so previously the
  prerequisite was delivered by an administrator password prompt followed by a
  notification explaining the password had been spent for nothing. A caution
  row now states it in the result list, and disappears once state has been
  verified.
- Distinguish a failed action from a successful one. Alfred renders a single
  notification style, so "Network Filter disabled — all connections are
  currently allowed" and "Cancelled — no Little Snitch setting was changed"
  arrived as the same banner. Failures now say so.
- Guarantee a notification on every path. The notification object shows nothing
  for empty input, so a run that died before printing — `set -u` aborting while
  sourcing `common.zsh`, a partially unpacked bundle — produced no feedback at
  all after the user had spent an administrator password, and silence is
  indistinguishable from success.
- List *Allow access via Terminal* in the README's requirements with what it
  actually costs: Objective Development ships it off to stop scripts
  manipulating firewall settings, and enabling it lifts that restriction for
  every process running as the user, not only this workflow.
- Make the README's checksum command version-agnostic. It named a specific
  release asset, so it broke on the next release at exactly the step the
  project asks security-conscious users not to skip.


- Package an explicit manifest instead of copying `workflow/` wholesale. The
  build shipped anything left in that directory — a `.DS_Store`, an editor swap
  file, a compiled `authorize.scpt` that `.gitignore` keeps out of
  `git status` — which made the published checksum a function of the working
  tree rather than of the commit. An unexpected file now fails the build.
- Prove the released menu still renders. Stripping the test hook uses a `sed`
  range; if its end marker is renamed or lost, `sed` deletes to end of file and
  leaves a syntactically valid prefix that emits nothing, and Alfred shows an
  empty list with no error. Both existing guards passed on that file. The build
  and `tests/package.zsh` now run the staged and packaged menus and require
  valid JSON with at least one item.
- Read the accepted action identifiers from one list, `LSCTL_ACTIONS`, in both
  `bin/action` and the suite.

### Tests

- Replace the second assertion that could not fail. The guard on the privileged
  user ID searched the source for a phrase that is not valid AppleScript for
  the bug it describes and has never appeared in the file; the realistic
  regression passed it. It now asserts the rendered command carries this
  process's own uid, exactly twice, and no other.
- Assert `lsctl_json_string` round-trips its input rather than merely emitting
  parseable JSON. The previous probes passed a stub that discards its argument.
- Assert the menu emits no action identifier `bin/action` rejects, and that no
  accepted identifier is unreachable from the menu. `open.app` and `open.help`
  had no coverage at all.
- Cover the version-unreadable menu state, which is what a user sees when
  Little Snitch is installed and *Allow access via Terminal* is off — the most
  common support case, and previously untested.
### Security

- Pin every GitHub Actions dependency to a full commit SHA. `release.yml` holds
  `contents: write` and `attestations: write`, so a repointed major tag could
  have run arbitrary code in the job that publishes the release asset and mints
  its build-provenance attestation. Dependabot keeps the pins current.
- Update `actions/attest-build-provenance` from v2 to v4.2.2 as part of the
  pinning pass.

## 0.2.0 — 2026-08-18

First public release.

### Fixed

- Accept every Little Snitch 6.2 and newer, including two-component releases
  such as `6.2`, `6.3` and `6.4`. The previous predicate required three numeric
  components, so it refused the versions the project claimed to support and
  would have refused 6.5 on the day it shipped. A version past the tested range
  is now labelled in the status row instead of blocking the workflow.
- Verify the Little Snitch executable with `codesign --verify --strict -R`
  instead of reading signature metadata with `codesign -d`. Metadata alone is
  satisfied by a binary whose code has been modified.
- Sanitize the privileged shell's own environment. Previously only the Little
  Snitch invocations ran under `env -i`, so an inherited `GREP_OPTIONS` could
  neutralize every integrity check at once.
- Keep `osascript`'s stderr out of the success payload. Any warning printed by
  the AppleScript host used to make a successful change report as
  "unexpected status".
- Run all entry points with `zsh -f`, so a user's `~/.zshenv` cannot change how
  the menu renders or which executable it reports on.
- Escape all control characters when emitting JSON. An unescaped one made
  Alfred discard the whole result list with no visible error.
- Derive the user ID inside the privileged script instead of accepting it as an
  argument.
- Break a dead owner's lock by atomic rename, so a concurrent run can no longer
  delete a live lock; releasing now verifies ownership.
- Refuse a symlinked cache directory instead of adopting it and changing its
  target's permissions.
- Report "the command line tool could not be run" separately from "unsupported
  version", and mirror every failure to stderr for Alfred's debugger.

### Changed

- Bundle identifier is now `com.hashkode.alfred.little-snitch-control`.
- Default keyword is `snitch` and is required; it remains configurable.
- Result matching is exact-from-start instead of loose word matching.
- Actions that weaken filtering state their `⌘↩` requirement in the title, carry
  a distinct icon, and populate the search field on a plain Return instead of
  doing nothing.
- Re-applying Alert Mode or re-enabling the Network Filter stays available even
  when the cache already reports them active, because the cache may be stale.
- The status row refreshes on Return.
- Notifications are titled "Little Snitch Control" so they are attributable.
- Setup help opens the project page rather than a Markdown file inside the
  installed bundle.
- The release archive is byte-reproducible, and the build fails if the test
  hook survives into it.

### Added

- Original workflow artwork, generated from source by `scripts/make-icons.py`.
- `scripts/verify-modes.zsh`, a read-only check of which `activeSilentMode`
  value corresponds to each operation mode, with a `--self-test` mode so its
  reporting path is covered without root or the interactive prompts. The
  mapping is confirmed on Little Snitch 6.4.1 in `docs/VERIFIED-MODES.md`.
- A test that asks zsh which parameters are read-only and fails if any script
  assigns to one. `zsh -n` does not catch this, and `status` reads like an
  ordinary name while actually being `$?`.
- Continuous integration and a tag-driven release workflow.
- `tests/package.zsh`, which validates a built archive; `tests/run.zsh` no
  longer builds anything and writes nothing outside a temporary directory.

## 0.1.0 — unreleased

Initial draft. Never published.
