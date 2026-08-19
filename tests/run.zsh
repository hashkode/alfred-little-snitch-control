#!/bin/zsh -f

# Unit and behaviour tests. Pure: writes nothing outside a temporary directory,
# never builds a release, never touches Little Snitch, and never elevates.
# Requires macOS and zsh only — no Little Snitch installation, no license, and
# no administrator password.

set -euo pipefail

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr ROOT_DIR="${SCRIPT_DIR:h}"
typeset -gr WORKFLOW_DIR="$ROOT_DIR/workflow"

typeset -gi checks=0

fail() {
  /usr/bin/printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  checks=$(( checks + 1 ))
}

assert_equal() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
  pass
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
  pass
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$message (unexpectedly found '$needle')"
  pass
}

assert_true() {
  local message="$2"
  (( $1 == 0 )) || fail "$message"
  pass
}

temporary_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-tests.XXXXXX")
cleanup() {
  if [[ -n "${temporary_dir:-}" && "$temporary_dir" == *"/alfred-little-snitch-tests."* && -d "$temporary_dir" ]]; then
    /bin/rm -rf -- "$temporary_dir"
  fi
}
trap cleanup EXIT INT TERM HUP

# --- static checks ---------------------------------------------------------

/usr/bin/plutil -lint "$WORKFLOW_DIR/info.plist" >/dev/null || fail "info.plist is invalid"
pass
# No third-party linter covers zsh — shellcheck and shfmt reject it rather than
# degrading — so every zsh file in the repository is syntax-checked here.
typeset -a zsh_sources
zsh_sources=(
  "$WORKFLOW_DIR/bin/common.zsh"
  "$WORKFLOW_DIR/bin/menu"
  "$WORKFLOW_DIR/bin/action"
  "$ROOT_DIR/scripts/build.zsh"
  "$ROOT_DIR/scripts/verify-modes.zsh"
  "$ROOT_DIR/tests/run.zsh"
  "$ROOT_DIR/tests/package.zsh"
)
for zsh_source in "${zsh_sources[@]}"; do
  [[ -f "$zsh_source" ]] || fail "expected zsh source is missing: $zsh_source"
  /bin/zsh -n "$zsh_source" || fail "invalid zsh syntax: ${zsh_source:t}"
  pass
done

for script_path in bin/menu bin/action bin/common.zsh; do
  [[ -x "$WORKFLOW_DIR/$script_path" ]] || fail "$script_path is not executable"
  pass
done
for asset in icon.png icon-caution.png; do
  [[ -f "$WORKFLOW_DIR/$asset" ]] || fail "$asset is missing from the workflow bundle"
  pass
done

# zsh aborts a script outright when a read-only parameter is assigned, and
# `zsh -n` does not catch it — `status` is $? and reads like an ordinary name.
# Ask zsh which parameters those are rather than maintaining a list by hand.
readonly_parameters=(${(f)"$(/bin/zsh -f -c 'typeset -r +')"})
(( ${#readonly_parameters} > 0 )) || fail "could not enumerate zsh read-only parameters"
pass
for source_file in \
  "$WORKFLOW_DIR/bin/menu" "$WORKFLOW_DIR/bin/action" "$WORKFLOW_DIR/bin/common.zsh" \
  "$ROOT_DIR/scripts/build.zsh" "$ROOT_DIR/scripts/verify-modes.zsh" \
  "$ROOT_DIR/tests/run.zsh" "$ROOT_DIR/tests/package.zsh"; do
  for parameter in "${readonly_parameters[@]}"; do
    [[ "$parameter" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || continue
    if /usr/bin/grep -nE "^[[:space:]]*((local|typeset|declare|export)([[:space:]]+-[A-Za-z]+)*[[:space:]]+)?${parameter}=" \
      "$source_file" >/dev/null; then
      fail "${source_file:t} assigns to zsh's read-only parameter '$parameter'"
    fi
  done
  pass
done

# The reporting half of verify-modes.zsh is otherwise reachable only after a
# password and three interactive prompts, which is exactly where a bug hides.
"$ROOT_DIR/scripts/verify-modes.zsh" --self-test "$temporary_dir/verify-modes" >/dev/null || \
  fail "scripts/verify-modes.zsh --self-test failed"
pass

# Every entry point must be immune to the user's zsh startup files: a stray
# `setopt` in ~/.zshenv would otherwise change how these behave.
for zsh_source in "${zsh_sources[@]}"; do
  head_line=$(/usr/bin/head -1 "$zsh_source")
  assert_equal '#!/bin/zsh -f' "$head_line" "${zsh_source:t} must ignore zsh rc files"
done

# --- info.plist wiring -----------------------------------------------------

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $1" "$WORKFLOW_DIR/info.plist"
}

script_filter_uid=$(plist_value ':objects:0:uid')
action_uid=$(plist_value ':objects:1:uid')
notification_uid=$(plist_value ':objects:2:uid')
[[ "$script_filter_uid" != "$action_uid" && "$script_filter_uid" != "$notification_uid" && "$action_uid" != "$notification_uid" ]] || \
  fail "workflow object UIDs must be unique"
pass

assert_equal "$action_uid" "$(plist_value ":connections:${script_filter_uid}:0:destinationuid")" \
  "Script Filter is not connected to the action"
assert_equal "$notification_uid" "$(plist_value ":connections:${action_uid}:0:destinationuid")" \
  "action is not connected to the notification"

# The keyword is useless if it references a variable the configuration does not
# define; both sides pass plutil -lint independently.
configured_variable=$(plist_value ':userconfigurationconfig:0:variable')
assert_equal "{var:$configured_variable}" "$(plist_value ':objects:0:config:keyword')" \
  "the Script Filter keyword does not reference the configured variable"
assert_equal "true" "$(plist_value ':userconfigurationconfig:0:config:required')" \
  "the keyword must be required, or clearing it leaves no way into the workflow"
keyword_default=$(plist_value ':userconfigurationconfig:0:config:default')
(( ${#keyword_default} >= 3 )) || fail "the default keyword should be at least three characters"
pass

# Alfred executes whatever scriptfile the plist names, not what the test knows.
for object_index in 0 1; do
  script_file=$(plist_value ":objects:${object_index}:config:scriptfile")
  [[ -x "$WORKFLOW_DIR/$script_file" ]] || fail "info.plist references a missing or non-executable scriptfile: $script_file"
  pass
done

assert_equal "true" "$(plist_value ':objects:0:config:skipuniversalaction')" \
  "the firewall keyword must not be offered as a universal action"
assert_equal "0" "$(plist_value ':objects:0:config:alfredfiltersresultsmatchmode')" \
  "result matching should be exact-from-start, not loose word matching"
assert_equal "Little Snitch Control" "$(plist_value ':objects:2:config:title')" \
  "notifications must be attributable to this workflow, not to Little Snitch"
assert_contains "$(plist_value ':webaddress')" "github.com" "webaddress should point at the project"

# --- common.zsh: version policy -------------------------------------------

source "$WORKFLOW_DIR/bin/common.zsh"

assert_equal "$LSCTL_BUNDLE_ID" "$(plist_value ':bundleid')" "info.plist and cache bundle IDs differ"

for supported in 6.2 6.3 6.4 6.4.1 6.5 6.5.0 6.10.2 6.4.1.2; do
  lsctl_is_supported_version "$supported" || fail "supported Little Snitch version rejected: $supported"
  pass
done
for refused in 5.9.9 7.0.0 6.1 6.1.3 6 "" "6.x" "6.4.1 (7212)" $'6.4.1\ninjected=true'; do
  if lsctl_is_supported_version "$refused"; then
    fail "unsupported version accepted: ${refused:-<empty>}"
  fi
  pass
done

# Two-component releases exist (6.2, 6.3, 6.4). A three-component predicate
# would refuse them and, through lsctl_write_cache, break caching permanently.
for two_component in 6.2 6.3 6.4; do
  lsctl_is_version "$two_component" || fail "lsctl_is_version rejected a real release string: $two_component"
  pass
done

# Newer-than-tested must be a label, never a refusal.
lsctl_is_untested_version "6.5" || fail "6.5 should be flagged as untested"
pass
if lsctl_is_untested_version "6.4.1"; then
  fail "6.4.1 is tested and must not be flagged"
fi
pass

for output_probe in "Version 6.4.1:6.4.1" "Version 6.4:6.4" "Version 6.4.1 (7212):6.4.1"; do
  assert_equal "${output_probe##*:}" "$(lsctl_version_from_output "${output_probe%%:*}")" \
    "version extraction failed for '${output_probe%%:*}'"
done
if lsctl_version_from_output "no digits here" >/dev/null 2>&1; then
  fail "version extraction accepted output with no version"
fi
pass

# --- common.zsh: JSON encoding --------------------------------------------

json_probe_dir="$temporary_dir/json"
/bin/mkdir -p "$json_probe_dir"
probe_index=0
for probe in 'plain' 'has "quote"' 'has \back' $'tab\there' $'form\ffeed' $'esc\x1bhere' $'soh\x01here' 'ünïcode ·'; do
  probe_file="$json_probe_dir/probe.$probe_index.json"
  /usr/bin/printf '{"value":%s}\n' "$(lsctl_json_string "$probe")" > "$probe_file"
  /usr/bin/plutil -convert xml1 -o /dev/null "$probe_file" 2>/dev/null || fail "lsctl_json_string produced invalid JSON for probe $probe_index"
  pass

  # Validity is not the property that matters -- fidelity is. Asserting only
  # that the document parses passes a stub that discards its input, and misses
  # every regression that produces valid but WRONG JSON: dropping the \u00XX
  # escaping of control characters, mangling multi-byte UTF-8 in the
  # per-character rebuild, or double-escaping a backslash.
  assert_equal "$probe" "$(/usr/bin/plutil -extract value raw -o - "$probe_file")" \
    "lsctl_json_string did not round-trip probe $probe_index"

  probe_index=$(( probe_index + 1 ))
done

# --- common.zsh: cache trust ----------------------------------------------

cache_dir="$temporary_dir/cache"
alfred_workflow_cache="$cache_dir"
current_uid=$(/usr/bin/id -u)
lsctl_write_cache "0" "true" "6.4.1" "$current_uid" "$(/bin/date +%s)" || fail "could not create test cache"
pass
lsctl_read_cache "$cache_dir/state" "$current_uid" || fail "a cache written by lsctl_write_cache was rejected"
assert_equal "0" "$LSCTL_STATE_MODE" "cache round-trip lost the mode"
assert_equal "6.4.1" "$LSCTL_STATE_VERSION" "cache round-trip lost the version"

write_raw_cache() {
  /usr/bin/printf '%s' "$1" > "$cache_dir/state"
  /bin/chmod 600 "$cache_dir/state"
}
good_cache="schema=1
uid=$current_uid
mode=0
filter=true
version=6.4.1
verified_at=1700000000
"
reject_cache() {
  local body="$1" message="$2"
  write_raw_cache "$body"
  if lsctl_read_cache "$cache_dir/state" "$current_uid"; then
    fail "$message"
  fi
  pass
  # A rejected read must not leave a previous read's values visible.
  assert_equal "" "$LSCTL_STATE_MODE" "rejected cache left stale state behind ($message)"
}

reject_cache "${good_cache/schema=1/schema=2}" "a cache with an unknown schema was trusted"
reject_cache "${good_cache}surprise=1
" "a cache with an unknown key was trusted"
reject_cache "${good_cache/mode=0/mode=9}" "a cache with an out-of-range mode was trusted"
reject_cache "${good_cache/filter=true/filter=maybe}" "a cache with a non-boolean filter was trusted"
reject_cache "${good_cache/version=6.4.1/version=six}" "a cache with a malformed version was trusted"
reject_cache "${good_cache/verified_at=1700000000/verified_at=99999999999999999999}" \
  "a cache with an unbounded timestamp was trusted"
reject_cache "${good_cache%$'\n'}" "a truncated final record was trusted"

write_raw_cache "$good_cache"
/bin/chmod 644 "$cache_dir/state"
if lsctl_read_cache "$cache_dir/state" "$current_uid"; then
  fail "a world-readable cache was trusted"
fi
pass
/bin/chmod 600 "$cache_dir/state"

if lsctl_read_cache "$cache_dir/state" "$(( current_uid + 1 ))"; then
  fail "a cache belonging to another user was trusted"
fi
pass

/bin/rm -f "$cache_dir/state"
/bin/ln -s /etc/hosts "$cache_dir/state"
if lsctl_read_cache "$cache_dir/state" "$current_uid"; then
  fail "a symlinked cache file was trusted"
fi
pass
/bin/rm -f "$cache_dir/state"

# A symlinked cache directory must be refused rather than adopted and chmod'ed.
victim_dir="$temporary_dir/victim"
/bin/mkdir -p "$victim_dir"
/bin/chmod 755 "$victim_dir"
/bin/ln -s "$victim_dir" "$temporary_dir/linked-cache"
if lsctl_prepare_cache_dir "$temporary_dir/linked-cache"; then
  fail "a symlinked cache directory was accepted"
fi
pass
assert_equal "755" "$(/usr/bin/stat -f '%Lp' "$victim_dir")" "a symlinked cache directory had its target's mode changed"

# --- common.zsh: the privileged readback shape ------------------------------
#
# This predicate is the only thing standing between an unexpected privileged
# result and a cached "success". Its previous form screened for a literal
# newline, which `do shell script` never emits — it returns AppleScript text,
# where a line break arrives as CR.

readback_accept=( "0|true" "0|false" "1|true" "2|false" )
for readback_case in "${readback_accept[@]}"; do
  lsctl_is_readback "$readback_case" || fail "a legal readback '$readback_case' was rejected"
  pass
done

readback_reject=(
  "0|true "
  " 0|true"
  "0|true|extra"
  "3|true"
  "0|maybe"
  "0"
  "|true"
  "0|TRUE"
  "*|*"
  $'0|true\r0|true'
  $'0|true\n0|true'
  $'0|true\r'
  ""
)
for readback_case in "${readback_reject[@]}"; do
  if lsctl_is_readback "$readback_case" ; then
    fail "an illegal readback ${(qqq)readback_case} was accepted"
  fi
  pass
done

# Sourcing twice in one shell must stay a no-op rather than aborting on the
# readonly declarations.
/bin/zsh -f -c "source ${(q)WORKFLOW_DIR}/bin/common.zsh; source ${(q)WORKFLOW_DIR}/bin/common.zsh" 2>/dev/null || \
  fail "sourcing common.zsh twice aborted"
pass

# --- common.zsh: locking ---------------------------------------------------
#
# The lock is a kernel advisory lock (zsystem flock). What matters is that a
# second *process* is refused while a first holds it, and that the kernel frees
# it when a holder dies without running any trap.

in_child() {
  /bin/zsh -f -c "source ${(q)WORKFLOW_DIR}/bin/common.zsh; $1"
}

lock_file="$temporary_dir/action.lock"
lsctl_acquire_lock "$lock_file" || fail "a free lock could not be acquired"
pass

if in_child "lsctl_acquire_lock ${(q)lock_file}"; then
  fail "a held lock was acquired by a second process"
fi
pass

# One process holds at most one lock: the kernel would grant a second flock on
# a new descriptor within the same process, which would leak the first.
if lsctl_acquire_lock "$lock_file"; then
  fail "the same process acquired the lock twice"
fi
pass

# fcntl locks are released when the process closes ANY descriptor to the file,
# so a re-entry attempt that reopened the path before being refused would
# silently drop the lock it was protecting.
if in_child "lsctl_acquire_lock ${(q)lock_file}"; then
  fail "a refused re-entry attempt released the lock"
fi
pass

lsctl_release_lock || fail "the lock owner could not release its own lock"
pass

in_child "lsctl_acquire_lock ${(q)lock_file}" || fail "a released lock could not be re-acquired"
pass

# A holder killed with SIGKILL runs no trap. The kernel must still release it,
# which is the whole reason this is not a PID file.
killed_child=$(in_child "lsctl_acquire_lock ${(q)lock_file} && print HELD; kill -9 \$\$" 2>/dev/null || true)
assert_equal "HELD" "$killed_child" "the SIGKILL fixture never acquired the lock, so the next assertion proves nothing"
lsctl_acquire_lock "$lock_file" || fail "a SIGKILLed holder's lock was not released by the kernel"
pass
lsctl_release_lock

# Releases before 0.3.0 created a directory at this path. An upgrade must not
# deadlock on the leftover.
legacy_lock="$temporary_dir/legacy.lock"
/bin/mkdir -m 700 "$legacy_lock"
/usr/bin/printf '%s\n' '99999999' > "$legacy_lock/pid"
lsctl_acquire_lock "$legacy_lock" || fail "a leftover directory lock was not replaced"
pass
[[ -f "$legacy_lock" && ! -d "$legacy_lock" ]] || fail "the legacy lock directory was not replaced by a lock file"
pass
lsctl_release_lock

# A symlink at the lock path must never be followed.
symlinked_lock="$temporary_dir/symlink.lock"
/bin/ln -s "$temporary_dir/lock-target" "$symlinked_lock"
if lsctl_acquire_lock "$symlinked_lock"; then
  fail "a symlinked lock path was accepted"
fi
pass
[[ ! -e "$temporary_dir/lock-target" ]] || fail "a symlinked lock path created its target"
pass

# --- the privileged action map --------------------------------------------

/usr/bin/osacompile -o "$temporary_dir/authorize.scpt" \
  "$WORKFLOW_DIR/bin/authorize.applescript" || fail "authorization AppleScript does not compile"
pass

invalid_authorizer_output=$(/usr/bin/osascript "$temporary_dir/authorize.scpt" unsupported.action --dry-run 2>&1) && \
  fail "authorization script accepted an unknown action"
assert_contains "$invalid_authorizer_output" "Unsupported action" \
  "authorization script did not reject unknown input before execution"

invalid_option_output=$(/usr/bin/osascript "$temporary_dir/authorize.scpt" refresh --bogus 2>&1) && \
  fail "authorization script accepted an unknown option"
assert_contains "$invalid_option_output" "Unsupported option" "unknown options must be rejected"

# Assert the map per action rather than grepping the source for five literals,
# which would still pass if two of them were swapped.
dry_run() {
  /usr/bin/osascript "$temporary_dir/authorize.scpt" "$1" --dry-run
}

typeset -A expected_writes
expected_writes=(
  "mode.alert"        "'write-preference' 'activeSilentMode' '0'"
  "mode.silent-allow" "'write-preference' 'activeSilentMode' '1'"
  "mode.silent-deny"  "'write-preference' 'activeSilentMode' '2'"
  "filter.enable"     "'write-preference' 'networkFilterEnabled' 'true'"
  "filter.disable"    "'write-preference' 'networkFilterEnabled' 'false'"
)
for action_id in "${(@k)expected_writes}"; do
  rendered=$(dry_run "$action_id")
  assert_contains "$rendered" "${expected_writes[$action_id]}" \
    "$action_id does not write the preference it claims to"
  for other_id in "${(@k)expected_writes}"; do
    [[ "$other_id" == "$action_id" ]] && continue
    assert_not_contains "$rendered" "${expected_writes[$other_id]}" \
      "$action_id also emits the write belonging to $other_id"
  done
done

refresh_rendered=$(dry_run refresh)
assert_not_contains "$refresh_rendered" "write-preference" "refresh must not write any preference"
assert_contains "$refresh_rendered" "'read-preference' 'activeSilentMode'" "refresh must read the mode"
assert_contains "$refresh_rendered" "'read-preference' 'networkFilterEnabled'" "refresh must read the filter"

# Integrity properties of the generated root shell.
assert_contains "$refresh_rendered" "codesign --verify --strict -R" \
  "the privileged path must verify the signature, not just read its metadata"
assert_not_contains "$refresh_rendered" "codesign -dv" \
  "signature metadata is forgeable and must not be the check"
assert_contains "$refresh_rendered" "unset GREP_OPTIONS" \
  "the root shell must not inherit GREP_OPTIONS, which would disable every grep-based gate"
assert_contains "$refresh_rendered" "check_cli; mode=\$(" \
  "each privileged read must be preceded by an integrity check"
assert_contains "$refresh_rendered" "MLZF7K7B5R" "the signing team must be pinned"
# The two version predicates must agree. The unprivileged one decides which
# actions the menu offers; the privileged one decides whether the elevated
# shell will run them. If the privileged side is the stricter of the two, the
# user approves an administrator prompt and is refused only afterwards -- for
# every action, forever. This used to be guarded by a literal search for one
# spelling of an upper bound, which could never fail and would not have caught
# a bound written any other way.
count_occurrences() {
  # grep -c counts matching LINES, and the rendered root shell is a single
  # line, so it reports 1 no matter how many times the needle appears.
  /usr/bin/printf '%s' "$2" | /usr/bin/grep -o -- "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' '
}

assert_equal "1" "$(count_occurrences "grep -Eq" "$refresh_rendered")" \
  "the rendered root shell must contain exactly one grep -Eq, or the extraction below picks the wrong one"
pass
if [[ "$refresh_rendered" =~ "grep -Eq '([^']+)'" ]]; then
  privileged_version_pattern="${match[1]}"
else
  fail "could not extract the privileged version pattern from the rendered root shell"
fi
pass

typeset -a version_table
version_table=(
  "Version 6.2"        "6.2"
  "Version 6.3"        "6.3"
  "Version 6.4"        "6.4"
  "Version 6.4.1"      "6.4.1"
  "Version 6.5"        "6.5"
  "Version 6.5 (7012)" "6.5"
  "Version 6.5.beta"   "6.5"
  "Version 6.10.2"     "6.10.2"
  "Version 6.1"        "6.1"
  "Version 6.0.4"      "6.0.4"
  "Version 7.0"        "7.0"
  "Version 5.9.9"      "5.9.9"
)
(( ${#version_table} % 2 == 0 )) || fail "version_table is not a list of pairs"
pass
for (( version_index = 1; version_index < ${#version_table}; version_index += 2 )); do
  version_raw="${version_table[version_index]}"
  version_parsed="${version_table[version_index + 1]}"

  assert_equal "$version_parsed" "$(lsctl_version_from_output "$version_raw")" \
    "the unprivileged parser misreads '$version_raw'"

  if lsctl_is_supported_version "$version_parsed"; then
    /usr/bin/printf '%s\n' "$version_raw" | /usr/bin/grep -Eq "$privileged_version_pattern" || \
      fail "the menu offers actions for '$version_raw' but the privileged gate refuses it"
  else
    if /usr/bin/printf '%s\n' "$version_raw" | /usr/bin/grep -Eq "$privileged_version_pattern"; then
      fail "the privileged gate accepts '$version_raw', which this workflow does not support"
    fi
  fi
  pass
done

# The user ID must be derived inside the privileged script, never accepted from
# the caller. Assert the OBSERVABLE property: the rendered command carries this
# process's uid, exactly once. The previous guard searched the source for the
# phrase "item 2 of argv as numericUser", which is not valid AppleScript for
# the bug it describes and has never appeared in the file -- so it was a
# permanent no-op, and the realistic regression (`set numericUser to item 2 of
# argv`) passed it. argv item 2 is already consumed for --dry-run, so the two
# are one edit apart.
assert_equal "2" "$(count_occurrences "'-u' '$(/usr/bin/id -u)'" "$refresh_rendered")" \
  "the privileged command must carry this process's own uid, once per read-preference call"

for forged_uid in 0 1 501000; do
  [[ "$forged_uid" == "$(/usr/bin/id -u)" ]] && continue
  assert_not_contains "$refresh_rendered" "'-u' '$forged_uid'" \
    "the rendered command must not carry a uid this process did not derive"
done

# --- bin/action ------------------------------------------------------------

malicious_marker="$temporary_dir/action-should-not-run"
malicious_output=$("$WORKFLOW_DIR/bin/action" "mode.alert; /usr/bin/touch $malicious_marker" 2>/dev/null)
assert_equal "Little Snitch Control failed — Unknown action — no Little Snitch setting was changed." \
  "$malicious_output" "unknown action was not rejected"
[[ ! -e "$malicious_marker" ]] || fail "unknown action caused command execution"
pass

multi_argument_output=$("$WORKFLOW_DIR/bin/action" refresh extra 2>/dev/null)
assert_equal "Little Snitch Control failed — Unknown action — no Little Snitch setting was changed." "$multi_argument_output" \
  "extra arguments were not rejected"

# Failures must reach Alfred's debugger, not only the notification.
malicious_stderr=$("$WORKFLOW_DIR/bin/action" nonsense.action 2>&1 >/dev/null)
assert_contains "$malicious_stderr" "little-snitch-control:" "failures must be mirrored to stderr"

# --- bin/menu --------------------------------------------------------------

mock_cli="$temporary_dir/littlesnitch"
make_mock() {
  /usr/bin/printf '%s\n' \
    '#!/bin/zsh' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    "  print -r -- \"Version $1\"" \
    '  exit 0' \
    'fi' \
    'exit 64' > "$mock_cli"
  /bin/chmod 755 "$mock_cli"
}
write_mock() {
  {
    /usr/bin/printf '#!/bin/zsh\n'
    /usr/bin/printf 'if [[ "${1:-}" == "--version" ]]; then\n'
    /usr/bin/printf '  print -r -- "Version %s"\n' "$1"
    /usr/bin/printf '  exit 0\n'
    /usr/bin/printf 'fi\n'
    /usr/bin/printf 'exit 64\n'
  } > "$mock_cli"
  /bin/chmod 755 "$mock_cli"
}

render_menu() {
  local output="$1"
  alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$mock_cli" \
    "$WORKFLOW_DIR/bin/menu" > "$output"
  /usr/bin/plutil -convert xml1 -o /dev/null "$output" 2>/dev/null || fail "menu output is not valid JSON: $output"
  pass
}

item_index_by_uid() {
  local json="$1" wanted="$2" index=0 uid
  while uid=$(/usr/bin/plutil -extract "items.$index.uid" raw "$json" 2>/dev/null); do
    [[ "$uid" == "$wanted" ]] && { print -r -- "$index"; return 0; }
    index=$(( index + 1 ))
  done
  return 1
}

item_field() {
  local json="$1" uid="$2" field="$3" index
  index=$(item_index_by_uid "$json" "$uid") || fail "no menu row with uid '$uid' in $json"
  /usr/bin/plutil -extract "items.$index.$field" raw "$json" 2>/dev/null
}

missing_json="$temporary_dir/missing.json"
alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$temporary_dir/does-not-exist" \
  "$WORKFLOW_DIR/bin/menu" > "$missing_json"
/usr/bin/plutil -convert xml1 -o /dev/null "$missing_json" 2>/dev/null || fail "missing-app menu is not JSON"
pass
assert_equal "Little Snitch Not Found" "$(item_field "$missing_json" status-missing title)" \
  "missing-app state was not rendered"
assert_equal "open.download" "$(item_field "$missing_json" open-download arg)" \
  "missing-app state offers no way forward"

write_mock "5.9.9"
unsupported_json="$temporary_dir/unsupported.json"
render_menu "$unsupported_json"
assert_equal "Unsupported Little Snitch Version" "$(item_field "$unsupported_json" status-unsupported title)" \
  "an unsupported major version was not refused"

write_mock "6.4.1"
lsctl_write_cache "0" "true" "6.4.1" "$current_uid" "$(/bin/date +%s)" >/dev/null
menu_json="$temporary_dir/menu.json"
render_menu "$menu_json"

# The source-once guard must not be forgeable from the environment. It used to
# test a variable, so exporting LSCTL_COMMON_LOADED=1 turned the whole library
# into a no-op and bin/menu emitted malformed JSON with no error at all.
forged_guard_json="$temporary_dir/forged-guard.json"
LSCTL_COMMON_LOADED=1 alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$mock_cli" \
  "$WORKFLOW_DIR/bin/menu" > "$forged_guard_json"
/usr/bin/plutil -convert xml1 -o /dev/null "$forged_guard_json" 2>/dev/null || \
  fail "an inherited LSCTL_COMMON_LOADED disabled common.zsh and the menu emitted invalid JSON"
pass

assert_equal "Filter: On · Mode: Alert Mode" "$(item_field "$menu_json" status title)" \
  "cached state was not rendered"
assert_equal "refresh" "$(item_field "$menu_json" status arg)" \
  "the status row should refresh on Return rather than doing nothing"

# The gate on the three firewall-weakening rows. Without these assertions a
# one-character change arms plain Return on Disable Network Filter and the
# whole suite still passes.
for gated_uid in mode-silent-allow mode-silent-deny filter-off; do
  assert_equal "false" "$(item_field "$menu_json" "$gated_uid" valid)" \
    "$gated_uid must not be actionable with plain Return"
  assert_equal "true" "$(item_field "$menu_json" "$gated_uid" mods.cmd.valid)" \
    "$gated_uid must be actionable with Command-Return"
  [[ -n "$(item_field "$menu_json" "$gated_uid" autocomplete)" ]] || \
    fail "$gated_uid needs an autocomplete value so plain Return is visibly inert"
  pass
  assert_contains "$(item_field "$menu_json" "$gated_uid" title)" "⌘↩" \
    "$gated_uid must state its modifier in the title"
  assert_equal "icon-caution.png" "$(item_field "$menu_json" "$gated_uid" icon.path)" \
    "$gated_uid should be visually distinct from safe rows"
done

assert_equal "mode.silent-allow" "$(item_field "$menu_json" mode-silent-allow mods.cmd.arg)" \
  "Silent Allow passes the wrong argument"
assert_equal "mode.silent-deny" "$(item_field "$menu_json" mode-silent-deny mods.cmd.arg)" \
  "Silent Deny passes the wrong argument"
assert_equal "filter.disable" "$(item_field "$menu_json" filter-off mods.cmd.arg)" \
  "Filter Off passes the wrong argument"

# Re-applying a safer state must stay possible even when the cache says it is
# already active, because the cache may be stale.
assert_equal "true" "$(item_field "$menu_json" mode-alert valid)" \
  "re-applying Alert Mode must remain possible"
assert_equal "true" "$(item_field "$menu_json" filter-on valid)" \
  "re-enabling the Network Filter must remain possible"
assert_contains "$(item_field "$menu_json" mode-alert title)" "✓" \
  "the active mode should be marked"

# Every word a user can see in a title must be searchable, because `match`
# replaces title matching entirely.
for row_uid in status refresh mode-alert mode-silent-allow mode-silent-deny filter-on filter-off open-app open-help; do
  row_title=$(item_field "$menu_json" "$row_uid" title)
  row_match=$(item_field "$menu_json" "$row_uid" match)
  for word in ${(z)row_title}; do
    word="${word//[^a-zA-Z]/}"
    [[ -z "$word" ]] && continue
    if [[ "${row_match:l}" != *"${word:l}"* ]]; then
      fail "row '$row_uid' shows the word '$word' but does not match on it"
    fi
  done
  pass
done

# A Little Snitch release newer than this workflow was tested against must be
# labelled, never refused: a hard upper bound would break every installation on
# the day Objective Development ships a new minor version.
write_mock "6.9"
lsctl_write_cache "0" "true" "6.9" "$current_uid" "$(/bin/date +%s)" >/dev/null
untested_json="$temporary_dir/untested.json"
render_menu "$untested_json"
assert_contains "$(item_field "$untested_json" status subtitle)" "untested" \
  "a newer-than-tested version should be labelled in the status row"
item_index_by_uid "$untested_json" mode-silent-deny >/dev/null || \
  fail "a newer-than-tested version must still render the full menu"
pass
assert_equal "filter.disable" "$(item_field "$untested_json" filter-off mods.cmd.arg)" \
  "a newer-than-tested version must keep its actions available"

write_mock "6.4.1"
lsctl_write_cache "0" "true" "6.3.0" "$current_uid" "$(/bin/date +%s)" >/dev/null
version_mismatch_json="$temporary_dir/version-mismatch.json"
render_menu "$version_mismatch_json"
assert_equal "Filter: Unknown · Mode: Unknown" "$(item_field "$version_mismatch_json" status-unknown title)" \
  "version-mismatched cache was trusted"
assert_contains "$(item_field "$version_mismatch_json" status-unknown subtitle)" "6.4.1" \
  "a Little Snitch upgrade should be explained in the status row"


# --- first-run guidance and failure reporting ------------------------------

# Nothing unprivileged can detect whether "Allow access via Terminal" is on,
# because reading any preference is itself privileged. On a first run the menu
# must therefore say so up front, rather than letting an administrator password
# prompt be the thing that delivers the setup instruction.
write_mock "6.4.1"
first_run_cache="$temporary_dir/first-run-cache"
/bin/mkdir -p "$first_run_cache"
first_run_json="$temporary_dir/first-run.json"
alfred_workflow_cache="$first_run_cache" LSCTL_TESTING=1 LSCTL_TEST_CLI="$mock_cli" \
  "$WORKFLOW_DIR/bin/menu" > "$first_run_json"
/usr/bin/plutil -convert xml1 -o /dev/null "$first_run_json" 2>/dev/null || \
  fail "the first-run menu is not valid JSON"
pass
assert_contains "$(item_field "$first_run_json" setup-required title)" "Allow access via Terminal" \
  "a first run must name the prerequisite it cannot detect"
assert_equal "icon-caution.png" "$(item_field "$first_run_json" setup-required icon.path)" \
  "the setup row must carry the caution icon"
assert_equal "0" "$(item_index_by_uid "$first_run_json" setup-required)" \
  "the setup row must come before the unknown-status row"

# Once state has been verified the row is gone: it is first-run guidance, not a
# permanent warning.
lsctl_write_cache "0" "true" "6.4.1" "$current_uid" "$(/bin/date +%s)" >/dev/null
verified_json="$temporary_dir/verified.json"
render_menu "$verified_json"
if item_index_by_uid "$verified_json" setup-required >/dev/null 2>&1; then
  fail "the setup row survived a verified refresh"
fi
pass

# A failure and a success must not read alike, and no path may be silent: the
# notification object shows nothing for empty input, so a script that dies
# before printing gives no feedback at all after an administrator password.
failure_output=$("$WORKFLOW_DIR/bin/action" not.an.action 2>/dev/null)
assert_contains "$failure_output" "failed" "a refusal must be distinguishable from a success"
pass

silent_output=$(/bin/zsh -f -c "
  source ${(q)WORKFLOW_DIR}/bin/common.zsh
  LSCTL_SPOKE=0
  report_silent_exit() { [[ \"\$LSCTL_SPOKE\" == 1 ]] && return; print -r -- 'Little Snitch Control failed unexpectedly'; }
  trap report_silent_exit EXIT
  exit 3
" 2>/dev/null || true)
assert_contains "$silent_output" "failed unexpectedly" \
  "an abort before any output must still produce a notification"


# --- the menu/action argument contract -------------------------------------
#
# bin/menu emits action identifiers; bin/action accepts them in a dispatch that
# now reads the same LSCTL_ACTIONS list. Asserting the two sets separately let
# open.app and open.help drift with no coverage at all: a typo on either side
# produced "Unknown action - no Little Snitch setting was changed" at runtime
# while the whole suite stayed green. These identifiers are NOT exercised by
# invoking bin/action, because open.* really do call /usr/bin/open.

typeset -A rendered_actions

collect_actions() {
  local json="$1" index=0 value
  while value=$(/usr/bin/plutil -extract "items.$index.uid" raw "$json" 2>/dev/null); do
    for field in "items.$index.arg" "items.$index.mods.cmd.arg"; do
      if value=$(/usr/bin/plutil -extract "$field" raw "$json" 2>/dev/null); then
        [[ -n "$value" ]] && rendered_actions[$value]=1
      fi
    done
    index=$(( index + 1 ))
  done
}

# Every terminal state of the menu, so no reachable row is missed.
write_mock "6.4.1"
contract_normal="$temporary_dir/contract-normal.json"
render_menu "$contract_normal"
collect_actions "$contract_normal"

contract_missing="$temporary_dir/contract-missing.json"
alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$temporary_dir/does-not-exist" \
  "$WORKFLOW_DIR/bin/menu" > "$contract_missing"
collect_actions "$contract_missing"

write_mock "5.9.9"
contract_unsupported="$temporary_dir/contract-unsupported.json"
render_menu "$contract_unsupported"
collect_actions "$contract_unsupported"

# A CLI that runs but reports nothing parseable. This is the state a user is in
# when Little Snitch is installed and "Allow access via Terminal" is off, which
# is the single most common support case -- and it had no coverage.
unreadable_cli="$temporary_dir/unreadable-cli"
/usr/bin/printf '#!/bin/zsh\nprint -r -- "no digits here"\nexit 0\n' > "$unreadable_cli"
/bin/chmod 755 "$unreadable_cli"
contract_unreadable="$temporary_dir/contract-unreadable.json"
alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$unreadable_cli" \
  "$WORKFLOW_DIR/bin/menu" > "$contract_unreadable"
/usr/bin/plutil -convert xml1 -o /dev/null "$contract_unreadable" 2>/dev/null || \
  fail "the version-unreadable menu is not valid JSON"
pass
assert_equal "Little Snitch Version Unavailable" \
  "$(item_field "$contract_unreadable" status-unreadable title)" \
  "a CLI that reports no parseable version must say so"
assert_equal "open.help" "$(item_field "$contract_unreadable" open-help arg)" \
  "the version-unreadable state must offer a route to the setup help"
collect_actions "$contract_unreadable"

failing_cli="$temporary_dir/failing-cli"
/usr/bin/printf '#!/bin/zsh\nexit 1\n' > "$failing_cli"
/bin/chmod 755 "$failing_cli"
contract_failing="$temporary_dir/contract-failing.json"
alfred_workflow_cache="$cache_dir" LSCTL_TESTING=1 LSCTL_TEST_CLI="$failing_cli" \
  "$WORKFLOW_DIR/bin/menu" > "$contract_failing"
assert_equal "Little Snitch Version Unavailable" \
  "$(item_field "$contract_failing" status-unreadable title)" \
  "a CLI that exits non-zero must render the version-unavailable state"
collect_actions "$contract_failing"

# Nothing the menu emits may be outside the accepted list.
for emitted in "${(@k)rendered_actions}"; do
  lsctl_is_action "$emitted" || \
    fail "bin/menu emits '$emitted', which bin/action does not accept"
  pass
done

# ...and nothing in the accepted list may be unreachable from the menu.
for accepted in "${LSCTL_ACTIONS[@]}"; do
  (( ${+rendered_actions[$accepted]} )) || \
    fail "bin/action accepts '$accepted', which no menu row emits"
  pass
done

write_mock "6.4.1"

/usr/bin/printf 'All %d checks passed.\n' "$checks"
