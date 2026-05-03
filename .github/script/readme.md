# `.github/script`

此目錄放給本機或 CI 使用的 shell／輔助說明；PR 自動合併相關流程見下方。

## `fast-merge-mergeable-prs.sh` — 4-phase parallel merge

**需求：** `gh`、`jq`、`git`（git 2.17+ for `--filter=blob:none`）。認證：`gh auth login` 或 `GH_TOKEN`。

使用 GraphQL API 一次取回所有 open PR 的 `mergeable` 狀態，不依賴 `gh search prs`（易卡住），速度快 10 倍以上。

### 4 個 Phase

| Phase | 行為 |
|-------|------|
| **1** | GraphQL 取回所有 open non-draft PR 及 `mergeable` 狀態（通常 < 5 s）。不屬於你或你 org 的 repo → `SKIP_EXTERNAL`。 |
| **2** | `MERGEABLE` PR → 平行直接 merge（預設 `--admin`）。 |
| **3** | `UNKNOWN` PR → Phase 2 跑完後重新確認，若 MERGEABLE 就 merge。 |
| **4** | `CONFLICTING` SAST PR（標題含 Snyk/Semgrep/Husky/CodeRabbit）→ blobless clone + `git merge -X ours`（保留 PR 側）+ push + merge。非 SAST → `SKIP_CONFLICT`。 |

### 結果標籤

| 標籤 | 意義 |
|------|------|
| `[MERGED]` | 成功 merge |
| `[MERGED_CONFLICT]` | 衝突自動解決並 merge |
| `[SKIP_EXTERNAL]` | Repo 不屬於你或你的 org，跳過 |
| `[SKIP_CONFLICT]` | 非 SAST 有衝突，需手動解決 |
| `[SKIP_UNKNOWN]` | 重試後仍 UNKNOWN，數分鐘後重跑 |
| `[ERROR]` | 你 org/自己 repo 的 merge 失敗（CI / branch protection / token 權限不足） |
| `[ERROR_CONFLICT]` | SAST 衝突解決失敗（clone 失敗 / git 歷史問題） |

### 常用環境變數

| 變數 | 預設 | 說明 |
|------|------|------|
| `DRY_RUN` | 0 | 只列出動作，不實際 merge |
| `MERGE_METHOD` | merge | `merge` / `squash` / `rebase` |
| `MERGE_ADMIN` | 1 | 加 `--admin`，繞過 branch protection |
| `DELETE_BRANCH` | 0 | merge 後刪除 head branch |
| `PARALLEL` | 8 | Phase 2 & 3 平行 worker 數 |
| `CONFLICT_PARALLEL` | 4 | Phase 4 平行 worker 數 |
| `GQL_TIMEOUT_SEC` | 60 | GraphQL fetch 逾時秒數 |
| `VERBOSE` | 0 | 顯示 `SKIP_EXTERNAL` PR 明細 |
| `FAST_MERGE_LOG` | — | 將所有結果行追加到此檔案 |

```bash
# 快速啟動
gh auth login

# Dry run
DRY_RUN=1 .github/script/fast-merge-mergeable-prs.sh

# 實際執行（含 verbose）
VERBOSE=1 .github/script/fast-merge-mergeable-prs.sh
```

### 已知限制

- **Phase 4 blobless clone**：`--filter=blob:none` 需要 git 2.17+（2018 年後，一般環境均已具備）。該模式下載完整 commit graph（合併時必要），但略過 blob（檔案內容），速度遠快於 full clone。
- **Phase 4 仍失敗**：若 `[ERROR_CONFLICT]` 仍出現，可能是 git server 不支援 partial clone filter，或 repo 有特殊設定；此時需手動 resolve。
- **UNKNOWN 滯留**：部分 PR 需要等 GitHub 後台計算，重跑腳本通常可解決。

---

## `merge-branch.sh`

**需求：** `gh`、`jq`、`git`。認證：`gh auth login` 或環境變數 `GH_TOKEN`（Actions／PAT）。

**模式：**

| 模式 | 說明 |
|------|------|
| **CI 分支合併（舊）** | 需設定 `branch1`、`branch2`（例如由 workflow 注入），將 `branch1` 合併進 `branch2` 並 push。 |
| **PR 自動化** | 在**儲存庫根目錄**執行：`.github/script/merge-branch.sh sast-prs` |

PR 模式會搜尋你帳號與所屬 org 底下未合併、非 draft 的 PR，去重後依權限嘗試合併。非 SAST 類 PR 若 GitHub 判定有衝突則略過。標題含 Snyk / Semgrep / Husky / CodeRabbit 的 SAST 類 PR：可合併則合併；若衝突則在 PR 分支上合併 base 並使用 **`-X ours`** 保留 PR 側內容，再 push 後於 GitHub 合併。

**常用環境變數（PR 模式）：**

| 變數 | 說明 |
|------|------|
| `DRY_RUN=1` | 只列出將執行的動作，不實際合併 |
| `MERGE_METHOD=merge\|squash\|rebase` | 合併方式（預設 `merge`） |
| `MERGE_ADMIN=1` | 允許 `gh pr merge --admin`（繞過 branch protection） |
| `DELETE_BRANCH=1` | 合併後刪除 PR 分支 |
| `PR_LIMIT` | 每個搜尋查詢上限（預設 300） |
| `MERGE_ONLY_SAST=1` | 只處理標題符合 SAST 關鍵字的 PR |
| `GH_SEARCH_TIMEOUT_SEC` | 每次 `gh search prs` 的秒數上限（預設無上限，建議 120） |
| `MERGE_SEARCH_BY_AUTHOR=1` | 搜尋加上 `--author LOGIN`，只看你開的 PR |
| `MERGE_INTER_PR_SLEEP` | 連續合併之間暫停秒數（預設 1，防止 API rate-limit） |
| `VERBOSE=1` / `MERGE_VERBOSE=1` | 開啟 verbose 日誌 |

```bash
# 快速啟動
gh auth login
chmod +x .github/script/merge-branch.sh

# Dry run
DRY_RUN=1 GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs

# 實際執行
GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs

# Verbose
VERBOSE=1 .github/script/merge-branch.sh sast-prs
```

**已知限制 / 設計注意事項：**

- `gh search prs` 使用 GitHub Search API，對 PR / repo 數量多的帳號可能耗時 30s–2m，可設 `GH_SEARCH_TIMEOUT_SEC=120` 加上逾時保護。逾時後該 phase 視為 0 PR 並繼續執行。若需更快速度，改用 `fast-merge-mergeable-prs.sh`（GraphQL）。
- SAST PR 衝突解決（`resolve_sast_conflicts_via_git`）會 clone 深度 200 commit；若 PR 分支與 base 的分歧超過此深度，git merge 可能找不到共同祖先，需手動處理。
- Workflow 需 `pull-requests: write` + `contents: write` 權限，否則 `GITHUB_TOKEN` 無法執行 merge / review。若有設定 `SAST_MERGE_GITHUB_TOKEN`（PAT），則由 PAT 控制。

---

## GitHub Actions 排程

Workflow：`.github/workflows/weekly-merge-sast-prs.yml`  
於排程或 `workflow_dispatch` 執行 `merge-branch.sh sast-prs`。

- `workflow_dispatch` 時勾選 **fast_merge** 可先跑 `fast-merge-mergeable-prs.sh`（4-phase 平行），再跑 `merge-branch.sh`。
- 若需合併**其他儲存庫**的 PR，請設定 secret `SAST_MERGE_GITHUB_TOKEN`（詳見該 workflow 檔案內註解）。

若改由下方 Cloudflare Worker 負責排程觸發，請考慮關閉該 workflow 的 `schedule`，避免與 Workers **重複執行**。

## Cloudflare Worker（每週兩次 Cron）

Worker **無法**執行 bash／git，因此改為依 Cron 呼叫 GitHub API **`workflow_dispatch`**，實際仍由 `weekly-merge-sast-prs.yml` 跑 `merge-branch.sh`。實作與設定位於：

`.github/script/cloudflare_workers/`

部署前請編輯該目錄下 `wrangler.toml` 的 `[vars]`（至少將 `GITHUB_REPO` 從 `YOUR_ORG/...` 改為你的 `owner/repo`），並以 secret 提供可 dispatch 該 workflow 的 `GITHUB_TOKEN`。

在專案目錄中，從 Worker 子目錄執行（路徑請依你 clone 位置調整）：

```bash
cd .github/script/cloudflare_workers
npx wrangler@latest login
npx wrangler@latest secret put GITHUB_TOKEN
npx wrangler@latest deploy
```

本機模擬排程觸發（開發用）：

```bash
cd .github/script/cloudflare_workers
npx wrangler@latest dev --test-scheduled
```

建議流程：`login` → `secret put GITHUB_TOKEN` → 確認 `[vars]` → `deploy`。

更細的 Worker 變數與權限說明見 `cloudflare_workers/wrangler.toml` 頂部註解與 `cloudflare_workers/src/index.ts`。
