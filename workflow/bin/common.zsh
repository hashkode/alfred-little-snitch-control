#!/bin/zsh -f

# Shared, unprivileged helpers. This file is never executed with administrator
# privileges. Sourcing it twice in one shell is a no-op.

[[ -n "${LSCTL_COMMON_LOADED:-}" ]] && return 0
typeset -gr LSCTL_COMMON_LOADED="1"

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

lsctl_create_lock() {
  local lock_dir="$1"
  local owner_pid="$2"

  /bin/mkdir -m 700 "$lock_dir" 2>/dev/null || return 1
  /usr/bin/printf '%s\n' "$owner_pid" > "$lock_dir/pid" || {
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    return 1
  }
  /bin/chmod 600 "$lock_dir/pid" || return 1
  return 0
}

lsctl_acquire_lock() {
  local lock_dir="$1"
  local owner_pid="$2"
  local lock_pid="" aside

  [[ "$owner_pid" == <-> && "$owner_pid" != "0" ]] || return 1

  lsctl_create_lock "$lock_dir" "$owner_pid" && return 0

  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
    IFS= read -r lock_pid < "$lock_dir/pid" || lock_pid=""
  fi

  if [[ "$lock_pid" == <-> && "$lock_pid" != "0" ]] && /bin/kill -0 "$lock_pid" 2>/dev/null; then
    return 1
  fi

  # Break a dead owner's lock by renaming it aside: rename is atomic, so a
  # racing process either wins the rename or fails it, and both then contend
  # for a fresh mkdir. Removing the directory in place could delete a lock
  # another process created in the meantime.
  aside="${lock_dir}.stale.$$"
  /bin/rm -rf -- "$aside" 2>/dev/null || true
  if /bin/mv "$lock_dir" "$aside" 2>/dev/null; then
    /bin/rm -rf -- "$aside" 2>/dev/null || true
  fi

  lsctl_create_lock "$lock_dir" "$owner_pid"
}

lsctl_release_lock() {
  local lock_dir="$1"
  local owner_pid="${2:-}"
  local lock_pid=""

  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 0

  if [[ -n "$owner_pid" ]]; then
    if [[ -f "$lock_dir/pid" && ! -L "$lock_dir/pid" ]]; then
      IFS= read -r lock_pid < "$lock_dir/pid" || lock_pid=""
    fi
    [[ -z "$lock_pid" || "$lock_pid" == "$owner_pid" ]] || return 1
  fi

  /bin/rm -f "$lock_dir/pid" 2>/dev/null || true
  /bin/rmdir "$lock_dir" 2>/dev/null || true
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
