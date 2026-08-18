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
/bin/zsh -n \
  "$WORKFLOW_DIR/bin/common.zsh" \
  "$WORKFLOW_DIR/bin/menu" \
  "$WORKFLOW_DIR/bin/action" || fail "a zsh source file has invalid syntax"
pass

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

# Every entry point must be immune to the user's zsh startup files.
for script_path in bin/menu bin/action bin/common.zsh; do
  head_line=$(/usr/bin/head -1 "$WORKFLOW_DIR/$script_path")
  assert_equal '#!/bin/zsh -f' "$head_line" "$script_path must ignore zsh rc files"
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

# --- common.zsh: locking ---------------------------------------------------

stale_lock="$temporary_dir/stale.lock"
/bin/mkdir -m 700 "$stale_lock"
/usr/bin/printf '%s\n' '99999999' > "$stale_lock/pid"
/bin/chmod 600 "$stale_lock/pid"
lsctl_acquire_lock "$stale_lock" "$$" || fail "dead-owner lock was not recovered"
pass
assert_equal "$$" "$(/bin/cat "$stale_lock/pid")" "recovered lock has the wrong owner PID"
if lsctl_acquire_lock "$stale_lock" "$$"; then
  fail "live lock was acquired twice"
fi
pass
if lsctl_release_lock "$stale_lock" "$(( $$ + 1 ))"; then
  fail "a lock was released by a process that does not own it"
fi
pass
lsctl_release_lock "$stale_lock" "$$" || fail "the lock owner could not release its own lock"
pass
[[ ! -d "$stale_lock" ]] || fail "the lock directory survived release"
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
assert_not_contains "$refresh_rendered" "6\\.(2|3|4)" \
  "the privileged version gate must not carry a hard upper bound"

# The user ID must be derived inside the privileged script, never accepted from
# the caller.
assert_not_contains "$(/bin/cat "$WORKFLOW_DIR/bin/authorize.applescript")" "item 2 of argv as numericUser" \
  "the user ID must not come from argv"
assert_contains "$(/bin/cat "$WORKFLOW_DIR/bin/authorize.applescript")" "id -u" \
  "the privileged script must derive the invoking user itself"

# --- bin/action ------------------------------------------------------------

malicious_marker="$temporary_dir/action-should-not-run"
malicious_output=$("$WORKFLOW_DIR/bin/action" "mode.alert; /usr/bin/touch $malicious_marker" 2>/dev/null)
assert_equal "Unknown action — no Little Snitch setting was changed." "$malicious_output" \
  "unknown action was not rejected"
[[ ! -e "$malicious_marker" ]] || fail "unknown action caused command execution"
pass

multi_argument_output=$("$WORKFLOW_DIR/bin/action" refresh extra 2>/dev/null)
assert_equal "Unknown action — no Little Snitch setting was changed." "$multi_argument_output" \
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

/usr/bin/printf 'All %d checks passed.\n' "$checks"
