#!/usr/bin/env bash
# Check only the commits introduced by this push or pull request. A local run
# intentionally falls back to the working-tree diff for developer feedback.
set -euo pipefail

event=${GITHUB_EVENT_NAME:-local}
zero_sha=0000000000000000000000000000000000000000

resolve_commit() {
  local sha=$1
  git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  git fetch --no-tags origin "$sha" && git cat-file -e "$sha^{commit}" 2>/dev/null
}

if [[ "$event" == "pull_request" ]]; then
  base=${GITHUB_EVENT_PULL_REQUEST_BASE_SHA:-}
  head=${GITHUB_EVENT_PULL_REQUEST_HEAD_SHA:-}
  [[ -n "$base" && -n "$head" ]] || { printf '%s\n' 'Missing pull-request base or head SHA.' >&2; exit 1; }
  resolve_commit "$base" || { printf '%s\n' "Cannot resolve pull-request base $base." >&2; exit 1; }
  resolve_commit "$head" || { printf '%s\n' "Cannot resolve pull-request head $head." >&2; exit 1; }
  printf 'Checking whitespace for pull request range %s...%s\n' "$base" "$head"
  git diff --check "$base...$head"
elif [[ "$event" == "push" ]]; then
  before=${GITHUB_EVENT_BEFORE:-}
  head=${GITHUB_SHA:-HEAD}
  if [[ -z "$before" || "$before" == "$zero_sha" ]]; then
    empty_tree=$(git hash-object -t tree /dev/null)
    printf 'Checking whitespace for initial push range %s..%s\n' "$empty_tree" "$head"
    git diff --check "$empty_tree" "$head"
  else
    resolve_commit "$before" || { printf '%s\n' "Cannot resolve push before SHA $before." >&2; exit 1; }
    resolve_commit "$head" || { printf '%s\n' "Cannot resolve push head $head." >&2; exit 1; }
    printf 'Checking whitespace for push range %s..%s\n' "$before" "$head"
    git diff --check "$before" "$head"
  fi
else
  printf '%s\n' 'Checking whitespace for local working-tree diff'
  git diff --check
fi
