# Manual integration test checklist

`make test` deliberately exercises no privileged path, so these checks are the
human release gate. Run them on a non-critical Mac before publishing a release.

Record the macOS version and architecture (`sw_vers -productVersion; uname -m`),
the Alfred version, the Little Snitch version
(`/Applications/Little\ Snitch.app/Contents/Components/littlesnitch --version`),
and whether an active profile selects an operation mode.

## Preparation

- `make all` (tests, build, package validation).
- `sudo ./scripts/verify-modes.zsh` — **release gate.** Do not tag until it
  reports a match. It only reads; you change modes in Little Snitch yourself.
- Install the built workflow in Alfred.
- Note the current filter state and mode so both can be restored.
- Keep Little Snitch's menu bar item visible during Filter Off testing; that,
  not this workflow, is your recovery path.

## Read and authorization

- With **Allow access via Terminal** disabled, choose Refresh. You will still
  get the macOS administrator prompt first — approve it — and the failure should
  then come from Little Snitch, with setup guidance and no change to the cache.
- Enable Terminal access, choose Refresh, approve, and compare both displayed
  values against Little Snitch.
- Cancel the authorization dialog; confirm the previous verified state is
  unchanged and the notification says nothing was changed.
- Note whether a second action within five minutes re-prompts. On macOS 26.7.1
  every action prompted; if a release behaves differently, update README.md and
  SECURITY.md to match.

## Modes

- Select Alert Mode; verify in Little Snitch.
- <kbd>⌘</kbd><kbd>↩</kbd> Silent Allow; verify.
- <kbd>⌘</kbd><kbd>↩</kbd> Silent Deny; verify.
- Repeat an already-active action and confirm it is idempotent and still
  offered (Alert Mode and Filter On stay actionable by design).
- Activate a profile that selects a mode, request a different mode, and confirm
  the readback mismatch reports the mode Little Snitch actually has.

## Network Filter

- Enable the Network Filter; confirm Little Snitch reports it on.
- Confirm a plain <kbd>↩</kbd> on **⌘↩ Disable Network Filter** does nothing
  except populate Alfred's search field.
- <kbd>⌘</kbd><kbd>↩</kbd> Filter Off, verify immediately in Little Snitch, then
  restore Filter On.
- Confirm the success message describes the configured preference and does not
  claim anything about system-extension health.

## Failure and recovery

- Confirm the not-installed screen without touching your installation:
  `LSCTL_TESTING=1 LSCTL_TEST_CLI=/nonexistent workflow/bin/menu` must render
  "Little Snitch Not Found". Only test real removal on a VM or spare Mac.
- Using a mock CLI that prints `Version 5.9.9`, `Version 6.2`, `Version 6.4` and
  `Version 6.9`, confirm each is refused or accepted as documented — 6.2/6.4
  (no patch component) and a newer-than-tested minor are the two regressions
  most likely to slip through.
- `kill -9` an action while its authorization dialog is open, then confirm the
  next invocation is not blocked by the abandoned lock. There is no dead-owner
  recovery to exercise: the kernel drops an fcntl lock when the holder dies. The
  dialog stays open, because its `osascript` child is orphaned rather than
  killed, so cancel it. The killed action's `.osascript.*` file stays in the
  cache directory: no handler runs on SIGKILL.
- Terminate an action with `kill` (not `kill -9`) while its dialog is open.
  Confirm the action exits, the lock is released and no second dialog appears.
  The `osascript` child survives with its dialog open (`pgrep -f
  authorize.applescript`); approved later, it would run the privileged command
  with nothing reporting the result. Cancel it. Tracked by #47.
- Upgrading from 0.2.x: leave a leftover `action.lock` **directory** in the
  workflow's cache directory and confirm the first action replaces it instead
  of reporting "Another Little Snitch action is still running".
- With an action's dialog open, start a second action from Terminal and confirm
  it is refused as already running, without a second dialog:
  `alfred_workflow_cache="$HOME/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.hashkode.alfred.little-snitch-control" <bundle>/bin/action refresh`,
  where `<bundle>` is the installed workflow (Alfred → Workflows → right-click →
  Open in Finder). It cannot be done through Alfred: Secure Input blocks Alfred's
  hotkey while the password field has focus, and `concurrently: false` queues a
  second invocation rather than starting it. The queued run starts, with its own
  prompt, once the first finishes.
- Change Little Snitch outside Alfred; confirm the cached state stays labelled
  "Last verified" until Refresh.
- Edit the cached version and confirm the status goes Unknown with an
  explanation:
  `~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/com.hashkode.alfred.little-snitch-control/state`

## Cleanup

- Restore the original filter state, mode, and profile.
- Disable **Allow access via Terminal** if nothing else needs it.
- Remove the workflow and confirm no root helper, daemon, login item, or
  `sudoers` entry was installed:
  `ls /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents /Library/PrivilegedHelperTools; sudo ls /etc/sudoers.d`
- Note that removing the workflow does not delete its cache directory; delete it
  manually (see README → Uninstall).

## Tagging

- Tag the tip of `main` once its CI has finished. The release workflow refuses
  a commit that is not on `main` or has no passing `ci-required` run, and CI
  runs only on the tip of a merged stack, so its intermediate commits cannot be
  released.
- To rehearse without spending a tag, run
  `gh workflow run release.yml --ref main`. It runs the gate, the build and the
  package check, and stops before the attestation and the release. A `v*` tag
  cannot be moved or deleted once pushed.
