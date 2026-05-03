<header>

<!--
  <<< Author notes: Course header >>>
  Include a 1280×640 image, course title in sentence case, and a concise description in emphasis.
  In your repository settings: enable template repository, add your 1280×640 social image, auto delete head branches.
  Add your open source license, GitHub uses MIT license.
-->

# Test with Actions

_Create workflows that enable you to use Continuous Integration (CI) for your projects._

</header>

<!--
  <<< Author notes: Step 1 >>>
  Choose 3-5 steps for your course.
  The first step is always the hardest, so pick something easy!
  Link to docs.github.com for further explanations.
  Encourage users to open new tabs for steps!
-->

## Step 1: Add a test workflow

_Welcome to "GitHub Actions: Continuous Integration"! :wave:_

**What is _continuous integration_?**: [Continuous integration](https://en.wikipedia.org/wiki/Continuous_integration) can help you stick to your team’s quality standards by running tests and reporting the results on GitHub. CI tools run builds and tests, triggered by commits. The quality results post back to GitHub in the pull request. The goal is fewer issues in `main` and faster feedback as you work.

![An illustration with a left half and a right half. On the left: illustration of how GitHub Actions terms are encapsulated. At the highest level: workflows and event triggers. Inside workflows: jobs and definition of the build environment. Inside jobs: steps. Inside steps: a call to an action. On the right: the evaluated sequence: workflow, job, step, action.](https://user-images.githubusercontent.com/6351798/88589835-f5ce0900-d016-11ea-8c8a-0e7d7907c713.png)

- **Workflow**: A workflow is a unit of automation from its start to finish, including the definition of what triggers the automation, what environment or other aspects should be taken into account during the automation, and what should happen as a result of the trigger.
- **Job**: A job is a section of the workflow, and is made up of one or more steps. In this section of our workflow, the template defines the steps that make up the `build` job.
- **Step**: A step represents one _effect_ of the automation. A step could be defined as a GitHub Action, or another unit, like printing something to the console.
- **Action**: An action is a piece of automation written in a way that is compatible with workflows. Actions can be written by GitHub, by the open source community, or you can write them yourself!

To learn more, check out [Workflow syntax for GitHub Actions](https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions) in the GitHub Docs.

First, let's add a workflow to lint (clean, like a lint roller) our Markdown files in this repository.

### :keyboard: Activity: Add a test workflow

1. Open a new browser tab, and work through the following steps in that tab while you read the instructions in this tab.
1. Go to the **Actions tab**.
1. Click **New workflow**.
1. Search for "Simple workflow" and click **Configure**.
1. Name your workflow `ci.yml`.
1. Update the workflow by deleting the last two steps.
1. Add the following step at the end of your workflow:
   ```yml
   - name: Run markdown lint
     run: |
       npm install remark-cli remark-preset-lint-consistent
       npx remark . --use remark-preset-lint-consistent --frail
   ```
   > Even after the code is indented properly in `ci.yml`, you will see a build error in GitHub Actions. We'll fix this in the next step.
1. Click **Commit changes...**, and choose to make a new branch named `ci`.
1. Click **Propose changes**.
1. Click **Create pull request**.
1. Wait about 20 seconds and then refresh this page (the one you're following instructions from). [GitHub Actions](https://docs.github.com/actions) will automatically update to the next step.

<footer>

<!--
  <<< Author notes: Footer >>>
  Add a link to get support, GitHub status page, code of conduct, license link.
-->

---

GH_SEARCH_TIMEOUT_SEC
新增 run_with_timeout_sec：會依序嘗試 timeout、gtimeout，否則用 bash 背景程序送 SIGTERM。
0 或未設定：不加逾時（維持以往行為）。
gh search prs 逾時：在 stderr 印錯誤，該次搜尋視為 []，流程會繼續下一階段。
MERGE_SEARCH_BY_AUTHOR=1
每次搜尋改為：gh search prs --author "$MY_LOGIN" --owner <命名空間>，較接近網頁的 author:，且仍限定在你的 user / 各 org 底下。
MERGE_SEARCH_BY_AUTHOR 未設或為 0：維持原本的 --owner only（該命名空間底下所有 open PR，不限作者）。
順序：個人 repo → 各 org
Phase 1：只對 owner=$MY_LOGIN 搜尋並跑完整 merge 流程。
Phase 2：對 MY_ORGS 裡每個 org 各搜尋一次並各自 merge。
每個 phase 內仍會做 repo_owner_allowed、SAST / mergeable / try_approve_and_merge 等既有邏輯。
檔案
.github/script/merge-branch.sh：上述邏輯與 merge_pull_requests_from_json 抽出共用。
.github/workflows/weekly-merge-sast-prs.yml：註解裡加上可選的 GH_SEARCH_TIMEOUT_SEC、MERGE_SEARCH_BY_AUTHOR。
2. 使用範例
貼近網頁「你開的 PR」、先個人再 org，並為每次 search 加上 120 秒上限：

GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs
只看（不 merge）：

DRY_RUN=1 GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs
3. 為什麼這樣設計
--author + --owner：同一個 author 搜尋在不同命名空間分段做，避免「單一 limit 把個人 PR 塞滿、org PR 完全撈不到」。
Phase 1 → Phase 2：符合你要的「先處理個人 repo，再處理 org」。
逾時：避免 gh search 無限卡住；可依網路環境調高（例如 300）。

---

Get help: [Post in our discussion board](https://github.com/orgs/skills/discussions/categories/test-with-actions) &bull; [Review the GitHub status page](https://www.githubstatus.com/)

&copy; 2023 GitHub &bull; [Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md) &bull; [MIT License](https://gh.io/mit)

</footer>
