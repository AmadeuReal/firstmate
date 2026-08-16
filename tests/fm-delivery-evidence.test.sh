#!/usr/bin/env bash
# Regression coverage for the public cross-repository delivery-evidence command.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-delivery-evidence)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
META="$HOME_DIR/state/app.meta"
printf '%s\n' 'kind=ship' 'cross_repository=lumbu-supabase' > "$META"

run_evidence() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-delivery-evidence.sh" "$@"
}

run_evidence app lumbu-supabase fm/schema-42 https://github.com/acme/lumbu-supabase/pull/7 >/dev/null \
  || fail "valid lumbu-supabase evidence was rejected"
grep -qx 'schema_repo=lumbu-supabase' "$META" || fail "schema repository was not recorded"
grep -qx 'schema_branch=fm/schema-42' "$META" || fail "isolated schema branch was not recorded"
grep -qx 'schema_pr=https://github.com/acme/lumbu-supabase/pull/7' "$META" \
  || fail "canonical schema PR URL was not recorded"

before=$(shasum -a 256 "$META" | awk '{print $1}')
run_evidence app lumbu-supabase fm/schema-42 https://github.com/acme/lumbu-supabase/pull/7 >/dev/null \
  || fail "idempotent evidence replay was rejected"
after=$(shasum -a 256 "$META" | awk '{print $1}')
[ "$before" = "$after" ] || fail "idempotent evidence replay changed metadata"

if run_evidence app lumbu-supabase main https://github.com/acme/lumbu-supabase/pull/7 >/dev/null 2>&1; then
  fail "default schema branch was accepted"
fi
if run_evidence app lumbu-supabase fm/schema-43 https://github.com/acme/application/pull/8 >/dev/null 2>&1; then
  fail "application PR was accepted as schema evidence"
fi

printf '%s\n' 'kind=ship' 'cross_repository=lumbu-supabase' > "$HOME_DIR/state/missing.meta"
if FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-pr-check.sh" missing https://github.com/acme/application/pull/8 >/dev/null 2>&1; then
  fail "application PR readiness ignored missing schema evidence"
fi

pass "cross-repository delivery evidence is canonical, isolated, idempotent, and scoped"
