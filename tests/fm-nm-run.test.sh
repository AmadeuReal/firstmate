#!/usr/bin/env bash
# Public-interface tests for the guarded no-mistakes launch surface.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-nm-run)
RUNNER="$ROOT/bin/fm-nm-run.sh"
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi status")
    if [ "${FM_FAKE_NM_ACTIVE:-0}" = 1 ]; then
      printf 'id: active\nstatus: running\noutcome:\n'
    else
      printf 'id: old\nstatus: completed\noutcome: passed\n'
    fi
    ;;
  "axi run"*)
    if [ "${FM_FAKE_NM_CAPACITY:-0}" = 1 ]; then
      printf 'error: workspace credits exhausted\n'
      exit 1
    fi
    sleep "${FM_FAKE_NM_SLEEP:-0}"
    printf 'outcome: passed\n'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config" "$home/wt"
}

run_nm() {
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$FAKEBIN:$PATH" "$RUNNER" "$@"
}

test_preflight_refuses_active_run() {
  local home="$TMP/active" out rc
  make_home "$home"
  out=$(FM_FAKE_NM_ACTIVE=1 run_nm "$home" preflight "$home/wt" task-active 2>&1); rc=$?
  expect_code 4 "$rc" "active run preflight is unavailable"
  assert_contains "$out" "active no-mistakes run is preserved" "active run is not duplicated"
  pass "no-mistakes preflight preserves an active run"
}

test_capacity_failure_blocks_retry() {
  local home="$TMP/blocker" out rc
  make_home "$home"
  out=$(FM_FAKE_NM_CAPACITY=1 run_nm "$home" start "$home/wt" --task task-capacity --intent "validate the accepted change" 2>&1); rc=$?
  expect_code 3 "$rc" "capacity failure is terminal for automatic retry"
  assert_contains "$out" "captain decision required" "capacity failure routes to captain"
  out=$(run_nm "$home" retry "$home/wt" --task task-capacity --intent "validate the accepted change" 2>&1); rc=$?
  expect_code 3 "$rc" "retry does not relaunch after capacity failure"
  assert_contains "$out" "recorded workspace-capacity blocker" "retry explains durable blocker"
  [ -f "$home/state/no-mistakes-capacity/task-capacity.blocker" ] || fail "capacity blocker was not durable"
  pass "workspace-capacity failure prevents duplicate retry"
}

test_concurrency_guard_bounds_new_runs() {
  local home="$TMP/concurrency" second rc holder
  make_home "$home"
  sleep 1 &
  holder=$!
  mkdir -p "$home/state/no-mistakes-runs"
  printf 'pid=%s\nworktree=%s\ntask=task-one\n' "$holder" "$home/wt" > "$home/state/no-mistakes-runs/task-one.$holder.run"
  second=$(run_nm "$home" start "$home/wt" --task task-two --intent "validate two" 2>&1); rc=$?
  expect_code 4 "$rc" "second run is refused at the default concurrency limit"
  assert_contains "$second" "limit 1" "concurrency refusal names deterministic limit"
  wait "$holder"
  pass "no-mistakes concurrency guard bounds new runs"
}

test_preflight_refuses_active_run
test_capacity_failure_blocks_retry
test_concurrency_guard_bounds_new_runs
