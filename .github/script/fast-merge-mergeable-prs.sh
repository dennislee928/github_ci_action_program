#!/usr/bin/env bash
# 快速合併：一次 gh search 列出「你開的」open PR → 僅當 mergeable=MERGEABLE 時執行 merge（預設帶 --admin 等同強制）。
# 其餘狀態略過並寫 log（stdout／可選 FAST_MERGE_LOG）。
#
# chmod a+x .github/script/fast-merge-mergeable-prs.sh
# .github/script/fast-merge-mergeable-prs.sh
#
# Environment:
#   PR_LIMIT=500            gh search 每筆查詢上限（預設 500；GitHub 全域搜尋約 1000）
#   MERGE_METHOD=merge      merge | squash | rebase
#   MERGE_ADMIN=1           預設 1：gh pr merge --admin（需對該 repo 有足夠權限才會成功）
#   MERGE_ADMIN=0           不帶 --admin
#   DELETE_BRANCH=1         合併後刪除 head branch
#   DRY_RUN=1               只列出將 merge / skip，不執行 merge
#   GH_SEARCH_TIMEOUT_SEC   搜尋逾時秒數；預設 120。設為 0 = 不限（可能卡住很久）
#   FAST_MERGE_LOG=path     可選；附加寫入每行結果（SKIP／MERGED／ERROR）
#
# Requires: gh, jq. Auth: gh auth login or GH_TOKEN.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_line() {
  local msg="$1"
  echo "$msg"
  echo "$msg" >&2
  [[ -n "${FAST_MERGE_LOG:-}" ]] && echo "$msg" >>"${FAST_MERGE_LOG}"
}

_FAST_HB_PID=
_fast_search_progress_start() {
  [[ "${FAST_MERGE_PROGRESS_SEC:-15}" == "0" ]] && return 0
  local every="${FAST_MERGE_PROGRESS_SEC:-15}"
  (
    local n=0
    while sleep "$every"; do
      n=$((n + 1))
      echo "[progress $(date '+%H:%M:%S')] still waiting for gh search prs … (${n}×${every}s elapsed)" >&2
    done
  ) &
  _FAST_HB_PID=$!
}

_fast_search_progress_stop() {
  [[ -z "${_FAST_HB_PID:-}" ]] && return 0
  kill "$_FAST_HB_PID" 2>/dev/null || true
  wait "$_FAST_HB_PID" 2>/dev/null || true
  _FAST_HB_PID=
}

run_with_timeout_sec() {
  local max_wait="${1:-0}"
  shift
  if [[ -z "$max_wait" || "$max_wait" == "0" ]]; then
    "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$max_wait" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$max_wait" "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  (
    sleep "$max_wait"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 3
    kill -KILL "$pid" 2>/dev/null || true
  ) &
  local killer=$!
  wait "$pid"
  local ec=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  if [[ "$ec" -eq 143 ]] || [[ "$ec" -eq 137 ]]; then
    echo "error: gh search timed out after ${max_wait}s (GH_SEARCH_TIMEOUT_SEC)." >&2
    return 124
  fi
  return "$ec"
}

normalize_gh_search_json() {
  local raw="$1"
  [[ -z "${raw//[$'\t\r\n ']/}" ]] && {
    echo '[]'
    return 0
  }
  echo "$raw" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || echo '[]'
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

MY_LOGIN=$(gh api user -q .login 2>/dev/null) || {
  echo "error: gh api user failed; run: gh auth login" >&2
  exit 1
}

limit="${PR_LIMIT:-500}"
dry="${DRY_RUN:-0}"
method="${MERGE_METHOD:-merge}"
admin_flag=()
[[ "${MERGE_ADMIN:-1}" == "1" ]] && admin_flag+=(--admin)
DELETE_FLAG=()
[[ "${DELETE_BRANCH:-0}" == "1" ]] && DELETE_FLAG+=(--delete-branch)
tout="${GH_SEARCH_TIMEOUT_SEC:-0}"

log_line "==> fast-merge-mergeable-prs: login=${MY_LOGIN} PR_LIMIT=${limit} MERGE_METHOD=${method} MERGE_ADMIN=${MERGE_ADMIN:-1} DRY_RUN=${dry} GH_SEARCH_TIMEOUT_SEC=${tout}"

echo "==> Searching open PRs (author=${MY_LOGIN}, non-draft) …" >&2
set +e
raw=$(run_with_timeout_sec "$tout" gh search prs --author "$MY_LOGIN" --state open --draft=false \
  --json number,title,url,repository --limit "$limit" 2>/dev/null)
search_ec=$?
set -e

if [[ "$search_ec" -eq 124 ]]; then
  echo "error: search timed out; increase GH_SEARCH_TIMEOUT_SEC or check network." >&2
  exit 124
fi

json=$(normalize_gh_search_json "$raw")
count=$(echo "$json" | jq 'length')
log_line "==> Search done: ${count} PR(s) (dedupe by URL below)"

merged_n=0
skipped_n=0
err_n=0

while read -r row; do
  title=$(echo "$row" | jq -r '.title')
  url=$(echo "$row" | jq -r '.url')
  num=$(echo "$row" | jq -r '.number')
  repo_full=$(echo "$row" | jq -r '.repository.nameWithOwner // empty')
  [[ -z "$repo_full" || "$repo_full" == "null" ]] && continue

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if ! gh pr view "$num" --repo "$repo_full" --json mergeable &>/dev/null; then
    log_line "[SKIP] ${ts} ${repo_full}#${num} reason=no_access_or_not_visible title=${title}"
    skipped_n=$((skipped_n + 1))
    continue
  fi

  mergeable=$(gh pr view "$num" --repo "$repo_full" --json mergeable -q .mergeable)

  if [[ "$mergeable" != "MERGEABLE" ]]; then
    log_line "[SKIP] ${ts} ${repo_full}#${num} mergeable=${mergeable} title=${title}"
    skipped_n=$((skipped_n + 1))
    continue
  fi

  if [[ "$dry" == "1" ]]; then
    log_line "[DRY_RUN] ${ts} ${repo_full}#${num} would_merge method=${method} admin=${MERGE_ADMIN:-1} title=${title}"
    continue
  fi

  set +e
  gh pr merge "$num" --repo "$repo_full" --"$method" "${admin_flag[@]+"${admin_flag[@]}"}" "${DELETE_FLAG[@]+"${DELETE_FLAG[@]}"}"
  mec=$?
  set -e

  if [[ "$mec" -eq 0 ]]; then
    log_line "[MERGED] ${ts} ${repo_full}#${num} url=${url}"
    merged_n=$((merged_n + 1))
  else
    log_line "[ERROR] ${ts} ${repo_full}#${num} merge_exit=${mec} title=${title} (try MERGE_ADMIN=1 or fix branch protection / token scope)"
    err_n=$((err_n + 1))
  fi

done < <(echo "$json" | jq 'unique_by(.url)' | jq -c '.[]')

log_line "==> Done: merged=${merged_n} skipped=${skipped_n} merge_errors=${err_n}"
