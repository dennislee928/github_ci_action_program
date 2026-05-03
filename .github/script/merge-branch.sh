#!/usr/bin/env bash
# Make sure this file is executable
# chmod a+x .github/script/merge-branch.sh
#
# MODES
# 1) CI branch merge (legacy): requires env branch1 and branch2
# 2) PR automation (from repo root):
#      .github/script/merge-branch.sh sast-prs
#
# PR mode: Phase 1 — open PRs under your user (owner=LOGIN), then Phase 2 — each org
# (owner=ORG). Optional MERGE_SEARCH_BY_AUTHOR=1 scopes searches with --author LOGIN
# (same idea as web "author:"). De-duplicates per phase, then merges when allowed.
# Non-SAST PRs: merge only when GitHub reports no conflicts.
# SAST titles (Snyk/Semgrep/Husky/CodeRabbit): if mergeable, merge; if conflicting,
# merges base into the PR branch locally with strategy "ours" (keep PR / tool side),
# pushes, then merges on GitHub.
#
# Requires: gh, jq, git. Auth: gh auth login or GH_TOKEN (Actions / PAT).

set -euo pipefail

# Repo-relative script directory (logs land here by default).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tee stdout+stderr to a file under SCRIPT_DIR. Honors MERGE_LOG_FILE; set
# MERGE_LOG_DISABLE=1 to keep console-only output.
merge_branch_start_session_log() {
  local default_name="$1"
  [[ "${MERGE_LOG_DISABLE:-0}" == "1" ]] && return 0
  local log_path="${MERGE_LOG_FILE:-${SCRIPT_DIR}/${default_name}}"
  exec > >(tee -a "${log_path}") 2>&1
  echo "==> Session log: ${log_path}"
}

# stderr-only; does not affect stdout JSON capture.
v_log() {
  [[ "${MERGE_SCRIPT_VERBOSE:-0}" == "1" ]] || return 0
  echo "[verbose $(date '+%H:%M:%S')] $*" >&2
}

# Human-readable duration for step timing logs (e.g. "30 min", "2 min 15s", "45s", "1h 5m").
format_duration_human() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  [[ "$s" -lt 0 ]] && s=0
  if [[ "$s" -ge 3600 ]]; then
    echo "$((s / 3600))h $(((s % 3600) / 60))m"
  elif [[ "$s" -ge 60 ]]; then
    local m=$((s / 60))
    local r=$((s % 60))
    if [[ "$r" -eq 0 ]]; then
      echo "${m} min"
    else
      echo "${m} min ${r}s"
    fi
  else
    echo "${s}s"
  fi
}

# While `raw=$(gh search prs ...)` runs, print periodic lines to stderr.
# Verbose: GH_HEARTBEAT_SEC (default 3s). Non-verbose: MERGE_SEARCH_PROGRESS_SEC (default 15s); set to 0 to disable.
_GH_HB_PID=
gh_heartbeat_start() {
  local every kill_msg prefix
  if [[ "${MERGE_SCRIPT_VERBOSE:-0}" == "1" ]]; then
    every="${GH_HEARTBEAT_SEC:-3}"
    prefix="verbose"
  else
    every="${MERGE_SEARCH_PROGRESS_SEC:-15}"
    prefix="progress"
    [[ "$every" == "0" ]] && return 0
  fi
  (
    local n=0
    while sleep "$every"; do
      n=$((n + 1))
      echo "[${prefix} $(date '+%H:%M:%S')] still waiting for GitHub: $* … (${n}×${every}s elapsed)" >&2
    done
  ) &
  _GH_HB_PID=$!
}

gh_heartbeat_stop() {
  [[ -z "${_GH_HB_PID:-}" ]] && return 0
  kill "$_GH_HB_PID" 2>/dev/null || true
  wait "$_GH_HB_PID" 2>/dev/null || true
  _GH_HB_PID=
}

# Optional wall-clock cap for `gh search prs` (unset or 0 = no limit). Uses `timeout`,
# `gtimeout`, or a bash fallback when GNU coreutils are missing (common on macOS).
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
  # macOS / no coreutils: run child then force-deadline (TERM, then KILL) so `gh` cannot hang past max_wait.
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
    echo "error: command timed out after ${max_wait}s (GH_SEARCH_TIMEOUT_SEC)." >&2
    return 124
  fi
  return "$ec"
}

usage() {
  cat <<'EOF'
Usage:
  CI merge (env):  branch1=origin/main branch2=ci .github/script/merge-branch.sh
  PR automation:   .github/script/merge-branch.sh sast-prs
                   DRY_RUN=1 .github/script/merge-branch.sh sast-prs

Environment (PR mode):
  VERBOSE=1 / MERGE_VERBOSE=1   Log each gh search (timing + result count) to stderr
  sast-prs -v / --verbose       Same as VERBOSE=1
  DRY_RUN=1           Print actions only
  MERGE_METHOD=merge  merge | squash | rebase (default: merge)
  MERGE_ADMIN=1       gh pr merge --admin when checks block merge
  DELETE_BRANCH=1     gh pr merge --delete-branch
  PR_LIMIT=300        Per search query cap (default 300)
  MERGE_ONLY_SAST=1   Only process PRs whose title matches SAST keywords (legacy)
  VERBOSE=2 / 100 / yes  All enable verbose (not only VERBOSE=1)
  GH_HEARTBEAT_SEC=3  Verbose: seconds between heartbeat lines during gh search (default 3)
  MERGE_SEARCH_PROGRESS_SEC   Non-verbose: heartbeat interval during gh search (default 15; 0 = off)
  GH_SEARCH_TIMEOUT_SEC   Seconds; caps each gh search prs call (0/unset = no cap). Ex: 120
  MERGE_SEARCH_BY_AUTHOR=1  Add --author LOGIN to each search (your PRs only), still scoped per owner phase
  MERGE_INTER_PR_SLEEP=1  Seconds to sleep between sequential PR merges (default 1; prevents rate-limiting)
  MERGE_LOG_FILE=path   Write full session log to this file (default: .github/script/merge-branch-*.log)
  MERGE_LOG_DISABLE=1   Do not write a session log file (console only)

Note: You must pass "sast-prs" for GitHub PR mode. Running the script with no args
      does nothing useful. Do not copy "git push origin $branch2" into your shell
      unless branch1/branch2 are set (normally only set by CI).
EOF
}

# --- SAST / tooling PR detection (title substring, case-insensitive) ---
is_sast_pr_title() {
  local t="$1"
  [[ -z "$t" ]] && return 1
  echo "$t" | grep -qiE 'snyk|semgrep|husky|coderabbit'
}

load_allowed_owners() {
  MY_LOGIN=$(gh api user -q .login 2>/dev/null) || {
    echo "error: gh api user failed; run: gh auth login" >&2
    exit 1
  }
  MY_ORGS=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && MY_ORGS+=("$line")
  done < <(gh api user/orgs --paginate -q '.[].login' 2>/dev/null || true)
}

repo_owner_allowed() {
  local owner="$1"
  [[ "$owner" == "$MY_LOGIN" ]] && return 0
  local o
  for o in "${MY_ORGS[@]}"; do
    [[ "$o" == "$owner" ]] && return 0
  done
  return 1
}

# gh search --json must yield an array; empty, errors, or API objects become [].
normalize_gh_search_json() {
  local raw="$1"
  [[ -z "${raw//[$'\t\r\n ']/}" ]] && {
    echo '[]'
    return 0
  }
  echo "$raw" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || echo '[]'
}

# One `gh search prs` for a single repo owner namespace. When use_author=1, restricts to
# PRs authored by MY_LOGIN (--author + --owner), matching the web "author:" experience.
# Prints JSON array on stdout; progress on stderr.
search_prs_for_owner_namespace() {
  local owner_ns="$1"
  local limit="${2:-300}"
  local use_author="${3:-0}"
  local raw="" chunk="" t0 t_end n search_ec=0
  local tout="${GH_SEARCH_TIMEOUT_SEC:-0}"
  local label author_arg=""

  if [[ "$use_author" == "1" ]]; then
    label="author=${MY_LOGIN} owner=${owner_ns}"
    author_arg="$MY_LOGIN"
  else
    label="owner=${owner_ns}"
  fi

  t0=$SECONDS
  echo "==> Searching PRs: ${label} (non-draft) …" >&2
  v_log "gh search prs ${author_arg:+--author $author_arg} --owner ${owner_ns} --limit ${limit} (timeout=${tout}s)"
  gh_heartbeat_start "${label}"
  set +e
  if [[ -n "$author_arg" ]]; then
    raw=$(run_with_timeout_sec "$tout" gh search prs --author "$author_arg" \
      --owner "$owner_ns" --state open --draft=false \
      --json number,title,url,repository --limit "$limit" 2>/dev/null)
  else
    raw=$(run_with_timeout_sec "$tout" gh search prs \
      --owner "$owner_ns" --state open --draft=false \
      --json number,title,url,repository --limit "$limit" 2>/dev/null)
  fi
  search_ec=$?
  set -e
  gh_heartbeat_stop

  t_end=$SECONDS
  if [[ "$search_ec" -eq 124 ]]; then
    echo "error: gh search timed out for namespace ${owner_ns} (GH_SEARCH_TIMEOUT_SEC=${tout})." >&2
    echo "==> Searching PRs: ${label} … : used $(format_duration_human $((t_end - t0))) — 0 PR(s), gh exit ${search_ec}" >&2
    echo '[]'
    return 0
  fi

  chunk=$(normalize_gh_search_json "$raw")
  n=$(echo "$chunk" | jq 'length')
  v_log "${label} — PRs: ${n} exit=${search_ec} wall=$((t_end - t0))s"
  echo "==> Searching PRs: ${label} … : used $(format_duration_human $((t_end - t0))) — ${n} PR(s), gh exit ${search_ec}" >&2
  echo "$chunk" | jq 'unique_by(.url)'
}

merge_pull_requests_from_json() {
  local json="$1"
  local phase_label="$2"
  local dry="$3"
  local method="$4"
  local only_sast="$5"

  local phase_t0=$SECONDS
  local count
  count=$(echo "$json" | jq 'length')
  echo "==> ${phase_label} — ${count} PR(s) to evaluate" >&2
  v_log "streaming ${count} PR rows; json bytes=${#json}"

  local _row_i=0
  while read -r row; do
    _row_i=$((_row_i + 1))
    v_log "row ${_row_i}/${count}"
    local title url repo_full owner num mergeable sast
    title=$(echo "$row" | jq -r '.title')
    url=$(echo "$row" | jq -r '.url')
    num=$(echo "$row" | jq -r '.number')
    repo_full=$(echo "$row" | jq -r '.repository.nameWithOwner // empty')
    [[ -z "$repo_full" || "$repo_full" == "null" ]] && continue
    owner="${repo_full%%/*}"

    if ! repo_owner_allowed "$owner"; then
      echo "skip (repo outside your user/orgs): $repo_full#$num"
      continue
    fi

    sast=false
    is_sast_pr_title "$title" && sast=true

    if [[ "$only_sast" == "1" ]] && [[ "$sast" != true ]]; then
      echo "skip (MERGE_ONLY_SAST): ${repo_full}#$num — $title"
      continue
    fi

    echo ""
    echo "---- ${repo_full}#${num} ----"
    echo "title: $title"
    echo "url:   $url"
    echo "sast:  $sast"

    if [[ "$dry" == "1" ]]; then
      echo "[DRY_RUN] would inspect merge state and merge or resolve SAST conflicts"
      continue
    fi

    local _pr_json
    if ! _pr_json=$(gh pr view "$num" --repo "$repo_full" --json mergeable 2>/dev/null); then
      echo "skip: cannot view PR (no access?)"
      continue
    fi
    mergeable=$(echo "$_pr_json" | jq -r '.mergeable // "UNKNOWN"')
    v_log "PR ${repo_full}#${num} mergeable=${mergeable}"

    if [[ "$mergeable" == "UNKNOWN" ]]; then
      echo "skip: mergeability unknown (wait and retry)"
      continue
    fi

    if [[ "$mergeable" == "CONFLICTING" ]]; then
      if [[ "$sast" == true ]]; then
        echo "SAST PR has conflicts: resolving by merging base into PR branch (-X ours) ..."
        if resolve_sast_conflicts_via_git "$repo_full" "$num"; then
          sleep 4
          mergeable=$(gh pr view "$num" --repo "$repo_full" --json mergeable -q .mergeable)
          echo "mergeable after fix: $mergeable"
        else
          echo "skip: could not auto-resolve conflicts"
          continue
        fi
      else
        echo "skip: conflicts on non-SAST PR (resolve manually)"
        continue
      fi
    fi

    if [[ "$mergeable" != "MERGEABLE" ]]; then
      echo "skip: mergeable=$mergeable"
      continue
    fi

    set +e
    set +u
    try_approve_and_merge "$repo_full" "$num" "$method" "${admin_flag[@]+"${admin_flag[@]}"}"
    merge_ec=$?
    set -u
    set -e
    if [[ "$merge_ec" -eq 0 ]]; then
      echo "merged OK"
    else
      echo "skip/error: merge failed or script error on ${repo_full}#${num} (exit ${merge_ec}). Try MERGE_ADMIN=1 or fix CI." >&2
      v_log "merge attempt exit=${merge_ec} repo=${repo_full} num=${num}"
    fi
    sleep "${MERGE_INTER_PR_SLEEP:-1}"  # avoid GitHub API rate-limiting between sequential merges
  done < <(echo "$json" | jq -c '.[]')

  local phase_t1=$SECONDS
  echo "==> ${phase_label} … : used $(format_duration_human $((phase_t1 - phase_t0))) (merge / skip pass)" >&2
}

# On PR head branch: merge origin/base with -X ours so conflict hunks keep the PR (tool) side.
resolve_sast_conflicts_via_git() {
  local repo_full="$1" num="$2"
  local token="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
  [[ -z "$token" ]] && {
    echo "error: need GH_TOKEN or gh auth token to resolve conflicts" >&2
    return 1
  }

  local head_branch base_branch
  head_branch=$(gh pr view "$num" --repo "$repo_full" --json headRefName -q .headRefName)
  base_branch=$(gh pr view "$num" --repo "$repo_full" --json baseRefName -q .baseRefName)

  local clone_url="https://x-access-token:${token}@github.com/${repo_full}.git"
  local workdir
  workdir=$(mktemp -d)

  echo "==> Clone PR head branch ${head_branch} (shallow) ..."
  # Trap is set after clone so a clone failure can do explicit cleanup and return 1
  # (set -e is suppressed when this function is called in an `if` context).
  if ! git clone --depth=200 --branch "$head_branch" "$clone_url" "$workdir" 2>&1; then
    echo "error: git clone failed (check token permissions or branch name)" >&2
    rm -rf "$workdir"
    return 1
  fi
  trap 'rm -rf "${workdir}"' RETURN
  pushd "$workdir" >/dev/null

  git config user.email "${GIT_AUTHOR_EMAIL:-$(gh api user -q .email 2>/dev/null || echo "${MY_LOGIN}@users.noreply.github.com")}"
  git config user.name "${GIT_AUTHOR_NAME:-$MY_LOGIN}"

  git fetch origin "$base_branch" --depth=200

  echo "==> Merge origin/${base_branch} into ${head_branch} favoring PR branch (-X ours) ..."
  if ! git merge "origin/${base_branch}" -m "Merge ${base_branch} into ${head_branch} (automated: favor PR branch on conflicts)" -X ours; then
    echo "error: git merge still failed (binary conflict or depth?). Try manual fix." >&2
    popd >/dev/null
    return 1
  fi

  echo "==> Push updated ${head_branch} ..."
  if ! git push origin "HEAD:refs/heads/${head_branch}"; then
    echo "error: git push failed (branch protection / permissions?)" >&2
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
  trap - RETURN
  rm -rf "${workdir}"
  echo "==> Conflicts resolved on remote; PR should be mergeable soon."
  return 0
}

try_approve_and_merge() {
  local repo_full="$1" num="$2" method="$3"
  shift 3
  local -a extra_flags=("$@")

  gh pr review "$num" --repo "$repo_full" --approve --body "Approved: automated merge." 2>/dev/null || true
  gh pr merge "$num" --repo "$repo_full" --"$method" "${extra_flags[@]}" "${DELETE_FLAG_ARR[@]+"${DELETE_FLAG_ARR[@]}"}"
}

merge_all_pull_requests() {
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh (GitHub CLI) is required" >&2
    exit 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required" >&2
    exit 1
  }
  command -v git >/dev/null 2>&1 || {
    echo "error: git is required" >&2
    exit 1
  }

  local _run_t0=$SECONDS
  local _ident_t0=$SECONDS
  load_allowed_owners
  local _ident_t1=$SECONDS
  echo "==> Step timing — gh api user + orgs list … : used $(format_duration_human $((_ident_t1 - _ident_t0)))" >&2

  local limit="${PR_LIMIT:-300}"
  local dry="${DRY_RUN:-0}"
  local method="${MERGE_METHOD:-merge}"
  local only_sast="${MERGE_ONLY_SAST:-0}"
  # Do not use `local admin_flag` here: bash 3.2 + `local` inside the PR `while` loop
  # can leave admin_flag unset when expanding "${admin_flag[@]}" under `set -u`.
  admin_flag=()
  DELETE_FLAG_ARR=()
  [[ "${MERGE_ADMIN:-0}" == "1" ]] && admin_flag+=(--admin)
  [[ "${DELETE_BRANCH:-0}" == "1" ]] && DELETE_FLAG_ARR+=(--delete-branch)

  echo "==> Logged in as: $MY_LOGIN"
  echo "==> Orgs (${#MY_ORGS[@]}): ${MY_ORGS[*]:-(none)}"
  v_log "PR_LIMIT=${limit} DRY_RUN=${dry} MERGE_ONLY_SAST=${only_sast} MERGE_ADMIN=${MERGE_ADMIN:-0} MERGE_SEARCH_BY_AUTHOR=${MERGE_SEARCH_BY_AUTHOR:-0} GH_SEARCH_TIMEOUT_SEC=${GH_SEARCH_TIMEOUT_SEC:-0}"

  local use_author=0
  [[ "${MERGE_SEARCH_BY_AUTHOR:-0}" == "1" ]] && use_author=1

  echo "    Note: each \`gh search\` blocks until the API returns. Many open PRs → 30s–2m is normal." >&2
  echo "==> Order: Phase 1 = your user namespace (${MY_LOGIN}/*), then Phase 2 = each org; one PR at a time." >&2

  local json
  local org

  echo "==> Phase 1: searching & merging personal namespace (owner=${MY_LOGIN}) …" >&2
  json=$(search_prs_for_owner_namespace "$MY_LOGIN" "$limit" "$use_author")
  merge_pull_requests_from_json "$json" "Phase 1 — personal repos" "$dry" "$method" "$only_sast"

  for org in "${MY_ORGS[@]}"; do
    echo "==> Phase 2: searching & merging org namespace (owner=${org}) …" >&2
    json=$(search_prs_for_owner_namespace "$org" "$limit" "$use_author")
    merge_pull_requests_from_json "$json" "Phase 2 — org ${org}" "$dry" "$method" "$only_sast"
  done

  local _run_t1=$SECONDS
  echo ""
  echo "==> Step timing — total sast-prs run … : used $(format_duration_human $((_run_t1 - _run_t0)))" >&2
  echo "Done."
}

# --- Mode: PR automation ---
if [[ "${1:-}" == "sast-prs" ]] || [[ "${MERGE_SAST_PRS:-}" == "1" ]]; then
  MERGE_SCRIPT_VERBOSE="${MERGE_SCRIPT_VERBOSE:-0}"
  [[ "${2:-}" == "-v" || "${2:-}" == "--verbose" ]] && MERGE_SCRIPT_VERBOSE=1
  [[ "${MERGE_VERBOSE:-0}" == "1" ]] && MERGE_SCRIPT_VERBOSE=1
  # VERBOSE=2, 100, yes, … all turn on (only 0 / false / no / off stay off)
  if [[ -n "${VERBOSE+x}" ]]; then
    case "${VERBOSE}" in
      0 | false | no | NO | off | OFF) ;;
      *) MERGE_SCRIPT_VERBOSE=1 ;;
    esac
  fi
  export MERGE_SCRIPT_VERBOSE
  export GH_HEARTBEAT_SEC="${GH_HEARTBEAT_SEC:-3}"
  export MERGE_SEARCH_PROGRESS_SEC="${MERGE_SEARCH_PROGRESS_SEC:-15}"
  merge_branch_start_session_log "merge-branch-$(date '+%Y%m%d-%H%M%S').log"
  merge_all_pull_requests
  exit 0
fi

# --- Mode: show usage if no CI vars ---
if [[ -z "${branch1:-}" || -z "${branch2:-}" ]]; then
  echo >&2 ""
  echo >&2 "merge-branch.sh: 未選模式。若要自動處理 GitHub PR，請加上第一個參數: sast-prs"
  echo >&2 "  例: .github/script/merge-branch.sh sast-prs"
  echo >&2 "  或: DRY_RUN=1 .github/script/merge-branch.sh sast-prs"
  echo >&2 ""
  usage
  exit 1
fi

# --- CI branch merge (original behavior) ---
merge_branch_start_session_log "merge-branch-ci-$(date '+%Y%m%d-%H%M%S').log"
git config user.name github-actions[bot]
git config user.email github-actions[bot]@users.noreply.github.com

echo "If branch $branch2 exists, merge branch $branch1 into branch $branch2"
if git show-ref --quiet "refs/heads/$branch2"; then
  git checkout "$branch2"
  git merge "$branch1"
  git push origin "$branch2"
else
  echo "Branch $branch2 does not exist"
fi
