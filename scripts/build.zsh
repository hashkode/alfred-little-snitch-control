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

for required in bin/menu bin/action bin/common.zsh; do
  [[ -x "$WORKFLOW_DIR/$required" ]] || abort "missing or non-executable: $required"
done
for required in bin/authorize.applescript info.plist icon.png icon-caution.png; do
  [[ -f "$WORKFLOW_DIR/$required" ]] || abort "missing required file: $required"
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

/usr/bin/ditto --norsrc --noextattr --noacl "$WORKFLOW_DIR" "$stage_dir"

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

/bin/chmod 755 "$stage_dir/bin/menu" "$stage_dir/bin/action" "$stage_dir/bin/common.zsh"
/bin/chmod 644 "$stage_dir/info.plist" "$stage_dir/bin/authorize.applescript" \
  "$stage_dir/icon.png" "$stage_dir/icon-caution.png" "$stage_dir/LICENSE"

# Pin every timestamp so the archive depends only on content and mode.
/usr/bin/find "$stage_dir" -exec /usr/bin/touch -h -t "$FIXED_TIMESTAMP" {} +

/bin/mkdir -p "$DIST_DIR"
archive_name="Little-Snitch-Control-v${version}.alfredworkflow"
archive_path="$DIST_DIR/$archive_name"

# Clear previous artifacts so a stale archive can never be mistaken for, or
# validated in place of, the current one.
/bin/rm -f -- "$DIST_DIR"/*.alfredworkflow "$DIST_DIR"/*.alfredworkflow.sha256

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
