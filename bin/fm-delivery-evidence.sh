#!/usr/bin/env bash
# Record required cross-repository PR evidence for an application task.
# Usage: fm-delivery-evidence.sh <task-id> lumbu-supabase <schema-branch> <pr-url>
# The operation is idempotent and never merges or changes the dependency repo.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-delivery-lib.sh"
. "$SCRIPT_DIR/fm-lock-lib.sh"
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$#" -eq 4 ] || { echo "usage: fm-delivery-evidence.sh <task-id> lumbu-supabase <schema-branch> <pr-url>" >&2; exit 2; }
ID=$1
REPO=$2
BRANCH=$3
URL=$4
fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }
[ "$REPO" = lumbu-supabase ] || { echo "error: only lumbu-supabase is supported" >&2; exit 2; }
fm_delivery_branch_valid "$BRANCH" || { echo "error: schema branch must be an isolated fm/<name> branch" >&2; exit 2; }
fm_pr_url_parse "$URL" || { echo "error: invalid canonical PR URL" >&2; exit 2; }
[ "${FM_PR_PATH##*/}" = lumbu-supabase ] || { echo "error: PR URL is not for lumbu-supabase" >&2; exit 2; }
fm_delivery_schema_pr_branch_matches "$FM_PR_URL" "$BRANCH" || {
  echo "error: lumbu-supabase schema PR does not exist or its head branch is not $BRANCH" >&2
  exit 1
}

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
[ "$(fm_delivery_required_repo "$META")" = lumbu-supabase ] || {
  echo "error: task does not require lumbu-supabase delivery evidence" >&2
  exit 1
}
LOCK=$(fm_meta_lock_path "$META")
fm_lock_acquire_wait "$LOCK"
TMP=$(mktemp "$STATE/.fm-delivery-meta.XXXXXX")
trap 'rm -f "$TMP"; fm_lock_release "$LOCK" || true' EXIT
existing_repo=$(sed -n 's/^schema_repo=//p' "$META" | tail -1)
existing_branch=$(sed -n 's/^schema_branch=//p' "$META" | tail -1)
existing_pr=$(sed -n 's/^schema_pr=//p' "$META" | tail -1)
if [ -n "$existing_repo$existing_branch$existing_pr" ]; then
  [ "$existing_repo" = "$REPO" ] && [ "$existing_branch" = "$BRANCH" ] && [ "$existing_pr" = "$FM_PR_URL" ] || {
    echo "error: conflicting lumbu-supabase schema delivery evidence already recorded" >&2
    exit 1
  }
  fm_delivery_requirements_check "$META"
  printf 'recorded: %s schema PR %s\n' "$REPO" "$FM_PR_URL"
  exit 0
fi
awk -F= '!($1 == "schema_repo" || $1 == "schema_branch" || $1 == "schema_pr")' "$META" > "$TMP"
printf 'schema_repo=%s\nschema_branch=%s\nschema_pr=%s\n' "$REPO" "$BRANCH" "$FM_PR_URL" >> "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$META"
TMP=
fm_delivery_requirements_check "$META"
printf 'recorded: %s schema PR %s\n' "$REPO" "$FM_PR_URL"
