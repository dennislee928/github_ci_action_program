在專案裡從 Worker 目錄 部署，可照下面做（路徑請依你的機器調整）：

cd {$}/.github/script/cloudflare_workers
首次／換帳號時登入 Cloudflare：

npx wrangler@latest login
設定 GitHub Token（機密，勿寫進 wrangler.toml）：

npx wrangler@latest secret put GITHUB_TOKEN
（可選） 在 wrangler.toml 的 [vars] 已改好 GITHUB_REPO 等之後再部署。

部署：

npx wrangler@latest deploy
本機模擬 Cron（開發用）：

npx wrangler@latest dev --test-scheduled
一次走完：login → secret put GITHUB_TOKEN → 確認 [vars] → deploy。