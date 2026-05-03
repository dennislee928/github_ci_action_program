# `.github/script`

此目錄放給本機或 CI 使用的 shell／輔助說明；PR 自動合併相關流程見下方。

## `merge-branch.sh`

**需求：** `gh`、`jq`、`git`。認證：`gh auth login` 或環境變數 `GH_TOKEN`（Actions／PAT）。

**模式：**

| 模式 | 說明 |
|------|------|
| **CI 分支合併（舊）** | 需設定 `branch1`、`branch2`（例如由 workflow 注入），將 `branch1` 合併進 `branch2` 並 push。 |
| **PR 自動化** | 在**儲存庫根目錄**執行：`.github/script/merge-branch.sh sast-prs` |

PR 模式會搜尋你帳號與所屬 org 底下未合併、非 draft 的 PR，去重後依權限嘗試合併。非 SAST 類 PR 若 GitHub 判定有衝突則略過。標題含 Snyk / Semgrep / Husky / CodeRabbit 的 SAST 類 PR：可合併則合併；若衝突則在 PR 分支上合併 base 並使用 **`-X ours`** 保留 PR 側內容，再 push 後於 GitHub 合併。

**常用環境變數（PR 模式）：**

- `DRY_RUN=1`：只列出將執行的動作  
- `MERGE_METHOD=merge|squash|rebase`（預設 `merge`）  
- `MERGE_ADMIN=1`：允許 `gh pr merge --admin`  
- `DELETE_BRANCH=1`：合併後刪分支  
- `PR_LIMIT`：每個搜尋查詢上限（預設 100）  
- `MERGE_ONLY_SAST=1`：只處理標題符合上述 SAST 關鍵字的 PR  

完整用法請執行腳本並閱讀其 `--`/無參數時印出的說明（或見檔案開頭 `usage()`）。

## GitHub Actions 排程

Workflow：`.github/workflows/weekly-merge-sast-prs.yml`  
於排程或 `workflow_dispatch` 執行 `merge-branch.sh sast-prs`。若需合併**其他儲存庫**的 PR，請設定 secret `SAST_MERGE_GITHUB_TOKEN`（詳見該 workflow 檔案內註解）。

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
