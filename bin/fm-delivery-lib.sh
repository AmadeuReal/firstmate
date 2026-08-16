#!/usr/bin/env bash
# Shared cross-repository delivery contract checks.

fm_delivery_required_repo() {
  local meta=$1
  sed -n 's/^cross_repository=//p' "$meta" | tail -1
}

fm_delivery_branch_valid() {
  local branch=${1-}
  [[ "$branch" =~ ^fm/[A-Za-z0-9._-]+$ ]]
}

fm_delivery_requirements_check() {
  local meta=$1 required repo branch pr
  [ -f "$meta" ] || return 1
  required=$(fm_delivery_required_repo "$meta")
  [ -z "$required" ] && return 0
  [ "$required" = lumbu-supabase ] || {
    echo "error: unsupported cross-repository delivery contract: $required" >&2
    return 1
  }
  repo=$(sed -n 's/^schema_repo=//p' "$meta" | tail -1)
  branch=$(sed -n 's/^schema_branch=//p' "$meta" | tail -1)
  pr=$(sed -n 's/^schema_pr=//p' "$meta" | tail -1)
  [ "$repo" = lumbu-supabase ] || {
    echo "error: lumbu-supabase schema delivery evidence is missing schema_repo" >&2
    return 1
  }
  fm_delivery_branch_valid "$branch" || {
    echo "error: lumbu-supabase schema delivery evidence needs an isolated fm/<name> branch" >&2
    return 1
  }
  fm_pr_url_parse "$pr" || {
    echo "error: lumbu-supabase schema delivery evidence needs a canonical full PR URL" >&2
    return 1
  }
  [ "${FM_PR_PATH##*/}" = lumbu-supabase ] || {
    echo "error: lumbu-supabase schema delivery evidence points at $FM_PR_PATH" >&2
    return 1
  }
}
