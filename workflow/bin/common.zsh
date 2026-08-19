#!/bin/zsh -f

# Shared, unprivileged helpers. This file is never executed with administrator
# privileges. Sourcing it twice in one shell is a no-op.
#
# The re-entry guard tests for a function this file defines rather than a
# variable. A variable guard is settable from the environment, so exporting
# LSCTL_COMMON_LOADED=1 used to turn the whole library into a no-op, after
# which bin/menu emitted malformed JSON with no error. A function cannot be
# forged through the environment.

(( ${+functions[lsctl_json_string]} )) && return 0

typeset -gr LSCTL_CACHE_SCHEMA="1"
typeset -gr LSCTL_BUNDLE_ID="com.hashkode.alfred.little-snitch-control"

# Version policy. The workflow accepts any Little Snitch 6.2 or newer and
# refuses other majors, where the preference names are not known to exist.
# Anything past the tested maximum is labelled, never refused: a hard upper
# bound would brick every installation the day Objective Development ships a
# new minor release. The real gate is the readback validation in bin/action,
# which fails closed on values it does not recognise.
typeset -gr LSCTL_SUPPORTED_MAJOR="6"
typeset -gr LSCTL_MINIMUM_MINOR="2"
typeset -gr LSCTL_TESTED_MAX_MINOR="4"

typeset -g LSCTL_STATE_MODE=""
typeset -g LSCTL_STATE_FILTER=""
typeset -g LSCTL_STATE_VERSION=""
typeset -g LSCTL_STATE_VERIFIED_AT=""

lsctl_cache_dir() {
  if [[ -n "${alfred_workflow_cache:-}" ]]; then
    print -r -- "$alfred_workflow_cache"
  else
    print -r -- "${TMPDIR:-/tmp}/${LSCTL_BUNDLE_ID}.cache"
  fi
}

lsctl_cache_file() {
  print -r -- "$(lsctl_cache_dir)/state"
}

# Create or adopt the cache directory, refusing a symlink or a directory owned
# by anyone else. Without the symlink check, a planted link would have its
# target silently chmod'ed to 700 and used to hold workflow state.
lsctl_prepare_cache_dir() {
  local cache_dir="$1"
  local owner

  [[ -n "$cache_dir" && ! -L "$cache_dir" ]] || return 1

  if [[ ! -e "$cache_dir" ]]; then
    /bin/mkdir -p "$cache_dir" 2>/dev/null || return 1
  fi

  [[ -d "$cache_dir" && ! -L "$cache_dir" ]] || return 1

  owner=$(/usr/bin/stat -f '%u' "$cache_dir" 2>/dev/null) || return 1
  [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 1

  /bin/chmod 700 "$cache_dir" 2>/dev/null || return 1
}

lsctl_read_cache() {
  local cache_file="$1"
  local expected_uid="$2"
  local owner permissions key value
  local schema="" uid="" mode="" filter="" version="" verified_at=""

  # Always clear published state first, so a failed read can never leave a
  # previous call's values visible to the caller.
  LSCTL_STATE_MODE=""
  LSCTL_STATE_FILTER=""
  LSCTL_STATE_VERSION=""
  LSCTL_STATE_VERIFIED_AT=""

  [[ -f "$cache_file" && ! -L "$cache_file" ]] || return 1

  owner=$(/usr/bin/stat -f '%u' "$cache_file" 2>/dev/null) || return 1
  permissions=$(/usr/bin/stat -f '%Lp' "$cache_file" 2>/dev/null) || return 1
  [[ "$owner" == "$expected_uid" && "$permissions" == "600" ]] || return 1

  # A record with no trailing newline is deliberately dropped, which makes the
  # whole file fail validation below. lsctl_write_cache always writes complete,
  # newline-terminated records through a temporary file and an atomic rename,
  # so an unterminated final line means truncation or tampering, not a normal
  # write in progress. tests/run.zsh asserts such a file is rejected.
  while IFS='=' read -r key value; do
    case "$key" in
      schema) schema="$value" ;;
      uid) uid="$value" ;;
      mode) mode="$value" ;;
      filter) filter="$value" ;;
      version) version="$value" ;;
      verified_at) verified_at="$value" ;;
      *) return 1 ;;
    esac
  done < "$cache_file"

  [[ "$schema" == "$LSCTL_CACHE_SCHEMA" ]] || return 1
  [[ "$uid" == "$expected_uid" ]] || return 1
  [[ "$mode" == "0" || "$mode" == "1" || "$mode" == "2" ]] || return 1
  [[ "$filter" == "true" || "$filter" == "false" ]] || return 1
  lsctl_is_version "$version" || return 1
  lsctl_is_timestamp "$verified_at" || return 1

  LSCTL_STATE_MODE="$mode"
  LSCTL_STATE_FILTER="$filter"
  LSCTL_STATE_VERSION="$version"
  LSCTL_STATE_VERIFIED_AT="$verified_at"
  return 0
}

lsctl_write_cache() {
  local mode="$1"
  local filter="$2"
  local version="$3"
  local uid="$4"
  local verified_at="$5"
  local cache_dir cache_file temporary

  [[ "$mode" == "0" || "$mode" == "1" || "$mode" == "2" ]] || return 1
  [[ "$filter" == "true" || "$filter" == "false" ]] || return 1
  lsctl_is_version "$version" || return 1
  [[ "$uid" == <-> ]] || return 1
  lsctl_is_timestamp "$verified_at" || return 1

  cache_dir="$(lsctl_cache_dir)"
  cache_file="$cache_dir/state"
  lsctl_prepare_cache_dir "$cache_dir" || return 1

  temporary=$(/usr/bin/mktemp "$cache_dir/.state.XXXXXX") || return 1
  /bin/chmod 600 "$temporary" || {
    /bin/rm -f "$temporary"
    return 1
  }

  {
    /usr/bin/printf 'schema=%s\n' "$LSCTL_CACHE_SCHEMA"
    /usr/bin/printf 'uid=%s\n' "$uid"
    /usr/bin/printf 'mode=%s\n' "$mode"
    /usr/bin/printf 'filter=%s\n' "$filter"
    /usr/bin/printf 'version=%s\n' "$version"
    /usr/bin/printf 'verified_at=%s\n' "$verified_at"
  } > "$temporary" || {
    /bin/rm -f "$temporary"
    return 1
  }

  /bin/mv -f "$temporary" "$cache_file"
}

# A plausible epoch second. Bounded so a hand-edited cache cannot push
# lsctl_relative_age past zsh's integer range.
lsctl_is_timestamp() {
  [[ "$1" == <-> && ${#1} -le 12 ]]
}

# Accepts one to four numeric components. Little Snitch ships two-component
# releases (6.2, 6.3, 6.4) as well as three-component ones (6.4.1), so a
# three-component predicate would reject the versions this workflow supports.
lsctl_is_version() {
  [[ "$1" == <-> || "$1" == <->.<-> || "$1" == <->.<->.<-> || "$1" == <->.<->.<->.<-> ]]
}

lsctl_version_major() {
  lsctl_is_version "$1" || return 1
  print -r -- "${1%%.*}"
}

lsctl_version_minor() {
  local version="$1" minor
  lsctl_is_version "$version" || return 1
  if [[ "$version" == *.* ]]; then
    minor="${version#*.}"
    minor="${minor%%.*}"
  else
    minor="0"
  fi
  print -r -- "$minor"
}

# True only for the exact payload the privileged script is permitted to return.
# Matching the whole shape rejects CR, LF, whitespace, extra fields and
# out-of-range values in one predicate. `do shell script` hands its result back
# as AppleScript text, in which a line break arrives as CR, so screening for a
# literal newline could never have caught a multi-line payload.
lsctl_is_readback() {
  [[ "$1" == (0|1|2)"|"(true|false) ]]
}

lsctl_is_supported_version() {
  local version="$1" major minor
  major=$(lsctl_version_major "$version") || return 1
  minor=$(lsctl_version_minor "$version") || return 1
  (( 10#$major == 10#$LSCTL_SUPPORTED_MAJOR )) || return 1
  (( 10#$minor >= 10#$LSCTL_MINIMUM_MINOR ))
}

# True for a supported version newer than anything this release was tested
# against. Advisory only — it decorates a subtitle and never blocks an action.
lsctl_is_untested_version() {
  local version="$1" minor
  lsctl_is_supported_version "$version" || return 1
  minor=$(lsctl_version_minor "$version") || return 1
  (( 10#$minor > 10#$LSCTL_TESTED_MAX_MINOR ))
}

# Serialises privileged actions with a kernel advisory lock (zsystem flock,
# which is an fcntl record lock). The kernel drops it when the process exits,
# including on SIGKILL when no trap can run, so there is no stale-owner state.
#
# fcntl locks are owned by the PROCESS, not by a descriptor. Two consequences
# the code below depends on, and which any future edit must preserve:
#   * a second lock attempt from the same process is GRANTED, so re-entry has
#     to be refused explicitly;
#   * closing ANY descriptor to this path drops every lock the process holds on
#     it, so nothing may reopen the lock file after the lock is taken.
#
# This replaces a mkdir+PID-file scheme that could not break a dead owner's
# lock safely. Two processes that both observed the same dead PID would each
# rename the survivor aside: the second renamed away a lock the first had just
# legitimately created, after which both believed they held it and both went on
# to prompt for administrator authorisation and mutate the same preferences.
# There is no stale state to detect here, so that race cannot exist.
typeset -g LSCTL_LOCK_FD=""

lsctl_acquire_lock() {
  local lock_file="$1"
  local fd=""

  [[ -n "$lock_file" ]] || return 1
  zmodload -F zsh/system b:zsystem 2>/dev/null || return 1

  # The kernel grants a second flock on a new descriptor within the same
  # process, so re-entry has to be refused here. One process holds at most one
  # action lock; without this, a second call would silently leak the first
  # descriptor and the lock would outlive its release.
  [[ -z "$LSCTL_LOCK_FD" ]] || return 1

  # Releases before 0.3.0 created a directory at this path. Clear it so an
  # upgrade does not deadlock on a leftover that can never be opened as a file.
  # rmdir, never rm -rf: between the test above and the removal another process
  # may have migrated the path and taken the lock on a regular file, and rm -rf
  # would unlink that live lock and let both processes proceed. rmdir refuses a
  # regular file, so a late migrator falls through and is refused below.
  if [[ -d "$lock_file" && ! -L "$lock_file" ]]; then
    /bin/rm -f -- "$lock_file/pid" 2>/dev/null || true
    /bin/rmdir -- "$lock_file" 2>/dev/null || true
  fi

  # Refuse anything that is not a regular file. Opening a FIFO would block
  # forever; the directory lock this replaced failed cleanly instead.
  [[ ! -L "$lock_file" ]] || return 1
  [[ ! -e "$lock_file" || -f "$lock_file" ]] || return 1

  # The open and the chmod must both precede the flock: reopening this path
  # afterwards would release the lock (see the note above).
  ( : >>"$lock_file" ) 2>/dev/null || return 1
  /bin/chmod 600 "$lock_file" 2>/dev/null || return 1

  # -t 0 fails immediately rather than waiting: a second action must be
  # refused, never queued behind an authorisation dialog the user may ignore.
  zsystem flock -t 0 -f fd "$lock_file" 2>/dev/null || return 1

  LSCTL_LOCK_FD="$fd"
  return 0
}

# The lock file is never unlinked. Deleting it while another process holds the
# lock would let a third process create a new file at the same path and lock
# that one instead, defeating the exclusion.
lsctl_release_lock() {
  [[ -n "$LSCTL_LOCK_FD" ]] || return 0
  zsystem flock -u "$LSCTL_LOCK_FD" 2>/dev/null || true
  LSCTL_LOCK_FD=""
  return 0
}

lsctl_mode_label() {
  case "$1" in
    0) print -r -- "Alert Mode" ;;
    1) print -r -- "Silent Allow" ;;
    2) print -r -- "Silent Deny" ;;
    *) print -r -- "Unknown" ;;
  esac
}

lsctl_filter_label() {
  case "$1" in
    true) print -r -- "On" ;;
    false) print -r -- "Off" ;;
    *) print -r -- "Unknown" ;;
  esac
}

lsctl_relative_age() {
  local timestamp="$1"
  local now age

  lsctl_is_timestamp "$timestamp" || {
    print -r -- "at an unknown time"
    return
  }

  now=$(/bin/date +%s)
  age=$(( now - timestamp ))
  (( age < 0 )) && age=0

  if (( age < 60 )); then
    print -r -- "${age}s ago"
  elif (( age < 3600 )); then
    print -r -- "$(( age / 60 ))m ago"
  elif (( age < 86400 )); then
    print -r -- "$(( age / 3600 ))h ago"
  else
    print -r -- "$(( age / 86400 ))d ago"
  fi
}

# Emits a JSON string literal. Control characters without a short escape are
# encoded as \u00XX: an unescaped one makes Alfred reject the whole document,
# which surfaces as an empty result list with no error anywhere.
lsctl_json_string() {
  local value="$1"
  local rebuilt current
  local -i index

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"

  if [[ "$value" == *[[:cntrl:]]* ]]; then
    rebuilt=""
    for (( index = 1; index <= ${#value}; index++ )); do
      current="${value[index]}"
      if [[ "$current" == [[:cntrl:]] ]]; then
        rebuilt+="\\u$(/usr/bin/printf '%04x' "'$current")"
      else
        rebuilt+="$current"
      fi
    done
    value="$rebuilt"
  fi

  /usr/bin/printf '"%s"' "$value"
}

# Extracts a dotted numeric version from CLI output. A bare "${output#Version }"
# silently yields garbage if Objective Development ever changes the prefix or
# appends a build number; this fails cleanly instead.
lsctl_version_from_output() {
  local output="$1"
  [[ -n "$output" ]] || return 1
  if [[ "$output" =~ '([0-9]+(\.[0-9]+)*)' ]]; then
    print -r -- "${match[1]}"
    return 0
  fi
  return 1
}
