#!/usr/bin/env bash
# Behavior tests for portable Firstmate Git snapshot materialization.
#
# The fixture exercises both checkout classes in the public fm-snapshot.sh
# interface: a linked worktree remains usable with full host access but is
# rejected by the portable boundary, while a materialized standalone checkout
# records its source commit and remains valid after the linked metadata is made
# unavailable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-snapshot)
fm_git_identity fmtest fmtest@example.invalid

assert_path_inside() {
  local path=$1 root=$2
  case "$path" in
    "$root"|"$root"/*) ;;
    *) fail "path '$path' escaped root '$root'" ;;
  esac
}

assert_rejected() {
  local label=$1 expected=$2
  shift 2
  local output rc
  output=$("$@" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded: $output"
  assert_contains "$output" "$expected" "$label omitted the rejection reason"
}

SOURCE="$TMP_ROOT/source"
LINKED="$TMP_ROOT/linked"
STANDALONE="$TMP_ROOT/standalone"
fm_git_worktree "$SOURCE" "$LINKED" fm/snapshot-linked >/dev/null

git -C "$LINKED" status --short >/dev/null || fail "linked worktree did not work with full host metadata"
pass "linked Treehouse-shaped worktree remains usable in full-host mode"

source_commit=$(git -C "$LINKED" rev-parse --verify HEAD^{commit})
materialized=$("$SNAPSHOT" materialize "$LINKED" "$STANDALONE") || fail "standalone snapshot materialization failed"
assert_contains "$materialized" "portable snapshot: materialized" "materialization did not report success"
assert_contains "$materialized" "source_commit=$source_commit" "materialization did not report the source commit"

git_dir=$(git -C "$STANDALONE" rev-parse --path-format=absolute --git-dir)
common_dir=$(git -C "$STANDALONE" rev-parse --path-format=absolute --git-common-dir)
root_real=$(cd "$STANDALONE" && pwd -P)
assert_path_inside "$git_dir" "$root_real"
assert_path_inside "$common_dir" "$root_real"
[ "$git_dir" = "$common_dir" ] || fail "standalone snapshot did not use one local Git directory"

manifest_commit=$(sed -n 's/^source_commit=//p' "$git_dir/fm-snapshot.v1")
[ "$manifest_commit" = "$source_commit" ] || fail "snapshot manifest recorded '$manifest_commit', expected '$source_commit'"
validated=$("$SNAPSHOT" validate "$STANDALONE") || fail "standalone snapshot validation failed"
assert_contains "$validated" "portable snapshot: valid" "validation did not report success"
assert_contains "$validated" "source_commit=$source_commit" "validation lost the source commit"
pass "standalone snapshot owns git-dir and git-common-dir and records the exact source commit"

assert_rejected "linked worktree portable validation" "Git metadata escapes snapshot root" "$SNAPSHOT" validate "$LINKED"
pass "portable validation rejects linked metadata outside the snapshot root"

linked_git_dir=$(git -C "$LINKED" rev-parse --path-format=absolute --git-dir)
if command -v sandbox-exec >/dev/null 2>&1; then
  sandbox_profile="(version 1) (allow default) (deny file-read* (subpath \"$linked_git_dir\"))"
  restricted_output=$(sandbox-exec -p "$sandbox_profile" /usr/bin/git -C "$LINKED" status 2>&1)
  restricted_rc=$?
  [ "$restricted_rc" -ne 0 ] || fail "sandboxed linked Git status unexpectedly succeeded"
  assert_contains "$restricted_output" "not a git repository" "sandboxed linked Git status did not expose the external metadata failure"
  pass "restricted metadata sandbox reproduces the linked-worktree Git failure"
else
  pass "restricted metadata sandbox unavailable; detached-admin fixture covers the failure"
fi

mv "$linked_git_dir" "$linked_git_dir.unavailable" || fail "could not make linked metadata unavailable"
assert_rejected "unavailable linked metadata validation" "Git metadata is unavailable or inaccessible" "$SNAPSHOT" validate "$LINKED"
git -C "$STANDALONE" status --short >/dev/null || fail "standalone snapshot depended on linked metadata"
validated=$("$SNAPSHOT" validate "$STANDALONE") || fail "standalone snapshot failed after linked metadata was removed"
assert_contains "$validated" "portable snapshot: valid" "standalone snapshot was not independent after linked metadata removal"
pass "standalone snapshot remains valid when linked metadata is unavailable"
