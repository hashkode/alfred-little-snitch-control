#!/bin/zsh -f

# Validates a built .alfredworkflow archive. Separate from tests/run.zsh so the
# unit suite stays pure and so CI can validate the exact artifact it is about
# to publish, rather than one it happens to rebuild.
#
#   ./tests/package.zsh [path/to/archive.alfredworkflow]

set -euo pipefail

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr ROOT_DIR="${SCRIPT_DIR:h}"
typeset -gr WORKFLOW_DIR="$ROOT_DIR/workflow"

fail() {
  /usr/bin/printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

version=$(/usr/libexec/PlistBuddy -c 'Print :version' "$WORKFLOW_DIR/info.plist")
archive="${1:-$ROOT_DIR/dist/Little-Snitch-Control-v${version}.alfredworkflow}"
[[ -f "$archive" ]] || fail "release archive not found: $archive (run 'make build' first)"

/usr/bin/unzip -t "$archive" >/dev/null || fail "release archive is corrupt"

listing=$(/usr/bin/unzip -Z1 "$archive")

for required in info.plist icon.png icon-caution.png bin/menu bin/action bin/common.zsh bin/authorize.applescript LICENSE; do
  /usr/bin/printf '%s\n' "$listing" | /usr/bin/grep -qx "$required" || \
    fail "release archive is missing $required"
done

# Alfred requires info.plist at the archive root; a wrapper directory is the
# classic packaging mistake.
if /usr/bin/printf '%s\n' "$listing" | /usr/bin/grep -q '^workflow/'; then
  fail "release archive contains an unwanted workflow wrapper directory"
fi
if /usr/bin/printf '%s\n' "$listing" | /usr/bin/grep -qE '(^|/)\.DS_Store$|^__MACOSX/|(^|/)\._'; then
  fail "release archive contains macOS metadata junk"
fi

# Developer-facing material must not ship inside the product.
for unwanted in docs/MANUAL_TESTING.md README.md CONTRIBUTING.md; do
  if /usr/bin/printf '%s\n' "$listing" | /usr/bin/grep -qx "$unwanted"; then
    fail "release archive ships developer documentation: $unwanted"
  fi
done

extract_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-package.XXXXXX")
cleanup() {
  if [[ -n "${extract_dir:-}" && "$extract_dir" == *"/alfred-little-snitch-package."* && -d "$extract_dir" ]]; then
    /bin/rm -rf -- "$extract_dir"
  fi
}
trap cleanup EXIT INT TERM HUP

/usr/bin/unzip -q "$archive" -d "$extract_dir"

for executable in bin/menu bin/action bin/common.zsh; do
  [[ -x "$extract_dir/$executable" ]] || fail "release scripts lost executable permissions: $executable"
done

# The unprivileged test hook must not reach users: anything able to set the
# workflow's environment could otherwise make the status display lie.
if /usr/bin/grep -q 'LSCTL_TEST_CLI' "$extract_dir/bin/menu"; then
  fail "the released menu still contains the test hook"
fi
/bin/zsh -n "$extract_dir/bin/menu" || fail "the released menu is not valid zsh"

packaged_version=$(/usr/libexec/PlistBuddy -c 'Print :version' "$extract_dir/info.plist")
[[ "$packaged_version" == "$version" ]] || \
  fail "packaged version ($packaged_version) does not match the source tree ($version)"

# Anchored on a non-digit so "## 0.2.0" is not satisfied by "## 0.2.01".
/usr/bin/grep -qE "^## ${version}([^0-9]|$)" "$ROOT_DIR/CHANGELOG.md" || \
  fail "CHANGELOG.md has no section for version $version"

# README names the release asset in the checksum-verification command it asks
# security-conscious users to run. A stale version there fails at exactly the
# step the project asks people not to skip, so drift is a release blocker.
readme_versions=$(/usr/bin/grep -o -E 'Little-Snitch-Control-v[0-9]+\.[0-9]+\.[0-9]+' \
  "$ROOT_DIR/README.md" | /usr/bin/sort -u || true)
for named in ${(f)readme_versions}; do
  [[ "$named" == "Little-Snitch-Control-v${version}" ]] || \
    fail "README.md names $named but the workflow version is $version"
done

# The packaged menu must actually render. Stripping the test hook with a sed
# range can truncate the file to a syntactically valid prefix that emits
# nothing, and Alfred shows an empty list with no error.
probe_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/alfred-little-snitch-package-probe.XXXXXX")
alfred_workflow_cache="$probe_dir" "$extract_dir/bin/menu" > "$probe_dir/menu.json" || \
  fail "the packaged menu exited non-zero"
/usr/bin/plutil -convert xml1 -o /dev/null "$probe_dir/menu.json" 2>/dev/null || \
  fail "the packaged menu did not emit valid JSON"
/usr/bin/plutil -extract items.0.uid raw "$probe_dir/menu.json" >/dev/null 2>&1 || \
  fail "the packaged menu emitted no items"
/bin/rm -rf -- "$probe_dir"

checksum_file="$archive.sha256"
[[ -f "$checksum_file" ]] || fail "checksum file not found: $checksum_file"
(
  cd "${archive:h}"
  /usr/bin/shasum -a 256 -c "${checksum_file:t}" >/dev/null
) || fail "release checksum does not match the archive"

/usr/bin/printf 'Package OK: %s (v%s)\n' "${archive:t}" "$version"
