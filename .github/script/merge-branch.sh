#!/usr/bin/env bash
# Make sure this file is executable
# chmod a+x .github/script/merge-branch.sh
#
# MODES
# 1) CI branch merge (legacy): requires env branch1 and branch2
# 2) PR automation (from repo root):
#      .github/script/merge-branch.sh sast-prs
#
# PR mode collects open PRs under your user namespace and your orgs (search:
# user:LOGIN + org:ORG...), de-duplicates, then for each PR tries merge when you
# have rights. Non-SAST PRs: merge only when GitHub reports no conflicts.
# SAST titles (Snyk/Semgrep/Husky/CodeRabbit): if mergeable, merge; if conflicting,
# merges base into the PR branch locally with strategy "ours" (keep PR / tool side),
# pushes, then merges on GitHub.
#
# Requires: gh, jq, git. Auth: gh auth login or GH_TOKEN (Actions / PAT).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  CI merge (env):  branch1=origin/main branch2=ci .github/script/merge-branch.sh
  PR automation:   .github/script/merge-branch.sh sast-prs
                   DRY_RUN=1 .github/script/merge-branch.sh sast-prs

Environment (PR mode):
  DRY_RUN=1           Print actions only
  MERGE_METHOD=merge  merge | squash | rebase (default: merge)
  MERGE_ADMIN=1       gh pr merge --admin when checks block merge
  DELETE_BRANCH=1     gh pr merge --delete-branch
  PR_LIMIT=100        Per search query cap (default 100)
  MERGE_ONLY_SAST=1   Only process PRs whose title matches SAST keywords (legacy)
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

collect_open_prs_in_namespaces() {
  local limit="${1:-100}"
  local parts=()

  echo "==> Searching open PRs: user:${MY_LOGIN} (non-draft) ..."
  parts+=("$(gh search prs "is:open is:pr is:draft:false user:${MY_LOGIN}" \
    --json number,title,url,repository \
    --limit "$limit" 2>/dev/null || echo '[]')")

  local org
  for org in "${MY_ORGS[@]}"; do
    echo "==> Searching open PRs: org:${org} (non-draft) ..."
    parts+=("$(gh search prs "is:open is:pr is:draft:false org:${org}" \
      --json number,title,url,repository \
      --limit "$limit" 2>/dev/null || echo '[]')")
  done

  local combined='[]'
  local p
  for p in "${parts[@]}"; do
    combined=$(jq -n --argjson a "$combined" --argjson b "$p" '$a + $b')
  done
  echo "$combined" | jq 'unique_by(.url)'
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
  trap 'rm -rf "${workdir}"' RETURN

  echo "==> Clone PR head branch ${head_branch} (shallow) ..."
  git clone --depth=80 --branch "$head_branch" "$clone_url" "$workdir"
  pushd "$workdir" >/dev/null

  git config user.email "${GIT_AUTHOR_EMAIL:-$(gh api user -q .email 2>/dev/null || echo "${MY_LOGIN}@users.noreply.github.com")}"
  git config user.name "${GIT_AUTHOR_NAME:-$MY_LOGIN}"

  git fetch origin "$base_branch" --depth=80

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
  gh pr merge "$num" --repo "$repo_full" --"$method" "${extra_flags[@]}" "${DELETE_FLAG_ARR[@]}"
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

  load_allowed_owners

  local limit="${PR_LIMIT:-100}"
  local dry="${DRY_RUN:-0}"
  local method="${MERGE_METHOD:-merge}"
  local only_sast="${MERGE_ONLY_SAST:-0}"
  local admin_flag=()
  declare -ga DELETE_FLAG_ARR=()
  [[ "${MERGE_ADMIN:-0}" == "1" ]] && admin_flag+=(--admin)
  [[ "${DELETE_BRANCH:-0}" == "1" ]] && DELETE_FLAG_ARR+=(--delete-branch)

  echo "==> Logged in as: $MY_LOGIN"
  echo "==> Orgs: ${MY_ORGS[*]:-(none)}"

  local json
  json=$(collect_open_prs_in_namespaces "$limit")

  local count
  count=$(echo "$json" | jq 'length')
  echo "==> Unique open PRs (user + org searches): $count"

  echo "$json" | jq -c '.[]' | while read -r row; do
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

    if ! gh pr view "$num" --repo "$repo_full" --json mergeable &>/dev/null; then
      echo "skip: cannot view PR (no access?)"
      continue
    fi

    mergeable=$(gh pr view "$num" --repo "$repo_full" --json mergeable -q .mergeable)

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

    if try_approve_and_merge "$repo_full" "$num" "$method" "${admin_flag[@]}"; then
      echo "merged OK"
    else
      echo "merge failed (checks, reviews, or permissions). Try MERGE_ADMIN=1 or fix CI."
    fi
  done

  echo ""
  echo "Done."
}

# --- Mode: PR automation ---
if [[ "${1:-}" == "sast-prs" ]] || [[ "${MERGE_SAST_PRS:-}" == "1" ]]; then
  merge_all_pull_requests
  exit 0
fi

# --- Mode: show usage if no CI vars ---
if [[ -z "${branch1:-}" || -z "${branch2:-}" ]]; then
  usage
  exit 1
fi

# --- CI branch merge (original behavior) ---
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
