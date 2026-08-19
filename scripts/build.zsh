#!/bin/zsh -f

# Packages the workflow into a byte-reproducible .alfredworkflow archive.
#
# Reproducibility matters here because README.md tells people to verify the
# published checksum: if two builds of the same tree disagreed, a user could
# not distinguish "non-deterministic build" from "tampered release".

set -euo pipefail
umask 022

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr ROOT_DIR="${SCRIPT_DIR:h}"
typeset -gr WORKFLOW_DIR="$ROOT_DIR/workflow"
typeset -gr DIST_DIR="$ROOT_DIR/dist"

# ZIP cannot represent timestamps before 1980, so this is the earliest fixed
# value available.
typeset -gr FIXED_TIMESTAMP="198001010000"

abort() {
  /usr/bin/printf 'build: %s\n' "$1" >&2
  exit 1
}

version=$(/usr/libexec/PlistBuddy -c 'Print :version' "$WORKFLOW_DIR/info.plist")
[[ "$version" == <->.<->.<-> ]] || abort "invalid workflow version: $version"

/usr/bin/plutil -lint "$WORKFLOW_DIR/info.plist" >/dev/null

# The packaged manifest, declared once. The pre-flight checks, the staging
# copy, the mode fixing and the archive member list are all derived from it, so
# the archive is a function of the tracked tree rather than of whatever happens
# to be sitting in workflow/. Copying the directory wholesale shipped anything
# left there -- a .DS_Store, an editor swap file, a compiled authorize.scpt
# that .gitignore hides from git status -- which made the published checksum
# reproducible per working tree instead of per commit.
typeset -a WORKFLOW_EXECUTABLES WORKFLOW_DATA WORKFLOW_MANIFEST
WORKFLOW_EXECUTABLES=(bin/menu bin/action bin/common.zsh)
WORKFLOW_DATA=(bin/authorize.applescript info.plist icon.png icon-caution.png)
WORKFLOW_MANIFEST=("${WORKFLOW_EXECUTABLES[@]}" "${WORKFLOW_DATA[@]}")

for required in "${WORKFLOW_EXECUTABLES[@]}"; do
  [[ -x "$WORKFLOW_DIR/$required" ]] || abort "missing or non-executable: $required"
done
for required in "${WORKFLOW_DATA[@]}"; do
  [[ -f "$WORKFLOW_DIR/$required" ]] || abort "missing required file: $required"
done

# Refuse anything the manifest does not name, rather than silently shipping it.
for found in "${(@f)$(cd "$WORKFLOW_DIR" && /usr/bin/find . -type f -print | /usr/bin/sed 's|^\./||')}"; do
  [[ -n "$found" ]] || continue
  (( ${WORKFLOW_MANIFEST[(Ie)$found]} )) || abort "unexpected file in workflow/: $found"
done

if /usr/bin/find "$WORKFLOW_DIR" -type l -print | /usr/bin/grep -q .; then
  abort "the workflow source contains a symlink; refusing to package one"
fi

compile_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-compile.XXXXXX")
/usr/bin/osacompile -o "$compile_dir/authorize.scpt" "$WORKFLOW_DIR/bin/authorize.applescript"
/bin/rm -rf -- "$compile_dir"

stage_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-build.XXXXXX")
cleanup() {
  if [[ -n "${stage_dir:-}" && "$stage_dir" == *"/alfred-little-snitch-build."* && -d "$stage_dir" ]]; then
    /bin/rm -rf -- "$stage_dir"
  fi
}
trap cleanup EXIT INT TERM HUP

/bin/mkdir -p "$stage_dir/bin"
for member in "${WORKFLOW_MANIFEST[@]}"; do
  /usr/bin/ditto --norsrc --noextattr --noacl "$WORKFLOW_DIR/$member" "$stage_dir/$member"
done

# MIT requires the notice to travel with the distribution. Nothing else from
# the repository ships: Alfred renders the info.plist "readme" key on import
# and never displays a bundled README, so the rest would be unread payload in
# a bundle users are encouraged to audit.
/bin/cp -p "$ROOT_DIR/LICENSE" "$stage_dir/LICENSE"

# Remove the unprivileged test hook from the released menu.
/usr/bin/sed -i '' '/^# >>> test-hook/,/^# <<< test-hook$/d' "$stage_dir/bin/menu"
if /usr/bin/grep -q 'LSCTL_TEST_CLI' "$stage_dir/bin/menu"; then
  abort "the test hook was not removed from the staged menu"
fi
/bin/zsh -n "$stage_dir/bin/menu" || abort "the staged menu is not valid zsh after stripping the test hook"

# Prove the stripped menu still RENDERS. The two guards above are negative --
# "the hook is gone" and "the file parses" -- and both pass on a truncated
# file: if the sed range's end marker is ever renamed or lost, sed deletes to
# EOF and leaves a syntactically complete prefix that emits nothing. Alfred
# would then show an empty result list with no error anywhere, which is the
# hardest failure mode to diagnose from a bug report. This needs no Little
# Snitch: with the app absent the menu renders its not-found rows instead.
probe_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-probe.XXXXXX")
probe_output="$probe_dir/menu.json"
if ! alfred_workflow_cache="$probe_dir" "$stage_dir/bin/menu" > "$probe_output"; then
  /bin/rm -rf -- "$probe_dir"
  abort "the staged menu exited non-zero"
fi
if ! /usr/bin/plutil -convert xml1 -o /dev/null "$probe_output" 2>/dev/null; then
  /bin/rm -rf -- "$probe_dir"
  abort "the staged menu did not emit valid JSON"
fi
if ! /usr/bin/plutil -extract items.0.uid raw "$probe_output" >/dev/null 2>&1; then
  /bin/rm -rf -- "$probe_dir"
  abort "the staged menu emitted no items"
fi
/bin/rm -rf -- "$probe_dir"

for member in "${WORKFLOW_EXECUTABLES[@]}"; do
  /bin/chmod 755 "$stage_dir/$member"
done
for member in "${WORKFLOW_DATA[@]}"; do
  /bin/chmod 644 "$stage_dir/$member"
done
/bin/chmod 644 "$stage_dir/LICENSE"

# Pin every timestamp so the archive depends only on content and mode.
/usr/bin/find "$stage_dir" -exec /usr/bin/touch -h -t "$FIXED_TIMESTAMP" {} +

/bin/mkdir -p "$DIST_DIR"
archive_name="Little-Snitch-Control-v${version}.alfredworkflow"
archive_path="$DIST_DIR/$archive_name"

# Clear previous artifacts so a stale archive can never be mistaken for, or
# validated in place of, the current one.
# (N) so a first build in a fresh checkout does not die on an unmatched glob.
/bin/rm -f -- "$DIST_DIR"/*.alfredworkflow(N) "$DIST_DIR"/*.alfredworkflow.sha256(N)

# A sorted, explicit file list keeps entry order independent of the
# filesystem's directory ordering, and stores no directory entries.
(
  cd "$stage_dir"
  /usr/bin/find . -type f -print | /usr/bin/sed 's|^\./||' | LC_ALL=C /usr/bin/sort | \
    COPYFILE_DISABLE=1 /usr/bin/zip -qX -@ "$archive_path"
)

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

/usr/bin/unzip -t "$archive_path" >/dev/null
/usr/bin/unzip -Z1 "$archive_path" | /usr/bin/grep -qx 'info.plist' || \
  abort "info.plist is not at the archive root"
/usr/bin/unzip -Z1 "$archive_path" | /usr/bin/grep -qx 'icon.png' || \
  abort "icon.png is not at the archive root"

/usr/bin/printf 'Built %s\n' "$archive_path"
/usr/bin/printf 'Checksum %s\n' "$(/usr/bin/cut -d' ' -f1 "$archive_path.sha256")"
