<h1>
  <img src="workflow/icon.png" width="42" align="center" alt="">
  Little Snitch Control for Alfred
</h1>

Switch [Little Snitch 6](https://www.obdev.at/products/littlesnitch/) operation
modes and its network filter from Alfred — without UI scripting, without a
passwordless `sudo` rule, and without a background helper. Every change is
authorized by macOS and read back from Little Snitch before the workflow claims
it worked.

[![Latest release](https://img.shields.io/github/v/release/hashkode/alfred-little-snitch-control?sort=semver)](https://github.com/hashkode/alfred-little-snitch-control/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/hashkode/alfred-little-snitch-control/total)](https://github.com/hashkode/alfred-little-snitch-control/releases)
[![License](https://img.shields.io/github/license/hashkode/alfred-little-snitch-control)](LICENSE)

![The workflow's result list in Alfred, showing the last verified state and the available actions](docs/images/menu.png)

## Why

Little Snitch's own controls live in a menu bar item and a settings window.
This puts the four states you actually switch between — Alert, Silent Allow,
Silent Deny, and filter on/off — one keystroke away, and shows you what the
firewall reported the last time it was asked.

The two states that weaken protection, plus turning the filter off, are only
reachable with <kbd>⌘</kbd><kbd>↩</kbd>. A stray Return cannot disable your
firewall.

> [!WARNING]
> Disabling the Network Filter makes every Little Snitch rule ineffective and
> allows all connections until you turn it back on. Nothing re-enables it
> automatically.

## Requirements

- macOS with Little Snitch 6.2 or newer installed in `/Applications`
- Alfred 5 with the Powerpack
- An administrator password each time the workflow reads or changes state

Verified against Little Snitch 6.4.1 on macOS 26 (Apple silicon). Newer 6.x
releases are accepted and labelled "untested" in the status row rather than
refused. Little Snitch 5 and earlier are refused.

## Install

1. Download the latest `.alfredworkflow` from the
   [releases page](https://github.com/hashkode/alfred-little-snitch-control/releases/latest).
2. Verify the checksum published with that release:

   ```sh
   shasum -a 256 -c Little-Snitch-Control-v0.2.0.alfredworkflow.sha256
   ```

3. Open the file to install it in Alfred.

Or build it yourself with `make build`; the archive is byte-reproducible, so a
local build of a release tag produces the same checksum as the published asset.

## Setup

1. In Little Snitch, open **Settings → Security**.
2. Unlock the settings and enable **Allow access via Terminal**.
3. Type `snitch` in Alfred and choose **Refresh Status**.
4. Approve the macOS administrator dialog.

> [!IMPORTANT]
> Step 2 is the largest security cost this workflow asks of you. Objective
> Development ships that switch off deliberately — in their words, "in order to
> prevent malicious scripts from manipulating your firewall settings". Turning
> it on lets **any** process that can obtain root reconfigure Little Snitch, not
> only this workflow. Decide that you want that before installing.

The keyword is configurable in the workflow's configuration in Alfred.

## Usage

Type `snitch` (default keyword) to see the last verified state and choose an
action:

| Row | What it does |
| --- | --- |
| **Filter: … · Mode: …** | Last verified state. <kbd>↩</kbd> refreshes it. |
| **Refresh Status** | Reads and verifies the current state. |
| **Use Alert Mode** | Ask when no existing rule matches. |
| **⌘↩ Use Silent Allow** | Allow unmatched connections without asking. |
| **⌘↩ Use Silent Deny** | Deny unmatched connections without asking. |
| **Enable Network Filter** | Apply Little Snitch rules to network traffic. |
| **⌘↩ Disable Network Filter** | Stop applying every Little Snitch rule. |
| **Open Little Snitch** | Open Network Monitor and manage rules. |
| **Open Setup Help** | Open this page. |

Rows prefixed <kbd>⌘</kbd><kbd>↩</kbd> ignore a plain Return by design.

State is labelled **Last verified** rather than "current", because Little
Snitch can also be changed from its own interface, by an active profile, or by
another administrator. The workflow never polls a privileged firewall setting in
the background.

## Uninstall

1. In Alfred → Workflows, right-click **Little Snitch Control** → Delete.
2. Remove the cached state:

   ```sh
   rm -rf ~/Library/Caches/com.runningwithcrayons.Alfred/Workflow\ Data/com.hashkode.alfred.little-snitch-control
   ```

3. Optionally turn **Allow access via Terminal** back off in Little Snitch.

Nothing else is installed. There is no daemon, login item, privileged helper, or
`sudoers` entry to remove — you can confirm with:

```sh
ls /Library/LaunchDaemons /Library/LaunchAgents ~/Library/LaunchAgents /Library/PrivilegedHelperTools
sudo ls /etc/sudoers.d
```

## How it works

Little Snitch ships an official command-line utility. The workflow sets these
preferences:

| Action | Preference and value |
| --- | --- |
| Alert Mode | `activeSilentMode 0` |
| Silent Allow | `activeSilentMode 1` |
| Silent Deny | `activeSilentMode 2` |
| Network Filter On | `networkFilterEnabled true` |
| Network Filter Off | `networkFilterEnabled false` |

> [!NOTE]
> `read-preference` and `write-preference` are documented commands, but these
> two preference **keys** are not a documented public API. Objective
> Development's documentation shows `activeSilentMode` only in passing, with the
> value `0`; the values `1` and `2`, and `networkFilterEnabled` entirely, were
> established by observation. They can change in any Little Snitch update
> without notice. This is why every action reads the state back and reports what
> Little Snitch actually says rather than what was requested. The mapping above
> was confirmed against Little Snitch 6.4.1 — see
> [docs/VERIFIED-MODES.md](docs/VERIFIED-MODES.md) — and is re-checked before
> each release with `scripts/verify-modes.zsh`.

Every privileged action follows the same sequence:

1. Alfred passes one opaque identifier from a closed list of six.
2. A fixed AppleScript maps that identifier to one predefined Little Snitch
   command. No text from Alfred reaches the shell.
3. macOS requests administrator authorization.
4. Both preferences are read back and accepted only if they are literally
   `0`, `1`, `2` and `true`, `false`.
5. Only a confirmed result is written to a user-owned cache and displayed.

Opening the result list never requests administrator access.

## Security model

What this design does defend against:

- Argument and environment injection from Alfred input: a closed six-action
  allowlist, fixed argument vectors built with `quoted form of` rather than
  string interpolation, and a sanitized privileged environment.
- Elevating the wrong executable: the path is fixed, each component is checked
  for root ownership and non-root writability, and the binary must satisfy
  `codesign --verify --strict` against Objective Development's Team ID.
- A forged or stale cache: it is refused unless it is a regular file owned by
  you with mode `0600`, and every field is validated. Nothing privileged ever
  reads it.
- Concurrent runs: actions are serialized, and results are read back before
  success is reported.

What it does **not** defend against — and cannot:

- Code already running as your user. An Alfred workflow bundle is user-writable
  by design, so anything running as you can rewrite this workflow and obtain
  root at the next authorization prompt you approve. The macOS dialog is titled
  `osascript` and does not show what will run, so you cannot detect this by
  reading the prompt.
- Little Snitch state changed after the last refresh, by anything at all.

No password is stored or piped anywhere, and no passwordless `sudo` rule or
persistent root helper is installed. See [SECURITY.md](SECURITY.md) for the full
threat model.

## Troubleshooting

### "Little Snitch rejected the request"

Confirm **Little Snitch → Settings → Security → Allow access via Terminal** is
enabled. This consent is deliberately not automated.

### The mode changed back immediately

An active Little Snitch profile can select its own operation mode. Change the
profile or its mode setting, then refresh.

### Signature verification failed

Reinstall Little Snitch from
[Objective Development](https://www.obdev.at/products/littlesnitch/download.html).
The workflow will not elevate an executable that fails verification.

### The status looks stale

Choose **Refresh Status**. The workflow never polls in the background.

## Development

No third-party runtime dependencies.

```sh
make test          # pure: no Little Snitch, no license, no password required
make build         # writes dist/
make package-test  # validates the built archive
```

`make test` runs entirely against mocks and writes nothing outside a temporary
directory. Privileged behaviour cannot be automated; follow
[the manual test checklist](docs/MANUAL_TESTING.md) on a non-critical Mac before
tagging a release, and re-run `scripts/verify-modes.zsh`.

```text
workflow/            Alfred bundle source (info.plist, icons, bin/)
scripts/build.zsh    reproducible release packaging
scripts/make-icons.py  generates the workflow artwork from source
scripts/verify-modes.zsh  read-only check of the operation-mode mapping
tests/run.zsh        unit and behaviour tests
tests/package.zsh    release-archive validation
docs/                developer documentation (not shipped in the workflow)
```

## Roadmap

No fixed schedule. Under consideration, in rough order of likelihood:

- Profile switching, if it can be done without letting free-form text cross the
  privileged boundary.
- Rule group and blocklist toggling.

A timed disable with automatic re-enabling, and a signed helper for promptless
operation, have both been considered and set aside: each requires background
persistence or a paid signing pipeline that this design deliberately avoids. See
[SECURITY.md](SECURITY.md).

Profiles are deliberately not exposed through free-form Alfred input.
Privileged arguments remain a closed list.

## License and trademarks

[MIT](LICENSE).

This project is unofficial and is not affiliated with, endorsed by, or
sponsored by Objective Development Software GmbH or Running with Crayons Ltd.
Little Snitch is a product of Objective Development Software GmbH. "Alfred" is a
registered trademark of Running with Crayons Ltd. The workflow's artwork is
original; Little Snitch's own icon is only ever read from your installed copy at
runtime and is never redistributed here.

## References

- [Little Snitch command-line overview](https://help.obdev.at/littlesnitch6/cmd-overview)
- [Little Snitch operation modes](https://help.obdev.at/littlesnitch6/concepts-opmodes)
- [Little Snitch security settings](https://help.obdev.at/littlesnitch6/pref-security)
- [Alfred Script Filter JSON](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/)
