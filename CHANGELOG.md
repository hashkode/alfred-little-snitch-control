# Changelog

All notable changes to this project are documented here. Versions follow
[semantic versioning](https://semver.org/); releases before 1.0 may change
behaviour in a minor release.

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
- MegaLinter, wired to the same configuration locally (`make lint`) and in CI,
  covering Markdown, YAML, Python, GitHub Actions, spelling, secret scanning and
  `.editorconfig` compliance. zsh is excluded deliberately — shellcheck and
  shfmt reject it — so `make test` syntax-checks every zsh file in the
  repository instead.
- A weekly link check over the documentation, kept off the pull-request path so
  an unrelated external outage cannot block a merge.
- Dependabot for the CI actions, which are the only third-party code here.
- `tests/package.zsh`, which validates a built archive; `tests/run.zsh` no
  longer builds anything and writes nothing outside a temporary directory.

## 0.1.0 — unreleased

Initial draft. Never published.
