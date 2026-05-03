#!/usr/bin/env bash
# fast-merge-mergeable-prs.sh
# Purpose: Merge open PRs as fast as possible. Four phases:
#
#   Phase 2 — MERGEABLE PRs       → immediate parallel merge
#   Phase 3 — UNKNOWN PRs         → re-check after Phase 2 delay; merge if now MERGEABLE
#   Phase 4 — CONFLICTING PRs     → SAST titles (Snyk/Semgrep/Husky/CodeRabbit):
#               auto-resolve with `git merge -X ours` (keep PR side), push, then merge.
#             Non-SAST conflicting PRs → [SKIP_CONFLICT] (manual fix needed).
#
#   [ERROR] causes:
#     EXTERNAL  — PR is in a repo you cannot write to (opened PR in someone else's repo)
#     OWN_REPO  — merge failed in your own repo (CI failing, branch protection, token scope)
#
# Usage:
#   .github/script/fast-merge-mergeable-prs.sh
#   DRY_RUN=1 .github/script/fast-merge-mergeable-prs.sh
#
# Environment:
#   MERGE_METHOD=merge        merge | squash | rebase (default merge)
#   MERGE_ADMIN=1             --admin flag; bypasses branch protection (default 1)
#   DELETE_BRANCH=1           Delete head branch after merge (default 0)
#   DRY_RUN=1                 List only; no actual merges or git operations
#   PARALLEL=8                Concurrent workers per phase (default 8)
#   CONFLICT_PARALLEL=4       Workers for Phase 4 conflict resolution (default 4)
#   GQL_PAGE_SIZE=100         PRs per GraphQL page (max 100; default 100)
#   GQL_TIMEOUT_SEC=60        GraphQL fetch timeout (default 60)
#   FAST_MERGE_LOG=path       Append all result lines to this file
#
# Requires: gh, jq, git. Auth: gh auth login or GH_TOKEN env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cleanup ───────────────────────────────────────────────────────────────────

TMP_DIR=""

_cleanup() {
  [[ -n "${TMP_DIR:-}" ]] && rm -rf "${TMP_DIR}" 2>/dev/null || true
}

trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ── helpers ───────────────────────────────────────────────────────────────────

log_line() {
  printf '%s\n' "$1"
  if [[ -n "${FAST_MERGE_LOG:-}" ]]; then
    printf '%s\n' "$1" >> "${FAST_MERGE_LOG}" 2>/dev/null || true
  fi
}

_fetch_prs_graphql() {
  local page_size="${GQL_PAGE_SIZE:-100}"
  local tout="${GQL_TIMEOUT_SEC:-60}"
  local gql_query
  gql_query='query($endCursor: String, $pageSize: Int!) {
  viewer {
    pullRequests(states: OPEN, first: $pageSize, after: $endCursor) {
      nodes {
        number
        title
        url
        isDraft
        mergeable
        repository { nameWithOwner }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}'
  local raw ec=0
  if command -v timeout  >/dev/null 2>&1; then
    raw=$(timeout  "$tout" gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    raw=$(gtimeout "$tout" gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  else
    raw=$(gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  fi
  if [[ "$ec" -ne 0 ]]; then
    printf 'error: GraphQL fetch failed (exit %s). Check auth + network.\n' "$ec" >&2
    printf '[]'; return 0
  fi
  printf '%s' "$raw" | jq -s '
    [.[].data.viewer.pullRequests.nodes[]
     | select(.isDraft == false)
    ]
  ' 2>/dev/null || printf '[]'
}

# ── Phase 2 worker: immediate merge ───────────────────────────────────────────
# Args: repo num title url out_file method admin del_branch dry
_merge_worker() {
  local repo_full="$1" num="$2" title="$3" url="$4" out_file="$5"
  local method="$6" admin="$7" del_branch="$8" dry="$9"
  local ts mec=0
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  if [[ "$dry" == "1" ]]; then
    printf '[DRY_RUN]  %s %s#%s  %s\n' "$ts" "$repo_full" "$num" "$url" >> "$out_file"
    return 0
  fi

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
    printf '[MERGED]   %s %s#%s  %s\n' "$ts" "$repo_full" "$num" "$url" >> "$out_file"
  else
    printf '[ERROR]    %s %s#%s  merge_exit=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$mec" "$title" >> "$out_file"
  fi
}

# ── Phase 3 worker: retry UNKNOWN ─────────────────────────────────────────────
# Re-checks mergeability (triggers GitHub to compute it); merges if MERGEABLE.
# Args: repo num title url out_file method admin del_branch dry
_retry_unknown_worker() {
  local repo_full="$1" num="$2" title="$3" url="$4" out_file="$5"
  local method="$6" admin="$7" del_branch="$8" dry="$9"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  local pr_json
  if ! pr_json=$(gh pr view "$num" --repo "$repo_full" \
    --json mergeable 2>/dev/null); then
    printf '[SKIP_UNKNOWN] %s %s#%s  no_access  %s\n' \
      "$ts" "$repo_full" "$num" "$title" >> "$out_file"
    return 0
  fi

  local mergeable
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')

  if [[ "$mergeable" == "MERGEABLE" ]]; then
    _merge_worker "$repo_full" "$num" "$title" "$url" "$out_file" \
      "$method" "$admin" "$del_branch" "$dry"
  else
    printf '[SKIP_UNKNOWN] %s %s#%s  still=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$mergeable" "$title" >> "$out_file"
  fi
}

# ── Phase 4 worker: resolve SAST conflict then merge ─────────────────────────
# Non-SAST conflicting PRs → SKIP_CONFLICT (manual fix needed).
# SAST PRs → clone head branch, merge base -X ours (keep PR side), push, merge.
# Args: repo num title url out_file method admin del_branch dry login
_resolve_conflict_worker() {
  local repo_full="$1" num="$2" title="$3" url="$4" out_file="$5"
  local method="$6" admin="$7" del_branch="$8" dry="$9" login="${10}"
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  # Only auto-resolve SAST PRs
  if ! printf '%s' "$title" | grep -qiE 'snyk|semgrep|husky|coderabbit'; then
    printf '[SKIP_CONFLICT] %s %s#%s  non-SAST (manual fix needed)  %s\n' \
      "$ts" "$repo_full" "$num" "$title" >> "$out_file"
    return 0
  fi

  if [[ "$dry" == "1" ]]; then
    printf '[DRY_CONFLICT]  %s %s#%s  would resolve+merge  %s\n' \
      "$ts" "$repo_full" "$num" "$url" >> "$out_file"
    return 0
  fi

  # Fetch head + base branch names
  local pr_info head_branch base_branch
  if ! pr_info=$(gh pr view "$num" --repo "$repo_full" \
    --json headRefName,baseRefName 2>/dev/null); then
    printf '[ERROR_CONFLICT] %s %s#%s  cannot get branch info\n' \
      "$ts" "$repo_full" "$num" >> "$out_file"
    return 0
  fi
  head_branch=$(printf '%s' "$pr_info" | jq -r '.headRefName')
  base_branch=$(printf '%s' "$pr_info" | jq -r '.baseRefName')

  local token
  token="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
  if [[ -z "$token" ]]; then
    printf '[ERROR_CONFLICT] %s %s#%s  no auth token for git push\n' \
      "$ts" "$repo_full" "$num" >> "$out_file"
    return 0
  fi

  local workdir clone_url
  workdir=$(mktemp -d)
  clone_url="https://x-access-token:${token}@github.com/${repo_full}.git"

  if ! git clone --depth=200 --branch "$head_branch" \
    "$clone_url" "$workdir" >/dev/null 2>&1; then
    printf '[ERROR_CONFLICT] %s %s#%s  clone failed\n' \
      "$ts" "$repo_full" "$num" >> "$out_file"
    rm -rf "$workdir"
    return 0
  fi

  local git_ok=0
  (
    cd "$workdir" || exit 1
    git config user.email "${GIT_AUTHOR_EMAIL:-${login}@users.noreply.github.com}"
    git config user.name  "${GIT_AUTHOR_NAME:-${login}}"
    git fetch origin "$base_branch" --depth=200 >/dev/null 2>&1 || exit 1
    git merge "origin/${base_branch}" \
      -m "Merge ${base_branch} into ${head_branch} (auto: favor PR side on conflicts)" \
      -X ours >/dev/null 2>&1 || exit 1
    git push origin "HEAD:refs/heads/${head_branch}" >/dev/null 2>&1 || exit 1
  ) && git_ok=1

  rm -rf "$workdir"

  if [[ "$git_ok" -eq 0 ]]; then
    printf '[ERROR_CONFLICT] %s %s#%s  git resolve failed (depth/binary conflict?)\n' \
      "$ts" "$repo_full" "$num" >> "$out_file"
    return 0
  fi

  # Wait for GitHub to recompute mergeability after the push
  sleep 6

  local new_state
  new_state=$(gh pr view "$num" --repo "$repo_full" \
    --json mergeable -q .mergeable 2>/dev/null) || new_state="UNKNOWN"

  if [[ "$new_state" != "MERGEABLE" ]]; then
    printf '[ERROR_CONFLICT] %s %s#%s  still=%s after conflict fix  %s\n' \
      "$ts" "$repo_full" "$num" "$new_state" "$title" >> "$out_file"
    return 0
  fi

  local mec=0
  if [[ "$admin" == "1" ]]; then
    gh pr merge "$num" --repo "$repo_full" "--${method}" --admin \
      >/dev/null 2>&1 || mec=$?
  else
    gh pr merge "$num" --repo "$repo_full" "--${method}" \
      >/dev/null 2>&1 || mec=$?
  fi

  if [[ "$mec" -eq 0 ]]; then
    printf '[MERGED_CONFLICT] %s %s#%s  (resolved+merged)  %s\n' \
      "$ts" "$repo_full" "$num" "$url" >> "$out_file"
  else
    printf '[ERROR_CONFLICT] %s %s#%s  merge_exit=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$mec" "$title" >> "$out_file"
  fi
}

# ── parallel batch runner ─────────────────────────────────────────────────────
# Usage: _run_phase LABEL PARALLEL JSON_ARRAY WORKER_FUNC [extra_args...]
# Each row in JSON_ARRAY is passed to WORKER_FUNC as positional args 1-4
# (repo, num, title, url) plus out_file and the common flags.
_run_phase() {
  local label="$1" par="$2" json="$3" worker="$4"
  shift 4
  local extra_args="$*"

  local count
  count=$(printf '%s' "$json" | jq 'length')
  [[ "$count" -eq 0 ]] && return 0

  log_line "==> ${label}: ${count} PR(s)"

  local out_files=() pids=() batch=0 processed=0

  while IFS= read -r row; do
    local repo num title url out
    repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner // empty')
    num=$(printf '%s' "$row" | jq -r '.number')
    title=$(printf '%s' "$row" | jq -r '.title')
    url=$(printf '%s' "$row" | jq -r '.url')
    [[ -z "$repo" || "$repo" == "null" || -z "$num" || "$num" == "null" ]] && continue

    out="${TMP_DIR}/$(printf '%s_%s_%s' "${label// /_}" "${repo//\//_}" "$num").log"
    out_files+=("$out")

    $worker "$repo" "$num" "$title" "$url" "$out" \
      "$FM_METHOD" "$FM_ADMIN" "$FM_DEL" "$FM_DRY" $extra_args &
    pids+=($!)
    batch=$((batch + 1))

    if [[ "$((batch % par))" -eq 0 ]]; then
      wait "${pids[@]}" 2>/dev/null || true
      pids=()
      processed=$((processed + batch))
      batch=0
      log_line "    [${label}] ${processed}/${count} dispatched"
    fi
  done < <(printf '%s' "$json" | jq -c '.[]')

  if [[ "${#pids[@]}" -gt 0 ]]; then
    wait "${pids[@]}" 2>/dev/null || true
  fi

  # Print results from this phase
  local n_ok=0 n_err=0 n_skip=0
  for f in "${out_files[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      log_line "$line"
      if [[ "$line" == \[MERGED\]* || "$line" == \[MERGED_CONFLICT\]* ]]; then
        n_ok=$((n_ok + 1))
        _TOTAL_MERGED=$((_TOTAL_MERGED + 1))
      elif [[ "$line" == \[ERROR\]* || "$line" == \[ERROR_CONFLICT\]* ]]; then
        n_err=$((n_err + 1))
        _TOTAL_ERRORS=$((_TOTAL_ERRORS + 1))
      elif [[ "$line" == \[SKIP\]* || "$line" == \[SKIP_CONFLICT\]* || \
              "$line" == \[SKIP_UNKNOWN\]* ]]; then
        n_skip=$((n_skip + 1))
        _TOTAL_SKIPPED=$((_TOTAL_SKIPPED + 1))
      elif [[ "$line" == \[DRY_RUN\]* || "$line" == \[DRY_CONFLICT\]* ]]; then
        _TOTAL_DRY=$((_TOTAL_DRY + 1))
      fi
    done < "$f"
  done
  log_line "    [${label} done] merged=${n_ok} errors=${n_err} skipped=${n_skip}"
}

# ── main ──────────────────────────────────────────────────────────────────────

command -v gh  >/dev/null 2>&1 || { echo "error: gh required"  >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "error: jq required"  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git required" >&2; exit 1; }

MY_LOGIN=$(gh api user -q .login 2>/dev/null) || {
  echo "error: gh api user failed; run: gh auth login" >&2; exit 1
}

FM_METHOD="${MERGE_METHOD:-merge}"
FM_ADMIN="${MERGE_ADMIN:-1}"
FM_DEL="${DELETE_BRANCH:-0}"
FM_DRY="${DRY_RUN:-0}"
FM_PAR="${PARALLEL:-8}"
FM_CPAR="${CONFLICT_PARALLEL:-4}"

if [[ -n "${FAST_MERGE_LOG:-}" && -d "${FAST_MERGE_LOG}" ]]; then
  echo "error: FAST_MERGE_LOG must be a file path, not a directory" >&2; exit 1
fi

# Global counters (updated by _run_phase)
_TOTAL_MERGED=0
_TOTAL_ERRORS=0
_TOTAL_SKIPPED=0
_TOTAL_DRY=0

log_line "==> fast-merge-mergeable-prs"
log_line "    login=${MY_LOGIN}  method=${FM_METHOD}  admin=${FM_ADMIN}  del=${FM_DEL}  dry=${FM_DRY}  parallel=${FM_PAR}  conflict_parallel=${FM_CPAR}"

# ── Phase 1: GraphQL fetch ────────────────────────────────────────────────────

log_line "==> Phase 1: GraphQL fetch (typically < 5s) ..."
t0=$SECONDS
ALL_PRS=$(_fetch_prs_graphql)
t1=$SECONDS
TOTAL=$(printf '%s' "$ALL_PRS" | jq 'length')
log_line "==> Fetched ${TOTAL} open non-draft PR(s) in $((t1 - t0))s"

MERGEABLE_PRS=$(printf '%s' "$ALL_PRS"   | jq '[.[] | select(.mergeable == "MERGEABLE")]')
CONFLICTING_PRS=$(printf '%s' "$ALL_PRS" | jq '[.[] | select(.mergeable == "CONFLICTING")]')
UNKNOWN_PRS=$(printf '%s' "$ALL_PRS"     | jq '[.[] | select(.mergeable == "UNKNOWN")]')

MC=$(printf '%s' "$MERGEABLE_PRS"   | jq 'length')
CC=$(printf '%s' "$CONFLICTING_PRS" | jq 'length')
UC=$(printf '%s' "$UNKNOWN_PRS"     | jq 'length')

log_line "==> Partition: MERGEABLE=${MC}  CONFLICTING=${CC}  UNKNOWN=${UC}"

[[ "$TOTAL" -eq 0 ]] && { log_line "==> Nothing to do."; exit 0; }

TMP_DIR=$(mktemp -d)

# ── Phase 2: immediate parallel merge ────────────────────────────────────────

log_line ""
log_line "---- Phase 2: merge MERGEABLE PRs (parallel=${FM_PAR}) ----"
_run_phase "Phase2-Merge" "$FM_PAR" "$MERGEABLE_PRS" _merge_worker

# ── Phase 3: retry UNKNOWN (Phase 2 runtime acts as natural wait) ────────────

log_line ""
log_line "---- Phase 3: retry UNKNOWN PRs (parallel=${FM_PAR}) ----"
if [[ "$UC" -eq 0 ]]; then
  log_line "==> Phase 3: no UNKNOWN PRs to retry"
else
  log_line "    (Phase 2 runtime already gave GitHub time to compute mergeability)"
  _run_phase "Phase3-Unknown" "$FM_PAR" "$UNKNOWN_PRS" _retry_unknown_worker
fi

# ── Phase 4: resolve CONFLICTING SAST PRs ─────────────────────────────────────

log_line ""
log_line "---- Phase 4: resolve CONFLICTING PRs (parallel=${FM_CPAR}) ----"
if [[ "$CC" -eq 0 ]]; then
  log_line "==> Phase 4: no CONFLICTING PRs"
else
  log_line "    SAST (Snyk/Semgrep/Husky/CodeRabbit): auto-resolve with -X ours then merge"
  log_line "    non-SAST: logged as SKIP_CONFLICT (manual fix needed)"
  _run_phase "Phase4-Conflict" "$FM_CPAR" "$CONFLICTING_PRS" \
    _resolve_conflict_worker "$MY_LOGIN"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

log_line ""
log_line "===================================================================="
log_line "==> TOTAL SUMMARY"
log_line "    merged=${_TOTAL_MERGED}  errors=${_TOTAL_ERRORS}  skipped=${_TOTAL_SKIPPED}  dry_run=${_TOTAL_DRY}"
log_line ""
log_line "  [ERROR] causes:"
log_line "    EXTERNAL — opened PR in a repo you cannot write to (close it or ask maintainer)"
log_line "    OWN_REPO — CI failing / branch protection / token missing repo scope"
log_line "  [SKIP_CONFLICT] — non-SAST conflicting PR: rebase your branch or run merge-branch.sh"
log_line "  [SKIP_UNKNOWN]  — GitHub still computing mergeability: run script again in a few minutes"
log_line "===================================================================="
