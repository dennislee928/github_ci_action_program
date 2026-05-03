#!/usr/bin/env bash
# fast-merge-mergeable-prs.sh
# Purpose: Rapidly merge ALL MERGEABLE open PRs authored by you as fast as possible.
#
# Strategy (optimised for speed):
#   1. Single gh search prs — collect all your open non-draft PRs.
#   2. PARALLEL workers run concurrently; each does ONE gh pr view call to check
#      mergeability, then immediately merges if MERGEABLE.
#   3. Anything not MERGEABLE is logged as SKIP — no retry, no conflict resolution.
#   4. Results are printed in order after every batch of PARALLEL workers finishes.
#
# Usage:
#   .github/script/fast-merge-mergeable-prs.sh
#   DRY_RUN=1 .github/script/fast-merge-mergeable-prs.sh
#
# Environment:
#   PR_LIMIT=500                Max PRs from gh search (default 500)
#   MERGE_METHOD=merge          merge | squash | rebase (default merge)
#   MERGE_ADMIN=1               Pass --admin to gh pr merge (default 1)
#   DELETE_BRANCH=1             Delete head branch after merge (default 0)
#   DRY_RUN=1                   List what would be merged; no actual merges
#   PARALLEL=6                  Concurrent check+merge workers (default 6)
#   GH_SEARCH_TIMEOUT_SEC=120   gh search timeout in seconds (default 120; 0=no limit)
#   FAST_MERGE_LOG=path         Append MERGED/SKIP/ERROR lines to this file too
#   FAST_MERGE_PROGRESS_SEC=15  Search heartbeat interval (default 15; 0=off)
#
# Requires: gh, jq. Auth: gh auth login or GH_TOKEN env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

log_line() {
  printf '%s\n' "$1"
  if [[ -n "${FAST_MERGE_LOG:-}" ]]; then
    printf '%s\n' "$1" >> "${FAST_MERGE_LOG}" 2>/dev/null || true
  fi
}

_HB_PID=
_hb_start() {
  local every="${FAST_MERGE_PROGRESS_SEC:-15}"
  [[ "$every" == "0" ]] && return 0
  (
    local n=0
    while sleep "$every"; do
      n=$((n + 1))
      printf '[progress %s] still waiting for gh search prs ... (%dx%ss elapsed)\n' \
        "$(date '+%H:%M:%S')" "$n" "$every" >&2
    done
  ) &
  _HB_PID=$!
}

_hb_stop() {
  [[ -z "${_HB_PID:-}" ]] && return 0
  kill "$_HB_PID" 2>/dev/null || true
  wait "$_HB_PID" 2>/dev/null || true
  _HB_PID=
}

_run_timeout() {
  local max="$1"; shift
  [[ -z "$max" || "$max" == "0" ]] && { "$@"; return $?; }
  command -v timeout  >/dev/null 2>&1 && { timeout  "$max" "$@"; return $?; }
  command -v gtimeout >/dev/null 2>&1 && { gtimeout "$max" "$@"; return $?; }
  # macOS fallback — bash background + kill watchdog
  "$@" & local pid=$!
  ( sleep "$max"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
  local kpid=$!
  wait "$pid"; local ec=$?
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null || true
  if [[ "$ec" -eq 143 || "$ec" -eq 137 ]]; then
    printf 'error: gh search timed out after %ss\n' "$max" >&2
    return 124
  fi
  return "$ec"
}

_normalize_json() {
  local raw="$1"
  [[ -z "${raw//[$'\t\r\n ']/}" ]] && { printf '[]'; return 0; }
  printf '%s' "$raw" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || printf '[]'
}

# ── per-PR worker (runs as a background job) ──────────────────────────────────
# Writes one result line to out_file; never writes to stdout/stderr (avoids
# interleaving when multiple workers run at once).
#
# Args: repo_full num title url out_file method admin del_branch dry
_worker() {
  local repo_full="$1"
  local num="$2"
  local title="$3"
  local url="$4"
  local out_file="$5"
  local method="$6"
  local admin="$7"
  local del_branch="$8"
  local dry="$9"

  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  # Single API call — access check + mergeability in one shot
  local pr_json
  if ! pr_json=$(gh pr view "$num" --repo "$repo_full" --json mergeable 2>/dev/null); then
    printf '[SKIP]   %s %s#%s  reason=no_access  %s\n' \
      "$ts" "$repo_full" "$num" "$title" >> "$out_file"
    return 0
  fi

  local mergeable
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')

  if [[ "$mergeable" != "MERGEABLE" ]]; then
    printf '[SKIP]   %s %s#%s  mergeable=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$mergeable" "$title" >> "$out_file"
    return 0
  fi

  if [[ "$dry" == "1" ]]; then
    printf '[DRY_RUN] %s %s#%s  method=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$method" "$url" >> "$out_file"
    return 0
  fi

  # Build gh pr merge command — avoid eval, enumerate flag combinations
  local mec=0
  if [[ "$admin" == "1" && "$del_branch" == "1" ]]; then
    gh pr merge "$num" --repo "$repo_full" "--${method}" --admin --delete-branch \
      >/dev/null 2>&1 || mec=$?
  elif [[ "$admin" == "1" ]]; then
    gh pr merge "$num" --repo "$repo_full" "--${method}" --admin \
      >/dev/null 2>&1 || mec=$?
  elif [[ "$del_branch" == "1" ]]; then
    gh pr merge "$num" --repo "$repo_full" "--${method}" --delete-branch \
      >/dev/null 2>&1 || mec=$?
  else
    gh pr merge "$num" --repo "$repo_full" "--${method}" \
      >/dev/null 2>&1 || mec=$?
  fi

  if [[ "$mec" -eq 0 ]]; then
    printf '[MERGED] %s %s#%s  %s\n' "$ts" "$repo_full" "$num" "$url" >> "$out_file"
  else
    printf '[ERROR]  %s %s#%s  merge_exit=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$mec" "$title" >> "$out_file"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

command -v gh  >/dev/null 2>&1 || { echo "error: gh required (brew install gh)" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "error: jq required (brew install jq)" >&2; exit 1; }

MY_LOGIN=$(gh api user -q .login 2>/dev/null) || {
  echo "error: gh api user failed; run: gh auth login" >&2; exit 1
}

FM_METHOD="${MERGE_METHOD:-merge}"
FM_ADMIN="${MERGE_ADMIN:-1}"
FM_DEL="${DELETE_BRANCH:-0}"
FM_DRY="${DRY_RUN:-0}"
FM_PAR="${PARALLEL:-6}"
FM_LIMIT="${PR_LIMIT:-500}"
FM_TOUT="${GH_SEARCH_TIMEOUT_SEC:-120}"

if [[ -n "${FAST_MERGE_LOG:-}" ]]; then
  if [[ -d "${FAST_MERGE_LOG}" ]]; then
    echo "error: FAST_MERGE_LOG must be a file path, not a directory" >&2; exit 1
  fi
  printf '' >> "${FAST_MERGE_LOG}" 2>/dev/null \
    || { echo "warning: cannot write FAST_MERGE_LOG, disabling file log" >&2; FAST_MERGE_LOG=""; }
fi

log_line "==> fast-merge-mergeable-prs"
log_line "    login=${MY_LOGIN} method=${FM_METHOD} admin=${FM_ADMIN} del_branch=${FM_DEL} dry=${FM_DRY} parallel=${FM_PAR} limit=${FM_LIMIT} timeout=${FM_TOUT}s"

# ── Phase 1: search (single, sequential — GitHub API constraint) ──────────────

log_line "==> Searching open PRs (author=${MY_LOGIN}, non-draft) ..."
log_line "    Heartbeat every ${FAST_MERGE_PROGRESS_SEC:-15}s (FAST_MERGE_PROGRESS_SEC=0 to disable)"

_hb_start
set +e
_RAW=$(_run_timeout "$FM_TOUT" gh search prs \
  --author "$MY_LOGIN" --state open --draft=false \
  --json number,title,url,repository --limit "$FM_LIMIT" 2>/dev/null)
_SRCH_EC=$?
set -e
_hb_stop

if [[ "$_SRCH_EC" -eq 124 ]]; then
  echo "error: search timed out after ${FM_TOUT}s. Raise GH_SEARCH_TIMEOUT_SEC." >&2
  exit 124
fi

_JSON=$(_normalize_json "$_RAW")
_DEDUPED=$(printf '%s' "$_JSON" | jq 'unique_by(.url)')
_COUNT=$(printf '%s' "$_DEDUPED" | jq 'length')
log_line "==> Search done: ${_COUNT} unique PR(s) to evaluate"

[[ "$_COUNT" -eq 0 ]] && { log_line "==> Nothing to do."; exit 0; }

# ── Phase 2: parallel check + merge ──────────────────────────────────────────

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

out_files=()
pids=()
batch=0
processed=0

while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner // empty')
  num=$(printf '%s' "$row" | jq -r '.number')
  title=$(printf '%s' "$row" | jq -r '.title')
  url=$(printf '%s' "$row" | jq -r '.url')
  [[ -z "$repo" || "$repo" == "null" || -z "$num" || "$num" == "null" ]] && continue

  out="${TMP_DIR}/$(printf '%s' "${repo}_${num}" | tr '/' '_').log"
  out_files+=("$out")

  _worker "$repo" "$num" "$title" "$url" "$out" \
    "$FM_METHOD" "$FM_ADMIN" "$FM_DEL" "$FM_DRY" &
  pids+=($!)
  batch=$((batch + 1))

  # Flush when batch is full: wait + print progress
  if [[ "$((batch % FM_PAR))" -eq 0 ]]; then
    wait "${pids[@]}" 2>/dev/null || true
    pids=()
    processed=$((processed + batch))
    batch=0
    log_line "    [batch] ${processed}/${_COUNT} PR(s) processed"
  fi
done < <(printf '%s' "$_DEDUPED" | jq -c '.[]')

# Wait for any final partial batch
if [[ "${#pids[@]}" -gt 0 ]]; then
  wait "${pids[@]}" 2>/dev/null || true
  processed=$((processed + batch))
fi

# ── Phase 3: print results in order + tally ───────────────────────────────────

log_line ""
log_line "---- Results ----"

n_merged=0
n_skipped=0
n_errors=0
n_dry=0

for f in "${out_files[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    log_line "$line"
    if [[ "$line" == \[MERGED\]* ]]; then
      n_merged=$((n_merged + 1))
    elif [[ "$line" == \[SKIP\]* ]]; then
      n_skipped=$((n_skipped + 1))
    elif [[ "$line" == \[ERROR\]* ]]; then
      n_errors=$((n_errors + 1))
    elif [[ "$line" == \[DRY_RUN\]* ]]; then
      n_dry=$((n_dry + 1))
    fi
  done < "$f"
done

log_line ""
log_line "==> Summary: merged=${n_merged}  skipped=${n_skipped}  errors=${n_errors}  dry_run=${n_dry}"
