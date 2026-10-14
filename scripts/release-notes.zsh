#!/bin/zsh -f

# Prints the release notes for one version: its section of CHANGELOG.md,
# without the heading, followed by a link comparing it with the previous
# release.
#
#   scripts/release-notes.zsh <version> <owner/repo> [changelog]
#
# Exit status: 0 printed, 1 no usable section, 2 usage.
#
# The release workflow publishes this instead of GitHub's generated notes,
# which list the pull requests merged between two tags and silently omit any
# commit whose pull request GitHub can no longer find. For v0.3.0 they listed
# 9 of 17 changes (#49).

set -euo pipefail

typeset -gr SCRIPT_DIR="${0:A:h}"
typeset -gr ROOT_DIR="${SCRIPT_DIR:h}"

# A wrong extraction, such as a heading that matched nothing or a section cut
# after its first line, is far smaller than any real entry. These floors make
# it fail the run instead of publishing an empty or truncated body.
typeset -gri MINIMUM_ENTRIES=1
typeset -gri MINIMUM_CHARACTERS=120

die() {
  /usr/bin/printf 'release-notes: %s\n' "$1" >&2
  exit "${2:-1}"
}

(( $# == 2 || $# == 3 )) || die "usage: release-notes.zsh <version> <owner/repo> [changelog]" 2
version="$1"
repository="$2"
changelog="${3:-$ROOT_DIR/CHANGELOG.md}"
[[ "$version" == <->.<->.<-> ]] || die "not a version: $version" 2
[[ "$repository" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || die "not a repository: $repository" 2
[[ -f "$changelog" ]] || die "no changelog at $changelog" 2

# Released sections are dated; "## Unreleased" and an undated heading are not
# releases. They never start the section, and the comparison link skips them
# to the previous dated release.
typeset -r dated_heading='^## ([0-9]+\.[0-9]+\.[0-9]+) — [0-9]{4}-[0-9]{2}-[0-9]{2}$'

typeset -a section
section=()
previous=""
found=0
ended=0
for line in "${(@f)$(<"$changelog")}"; do
  if [[ "$line" == "## "* ]]; then
    if (( found )); then
      ended=1
      if [[ "$line" =~ $dated_heading ]]; then
        previous="${match[1]}"
        break
      fi
    elif [[ "$line" =~ $dated_heading && "${match[1]}" == "$version" ]]; then
      found=1
    fi
    continue
  fi
  (( found && ! ended )) && section+=("$line")
done

(( found )) || die "CHANGELOG.md has no dated section for $version"

# Trim the blank lines around the section.
while (( ${#section} )) && [[ -z "${section[1]// /}" ]]; do section[1]=(); done
while (( ${#section} )) && [[ -z "${section[-1]// /}" ]]; do section[-1]=(); done

entries=${#${(M)section:#- *}}
body="${(F)section}"
(( entries >= MINIMUM_ENTRIES )) || die "the $version section has no entries"
(( ${#body} >= MINIMUM_CHARACTERS )) || \
  die "the $version section is ${#body} characters, under the $MINIMUM_CHARACTERS expected of a real one"

/usr/bin/printf '%s\n' "$body"
if [[ -n "$previous" ]]; then
  /usr/bin/printf '\n**Full Changelog**: https://github.com/%s/compare/v%s...v%s\n' "$repository" "$previous" "$version"
fi
