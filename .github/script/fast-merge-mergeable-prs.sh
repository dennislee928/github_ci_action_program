#!/usr/bin/env bash
# fast-merge-mergeable-prs.sh
# Purpose: Merge ALL MERGEABLE open PRs authored by you as fast as possible.
#
# Why not gh search prs:
#   gh search prs uses GitHub's search index, which can take 30s-several hours
#   and is prone to hanging. This script uses the GraphQL API instead, which
#   typically returns all PR data (including mergeable state) in < 5 seconds.
#
# Strategy:
#   1. GraphQL query  — one paginated call returns every open PR + mergeable state.
#      No separate gh pr view per PR needed.
#   2. Filter         — MERGEABLE PRs are merged; UNKNOWN/CONFLICTING are SKIP.
#   3. PARALLEL merge — concurrent gh pr merge workers (default 8).
#
# Usage:
#   .github/script/fast-merge-mergeable-prs.sh
#   DRY_RUN=1 .github/script/fast-merge-mergeable-prs.sh
#
# Environment:
#   MERGE_METHOD=merge      merge | squash | rebase (default merge)
#   MERGE_ADMIN=1           --admin flag; bypasses branch protection (default 1)
#   DELETE_BRANCH=1         Delete head branch after merge (default 0)
#   DRY_RUN=1               List only; no actual merges
#   PARALLEL=8              Concurrent merge workers (default 8)
#   GQL_PAGE_SIZE=100       PRs per GraphQL page (max 100; default 100)
#   GQL_TIMEOUT_SEC=60      Hard timeout for the GraphQL fetch (default 60)
#   FAST_MERGE_LOG=path     Also append results to this file
#
# Requires: gh, jq. Auth: gh auth login or GH_TOKEN env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── cleanup (runs on exit / INT / TERM) ───────────────────────────────────────

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

# ── GraphQL fetch: all open PRs for the viewer, paginated ────────────────────
# Returns a JSON array of non-draft PRs including the .mergeable field.
# Typical wall time: 1-5 seconds regardless of PR count.
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
  # --paginate outputs one JSON object per page; jq -s collects all pages.
  if command -v timeout >/dev/null 2>&1; then
    raw=$(timeout "$tout" gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    raw=$(gtimeout "$tout" gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  else
    # No system timeout available: GraphQL is fast enough that this is acceptable
    raw=$(gh api graphql --paginate \
      -f query="$gql_query" -F pageSize="$page_size" 2>/dev/null) || ec=$?
  fi
  if [[ "$ec" -ne 0 ]]; then
    printf 'error: GraphQL fetch failed (exit %s). Check gh auth and network.\n' "$ec" >&2
    printf '[]'
    return 0
  fi
  printf '%s' "$raw" | jq -s '
    [.[].data.viewer.pullRequests.nodes[]
     | select(.isDraft == false)
    ]
  ' 2>/dev/null || printf '[]'
}

# ── per-PR merge worker (background job) ─────────────────────────────────────
# Args: repo_full num title url out_file method admin del_branch dry
_merge_worker() {
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

  if [[ "$dry" == "1" ]]; then
    printf '[DRY_RUN] %s %s#%s  method=%s  %s\n' \
      "$ts" "$repo_full" "$num" "$method" "$url" >> "$out_file"
    return 0
  fi

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
FM_PAR="${PARALLEL:-8}"

if [[ -n "${FAST_MERGE_LOG:-}" && -d "${FAST_MERGE_LOG}" ]]; then
  echo "error: FAST_MERGE_LOG must be a file path, not a directory" >&2; exit 1
fi

log_line "==> fast-merge-mergeable-prs"
log_line "    login=${MY_LOGIN}  method=${FM_METHOD}  admin=${FM_ADMIN}  del_branch=${FM_DEL}  dry=${FM_DRY}  parallel=${FM_PAR}"

# ── Phase 1: GraphQL fetch ────────────────────────────────────────────────────

log_line "==> Fetching open PRs via GraphQL (typically < 5s) ..."
t0=$SECONDS
ALL_PRS=$(_fetch_prs_graphql)
t1=$SECONDS
TOTAL=$(printf '%s' "$ALL_PRS" | jq 'length')
log_line "==> Fetched ${TOTAL} open non-draft PR(s) in $((t1 - t0))s"

# Partition by mergeable state
MERGEABLE_PRS=$(printf '%s' "$ALL_PRS" | jq '[.[] | select(.mergeable == "MERGEABLE")]')
SKIP_PRS=$(printf '%s' "$ALL_PRS" | jq '[.[] | select(.mergeable != "MERGEABLE")]')
MERGE_COUNT=$(printf '%s' "$MERGEABLE_PRS" | jq 'length')
SKIP_COUNT=$(printf '%s' "$SKIP_PRS" | jq 'length')

log_line "==> MERGEABLE: ${MERGE_COUNT}  |  skipping (not yet mergeable): ${SKIP_COUNT}"

# Log skipped PRs immediately
while IFS= read -r row; do
  repo=$(printf '%s' "$row" | jq -r '.repository.nameWithOwner // "?"')
  num=$(printf '%s' "$row" | jq -r '.number')
  state=$(printf '%s' "$row" | jq -r '.mergeable')
  title=$(printf '%s' "$row" | jq -r '.title')
  log_line "[SKIP]   $(date -u +'%Y-%m-%dT%H:%M:%SZ') ${repo}#${num}  mergeable=${state}  ${title}"
done < <(printf '%s' "$SKIP_PRS" | jq -c '.[]' 2>/dev/null)

if [[ "$MERGE_COUNT" -eq 0 ]]; then
  log_line "==> Nothing to merge."
  exit 0
fi

# ── Phase 2: parallel merge ───────────────────────────────────────────────────

TMP_DIR=$(mktemp -d)

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

  _merge_worker "$repo" "$num" "$title" "$url" "$out" \
    "$FM_METHOD" "$FM_ADMIN" "$FM_DEL" "$FM_DRY" &
  pids+=($!)
  batch=$((batch + 1))

  # Flush batch when we hit PARALLEL limit
  if [[ "$((batch % FM_PAR))" -eq 0 ]]; then
    wait "${pids[@]}" 2>/dev/null || true
    pids=()
    processed=$((processed + batch))
    batch=0
    log_line "    [batch] ${processed}/${MERGE_COUNT} dispatched"
  fi
done < <(printf '%s' "$MERGEABLE_PRS" | jq -c '.[]')

# Wait for any remaining partial batch
if [[ "${#pids[@]}" -gt 0 ]]; then
  wait "${pids[@]}" 2>/dev/null || true
  processed=$((processed + batch))
fi

# ── Phase 3: results ─────────────────────────────────────────────────────────

log_line ""
log_line "---- Results ----"

n_merged=0
n_errors=0
n_dry=0

for f in "${out_files[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    log_line "$line"
    if [[ "$line" == \[MERGED\]* ]]; then
      n_merged=$((n_merged + 1))
    elif [[ "$line" == \[ERROR\]* ]]; then
      n_errors=$((n_errors + 1))
    elif [[ "$line" == \[DRY_RUN\]* ]]; then
      n_dry=$((n_dry + 1))
    fi
  done < "$f"
done

log_line ""
log_line "==> Summary: merged=${n_merged}  errors=${n_errors}  dry_run=${n_dry}  skipped=${SKIP_COUNT} (not mergeable)"
