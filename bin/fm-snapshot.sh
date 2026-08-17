#!/usr/bin/env bash
# Materialize and validate a portable Firstmate Git snapshot.
#
# Usage:
#   fm-snapshot.sh materialize <source-root> <snapshot-root>
#       Clone a clean source checkout into a new standalone snapshot root,
#       record the source commit under the snapshot's own .git directory, and
#       validate the portable metadata boundary before returning success.
#   fm-snapshot.sh validate <snapshot-root>
#       Require a self-contained Git checkout and a matching fm-snapshot.v1
#       source-commit record. This command is for portable snapshot consumers;
#       full-host Treehouse linked worktrees remain valid outside this contract.
#   fm-snapshot.sh --help
#
# Portable snapshots are intentionally opt-in. Treehouse linked worktrees keep
# their existing shared metadata behavior for full-host execution. A portable
# snapshot never accepts a git-dir or git-common-dir that resolves outside its
# declared root, and it refuses dirty or incomplete snapshots rather than
# guessing what source state should be preserved.
set -u

SNAPSHOT_CREATED=0
SNAPSHOT_DEST=
SNAPSHOT_ERROR=
SNAPSHOT_ROOT_REAL=
SNAPSHOT_GIT_DIR=

usage() {
  cat <<'USAGE'
Usage:
  fm-snapshot.sh materialize <source-root> <snapshot-root>
  fm-snapshot.sh validate <snapshot-root>
  fm-snapshot.sh --help
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  (cd "$path" && pwd -P)
}

path_inside() {
  local path=$1 root=$2
  case "$path" in
    "$root"|"$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_partial_snapshot() {
  local code=$?
  if [ "$SNAPSHOT_CREATED" -eq 1 ] && [ -n "$SNAPSHOT_DEST" ] && [ -e "$SNAPSHOT_DEST" ]; then
    rm -rf -- "$SNAPSHOT_DEST"
  fi
  exit "$code"
}

trap cleanup_partial_snapshot EXIT

metadata_for_root() {
  local root=$1 git_dir common git_dir_real common_real
  SNAPSHOT_ERROR=
  SNAPSHOT_ROOT_REAL=$(existing_dir "$root") || {
    SNAPSHOT_ERROR="portable snapshot rejected: snapshot root is not a directory: $root"
    return 1
  }

  git_dir=$(git -C "$root" rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
    SNAPSHOT_ERROR="portable snapshot rejected: Git metadata is unavailable or inaccessible under $root"
    return 1
  }
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    SNAPSHOT_ERROR="portable snapshot rejected: Git common metadata is unavailable or inaccessible under $root"
    return 1
  }
  git_dir_real=$(existing_dir "$git_dir") || {
    SNAPSHOT_ERROR="portable snapshot rejected: git-dir is unavailable: $git_dir"
    return 1
  }
  common_real=$(existing_dir "$common") || {
    SNAPSHOT_ERROR="portable snapshot rejected: git-common-dir is unavailable: $common"
    return 1
  }
  if ! path_inside "$git_dir_real" "$SNAPSHOT_ROOT_REAL" ||
    ! path_inside "$common_real" "$SNAPSHOT_ROOT_REAL"; then
    SNAPSHOT_ERROR="portable snapshot rejected: Git metadata escapes snapshot root (git-dir=$git_dir_real; git-common-dir=$common_real; root=$SNAPSHOT_ROOT_REAL)"
    return 1
  fi

  SNAPSHOT_GIT_DIR=$git_dir_real
}

snapshot_manifest_field() {
  local field=$1 manifest=$2
  sed -n "s/^${field}=//p" "$manifest"
}

validate_snapshot() {
  local root=$1 manifest format source_commit head status
  metadata_for_root "$root" || die "$SNAPSHOT_ERROR"
  manifest="$SNAPSHOT_GIT_DIR/fm-snapshot.v1"
  [ -f "$manifest" ] || die "portable snapshot rejected: missing $manifest"

  format=$(snapshot_manifest_field format "$manifest")
  [ "$format" = fm-snapshot.v1 ] || die "portable snapshot rejected: unsupported snapshot format in $manifest"
  source_commit=$(snapshot_manifest_field source_commit "$manifest")
  case "$source_commit" in
    ''|*[!0-9a-fA-F]*) die "portable snapshot rejected: invalid source_commit in $manifest" ;;
  esac

  head=$(git -C "$SNAPSHOT_ROOT_REAL" rev-parse --verify HEAD^{commit} 2>/dev/null) ||
    die "portable snapshot rejected: HEAD is unavailable under $SNAPSHOT_ROOT_REAL"
  [ "$head" = "$source_commit" ] ||
    die "portable snapshot rejected: source_commit $source_commit does not match HEAD $head"
  status=$(git -C "$SNAPSHOT_ROOT_REAL" status --porcelain --untracked-files=all 2>/dev/null) ||
    die "portable snapshot rejected: Git status is unavailable under $SNAPSHOT_ROOT_REAL"
  [ -z "$status" ] || die "portable snapshot rejected: snapshot worktree is dirty"

  printf 'portable snapshot: valid\nroot=%s\nsource_commit=%s\n' \
    "$SNAPSHOT_ROOT_REAL" "$source_commit"
}

materialize_snapshot() {
  local source=$1 destination=$2 source_commit source_status clone_commit
  local destination_parent git_dir manifest temp_manifest
  source=$(existing_dir "$source") || die "source root is not a directory: $1"
  source_commit=$(git -C "$source" rev-parse --verify HEAD^{commit} 2>/dev/null) ||
    die "source root has no readable Git commit: $source"
  source_status=$(git -C "$source" status --porcelain --untracked-files=all 2>/dev/null) ||
    die "source root Git metadata is unavailable: $source"
  [ -z "$source_status" ] || die "source root is dirty; portable snapshot requires a clean source: $source"

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    die "snapshot destination already exists: $destination"
  fi
  destination_parent=$(dirname "$destination")
  mkdir -p "$destination_parent" || die "could not create snapshot parent: $destination_parent"
  SNAPSHOT_DEST=$destination
  SNAPSHOT_CREATED=1

  git clone --quiet --no-hardlinks -- "$source" "$destination" ||
    die "could not clone source root into snapshot: $destination"
  clone_commit=$(git -C "$destination" rev-parse --verify HEAD^{commit} 2>/dev/null) ||
    die "materialized snapshot has no readable HEAD: $destination"
  [ "$clone_commit" = "$source_commit" ] ||
    die "materialized snapshot commit changed from $source_commit to $clone_commit"

  metadata_for_root "$destination" || die "$SNAPSHOT_ERROR"
  git_dir=$SNAPSHOT_GIT_DIR
  manifest="$git_dir/fm-snapshot.v1"
  temp_manifest="$git_dir/.fm-snapshot.v1.tmp.$$"
  umask 077
  if ! {
    printf 'format=fm-snapshot.v1\n'
    printf 'source_commit=%s\n' "$source_commit"
  } > "$temp_manifest"; then
    rm -f -- "$temp_manifest"
    die "could not write snapshot manifest: $manifest"
  fi
  mv -f -- "$temp_manifest" "$manifest" || die "could not publish snapshot manifest: $manifest"

  validate_snapshot "$destination" >/dev/null
  SNAPSHOT_CREATED=0
  printf 'portable snapshot: materialized\nroot=%s\nsource_commit=%s\n' \
    "$SNAPSHOT_ROOT_REAL" "$source_commit"
}

case "${1:-}" in
  --help|-h)
    usage
    ;;
  materialize)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    materialize_snapshot "$2" "$3"
    ;;
  validate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    validate_snapshot "$2"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
