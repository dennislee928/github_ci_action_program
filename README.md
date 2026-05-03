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

## PR Automation

Two scripts handle automated PR merging. Use `fast-merge-mergeable-prs.sh` for speed (GraphQL, parallel), and `merge-branch.sh` for the sequential SAST-focused sweep.

### `fast-merge-mergeable-prs.sh` — 4-phase parallel merge

Script: `.github/script/fast-merge-mergeable-prs.sh`

#### Quick start

```bash
# Dry run (list what would happen):
DRY_RUN=1 .github/script/fast-merge-mergeable-prs.sh

# Run for real:
.github/script/fast-merge-mergeable-prs.sh

# Verbose output for external-PR details:
VERBOSE=1 .github/script/fast-merge-mergeable-prs.sh
```

#### How it works

| Phase | What happens |
|-------|-------------|
| **1** | GraphQL fetch — all open non-draft PRs with `mergeable` state in one call (typically < 5 s). Repos not owned by you or your orgs → `SKIP_EXTERNAL` immediately. |
| **2** | `MERGEABLE` PRs — immediate parallel merge (`--admin` by default). |
| **3** | `UNKNOWN` PRs — re-check after Phase 2 delay; merge if `MERGEABLE`; route to Phase 4 if now `CONFLICTING` (`REQUEUE_P4`). |
| **4** | `CONFLICTING` SAST PRs (Snyk/Semgrep/Husky/CodeRabbit) — blobless clone (`--filter=blob:none`), `git merge -X ours` (keep PR side), push; if merge still fails after a retry, logs reason. Non-SAST → `SKIP_CONFLICT`. |

**Result tags:**

| Tag | Meaning |
|-----|---------|
| `[MERGED]` | Successfully merged |
| `[MERGED_CONFLICT]` | Conflict auto-resolved and merged (with optional retry) |
| `[REQUEUE_P4]` | Was UNKNOWN at fetch; turned CONFLICTING in Phase 3 → processed in Phase 4 |
| `[SKIP_EXTERNAL]` | Repo not owned by you/your orgs — skipped without attempting |
| `[SKIP_CONFLICT]` | Non-SAST conflicting PR — fix manually or run `merge-branch.sh` |
| `[SKIP_UNKNOWN]` | Still UNKNOWN after retry — re-run in a few minutes |
| `[ERROR]` | Merge failed in owned repo (CI / branch protection / token scope) |
| `[ERROR_CONFLICT]` | Post-resolution merge failed (see `reason=` in log). Common cause: an adjacent PR merged first, making this one conflicting again. Fix: re-run, or close and let Snyk reopen. |

#### Key environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | 0 | Print actions only, no merges |
| `MERGE_METHOD` | merge | `merge` / `squash` / `rebase` |
| `MERGE_ADMIN` | 1 | `--admin` flag; bypasses branch protection |
| `DELETE_BRANCH` | 0 | Delete head branch after merge |
| `PARALLEL` | 8 | Concurrent workers for Phase 2 & 3 |
| `CONFLICT_PARALLEL` | 4 | Concurrent workers for Phase 4 |
| `GQL_TIMEOUT_SEC` | 60 | GraphQL fetch timeout (seconds) |
| `VERBOSE` | 0 | Show `SKIP_EXTERNAL` PR details |
| `FAST_MERGE_LOG` | — | Append all result lines to this file |

---

### `merge-branch.sh sast-prs` — sequential SAST sweep

Script: `.github/script/merge-branch.sh` · Workflow: `.github/workflows/weekly-merge-sast-prs.yml`

#### Quick start

```bash
# List only (no merges):
DRY_RUN=1 GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs

# Run for real — your PRs only, 120 s search cap:
GH_SEARCH_TIMEOUT_SEC=120 MERGE_SEARCH_BY_AUTHOR=1 \
  .github/script/merge-branch.sh sast-prs
```

#### How it works

| Phase | Scope |
|-------|-------|
| Phase 1 | Your user namespace (`owner=LOGIN`) |
| Phase 2 | Each org you belong to (`owner=ORG`), one at a time |

- `MERGE_SEARCH_BY_AUTHOR=1` adds `--author LOGIN` to every `gh search prs` call.
- SAST PRs (title matches Snyk / Semgrep / Husky / CodeRabbit): if conflicting, the base is merged into the PR branch locally with `-X ours` (keeps the tool side), then pushed before the GitHub merge.
- Non-SAST PRs with conflicts are skipped (resolve manually).
- A 1 s sleep between merges prevents GitHub API rate-limiting (`MERGE_INTER_PR_SLEEP` to override).

#### Key environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GH_SEARCH_TIMEOUT_SEC` | 0 (none) | Cap each `gh search prs` call (recommended: `120`) |
| `MERGE_SEARCH_BY_AUTHOR` | 0 | Restrict search to your PRs (`--author LOGIN`) |
| `MERGE_INTER_PR_SLEEP` | 1 | Seconds between sequential merges |
| `DRY_RUN` | 0 | Print actions only, no merges |
| `MERGE_METHOD` | merge | `merge` / `squash` / `rebase` |
| `MERGE_ADMIN` | 0 | `gh pr merge --admin` (bypasses branch protection) |
| `DELETE_BRANCH` | 0 | Delete PR branch after merge |
| `MERGE_ONLY_SAST` | 0 | Only process SAST-keyword PRs |

### Workflow permissions

Both scripts require `pull-requests: write` and `contents: write` for `GITHUB_TOKEN`. Without `SAST_MERGE_GITHUB_TOKEN` (a PAT with `repo` + `read:org`), merges are limited to this repository only.

To enable `fast-merge-mergeable-prs.sh` in the weekly workflow, trigger `workflow_dispatch` and set **fast_merge = true**.

---

Get help: [Post in our discussion board](https://github.com/orgs/skills/discussions/categories/test-with-actions) &bull; [Review the GitHub status page](https://www.githubstatus.com/)

&copy; 2023 GitHub &bull; [Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md) &bull; [MIT License](https://gh.io/mit)

</footer>
