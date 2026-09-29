---
name: clear-backlog
description: >
  Clear the OTodo coding issue backlog autonomously. Use when asked to clear
  the backlog or work through open issues in otodo project gitobstodo tagged
  coding. Deliver each issue through implementation, local verification,
  native TestFlight when required, and otodo completion, then refresh and
  continue without waiting for manual testing.
---

# clear-backlog

Process one issue at a time until a fresh query finds no remaining issues.
The backlog is the otodo store, not GitHub Issues. The required order is:
**implement → local verification → native TestFlight when required → record delivery → mark done → refresh**.

## Prerequisites and discovery

1. Read `~/obs/default/.agents/skills/otodo/SKILL.md` before using otodo.
   Follow its CLI, store, mutation, and error-handling rules. Do not replace
   otodo operations with direct Markdown edits or GitHub issue commands.
2. Read this repository's `AGENTS.md`, `docs/RELEASE.md`, `scripts/test.sh`,
   `scripts/build-release.sh`, and `xtool-release.yml`. Use the local verification
   and native release paths. GitHub Actions is retired; never dispatch workflows
   or re-enable Actions as a fallback.
3. Work in this repository (`plastic-karma/otodo-app`). Preserve unrelated
   changes and other worktrees. Create a dedicated issue branch/worktree from
   the current verified local baseline for each issue. Continue subsequent
   issues from the last delivered local revision, not an unrelated or stale branch.
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
and exact commit SHA. Keep the committed source unchanged while local verification
and native release run.

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
trailer. Before delivery, verify the trailer on each product-feature commit
and confirm the generated `Changelog.json` includes each feature.
Do not mark maintenance-only commits as product features.

Commit the scoped fix locally on the issue branch and record the full SHA.
This skill does not authorize pushing branches or updating remote `main`.

### 2. Run local verification

Use the declared Swift 6.3.3 compiler and prepared Python dependencies described
in `docs/RELEASE.md`, without changing the global compiler or shell environment:

```bash
./scripts/test.sh
```

For Apple-platform coverage on a local Mac with the selected Xcode and installed
iOS/watchOS runtimes:

```bash
./scripts/test.sh --apple
```

Run the checks appropriate to the acceptance criteria. Preserve complete hosted/UI,
bundle and Watch coverage; focused tests do not replace an applicable full suite.
Report unavailable platform coverage honestly. Do not substitute GitHub CI or
claim a Linux run executed Apple simulators.

Diagnose failures, fix them, retest locally and commit the fix. Do not weaken
tests or ignore compiler failures. Keep command results and retained evidence
associated with the exact source revision.

### 3. Deliver through native TestFlight when required

Completed product features require TestFlight delivery after appropriate local
verification. Infrastructure/documentation-only changes do not require a new
upload; record that scope decision rather than fabricating delivery evidence.

Use the installed native xtool and existing external signing configuration as
described in `docs/RELEASE.md`:

```bash
./scripts/build-release.sh --upload
```

This is the only build/sign/upload route. It must preserve all shipping components,
entitlements and resources. Never put credentials in the repository or create,
revoke or replace identities as a side effect of testing.

Record the exact source SHA, marketing version, unique build number, IPA checksum,
and release/verification/upload receipts. Confirm the uploaded build is `VALID`,
unexpired, available for beta testing, and accessible to the internal tester group
pinned by `appStoreConnect.groupIDs`. An exported IPA or accepted transport alone
is not TestFlight availability. Do not submit a public App Store release.

Run deliveries sequentially. Investigate failures without blindly re-uploading;
query the exact existing build after an ambiguous upload result. Any source change
requires fresh applicable local verification and a new delivery when required.
Do not wait for manual tester acceptance or claim an unperformed device check.

### 4. Record the delivered local revision

Keep the verified commit and its evidence locally. Confirm the working revision
matches the recorded source SHA, and do not mix later or unrelated changes into
the delivered result. Continue the next issue from this verified local baseline.

Do not automatically push issue branches, promote remote `main`, create a PR,
or dispatch workflows. Repository publication requires a separate user request.
If the baseline changes, reconcile it without overwriting another worker's work
and repeat the affected verification/delivery before claiming the new revision.

### 5. Mark the issue done

Only after local verification and successful TestFlight delivery when required,
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

Report the issue ID/title, delivered commit SHA, local verification results,
marketing version/build and artifact/receipt paths when applicable, Apple
processing/tester-access results actually observed, and verified task state.
This progress report is not a handoff or
a reason to stop.

### 6. Refresh and pick the next issue

Immediately rerun the discovery command for project `gitobstodo` and tag
`coding`, read the next issue, and repeat from the last verified local revision.
Never process only a startup snapshot, stop after one issue, ask for permission
to continue, or wait for manual testing between issues. Invoking this skill
authorizes scoped local commits, required native TestFlight deliveries and task
completions—not remote pushes, public App Store releases or GitHub workflows.

Finish only when a successful fresh query returns no remaining matching
issues. If an external prerequisite cannot be resolved with available tools,
leave the affected issue unfinished, report the exact blocker and evidence,
and continue any independent actionable issues. If only blocked issues
remain, report them explicitly; never call the backlog cleared.
