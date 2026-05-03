/**
 * 每週兩次（wrangler.toml crons）呼叫 GitHub Actions workflow_dispatch，
 * 由既有 workflow 執行 .github/script/merge-branch.sh sast-prs。
 *
 * 環境變數（Wrangler [vars] 或 Dashboard）：
 *   GITHUB_REPO    owner/repo
 *   WORKFLOW_FILE  預設 weekly-merge-sast-prs.yml
 *   DEFAULT_BRANCH 預設 main
 *   CRON_SECRET    選填；若設定，HTTP 手動觸發時須帶 Header: X-Cron-Secret
 *
 * 機密：GITHUB_TOKEN（wrangler secret put）
 */

export interface Env {
  GITHUB_TOKEN: string;
  GITHUB_REPO: string;
  WORKFLOW_FILE?: string;
  DEFAULT_BRANCH?: string;
  CRON_SECRET?: string;
}

export default {
  async scheduled(_event: ScheduledEvent, env: Env, _ctx: ExecutionContext): Promise<void> {
    try {
      await dispatchMergeWorkflow(env);
      console.log("[merge-sast-prs-cron] workflow_dispatch OK");
    } catch (e) {
      console.error("[merge-sast-prs-cron] failed:", e);
      throw e;
    }
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST" && request.method !== "GET") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const secret = env.CRON_SECRET;
    if (secret) {
      const hdr = request.headers.get("X-Cron-Secret");
      if (hdr !== secret) {
        return new Response("Unauthorized", { status: 401 });
      }
    }

    try {
      const res = await dispatchMergeWorkflow(env);
      return new Response(JSON.stringify({ ok: true, status: res.status }), {
        status: 200,
        headers: { "content-type": "application/json; charset=utf-8" },
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return new Response(JSON.stringify({ ok: false, error: msg }), {
        status: 502,
        headers: { "content-type": "application/json; charset=utf-8" },
      });
    }
  },
};

async function dispatchMergeWorkflow(env: Env): Promise<Response> {
  const repo = env.GITHUB_REPO?.trim();
  if (!repo || repo.includes("YOUR_ORG")) {
    throw new Error("Set GITHUB_REPO in wrangler.toml [vars] or Worker settings.");
  }

  const workflow = env.WORKFLOW_FILE?.trim() || "weekly-merge-sast-prs.yml";
  const ref = env.DEFAULT_BRANCH?.trim() || "main";
  const token = env.GITHUB_TOKEN;
  if (!token) {
    throw new Error("Missing GITHUB_TOKEN secret.");
  }

  const url = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`;

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "cloudflare-worker-merge-sast-prs-cron",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ ref }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`GitHub API ${res.status}: ${text}`);
  }

  return res;
}
