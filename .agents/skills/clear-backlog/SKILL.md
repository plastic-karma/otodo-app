---
name: clear-backlog
description: >
  Clear the OTodo coding issue backlog autonomously. Use when asked to clear
  the backlog or work through open issues in otodo project gitobstodo tagged
  coding. Deliver each issue through implementation, full CI, TestFlight,
  promotion to main, and otodo completion, then refresh and continue without
  waiting for manual testing.
---

# clear-backlog

Process one issue at a time until a fresh query finds no remaining issues.
The backlog is the otodo store, not GitHub Issues. The required order is:
**implement → CI → TestFlight → push to main → mark done → refresh**.

## Prerequisites and discovery

1. Read `~/obs/default/.agents/skills/otodo/SKILL.md` before using otodo.
   Follow its CLI, store, mutation, and error-handling rules. Do not replace
   otodo operations with direct Markdown edits or GitHub issue commands.
2. Read this repository's `AGENTS.md`, `docs/RELEASE.md`, and current
   `.github/workflows/ci.yml` and `.github/workflows/release.yml`. Use the
   existing verification and release workflows; do not bypass their gates.
3. Work in this repository (`plastic-karma/otodo-app`). Preserve unrelated
   changes and other worktrees. Fetch `origin/main` and create a dedicated
   issue branch/worktree from it for each issue. Do not start from an unrelated
   feature branch.
4. Check the project and discover its coding issues with the real CLI:

   ```bash
   /home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json project show gitobstodo
   /home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json list --project gitobstodo --tag coding
   ```

   Default `list` excludes terminal tasks, so it includes unfinished work
   without rediscovering done or cancelled issues. Do not use `--all` or
   discard active tasks by limiting discovery to `--state open`. Parse the
   JSON, retain full task IDs, and inspect the selected issue with `show`.
   A command failure is not an empty backlog. If another worker owns an
   issue, coordinate before changing it rather than duplicating its work.

## Per-issue delivery loop

Replace angle-bracket placeholders with the selected task ID, issue branch,
commit SHA, and exact workflow run IDs. Keep the issue branch unchanged while
its CI and release runs execute.

### 1. Implement the fix

```bash
/home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json show <task-id>
```

Read the full issue and acceptance criteria, reproduce the reported behavior,
and implement the complete fix using existing repository patterns. Perform
local verification appropriate to the affected behavior; keep useful
regressions and update affected documentation. Do not require user/manual
acceptance testing. Re-read the task before mutating it through otodo and
verify any state change as prescribed by the otodo skill.

Every new feature must also be mentioned in the app's changelog. Follow
`README.md`'s **Product changelog entries** convention: give every
product-feature commit a user-facing subject and a `Changelog: feature`
trailer. Before pushing, verify the trailer on each product-feature commit
and confirm the generated `Changelog.json` includes each feature.
Do not mark maintenance-only commits as product features.

Commit the scoped fix on the issue branch and push that branch to `origin`
so GitHub Actions can run it. Record the full commit SHA. This preliminary
branch push is required for CI; **do not push to `main` yet**.

### 2. Run CI and wait for success

Dispatch the canonical workflow at the issue branch:

```bash
gh workflow run ci.yml --repo plastic-karma/otodo-app --ref <issue-branch>
gh run list --repo plastic-karma/otodo-app --workflow ci.yml --branch <issue-branch> --commit <sha> --event workflow_dispatch --json databaseId,headSha,headBranch,displayTitle,status,conclusion,url,createdAt
gh run watch <ci-run-id> --repo plastic-karma/otodo-app --exit-status
```

Select the run matching this dispatch, branch, and exact SHA, not the latest
repository-wide run. Require a completed successful **full** run, including
`CI / full verification` and all required jobs. Do not set `test_filter`,
`design_survey_only`, or `complete_diagnostics`; focused/diagnostic runs and
local tests cannot replace full CI.

Diagnose product failures, fix them, retest locally, commit and push the fix,
and run full CI again for the new SHA. Retry transient runner/simulator
infrastructure failures. Do not proceed on a failed, cancelled, queued, or
incomplete run, or weaken tests to obtain a green result.

### 3. When CI passes, run TestFlight

Only after full CI succeeds, dispatch release on the same unchanged branch
and verified SHA:

```bash
gh workflow run release.yml --repo plastic-karma/otodo-app --ref <issue-branch> -f publish_testflight=true
gh run list --repo plastic-karma/otodo-app --workflow release.yml --branch <issue-branch> --commit <sha> --event workflow_dispatch --json databaseId,headSha,headBranch,status,conclusion,url,createdAt
gh run watch <release-run-id> --repo plastic-karma/otodo-app --exit-status
```

Follow `docs/RELEASE.md` for marketing-version overrides and failure recovery.
Confirm the selected run built the exact CI-verified SHA, finished
successfully, and reports an attempted and **accepted App Store Connect
upload**. An exported IPA, a green artifact-only run, or a dispatch receipt
is not TestFlight delivery. Record the release URL, marketing version, build
number, and upload result from the release evidence.

If upload was accepted but certificate cleanup failed, retry only the failed
cleanup job as documented; do not upload again. Fix product/release failures
and retry transient infrastructure failures. Any source change requires a
new full CI pass and TestFlight delivery for the new SHA. Run releases
sequentially. Apple processing is asynchronous; do not wait for manual
testing or claim Apple processing/tester installation was verified.

### 4. When TestFlight passes, push to main

Promote only the exact commit that passed both gates:

```bash
git fetch origin main
git merge-base --is-ancestor origin/main <verified-sha> && git push origin <verified-sha>:refs/heads/main
git ls-remote origin refs/heads/main
```

Verify that the remote main tip is the delivered SHA. Never force-push or
create an unverified squash/merge commit during promotion. If main has
advanced incompatibly or the push is rejected, integrate current
`origin/main` into the issue branch without overwriting others' work, resolve
conflicts, repeat local verification, and rerun **both full CI and TestFlight**
for the resulting SHA before retrying promotion. If main has advanced after
a successful push, fetch and verify it contains the delivered SHA instead of
rewinding it.

### 5. Mark the issue done

Only after successful TestFlight delivery and verified main promotion,
re-read the issue, complete it through otodo, and verify the result:

```bash
/home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json show <task-id>
/home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json complete <task-id>
/home/br/.cargo/bin/otodo --root /home/br/obs/default/todos --format json show <task-id>
```

For a one-off issue, confirm its state is `done`. If the task changed during
delivery, reconcile its current acceptance criteria before completing it.
Respect otodo recurrence semantics if an issue is recurring: completing an
occurrence is not permission to terminate the series. Do not delete issues
or mark failed/undelivered work done. Run otodo `validate` after multi-record
work, as required by the otodo skill.

Report the issue ID/title, delivered commit SHA, CI run URL, release run URL,
marketing version, build number, App Store Connect upload result, main
promotion, and verified task state. This progress report is not a handoff or
a reason to stop.

### 6. Refresh and pick the next issue

Immediately rerun the discovery command for project `gitobstodo` and tag
`coding`, read the next issue, and repeat from current `origin/main`. Never
process only a startup snapshot, stop after one issue, ask for permission to
continue, or wait for manual testing between issues. Invoking this skill
authorizes the issue-branch pushes, CI and TestFlight dispatches, gated main
pushes, and task completions needed for the loop.

Finish only when a successful fresh query returns no remaining matching
issues. If an external prerequisite cannot be resolved with available tools,
leave the affected issue unfinished, report the exact blocker and evidence,
and continue any independent actionable issues. If only blocked issues
remain, report them explicitly; never call the backlog cleared.
