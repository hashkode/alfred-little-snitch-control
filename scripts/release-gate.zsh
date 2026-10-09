#!/bin/zsh -f

# Refuses a release unless the commit is on the default branch and its
# ci-required check run concluded success: the evidence a merge must already
# produce. The release reads that evidence instead of re-running the gate, so
# .github/workflows/ci.yml stays the only gate definition.
# docs/decisions/release-gate.md has the reasoning and the measurements behind
# the timing defaults.
#
#   scripts/release-gate.zsh <owner/repo> <commit-sha> [options]
#
#   --timeout <seconds>   how long to wait for CI still running on the commit (600)
#   --interval <seconds>  how often to poll while waiting, fractions allowed (20)
#   --grace <seconds>     how long to wait for CI to start at all (120)
#
# Exit status: 0 the commit may be released, 1 refused, 2 usage or API error.
# Reads GitHub through `gh api`; the token needs read access to contents,
# checks and actions.

set -u

typeset -gr REQUIRED_CHECK="ci-required"
# GitHub Actions' integration on github.com, the one the main ruleset requires
# ci-required from. A check run of the same name from any other app does not
# count.
typeset -gr ACTIONS_APP_ID="15368"
typeset -gr CI_WORKFLOW_PATH=".github/workflows/ci.yml"
typeset -gr JQ="/usr/bin/jq"

refuse() {
  # GitHub renders ::error:: as an annotation on the run; locally it is a line.
  /usr/bin/printf '::error::release gate refused: %s\n' "$1" >&2
  exit 1
}

broken() {
  /usr/bin/printf '::error::release gate could not run: %s\n' "$1" >&2
  exit 2
}

# gh is the one tool resolved through PATH: its location differs between
# GitHub's runner images and a developer's machine.
gh_bin="${commands[gh]:-}"
[[ -n "$gh_bin" ]] || broken "gh is not installed"
[[ -x "$JQ" ]] || broken "$JQ is missing"

api() {
  "$gh_bin" api "$1"
}

(( $# >= 2 )) || broken "usage: release-gate.zsh <owner/repo> <commit-sha> [--timeout s] [--interval s] [--grace s]"
repo="$1"
sha="$2"
shift 2

timeout=600
interval=20
grace=120
while (( $# )); do
  (( $# >= 2 )) || broken "$1 needs a value"
  case "$1" in
    --timeout) timeout="$2" ;;
    --interval) interval="$2" ;;
    --grace) grace="$2" ;;
    *) broken "unknown option: $1" ;;
  esac
  shift 2
done

[[ "$repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || broken "not an owner/repo: $repo"
[[ "$sha" =~ '^[0-9a-f]{40}$' ]] || broken "not a full 40-character commit SHA: $sha"
[[ "$timeout" == <-> && "$grace" == <-> ]] || broken "--timeout and --grace take whole seconds"
[[ "$interval" =~ '^[0-9]+(\.[0-9]+)?$' ]] || broken "--interval takes seconds"

# --- on the default branch ---------------------------------------------------
#
# A green ci-required alone is not enough: a pull request's head commit carries
# one too, and a tag can be pointed at any commit.

repository=$(api "repos/$repo") || broken "could not read repos/$repo"
default_branch=$(print -r -- "$repository" | "$JQ" -r '.default_branch // empty')
[[ -n "$default_branch" ]] || broken "repos/$repo returned no default branch"

comparison=$(api "repos/$repo/compare/$default_branch...$sha") || \
  broken "could not compare $sha with $default_branch"
relation=$(print -r -- "$comparison" | "$JQ" -r '.status // empty')
case "$relation" in
  identical|behind) ;;
  ahead|diverged)
    refuse "$sha is not on $default_branch ($relation); only a commit reachable from $default_branch may be released" ;;
  *)
    broken "unexpected comparison status '$relation'" ;;
esac
print -r -- "on $default_branch: $sha ($relation)"

# --- passed ci-required ------------------------------------------------------

waiting_for=""
while true; do
  check_runs=$(api "repos/$repo/commits/$sha/check-runs?check_name=$REQUIRED_CHECK&filter=all&per_page=100") || \
    broken "could not read check runs for $sha"
  # The latest run decides, as it does for a required check: a re-run that
  # failed overrides an earlier pass.
  latest=$(print -r -- "$check_runs" | "$JQ" -c --argjson app "$ACTIONS_APP_ID" \
    '[.check_runs[] | select(.app.id == $app)] | max_by(.id) // empty')

  if [[ -n "$latest" ]]; then
    run_status=$(print -r -- "$latest" | "$JQ" -r '.status')
    conclusion=$(print -r -- "$latest" | "$JQ" -r '.conclusion // ""')
    run_url=$(print -r -- "$latest" | "$JQ" -r '.html_url // ""')
    if [[ "$run_status" == completed ]]; then
      [[ "$conclusion" == success ]] || \
        refuse "$REQUIRED_CHECK concluded '$conclusion' on $sha ${run_url}"
      print -r -- "$REQUIRED_CHECK: success ${run_url}"
      print -r -- "release may proceed"
      exit 0
    fi
    waiting_for="$REQUIRED_CHECK, which is $run_status"
  else
    # Absent is ambiguous: CI may still be creating its jobs, or it may never
    # produce this check. Only the CI workflow's own run tells them apart; any
    # other workflow's run on the commit says nothing either way.
    runs=$(api "repos/$repo/actions/runs?head_sha=$sha&per_page=100") || \
      broken "could not read workflow runs for $sha"
    ci_state=$(print -r -- "$runs" | "$JQ" -r --arg path "$CI_WORKFLOW_PATH" '
      [.workflow_runs[] | select(.path == $path)] as $ci
      | if ($ci | length) == 0 then "none"
        elif any($ci[]; .status != "completed") then "running"
        else "finished" end')
    case "$ci_state" in
      running)
        waiting_for="CI on $sha to create $REQUIRED_CHECK" ;;
      finished)
        refuse "CI ran on $sha but produced no $REQUIRED_CHECK; the commit predates the check, or its run was cut short" ;;
      none)
        (( SECONDS < grace )) || refuse "CI never ran on $sha, so nothing shows it passed $REQUIRED_CHECK"
        waiting_for="CI to start on $sha" ;;
      *)
        broken "unexpected CI state '$ci_state'" ;;
    esac
  fi

  (( SECONDS < timeout )) || \
    refuse "gave up after ${timeout}s waiting for ${waiting_for}; re-run this workflow once CI on $sha has finished"
  print -r -- "waiting for ${waiting_for}"
  /bin/sleep "$interval"
done
