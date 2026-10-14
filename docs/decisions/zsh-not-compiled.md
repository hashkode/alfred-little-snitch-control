---
type: decision
title: "Ship zsh scripts, not a compiled binary"
description: An exception to the engineering standard's rule that shell is for repo-local scripts only; the Alfred Gallery requires compiled binaries to be signed and notarised and exempts scripts, and the privileged step is AppleScript whatever the host language.
tags: [distribution, zsh, alfred, gatekeeper, language-choice]
sources:
  - { name: "Alfred Gallery submission rules, https://alfred.app/submit/", credibility: documented }
  - { name: "Engineering standard, language choice: shell is for repo-local scripts only", credibility: documented }
  - { name: "cronai-labs/schriftsatz#71: quarantined, non-notarised binary killed before main()", credibility: verified-firsthand }
verified: true
verified_on: 2026-10-14
stale_after: 2027-10-14
status: active
---

# Ship zsh scripts, not a compiled binary

## Decision

The workflow ships zsh scripts (`bin/menu`, `bin/action`, `bin/common.zsh`) and an AppleScript
source (`bin/authorize.applescript`) inside the `.alfredworkflow` bundle. There is no compiled
binary.

This is a deliberate exception. The engineering standard says shell is for repo-local scripts
only, and that "the line is *distribution*, not length: the moment someone is expected to
install it, the portability traps become theirs." This project is installed by people who are
not its author, so it is on the far side of that line.

## Why

- **The distribution channel forbids an unsigned binary and exempts scripts.** The Alfred
  Gallery's rules (alfred.app/submit, read 2026-10-14): "If they contain compiled binaries,
  they must be signed and notarised", "Workflows must not have unsigned and non-notarised
  binaries", and "Scripts don't fall into this category." A binary needs a Developer ID and a
  notarisation pipeline, which means a paid Apple Developer Program membership this project
  does not have.
- **Gatekeeper is not hypothetical.** In a sibling project, an ad-hoc-signed, non-notarised Go
  binary carrying `com.apple.quarantine` was killed (exit 137) before `main()` ran. It started
  only once the attribute was removed (cronai-labs/schriftsatz#71, 2026-10-14). Scripts run
  through `/bin/zsh`, which Apple signs.
- **A binary would not remove the script that matters.** The only privileged step is
  `do shell script … with administrator privileges`, run by `osascript`. That is the macOS
  authorisation prompt, and a compiled front end would hand the same work to the same
  AppleScript. The standard's own question applies: the tool shells out to `littlesnitch` and
  `osascript` regardless, so "single static binary" was never on the table.
- **There is little for a compiled language to improve.** About 1,150 lines read a cache,
  print Script Filter JSON and run one `osascript`. Most of the logic is predicates and
  string shapes, and `tests/run.zsh` tests it directly.
- **The portability traps the standard names are bash traps.** Every script starts with
  `#!/bin/zsh -f`, so it uses the zsh macOS ships and ignores the user's startup files.

## Consequences

- No third-party linter supports zsh; shellcheck and shfmt reject it. `tests/run.zsh` carries
  the checks instead: it syntax-checks every zsh file, requires the `#!/bin/zsh -f` line,
  and refuses assignments to zsh's read-only parameters, which `zsh -n` does not catch.
- Users audit source, not a binary. `SECURITY.md` asks them to.

## Revisit when

- the Alfred Gallery's rules on binaries change, or this project gets a Developer ID and can
  sign and notarise;
- macOS stops shipping `/bin/zsh`;
- the workflow needs logic that zsh makes hard to test, such as parsing structured output
  rather than fixed line shapes.
