#!/usr/bin/env bash
# Make sure this file is executable
# chmod a+x .github/script/merge-branch.sh
#
# MODES
# 1) CI branch merge (legacy): requires env branch1 and branch2
# 2) SAST PR automation: ./merge-branch.sh sast-prs
#    or: MERGE_SAST_PRS=1 ./merge-branch.sh
#
# SAST mode lists your open PRs, keeps only repos you own or belong to your orgs,
# matches titles for Snyk / Semgrep / Husky / CodeRabbit (case-insensitive), then
# approves and merges. Requires: gh CLI, jq, and auth (gh auth login).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  CI merge (env):  branch1=origin/main branch2=ci ./merge-branch.sh
  SAST PRs:        ./merge-branch.sh sast-prs
                   MERGE_SAST_PRS=1 ./merge-branch.sh

Environment (SAST mode):
  DRY_RUN=1          Only print actions, no approve/merge
  MERGE_METHOD=merge Merge strategy: merge | squash | rebase (default: merge)
  MERGE_ADMIN=1      Pass --admin to gh pr merge (bypass protection if you have rights)
  DELETE_BRANCH=1    After merge, delete the remote head branch (optional)
  PR_LIMIT=100       Max PRs from search (default 100)
EOF
}

# --- SAST / tooling PR detection (title substring, case-insensitive) ---
is_sast_pr_title() {
  local t="$1"
  [[ -z "$t" ]] && return 1
  echo "$t" | grep -qiE 'snyk|semgrep|husky|coderabbit'
}

# owner is allowed if it is the logged-in user or one of their GitHub orgs
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

merge_sast_pull_requests() {
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh (GitHub CLI) is required" >&2
    exit 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required" >&2
    exit 1
  }

  load_allowed_owners

  local limit="${PR_LIMIT:-100}"
  local dry="${DRY_RUN:-0}"
  local method="${MERGE_METHOD:-merge}"
  local admin_flag=()
  local delete_flag=()
  [[ "${MERGE_ADMIN:-0}" == "1" ]] && admin_flag+=(--admin)
  [[ "${DELETE_BRANCH:-0}" == "1" ]] && delete_flag+=(--delete-branch)

  echo "==> Logged in as: $MY_LOGIN"
  echo "==> Orgs: ${MY_ORGS[*]:-(none)}"
  echo "==> Searching open PRs authored by you (author:${MY_LOGIN})..."

  local json
  json=$(gh search prs "is:open is:pr author:${MY_LOGIN}" \
    --json number,title,url,repository \
    --limit "$limit" 2>/dev/null) || json="[]"

  local count
  count=$(echo "$json" | jq 'length')
  echo "==> Found $count open PR(s) from search"

  echo "$json" | jq -c '.[]' | while read -r row; do
    local title url repo_full owner num
    title=$(echo "$row" | jq -r '.title')
    url=$(echo "$row" | jq -r '.url')
    num=$(echo "$row" | jq -r '.number')
    repo_full=$(echo "$row" | jq -r '.repository.nameWithOwner // empty')
    [[ -z "$repo_full" || "$repo_full" == "null" ]] && {
      echo "skip (no repo): $title"
      continue
    }
    owner="${repo_full%%/*}"

    if ! repo_owner_allowed "$owner"; then
      echo "skip (not your user/org repo): $repo_full — $title"
      continue
    fi

    if ! is_sast_pr_title "$title"; then
      echo "skip (not SAST tool title): ${repo_full}#${num} — $title"
      continue
    fi

    echo ""
    echo "---- $repo_full#$num ----"
    echo "title: $title"
    echo "url:   $url"

    if [[ "$dry" == "1" ]]; then
      echo "[DRY_RUN] would: gh pr review --approve && gh pr merge --$method"
      continue
    fi

    if ! gh pr view "$num" --repo "$repo_full" --json mergeable,mergeStateStatus &>/dev/null; then
      echo "error: cannot view PR (permissions? repo gone?)" >&2
      continue
    fi

    local mergeable state
    mergeable=$(gh pr view "$num" --repo "$repo_full" --json mergeable -q .mergeable)
    state=$(gh pr view "$num" --repo "$repo_full" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || echo "UNKNOWN")

    echo "mergeable=$mergeable mergeStateStatus=$state"

    if [[ "$mergeable" == "CONFLICTING" ]]; then
      echo "skip: merge conflicts"
      continue
    fi

    # Approve (ignore failure if already approved or not permitted)
    gh pr review "$num" --repo "$repo_full" --approve --body "Approved: automated SAST dependency/tooling PR." 2>/dev/null || true

    if gh pr merge "$num" --repo "$repo_full" --"$method" "${admin_flag[@]}" "${delete_flag[@]}" 2>/dev/null; then
      echo "merged OK"
    else
      echo "merge failed (failing checks or branch protection?). Retry with MERGE_ADMIN=1 if appropriate, or fix CI."
    fi
  done

  echo ""
  echo "Done."
}

# --- Mode: SAST PRs ---
if [[ "${1:-}" == "sast-prs" ]] || [[ "${MERGE_SAST_PRS:-}" == "1" ]]; then
  merge_sast_pull_requests
  exit 0
fi

# --- Mode: show usage if no CI vars ---
if [[ -z "${branch1:-}" || -z "${branch2:-}" ]]; then
  usage
  exit 1
fi

# --- CI branch merge (original behavior) ---
# USAGE: This script is used to merge a branch into another branch
# BACKGROUND: This operation is required to avoid conflicts between branches.

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
