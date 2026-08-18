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
- Note whether a second action within five minutes re-prompts. macOS may reuse a
  successful authorization; the README should match observed behaviour.

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
- Terminate an action while its authorization dialog is open, then confirm the
  next invocation recovers the dead-owner lock.
- Trigger two actions from two separate Alfred invocations while a dialog is
  open, and confirm the second is refused as already running. (Alfred's own
  `concurrently: false` serialises a single invocation, so one window is not
  enough to exercise the lock.)
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
