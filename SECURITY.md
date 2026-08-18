# Security

This workflow controls a network filter. Its security boundary is narrow and
worth stating precisely.

## Supported versions

| Version | Supported |
| --- | --- |
| 0.2.x | ✅ latest release only |
| < 0.2 | ❌ never published |

Only the most recent release receives fixes.

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/hashkode/alfred-little-snitch-control/security/advisories/new).
If you cannot use GitHub, email hashkode@posteo.de.

Please do not open a public issue for a security problem. Expect an
acknowledgement within 7 days. This is a single-maintainer project with no bug
bounty and no guaranteed fix timeline; you will be credited in the advisory
unless you ask otherwise.

**In scope:** privilege escalation through the workflow, execution of
attacker-controlled arguments as root, a false "verified" status display, or any
path that changes Little Snitch state without a macOS authorization prompt.

**Out of scope:** anything that presupposes code execution as your user (see
Limitations), vulnerabilities in Little Snitch itself (report those to Objective
Development), and vulnerabilities in Alfred.

## The prerequisite you are accepting

The workflow only functions if you enable **Little Snitch → Settings → Security
→ Allow access via Terminal**. Objective Development ships that switch off
deliberately: "In order to prevent malicious scripts from manipulating your
firewall settings, most of the functions of this command are only available to
the superuser and only if enabled here in the settings."

Enabling it lets **any** process that can obtain root reconfigure Little Snitch.
That is a larger change to your machine's posture than anything else in this
project, and it is not reversible by uninstalling the workflow — you have to
turn the switch back off yourself.

## What this defends against

- **Argument and environment injection from Alfred input.** Six privileged
  action identifiers are accepted: refresh, three modes, two filter states. Each
  maps to a fixed argument vector built with AppleScript's `quoted form of`; no
  text from Alfred is ever interpolated into a shell string. The privileged
  shell exports a fixed `PATH` and `LC_ALL` and unsets `GREP_OPTIONS`,
  `GREP_COLORS`, `IFS`, `CDPATH`, `BASH_ENV`, `ENV`, `LD_LIBRARY_PATH` and
  `DYLD_INSERT_LIBRARIES`; Little Snitch itself is invoked under `env -i`.
- **Elevating the wrong executable.** The path is fixed. Every component from
  `/Applications/Little Snitch.app` down to the binary must be a non-symlink
  owned by root and not writable by group or other, and the binary must satisfy
  `codesign --verify --strict -R '=identifier "littlesnitch" and anchor apple
  generic and certificate leaf[subject.OU] = "MLZF7K7B5R"'`. This is re-checked
  immediately before each privileged sub-command, not once up front.
- **A forged, stale, or foreign cache.** The cache is read only if it is a
  regular file, not a symlink, owned by the invoking user, mode `0600`, with a
  known schema and every value in range; an unrecognised key voids the whole
  file. It is invalidated when Little Snitch's version changes. Nothing
  privileged reads it — poisoning it can only mislead the display.
- **Concurrent runs.** Actions are serialized with a lock whose stale-owner
  recovery is a rename, so a racing process cannot delete a live lock.
- **Misreported outcomes.** Both preferences are read back after every action
  and must be literally `0`, `1`, `2` and `true`, `false`. If the observed state
  disagrees with the requested one, the workflow says so rather than claiming
  success.

## What this does not defend against

- **Code already running as your user.** An Alfred workflow bundle is
  user-writable — that is how Alfred works. Anything running as you can rewrite
  `bin/action` or `bin/authorize.applescript` and obtain root the next time you
  approve an authorization prompt for this workflow. The macOS dialog is titled
  `osascript`, cannot be retitled, and does not display the command that will
  run, so you cannot detect a modified bundle by reading the prompt. This is the
  fundamental limitation of the design.
  The integrity checks above are therefore *not* a defence against a
  compromised bundle: they are emitted by the very file such an attacker
  rewrites. They defend against a replaced or damaged **Little Snitch**, which
  is a different and real problem.
- **The authorization grace period.** macOS may briefly reuse a successful
  authorization. A modified script gets its own prompt, but that prompt looks
  identical to the legitimate one.
- **Drift.** The displayed state is a last-verified cache, not a live assertion.
  Little Snitch, an active profile, another administrator, or another process
  may change the actual state at any time.
- **A managed Mac.** Under MDM, Little Snitch settings can be locked or
  centrally overridden; an action may be authorized and still not take effect.
  The readback will report the mismatch.

## Undocumented interfaces

The workflow depends on two Little Snitch preference keys that Objective
Development does not document as a public API: `activeSilentMode` (documented
only in passing, only with the value `0`) and `networkFilterEnabled` (not
documented at all). A Little Snitch update could change or remove either
without notice.

Two mitigations: every action reads the state back and reports what Little
Snitch actually says, and `scripts/verify-modes.zsh` re-confirms which value
corresponds to which operation mode before a release. It reads only — you change
the mode in Little Snitch's own interface and it reports what the preference
says.

## Design decisions taken deliberately

- **No `sudoers` entry.** A `NOPASSWD` rule for `littlesnitch` would downgrade
  the attacker's cost from "needs your password" to "needs nothing", and
  `littlesnitch` also exposes `restore-model`, `rulegroup`, and
  `write-preference allowCommandLineAccess false`.
- **No privileged helper or daemon.** `SMJobBless` is deprecated and
  `SMAppService` requires a companion application bundle, an Apple Developer
  Program membership, notarisation, and a user-approved background item — in
  exchange for a permanently resident root daemon with an XPC surface to design
  and defend. For a tool that flips a setting a few times a day, a per-action
  password prompt is the smaller attack surface. This is a decision, not a
  pending task.
- **No GUI scripting.** It would require enabling Little Snitch's
  `allowGUIScripting`, which Objective Development warns "undermines some of the
  security gained by Little Snitch", and it breaks on every UI change.
- **No auto-updater.** The workflow never updates itself or downloads anything.
- **`codesign --verify`, not `codesign -d`.** Reading signature metadata is
  satisfied by a binary whose code has been modified; verification is not.

## Verifying what you install

The release archive is byte-reproducible: building a release tag with
`make build` produces the same SHA-256 as the published asset. Verify the
checksum published with the release before importing, and prefer building from a
tag you have reviewed.
