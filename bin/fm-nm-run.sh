#!/usr/bin/env bash
# fm-nm-run.sh - guarded entrypoint for starting or retrying no-mistakes AXI runs.
#
# The preflight asks the installed no-mistakes daemon for its current state and
# uses only local durable records for the fleet-wide concurrency limit. It does
# not estimate remaining workspace credits: historical `no-mistakes stats`
# output is not a remaining-credit balance. A capacity-shaped failure is
# recorded for the task and makes later retries a captain decision.
#
# Usage:
#   fm-nm-run.sh preflight <worktree> [task-id]
#   fm-nm-run.sh start <worktree> --intent <intent> [--task <task-id>]
#   fm-nm-run.sh retry <worktree> --intent <intent> [--task <task-id>]
#
# Configuration:
#   config/no-mistakes-max-concurrency, or FM_NO_MISTAKES_MAX_CONCURRENCY,
#   sets the number of runs this home may start at once. The default is 1.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
RUN_DIR=$STATE/no-mistakes-runs
BLOCKER_DIR=$STATE/no-mistakes-capacity

die() { echo "error: $*" >&2; exit 2; }
usage() { sed -n 's/^# //p' "$0" | sed -n '/^Usage:/,/^Configuration:/p'; }

task_key() {
  local value=$1
  value=$(printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_')
  [ -n "$value" ] || value=worktree
  printf '%s' "$value"
}

capacity_limit() {
  local value=${FM_NO_MISTAKES_MAX_CONCURRENCY:-}
  if [ -z "$value" ] && [ -f "$CONFIG/no-mistakes-max-concurrency" ]; then
    value=$(cat "$CONFIG/no-mistakes-max-concurrency")
  fi
  [ -n "$value" ] || value=1
  case "$value" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s' "$value"
}

with_guard_lock() {
  local lock=$RUN_DIR/.lock attempt=0
  mkdir -p "$RUN_DIR" "$BLOCKER_DIR"
  while ! mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 20 ] || return 1
    sleep 0.05
  done
  trap 'rmdir "$RUN_DIR/.lock" 2>/dev/null || true' EXIT
}

active_slots() {
  local record pid count=0
  for record in "$RUN_DIR"/*.run; do
    [ -f "$record" ] || continue
    pid=$(sed -n 's/^pid=//p' "$record" | head -1)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    else
      rm -f "$record"
    fi
  done
  printf '%s' "$count"
}

axi_status() {
  (cd "$1" && no-mistakes axi status) 2>&1 || true
}

status_is_active() {
  local output=$1 status outcome
  status=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)
  outcome=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*outcome:[[:space:]]*//p' | head -1)
  [ -z "$outcome" ] || return 1
  case "$status" in running|fixing|ci|awaiting_approval|fix_review) return 0 ;; esac
  return 1
}

blocker_path() { printf '%s/%s.blocker' "$BLOCKER_DIR" "$(task_key "$1")"; }

preflight() {
  local wt=$1 task=${2:-$1} output limit slots
  [ -d "$wt" ] || die "worktree does not exist: $wt"
  command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is not installed"
  [ ! -e "$(blocker_path "$task")" ] || {
    echo "capacity-blocked: task $task has a recorded workspace-capacity blocker; captain decision required" >&2
    return 3
  }
  output=$(axi_status "$wt")
  if status_is_active "$output"; then
    echo "capacity-unavailable: an active no-mistakes run is preserved; no duplicate run started" >&2
    return 4
  fi
  limit=$(capacity_limit) || {
    echo "capacity-unavailable: invalid no-mistakes concurrency limit" >&2
    return 4
  }
  with_guard_lock || {
    echo "capacity-unavailable: could not establish the no-mistakes concurrency guard" >&2
    return 4
  }
  slots=$(active_slots)
  [ "$slots" -lt "$limit" ] || {
    echo "capacity-unavailable: $slots active guarded run(s), limit $limit" >&2
    return 4
  }
  echo "capacity-available: guarded slots $slots/$limit"
}

run_pipeline() {
  local action=$1 wt=$2 task=$3 intent=$4 output_file record key rc
  preflight "$wt" "$task" || return $?
  key=$(task_key "$task")
  record=$RUN_DIR/"$key"."$$".run
  printf 'pid=%s\nworktree=%s\ntask=%s\n' "$$" "$wt" "$task" > "$record"
  output_file=$(mktemp "${TMPDIR:-/tmp}/fm-nm-run.XXXXXX") || {
    rm -f "$record"
    die "could not create run output file"
  }
  set +e
  (cd "$wt" && no-mistakes axi run --intent "$intent") 2>&1 | tee "$output_file"
  rc=${PIPESTATUS[0]}
  set -e
  rm -f "$record"
  if grep -Eiq 'workspace[ -]?credit|credit[^[:alnum:]]*(exhaust|limit|capacity)|capacity[^[:alnum:]]*(exhaust|limit|unavailable)' "$output_file"; then
    printf 'task=%s\naction=%s\nreason=workspace capacity reported by no-mistakes\n' "$task" "$action" > "$(blocker_path "$task")"
    echo "capacity-blocked: preserved no-mistakes capacity failure for task $task; captain decision required" >&2
    rm -f "$output_file"
    return 3
  fi
  rm -f "$output_file"
  return "$rc"
}

main() {
  local command=${1:-} wt task= intent= arg
  shift || true
  case "$command" in
    preflight)
      wt=${1:-}; task=${2:-$wt}
      [ -n "$wt" ] || { usage >&2; exit 2; }
      preflight "$wt" "$task"
      ;;
    start|retry)
      wt=${1:-}; shift || true
      [ -n "$wt" ] || { usage >&2; exit 2; }
      while [ "$#" -gt 0 ]; do
        arg=$1; shift
        case "$arg" in
          --intent) intent=${1:-}; shift || true ;;
          --task) task=${1:-}; shift || true ;;
          *) die "unknown option: $arg" ;;
        esac
      done
      [ -n "$intent" ] || die "--intent is required"
      [ -n "$task" ] || task=$wt
      run_pipeline "$command" "$wt" "$task" "$intent"
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}
main "$@"
