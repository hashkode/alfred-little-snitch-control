-- The only component that requests administrator privileges.
--
-- It never runs another file from the user-writable Alfred workflow bundle as
-- root: the privileged payload is a shell program assembled here from
-- constants. Every accepted action maps to one fixed Little Snitch
-- preference/value pair, and no caller-supplied text reaches the shell.
--
-- Pass "--dry-run" as a second argument to print the shell program that would
-- run, without elevating and without executing anything. The test suite uses
-- this to assert the action-to-preference map directly.

use scripting additions

property littleSnitchCLI : "/Applications/Little Snitch.app/Contents/Components/littlesnitch"
property littleSnitchApp : "/Applications/Little Snitch.app"

-- Signature requirement for the Little Snitch executable. Unlike reading
-- signature metadata with "codesign -d", this verifies the code hashes and the
-- certificate chain, so a patched or re-signed binary is rejected.
property signatureRequirement : "=identifier \"littlesnitch\" and anchor apple generic and certificate leaf[subject.OU] = \"MLZF7K7B5R\""

on run argv
  if (count of argv) is 0 or (count of argv) > 2 then error "Expected an action." number 64

  set actionID to item 1 of argv
  set dryRun to false
  if (count of argv) is 2 then
    if item 2 of argv is "--dry-run" then
      set dryRun to true
    else
      error "Unsupported option." number 64
    end if
  end if

  -- Derive the user ourselves rather than trusting an argument. This keeps the
  -- only variable token in the shell program out of the caller's hands and
  -- guarantees Little Snitch is addressed on behalf of the invoking user.
  set numericUser to («event sysoexec» given «class ----»:"/usr/bin/id -u")
  if (my isDecimalDigits(numericUser)) is false then error "Could not determine the current user." number 65

  set baseArguments to {"/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "LC_ALL=C", littleSnitchCLI, "-u", numericUser}
  set mutationArguments to missing value

  if actionID is "refresh" then
    set mutationArguments to missing value
  else if actionID is "mode.alert" then
    set mutationArguments to baseArguments & {"write-preference", "activeSilentMode", "0"}
  else if actionID is "mode.silent-allow" then
    set mutationArguments to baseArguments & {"write-preference", "activeSilentMode", "1"}
  else if actionID is "mode.silent-deny" then
    set mutationArguments to baseArguments & {"write-preference", "activeSilentMode", "2"}
  else if actionID is "filter.enable" then
    set mutationArguments to baseArguments & {"write-preference", "networkFilterEnabled", "true"}
  else if actionID is "filter.disable" then
    set mutationArguments to baseArguments & {"write-preference", "networkFilterEnabled", "false"}
  else
    error "Unsupported action." number 64
  end if

  set modeCommand to my quotedCommand(baseArguments & {"read-preference", "activeSilentMode"})
  set filterCommand to my quotedCommand(baseArguments & {"read-preference", "networkFilterEnabled"})
  set protectedPaths to {littleSnitchApp, littleSnitchApp & "/Contents", littleSnitchApp & "/Contents/Components", littleSnitchCLI}

  -- Sanitise the root shell itself, not merely the Little Snitch invocations.
  -- GREP_OPTIONS alone would otherwise turn every integrity check below into an
  -- unconditional pass.
  set shellSource to "export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C; "
  set shellSource to shellSource & "unset GREP_OPTIONS GREP_COLOR GREP_COLORS IFS CDPATH BASH_ENV ENV LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES; "
  set shellSource to shellSource & "set -eu; " & my integrityCheckFunction(protectedPaths)

  if mutationArguments is not missing value then
    set shellSource to shellSource & "check_cli; " & my quotedCommand(mutationArguments) & " >/dev/null; "
  end if

  set shellSource to shellSource & "check_cli; mode=$(" & modeCommand & "); "
  set shellSource to shellSource & "check_cli; filter=$(" & filterCommand & "); "
  set shellSource to shellSource & "case \"$mode\" in 0|1|2) ;; *) exit 65 ;; esac; "
  set shellSource to shellSource & "case \"$filter\" in true|false) ;; *) exit 65 ;; esac; "
  set shellSource to shellSource & "/usr/bin/printf '%s|%s\\n' \"$mode\" \"$filter\""

  if dryRun then return shellSource

  -- Raw Standard Additions event and parameter codes keep this source
  -- portable when the user's AppleScript terminology is localized.
  return «event sysoexec» given «class ----»:shellSource, «class badm»:true
end run

on integrityCheckFunction(protectedPaths)
  set pathWords to {}
  repeat with protectedPath in protectedPaths
    set end of pathWords to quoted form of (protectedPath as text)
  end repeat

  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to " "
  set pathList to pathWords as text
  set AppleScript's text item delimiters to previousDelimiters

  set quotedCLI to quoted form of littleSnitchCLI
  set quotedRequirement to quoted form of signatureRequirement

  set checkSource to "check_cli() { "
  set checkSource to checkSource & "for protected_path in " & pathList & "; do "
  set checkSource to checkSource & "[ ! -L \"$protected_path\" ] || return 77; "
  set checkSource to checkSource & "metadata=$(/usr/bin/stat -f '%u %p' \"$protected_path\") || return 77; "
  set checkSource to checkSource & "owner=${metadata%% *}; permissions=${metadata#* }; "
  set checkSource to checkSource & "[ \"$owner\" = 0 ] || return 77; "
  set checkSource to checkSource & "case \"$permissions\" in *[!0-7]*) return 77 ;; esac; "
  set checkSource to checkSource & "[ $((0$permissions & 022)) -eq 0 ] || return 77; "
  set checkSource to checkSource & "done; "
  set checkSource to checkSource & "[ -f " & quotedCLI & " ] && [ -x " & quotedCLI & " ] || return 77; "
  set checkSource to checkSource & "/usr/bin/codesign --verify --strict -R " & quotedRequirement & " " & quotedCLI & " >/dev/null 2>&1 || return 77; "
  set checkSource to checkSource & "reported_version=$(" & quotedCLI & " --version) || return 78; "
  -- Must never be STRICTER than lsctl_is_supported_version in common.zsh. That
  -- predicate extracts the first dotted number appearing anywhere in the output
  -- and accepts major 6, minor >= 2. An anchored pattern here that additionally
  -- demanded the "Version " prefix and nothing trailing disagreed with it: on a
  -- build printing "Version 6.5 (7012)" the menu offered every action, the user
  -- approved an administrator prompt, and only then did this check refuse --
  -- every action, forever, after a password each time. Matching the version
  -- anywhere in the output keeps this side no stricter, while still refusing a
  -- major this workflow knows nothing about. There is deliberately no trailing
  -- context group: requiring one made the gate stricter again for versions
  -- followed by a dot ("Version 6.5.beta"). The leading (^|[^0-9.]) alone is
  -- what refuses "Version 16.4" and "Version 1.6.2", and no trailing text can
  -- turn a 6.x into a different major. tests/run.zsh asserts the two
  -- predicates agree over a table of version strings.
  set checkSource to checkSource & "/usr/bin/printf '%s\\n' \"$reported_version\" | /usr/bin/grep -Eq '(^|[^0-9.])6\\.([2-9]|[1-9][0-9]+)' || return 78; "
  set checkSource to checkSource & "}; "
  return checkSource
end integrityCheckFunction

on quotedCommand(argumentList)
  set quotedArguments to {}
  repeat with currentArgument in argumentList
    set end of quotedArguments to quoted form of (currentArgument as text)
  end repeat

  set previousDelimiters to AppleScript's text item delimiters
  set AppleScript's text item delimiters to " "
  set commandText to quotedArguments as text
  set AppleScript's text item delimiters to previousDelimiters
  return commandText
end quotedCommand

on isDecimalDigits(candidate)
  if candidate is "" then return false
  if (length of candidate) > 10 then return false
  repeat with currentCharacter in characters of candidate
    set characterID to id of (currentCharacter as text)
    if characterID < 48 or characterID > 57 then return false
  end repeat
  return true
end isDecimalDigits
