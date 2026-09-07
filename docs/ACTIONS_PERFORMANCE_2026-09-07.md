# GitHub Actions performance and failure-feedback report

Analysis date: **2026-09-07**. Repository: **plastic-karma/otodo-app**.

## Executive findings

1. **Optimize iOS test execution and failure feedback first.** Recent unfiltered successful iOS jobs have a **30:01 median**, **46:15 p90**, and **47:40 maximum**. The test step accounts for **93.2%** of those jobs' aggregate elapsed time; building accounts for only **3.7%**.
2. **An already-known failure can remain hidden behind a running check for almost 40 minutes.** The longest failed iOS job took **52:04**, emitted a concrete attachment-test assertion **12:09** after starting, and finished **39:55 later**. Its check annotation contains only `Process completed with exit code 65.`
3. **Duplicate runs consume substantial capacity.** There are **62 same-SHA push/manual pairs created within 60 seconds**. Not all are equivalent coverage, but three verified full-suite duplicate pairs alone spent **88:57 of runner time** on the redundant push copies. There is no CI concurrency policy in the inspected workflow.
4. **Watch CI is the second major cost center:** successful-job median **16:37**. Preparation, building, and live delivery all matter. The slowest failed Watch job spent **12:45 in a successful build** before ultimately timing out on live delivery. Do not call all of that interval compiler time.
5. **Do not shorten Watch polling blindly.** A completed successful Watch job needed approximately **275 seconds** from cache lookup to a real reply. Shortening the current 300-second wait to 60–180 seconds would reject this observed success.
6. **Release is comparatively short.** Eight recent successful release jobs have a **4:06 median**; the three with the current Watch-capable target graph took **4:30, 5:09, and 6:05**. Archive and Apple's upload handling dominate, not checkout, XcodeGen, artifact upload, or certificate cleanup.
7. **Preserve diagnostics and verification strength.** Full and focused green runs are not equivalent. At one identical SHA, a **6:59 design-only run passed while a 52:04 full run failed**. Artifact-only release success likewise does not establish TestFlight acceptance.

**Recommendation:** first improve native failure annotations and full/focused run identity; eliminate equivalent duplicate runs; then introduce a deliberately designed early failure gate and investigate iOS startup/SpringBoard waits and Watch phase overlap. Keep full coverage required for a successful delivery. Every proposed speedup below is unimplemented; numerical opportunity estimates are labeled separately from observed timings.

## 1. Scope, definitions, and limitations

### Dataset

- Enumerated **all 224 available workflow runs**, created from **2026-09-03 17:21:02 UTC** through **2026-09-07 13:36:20 UTC**. Collection began at approximately **13:45 UTC** on September 7.
- Included **238 workflow attempts**, counting reruns rather than only each run's final state. Two runs were unfinished in the run-list snapshot: `34128325659` and `34125198240`. They are excluded from aggregate completed-run timings, even if they finished later.
- GitHub returned **482 job records**. Nine were carried-forward rerun records with **new job IDs but identical original execution intervals**. Deduplicating by run, job name, start, and completion gives **473 distinct job executions**. Excluding the six jobs belonging to the two unfinished runs leaves **467 records**, of which **8 are skipped** and **459 actually ran**.
- The completed population comprises **222 runs / 236 attempts**. Job outcomes are **266 successes, 77 failures, 116 cancellations, and 8 skips**. Failures in cancelled or eventually recovered runs are retained at job/attempt level.
- Fetched **all 77 failed-job logs** and inspected their failure records, recent successful iOS/Watch/release logs, representative Linux logs, and selected Watch diagnostic artifacts. Separately checked export-result markers in every older successful release log: all **43 executed exports** are covered. Checked actual GitHub check annotations for the two longest iOS failures, the longest Watch failure, and the late failed release.
- Source baseline: inspected working-tree workflows/scripts with Git HEAD **`0e4bf90bd69701e3494ffaeb15b18ff35282713f`**. Case studies use their own run SHAs; some design/editor branches and early workflow versions differ. Historical defects are explicitly separated from current recommendations.
- A completed Watch job from unfinished workflow `34125198240` is used as a **supplementary case study only**, not added to the aggregate success cohort.

### Measurement rules

| Measure | Definition |
|---|---|
| Job/step duration | `completed_at - started_at`, using GitHub API timestamps. |
| Workflow wall time | Latest completed attempt's `run_started_at` to its last actually executed job's completion. Rerun repair/wait gaps are excluded. |
| Job scheduling delay | Actual job start minus **that attempt's** start. Includes scheduling/runner availability; not a claim about a particular queue service. For first attempts, run creation and attempt start coincide in these examples. |
| Runner occupancy | Sum of distinct job execution durations. Parallel jobs add here, but not to workflow wall time. **Not billed minutes or monetary cost.** |
| First failure signal | First concrete compiler/XCTest assertion or terminal protocol/process/service error found in the log, not a generic warning containing “failed.” |
| p50 / p90 | Median / nearest-rank 90th percentile. Tables round to the nearest second and display **minutes:seconds**. |

Skipped records are not timed; four contain one-second inverted placeholder intervals. Carried-forward rerun rows are not joined to the new attempt's start or counted twice. In particular, subtracting a later rerun timestamp from an inherited old job start would produce a meaningless negative queue time.

**Recent cohort:** runs created on September 6–7. The main recent iOS success cohort is **14 unfiltered successes**, separated from **4 focused successes** (median **9:58**, range **6:59–13:02**). Classification uses the **effective xcodebuild command**, not echoed conditional shell code. The recent failure cohort contains 22 jobs, including one focused diagnosis and failures before tests started. Suites evolved during the window: the latest main success ran **7 hosted application tests and 34 UI tests**, while inspected branch failures ran 36 or 41 UI tests. The older, much lower median is not a valid current performance target.

API timestamps are second-resolution; log receipt timestamps can be buffered. A displayed zero-second step is sub-second/rounded, not free. Step medians do not add to the median job. No changes or controlled performance experiments were run, so observed associations and upper-bound overlap opportunities are not measured speedups.

## 2. Workflow-level results

The run counts below describe the final state at the fixed snapshot; timings describe latest completed attempts, not elapsed time across human repair and rerun gaps.

| Workflow | Runs | Success | Failure | Cancelled | Unfinished | Successful wall p50 / p90 / max | Failed wall p50 / p90 / max |
|---|---:|---:|---:|---:|---:|---|---|
| CI | 177 | 70 | 48 | 57 | 2 | 15:18 / 30:02 / 50:29 | 15:36 / 45:34 / 52:12 |
| Release IPA | 47 | 42 | 4 | 1 | 0 | 3:51 / 4:42 / 6:15 | 1:04 / 4:33 / 4:33 |

These all-history workflow medians mix substantially different suite sizes and diagnostic modes. Prefer the recent full-suite job breakdown below for today's iOS optimization work.

- **iOS was the last-finishing job in 69 of 70 successful CI workflows**; Watch was last in the remaining one. Accelerating Linux alone generally will not make CI finish sooner.
- Across distinct completed-run jobs, observed occupancy was **56.41 runner-hours**: **28.23 successful**, **18.53 failed**, and **9.64 cancelled**. These are job outcomes, not workflow outcomes; successful sibling jobs inside failed workflows belong to the successful-job bucket.

| Job | All-window runner-hours | Share of observed occupancy | Successful-job count, all window | All-window success p50 / p90 |
|---|---:|---:|---:|---|
| iOS simulator | 42.16 | 74.74% | 70 | 13:55 / 29:53 |
| Apple Watch companion | 8.96 | 15.88% | 13 | 16:37 / 21:21 |
| Archive, sign, and export | 2.79 | 4.95% | 42 | 3:44 / 4:38 |
| Swift package tests | 2.50 | 4.43% | 141 | 0:56 / 1:05 |

### Recent jobs: current optimization priorities

| Job / cohort | Successful n | Success p50 / p90 / max | Failed n | Failure p50 / p90 / max |
|---|---:|---|---:|---|
| iOS simulator, unfiltered successes | 14 | **30:01 / 46:15 / 47:40** | 22, mixed failure stages/modes | **26:02 / 37:59 / 52:04** |
| Apple Watch companion | 13 | **16:37 / 21:21 / 24:11** | 13 | **15:43 / 22:45 / 24:56** |
| Archive, sign, and export | 8 | 4:06 / 6:05 / 6:05 | 3 | 0:49 / 0:50 / 0:50 |
| Swift package tests | 62 | 0:58 / 1:06 / 2:05 | 0 | — |

CI's inspected macOS logs use **macos-15-arm64 / Xcode 26.3 (17C529)**; the recent/failed release logs use **macos-26-arm64 / Xcode 26.6 (17F113)**. Do not assume simulator CI products are directly reusable as signed release archives, or compare runner images as if workload and toolchains were controlled.

### Scheduling versus execution

| Job | Scheduling delay p50 / p90 / max, all actual executions |
|---|---|
| Swift package tests | 0:03 / 0:04 / 0:40 |
| iOS simulator | 0:08 / 0:12 / 10:21 |
| Apple Watch companion | 0:08 / 1:33 / 13:37 |
| Release | 0:07 / 0:09 / 1:25 |

Scheduling is usually small, but some Mac tails are material. Reducing duplicate work may relieve pressure **[INFERENCE]**; the data do not prove duplicates caused a particular wait. Release serialization is not a general bottleneck: successful release scheduling delay never exceeded 11 seconds in this population.

## 3. Steps inside each workflow

The following tables include **every step that executed successfully in the recent successful cohort**, including runner setup/teardown. iOS uses only unfiltered successes. Failure-only diagnostic steps follow separately.

### iOS simulator

| Step | n | p50 | p90 | Maximum |
|---|---:|---:|---:|---:|
| Run UI tests without rebuilding | 14 | 28:17 | 42:50 | 45:28 |
| Build for testing | 14 | 1:13 | 1:49 | 1:51 |
| Select available iPhone simulator | 14 | 0:26 | 1:19 | 2:18 |
| Select newest installed Xcode | 14 | 0:03 | 0:03 | 0:04 |
| Complete job | 14 | 0:03 | 0:04 | 0:04 |
| Export UI snapshots | 7 | 0:04 | 0:07 | 0:07 |
| Checkout | 14 | 0:02 | 0:02 | 0:03 |
| Upload UI snapshots | 7 | 0:03 | 0:04 | 0:04 |
| Post Checkout | 14 | 0:01 | 0:02 | 0:03 |
| Set up job | 14 | 0:01 | 0:01 | 0:01 |
| Install XcodeGen 2.46.0 | 14 | 0:00 | 0:01 | 0:01 |
| Verify feature changelog generation | 14 | 0:00 | 0:01 | 0:01 |
| Validate App Store bundle metadata | 14 | 0:00 | 0:01 | 0:01 |
| Generate Xcode project | 14 | 0:00 | 0:00 | 0:01 |

### Apple Watch companion

| Step | n | p50 | p90 | Maximum |
|---|---:|---:|---:|---:|
| Build iPhone with embedded Watch app and complication | 13 | 7:05 | 10:14 | 12:54 |
| Prepare paired iPhone and Watch simulators | 13 | 4:18 | 5:51 | 6:07 |
| Verify live companion delivery and offline Watch relaunch | 13 | 3:54 | 6:16 | 7:27 |
| Complete job | 13 | 0:10 | 0:13 | 0:16 |
| Collect Watch diagnostics | 13 | 0:05 | 0:08 | 0:10 |
| Select newest installed Xcode | 13 | 0:03 | 0:04 | 0:04 |
| Upload Watch simulator evidence | 13 | 0:02 | 0:03 | 0:03 |
| Checkout | 13 | 0:02 | 0:02 | 0:02 |
| Set up job | 13 | 0:01 | 0:01 | 0:01 |
| Post Checkout | 13 | 0:01 | 0:01 | 0:02 |
| Install XcodeGen 2.46.0 | 13 | 0:00 | 0:01 | 0:01 |
| Generate Xcode project | 13 | 0:00 | 0:00 | 0:01 |

### Swift package tests

| Step | n | p50 | p90 | Maximum |
|---|---:|---:|---:|---:|
| Initialize containers | 62 | 0:25 | 0:36 | 0:44 |
| Run all core tests | 62 | 0:26 | 0:34 | 0:36 |
| Checkout | 62 | 0:01 | 0:02 | 0:03 |
| Set up job | 62 | 0:01 | 0:01 | 0:02 |
| Stop containers | 62 | 0:00 | 0:01 | 0:02 |
| Post Checkout | 62 | 0:00 | 0:01 | 0:01 |
| Complete job | 62 | 0:00 | 0:00 | 0:01 |

### Archive, sign, and export

| Step | n | p50 | p90 | Maximum |
|---|---:|---:|---:|---:|
| Archive with cloud signing | 8 | 2:07 | 4:02 | 4:02 |
| Upload to TestFlight | 8 | 1:20 | 1:39 | 1:39 |
| Export App Store IPA | 8 | 0:23 | 0:30 | 0:30 |
| Checkout | 8 | 0:02 | 0:03 | 0:03 |
| Upload IPA artifact | 8 | 0:02 | 0:03 | 0:03 |
| Revoke ephemeral signing certificates | 8 | 0:01 | 0:01 | 0:01 |
| Post Checkout | 8 | 0:01 | 0:01 | 0:01 |
| Set up job | 8 | 0:01 | 0:01 | 0:01 |
| Select newest Xcode | 8 | 0:01 | 0:01 | 0:01 |
| Prepare ephemeral signing certificate cleanup | 8 | 0:01 | 0:01 | 0:01 |
| Complete job | 8 | 0:01 | 0:02 | 0:02 |
| Install XcodeGen (pinned and verified) | 8 | 0:01 | 0:01 | 0:01 |
| Set up private output paths | 8 | 0:00 | 0:01 | 0:01 |
| Generate Xcode project | 8 | 0:00 | 0:01 | 0:01 |
| Write release summary | 8 | 0:00 | 0:01 | 0:01 |
| Verify release prerequisites | 8 | 0:00 | 0:00 | 0:00 |
| Validate and install App Store Connect API key | 8 | 0:00 | 0:00 | 0:00 |
| Resolve version and unique build number | 8 | 0:00 | 0:00 | 0:00 |

### Failure diagnostics are small relative to the expensive work

| Recent failed-job step | Executed n | p50 / p90 / maximum |
|---|---:|---|
| iOS: export UI snapshots | 19 | 0:03 / 0:06 / 0:07 |
| iOS: upload UI snapshots | 19 | 0:03 / 0:05 / 0:05 |
| iOS: retain failed xcresult bundles | 22 | 0:07 / 0:12 / 0:15 |
| Watch: collect diagnostics | 13 | 0:12 / 0:27 / 0:27 |
| Watch: upload evidence | 13 | 0:02 / 0:04 / 0:05 |

Some successful upload actions found no files after earlier build/configuration failures; these are step-execution counts, not counts of usable artifacts. In the 50-minute iOS failure, a real **319 MB result-bundle artifact** uploaded in **15 seconds**. Removing failure evidence is a poor trade for saving seconds after tens of minutes of work.

### Third-party Actions versus shell steps

The current workflows directly use **`actions/checkout` and `actions/upload-artifact`**. Neither is the primary bottleneck. Checkout is normally 1–2 seconds, ordinary evidence uploads 2–3 seconds, and even the large failed xcresult upload above was 15 seconds. XcodeGen is a shell download/checksum/install step, not a slow setup Action; its recent p90 is approximately one second. There is no existing cross-run build cache in these workflows.

Do **not** reduce `fetch-depth: 0` blindly: `project.yml` runs `.github/scripts/generate_changelog.py` during the app build, and that script requires complete Git history. A two-second checkout optimization could instead cause a late build failure. Retain checksum verification and pinned Action revisions.

## 4. iOS: the largest opportunities

### 4.1 A passing full run is mostly tests and test startup, not building

[Run 34123426871, job 101746464790, attempt 1](https://github.com/plastic-karma/otodo-app/actions/runs/34123426871/job/101746464790), main SHA `0e4bf90`:

| Phase | Observed duration |
|---|---:|
| Entire job, 12:47:45–13:34:00 UTC | **46:15** |
| Select simulator | 1:19 |
| Build for testing | **1:51** |
| Test-without-building step | **42:50** |
| Test-step start to first XCTest suite | approximately **6:14** |
| Hosted application tests | 7 tests, **1.883 seconds** |
| UI tests | 34 tests, **35:37.7** |
| UI-suite completion to test-step completion | approximately **0:41** |

The pre-suite interval includes simulator/test-runner preparation, installation, and launch; the logs do not isolate boot time. The current iOS workflow selects a simulator but does not explicitly boot it or expose a readiness phase. `build-for-testing` and `test-without-building` already reuse one runner-local DerivedData directory; **recommending “build once, test without rebuilding” would merely repeat what already exists**.

Across all 14 recent unfiltered successes, the test step accounts for **25,629 / 27,509 seconds = 93.2%** of job time. Completely eliminating the measured build steps would remove only **3.7%** before accounting for any cache/transfer overhead.

### 4.2 First failure versus final red status

| Run / job, all attempt 1 | Job total | First actionable assertion UTC | Time from job start | Job time remaining after assertion |
|---|---:|---|---:|---:|
| [34119922075 / 101735389781](https://github.com/plastic-karma/otodo-app/actions/runs/34119922075/job/101735389781) | **52:04** | 12:17:05.714 | **12:09** | **39:55** |
| [34122415173 / 101743276310](https://github.com/plastic-karma/otodo-app/actions/runs/34122415173/job/101743276310) | **50:28** | 12:46:14.644 | **13:39** | **36:49** |
| [34093446664 / 101651682771](https://github.com/plastic-karma/otodo-app/actions/runs/34093446664/job/101651682771) | **37:59** | 07:07:07.823 | **5:43** | **32:16** |

For the first row, the test step itself exits at **12:56:42**, **39:36 after the assertion**; the remaining 19 seconds are job finalization. The assertion was already specific: file, line, test name, and `XCTAssertTrue failed`. Yet the actual GitHub check annotation for both longest jobs is only **`Process completed with exit code 65.`** This is a strong, directly observed opportunity for better signal, not merely shorter timeouts.

A conservative extraction found definitive compiler/XCTest failure records in **52 of 55 failed iOS jobs**. Job completion followed these records by a **4:10 median**, **19:15 p90**, and **39:55 maximum**; approximately **7.00 runner-hours** remained in total. For the 19 matching recent failures, the median was **13:03**. This is **time after the first known failure**, not a claim that all remaining work was useless or can be removed without tradeoffs.

In the 50:28 job, continuing after the first attachment failure also discovered an independent keyboard-focus failure. The logs show retries of an individual XCTest typing action, **not a rerun of the whole test suite**. The expensive behavior is largely continuing to run subsequent tests. Current tests already set `continueAfterFailure = false`, which stops the failing test, not the entire suite.

**Current versus historical:** the longest two failures used a branch's obsolete Quick Look `Done` selector. The inspected main test now checks the actual preview container/content and `QLOverlayDoneButtonAccessibilityIdentifier`; the full main success passed that flow. Do not weaken the new assertion, retry the stale selector, or report this old selector as an unfixed current defect. The **failure-reporting delay** remains an architectural issue.

### 4.3 Measured SpringBoard idleness costs about six minutes in one passing run

In the full main success above:

| Passing UI test | Duration |
|---|---:|
| `testHomeScreenQuickActionOpensNewTodoEditor` | 2:19.3 |
| `testHomeScreenQuickActionReplacesOpenSiblingDraftWithRoot` | 2:54.5 |
| `testTodayWidgetRendersInWidgetGallery` | 2:37.2 |
| **Combined** | **7:51.0**, about **22%** of UI-suite time |

The log contains six approximately 60-second waits ending **“App animations complete notification not received, will attempt to continue.”** These are implicit XCTest/SpringBoard idleness waits, not explicit test sleeps or screenshot export. About **six minutes is observed waiting**, not a demonstrated removable saving.

Investigate these exact OS interactions on the selected Xcode/runtime, and consider a separate OS-integration partition. Preserve real Home Screen/widget interaction: replacing it with an in-app shortcut would test a different contract. Do not globally disable synchronization or skip these tests to produce a faster green check.

Other expensive passing cases include subtask reparent/detach/relaunch (**2:07**), saved filters (**2:04**), and create-another (**1:46**). These exercise durable transitions. Parallelization needs isolated simulators/App Groups and enough runner capacity; the main UI suite is largely one class, so merely enabling a generic parallel flag does not establish balanced scheduling.

### 4.4 Older failures show what should fail before UI interaction

- [34000654622 / 101398801121](https://github.com/plastic-karma/otodo-app/actions/runs/34000654622/job/101398801121) built with historical `CODE_SIGNING_ALLOWED=NO`, then reported **“client is not entitled”** and an unavailable shared container. All **23 UI tests failed** afterward. Current ad-hoc simulator signing fixes that historical configuration. A fast check of the **built app's effective entitlements**, plus the existing hosted runtime tests, would make any recurrence clearer before a missing-button cascade.
- [33854884206 / 100965766813](https://github.com/plastic-karma/otodo-app/actions/runs/33854884206/job/100965766813), attempt 1, and [attempt 2 / 100967844493](https://github.com/plastic-karma/otodo-app/actions/runs/33854884206/job/100967844493) failed at `app.launch()` with **“Timed out while requesting launch progress.”** These timeouts occurred before ordinary element-existence waits. A later attempt succeeded; that supports investigating launch infrastructure, not classifying every UI assertion as a harmless flake.

Across all failed iOS jobs, failure steps were **46 test steps, 7 builds, and 2 historical simulator-entitlement checks**. Preserve the already-separated build phase and meaningful compiler failures.

## 5. Watch: preparation, build overhead, and live delivery

### 5.1 Slow failures were not compiler failures

| Run / job, attempt 1 | Job total | Prepare | Build, succeeded | Verify, failed |
|---|---:|---:|---:|---:|
| [34119922075 / 101735389991](https://github.com/plastic-karma/otodo-app/actions/runs/34119922075/job/101735389991) | **24:56** | 4:00 | **12:45** | 7:01 |
| [34117372837 / 101727234221](https://github.com/plastic-karma/otodo-app/actions/runs/34117372837/job/101727234221) | **22:45** | 5:49 | **7:58** | 7:45 |
| [34098551371 / 101667512591](https://github.com/plastic-karma/otodo-app/actions/runs/34098551371/job/101667512591) | **22:26** | 5:59 | **7:57** | 7:10 |

In the 12:45 build, the log has a **4:19 gap** between the shell group's end and Xcode's first command-invocation output; package graph resolution then takes **52.7 seconds**, and build-description-to-success takes **5:57.9**. The prelude is not instrumented well enough to identify its cause. Do not label the full 12:45 as compilation or assume a specific runner-contention cause.

Preparation also contains more than booting: one failed job spent **1:49 just in `simctl list`**. Current preparation can download missing runtimes, creates and pairs devices, then boots phone and Watch **sequentially** before building the entire embedded-app graph.

### 5.2 Surface the actual readiness/reply stage while waiting

Saved diagnostics distinguish at least two failure modes:

- In the longest failure, phone state reported **paired but `appInstalled:NO` at 12:23:19.695**, and Watch state reported **unreachable / first unlock needed at 12:23:42.278**. The step did not exit until **12:28:50.924**. These observations would have given useful state context roughly **five minutes earlier**. They are not by themselves safe terminal-failure predicates.
- In the third failure, Watch became **reachable at 08:26:17.592**, sent a real request, and got **`WCErrorCodeMessageReplyTimedOut` at 08:31:18.704**. The helper exited **15.6 seconds later**. This was not simply an unbooted or unpaired simulator; a request was submitted and its reply timed out.
- The longest Watch job's actual GitHub annotation is only **`Process completed with exit code 1.`** The useful state is buried in later artifact logs.

Artifacts: [longest failure](https://github.com/plastic-karma/otodo-app/actions/runs/34119922075/artifacts/10018593998), [second failure](https://github.com/plastic-karma/otodo-app/actions/runs/34117372837/artifacts/10017526460), [reply timeout](https://github.com/plastic-karma/otodo-app/actions/runs/34098551371/artifacts/10010487549).

### 5.3 A real success rules out simplistic timeout reductions

Supplementary [completed Watch job 101752149530 in run 34125198240](https://github.com/plastic-karma/otodo-app/actions/runs/34125198240/job/101752149530), excluded from aggregate tables because its overall workflow was unfinished at the snapshot:

- Job **13:59**; prepare **3:45**, build **3:46**, verify **6:05**.
- Initial Watch unreachable/first-unlock state lasted **166.7 seconds**.
- Once reachable, request-to-successful-reply took another **122.4 seconds**.
- Cache lookup to reply spanned **274.7 seconds**; both real delivery and offline relaunch passed.
- Its preparation also printed **`Data Migration Failed`** and nevertheless completed successfully. Failing immediately on that phrase would reject this observed good run.
- The actual offline portion took approximately **9 seconds**. Removing phone shutdown/cached relaunch would save little and remove a named product guarantee.

Keep the 300-second live-delivery budget initially. Add timestamped stage/state progress and immediate reporting of definitive protocol, process-death, or terminal message failures. Initial `reachable:NO`, first-unlock state, or `appInstalled:NO` must be allowed to transition.

### 5.4 Safe candidates for improvement

1. **Bound subprocesses, not just the whole job.** `watch_smoke.py:21-27` has no subprocess timeout. Inventory, runtime downloads, pairing, boot, install, launch, container lookup, screenshots, and diagnostics can consume the 45-minute outer job limit. Use phase-specific deadlines with graceful termination and artifact headroom; derive budgets from healthy and slow-success observations.
2. **Keep both liveness checks.** Watch PID death is already detected during polling; phone launch PID is discarded. Retain it and detect a dead phone during its initial 300-second seed wait instead of waiting out the entire budget **[INFERENCE: potential failure class, not an observed five-minute dead-phone incident]**.
3. **Overlap boot with build only after splitting device selection from readiness.** In the supplementary success, serial phone/Watch boot intervals total about **3:17**, while the build takes **3:46**. **3:17 is an ideal overlap envelope**, not a promised saving; CPU/IO contention may erase it. Publish UUIDs after creation/pairing, start bounded boot preparation and build, then require both before install. Concurrent phone/Watch boots have a separate ideal envelope of about **1:03**; these envelopes do not add.
4. **Collect phone evidence before shutting it down.** In that success artifact, `phone-watch-sync.log` is a **339-byte “device is not booted” error**, and the phone PNG is empty. Current diagnostics use `check=False`, so the collection step remains green. Stream/capture phone logs before the offline transition, retain Watch logs through relaunch, and report evidence-collection errors separately from the original test failure.
5. **Keep wrong-content failures specific.** Report expected/observed snapshot names, version, workspace availability, and request stage, rather than only “snapshot did not arrive.” Preserve atomic-cache equality and actual WCSession delivery; do not inject the expected snapshot or retry away content/persistence failures.

Earlier Watch failures included an obsolete `pair_activate` error and a removed `simctl openurl` complication-routing check. The current slow-path examples above use the current smoke/bridge implementation. Do not treat all 12 verification failures in the aggregate as the same five-minute connectivity timeout.

## 6. Linux: already a useful, fast early signal

A representative successful [job 101762146455](https://github.com/plastic-karma/otodo-app/actions/runs/34128326340/job/101762146455) took **60 seconds**: **23 seconds container initialization**, roughly **24 seconds building**, and **206 tests in 5.311 seconds**. Yams fetch took under one second. Much of the container time was after network layer downloads, so it is not all bandwidth.

The slowest successful Linux job, [101487706900](https://github.com/plastic-karma/otodo-app/actions/runs/34033657725/job/101487706900), took **2:05**, but **69 seconds elapsed before its first setup step**. Its container step was 24 seconds, core step 27 seconds, and actual 164-test execution 1.114 seconds. This outlier is not evidence of slow core tests.

The sole failed Linux job, [101123218609](https://github.com/plastic-karma/otodo-app/actions/runs/33903611684/job/101123218609), reported a concrete Swift type-inference error at **18:01:34.505** and exited **3.05 seconds later**. The current explicit closure result type corrects that historical failure.

Keep the complete suite. A preprovisioned/pinned toolchain or compiler/dependency cache may reduce the container/build envelopes, but restore/save overhead must be measured. Making both macOS jobs wait for Linux would add roughly a minute to healthy runs; with only one observed Linux failure, it is not a free or obviously high-priority wall-time optimization. A separate lightweight shared metadata preflight has a different cost profile.

## 7. Release: archive and upload, not setup

### 7.1 Latest successful release

[Run 34121538056, job 101740478773, attempt 1](https://github.com/plastic-karma/otodo-app/actions/runs/34121538056/job/101740478773), SHA `0e4bf90`:

- Entire job **6:05**: archive **4:02**, export **0:24**, TestFlight upload **1:23**.
- Certificate preparation and cleanup were **one second each**; IPA artifact upload was **three seconds**.
- Provisioning-stage markers were about **12.8 seconds apart**. The **205 seconds after build-description creation** include compilation, resource processing, linking, and signing—not exclusively compiler CPU.
- `altool` reported acceptance at **12:28:51.809 UTC**. Its reported bulk transfer was approximately **14.6 MB in 0.269 seconds**, despite the 83-second step. Compressing the IPA or parallelizing byte transfer does not address most of the observed upload duration; logs do not divide the remaining time completely between local and Apple service processing.

The successful upload is historical evidence, not a new delivery performed for this report. Apple acceptance and subsequent App Store Connect processing remain distinct.

### 7.2 Every failed release attempt

| Failure class | Run / attempts | Failed phase | Job durations | Current status of the observed cause |
|---|---|---|---|---|
| Missing iPad orientations and launch screen | [33794040203](https://github.com/plastic-karma/otodo-app/actions/runs/33794040203), a1 | TestFlight upload | **4:28** | Metadata fixed in `9359457`; source CI checks exist now |
| Signing-certificate quota | [33860707512](https://github.com/plastic-karma/otodo-app/actions/runs/33860707512), a1/a2 | Archive | 0:44 / 0:43 | Later certificate lifecycle management addresses the historical accumulation |
| Main/widget App Group profile mismatch | [33914204022](https://github.com/plastic-karma/otodo-app/actions/runs/33914204022), a1; [33918112538](https://github.com/plastic-karma/otodo-app/actions/runs/33918112538), a1 | Archive | 0:57 / 0:57 | Later exact-SHA release succeeded; external profile/capability prerequisite remains |
| Share App Group profile mismatch | [34007933703](https://github.com/plastic-karma/otodo-app/actions/runs/34007933703), a1/a2 | Archive | 0:49 / 0:50 | a3 succeeded on the same SHA |
| Watch/complication App Group profile mismatch | [34039625782](https://github.com/plastic-karma/otodo-app/actions/runs/34039625782), a1 | Archive | 0:41 | a2 succeeded on the same SHA |

The **seven archive failures already exited almost immediately after Xcode printed the concrete error**: under 0.11 seconds to the exit annotation. Their meaningful errors appeared roughly 37–52 seconds after job start. There is no measured multi-minute post-error build continuation to eliminate there. Repeating quota or App Group failures without changing the prerequisite did not help. Same-SHA recoveries are consistent with repaired/refreshed external provisioning state; Actions logs do not prove the precise administrator action.

The late upload failure is different: archive and export succeeded, then Apple rejected deterministic metadata. A local archive-content check could have exposed those particular missing keys **about 93 seconds earlier**, before export/upload **[INFERENCE: exposed interval, not an implemented saving]**. A generated-metadata check could act earlier still. The specific missing-key bug is already fixed; this supports retaining that preflight class, not re-reporting it as currently broken.

### 7.3 Earlier release signals and unsafe shortcuts

- **Existing preflight is valuable:** presence of credentials/OAuth variable, PEM validation, and a real certificate-list API call already run before archiving. The API call proves some authentication/access; it does **not** prove cloud-distribution permissions, the correct named App Group assignment, an app record, accepted agreements, an open version train, or all upload validation rules.
- Reuse the existing authentication and metadata checks. Add read-only app/Bundle ID/capability checks where they can establish a definite missing resource or authorization error. Capability enablement alone does **not** prove that `group.plastickarma.otodo` is assigned; a stale existing profile is not necessarily fatal if automatic provisioning can repair it. Do not turn preflight into a second archive or certificate-creation probe.
- **The release summary currently mislabels upload failures.** At `release.yml:434-438`, an existing IPA with no `PUBLISHED_TESTFLIGHT` becomes **“TestFlight: not requested”**, including after an attempted upload failed. Track requested, attempted, accepted, and failed separately, and distinguish cleanup failure after accepted upload from upload failure. The old metadata-rejection log demonstrates the misleading branch, and the logic remains in the inspected source.
- **Legacy export fallback has no observed timing benefit or cost:** all **43 executed exports succeeded using the primary method**. The current unconditional retry with `app-store` would repeat future permission/profile failures without repairing their cause **[INFERENCE]**. Remove it for a supported Xcode or gate it narrowly on an actual unsupported-method diagnostic. Credit **zero measured current savings**.
- **Keep global release serialization and certificate cleanup.** A before/after team-wide certificate snapshot is not safe to overlap casually: one release could revoke another's new certificate. Current epoch-second build numbering also relies on serialization. Do not cache signing keys/profiles/archives as a shortcut or drop required Watch/architecture output.
- One identifiable serialized wait was **85 seconds** for duplicate [33870752040](https://github.com/plastic-karma/otodo-app/actions/runs/33870752040), whose predecessor ended four seconds before its job started. This is not a reason to parallelize signing.
- `docs/RELEASE.md` says queued requests are not cancelled, but GitHub's default concurrency queue retains only one pending run. Current official documentation supports `queue: max` for up to 100 pending runs. Reconcile this contract if every queued release must be retained; it is a correctness detail, not the observed duration bottleneck. [GitHub concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

## 8. Duplicate work and full-versus-focused verification

CI has **106 push runs and 71 manual runs**, with no pull-request runs in this window despite that trigger being enabled. There are **104 distinct CI SHAs**, **70 SHAs with multiple runs**, and **73 runs beyond one per SHA**. Those counts alone do not prove redundancy: retries, changed external state, explicit snapshots, and focused diagnoses can be intentional.

Stronger evidence: **62 push/manual pairs share a SHA and were created within 60 seconds**. Three recent pairs have verified unfiltered test commands and matching suite sizes:

| SHA | Push run | Manual run | UI tests in each | Push iOS / Linux time |
|---|---|---|---:|---|
| `d7e588210b5e` | [34026801423](https://github.com/plastic-karma/otodo-app/actions/runs/34026801423) | [34026800963](https://github.com/plastic-karma/otodo-app/actions/runs/34026800963) | 27 | 27:25 / 1:02 |
| `b2bf92a7bf4b` | [34024474933](https://github.com/plastic-karma/otodo-app/actions/runs/34024474933) | [34024474406](https://github.com/plastic-karma/otodo-app/actions/runs/34024474406) | 26 | 29:53 / 0:53 |
| `71be6e419cf1` | [34017480353](https://github.com/plastic-karma/otodo-app/actions/runs/34017480353) | [34017480321](https://github.com/plastic-karma/otodo-app/actions/runs/34017480321) | 26 | 28:45 / 0:59 |

Keeping the mandatory manual verification and suppressing these equivalent push copies would have avoided **86:03 of macOS occupancy plus 2:54 Linux = 88:57 total** for just these three pairs. This is measured duplicate work, not a prediction that all 62 pairs can safely be removed or that one remaining run would finish proportionally faster.

The opposite case is equally important: at SHA `5aea785`, [design-only 34119921794](https://github.com/plastic-karma/otodo-app/actions/runs/34119921794) passed in **6:59**, while [full 34119922075](https://github.com/plastic-karma/otodo-app/actions/runs/34119922075) failed in **52:04**. Both iOS jobs started at exactly **12:04:57**. The green run executed two design tests, not the failing attachment flow.

Recommended policy:

- Choose **one canonical full, exact-SHA run for delivery**. With the repository's mandatory manual CI delivery process, avoid launching an equivalent automatic push copy for that path; retain automatic review verification where appropriate. Do not quietly weaken the exact-ref CI requirement.
- Cancel superseded **CI** runs per branch/ref and purpose, but keep **full, focused diagnosis, and screenshot-only coverage clearly distinct**. A ref-only concurrency key can let a focused diagnostic cancel the required full check. Concurrency serializes/cancels; it does not by itself prove equivalent coverage or prevent a redundant run after its predecessor finishes.
- Record actual SHA, attempt, mode/filter, selected runtime, executed test counts, and first failure in a small summary. Give diagnostic checks distinct identities; they must never satisfy the required full-suite release check.
- Do not apply CI's cancellation policy to the signing/upload release queue.

## 9. Prioritized implementation plan and expected effects

All entries below are recommendations, **not changes made by this investigation**.

| Priority | Change | Measured basis / expected effect | Tradeoff and verification needed |
|---|---|---|---|
| **P0** | Emit native XCTest/compiler/Watch failures as immediate file/test/stage-specific GitHub annotations; retain xcodebuild's exit status and raw logs | Current longest checks expose only exit 65/1. Useful assertion exists **up to 39:55 before job completion**. Earlier signal; no automatic runtime reduction | Match real issue records, not warnings or echoed scripts. Replay captured logs and ensure passing SpringBoard/migration warnings do not become errors |
| **P0** | Make full and diagnostic verification unambiguous; eliminate equivalent push/manual runs | Three proven redundant pushes cost **88:57** of occupancy. Same-SHA focused green/full red case proves mode checks matter | Preserve mandatory exact-SHA full CI. Do not cancel full verification with a focused run or count focused green as acceptance |
| **P1** | Add an early behavioral gate using existing built products, with a deliberately chosen fail-fast policy | The first attachment assertion was followed by **36–40 minutes** of work in two runs | Stop remaining work only after a definitive gate failure; this loses later independent failures. Measure extra invocation/startup cost. Offer a complete-diagnostics mode rather than quietly skipping coverage |
| **P1** | Give simulator inventory/readiness, test startup, build, per-scenario execution, and diagnostics separate deadlines and stage summaries | Silent iOS pre-suite interval reached **6:14** in a good run; Watch subprocesses currently rely on the **45-minute job cap** | Reserve time for graceful termination and artifacts. Do not set a global iOS cap below the **47:40 observed good job**, or a Watch live cap below the **275-second observed good delivery** |
| **P1** | Surface Watch installation/readiness/request/reply state; retain phone PID and capture phone logs before shutdown | Earlier stalled state is visible about **five minutes** before generic failure; successful phone evidence is currently lost after shutdown | Initial unreachable/uninstalled state is transient. Fail early on definitive protocol/process/message errors, not the first warning |
| **P1** | Investigate the three slow SpringBoard tests and isolate their OS-integration execution | Three tests cost **7:51**, with about **six minutes of implicit idleness waits** in a full success | Observed wait is an optimization target, not guaranteed savings. Preserve actual widget and Home Screen behavior |
| **P2** | Overlap bounded Watch boots with building; explicitly measure build prelude and package-resolution time | Supplementary good run has an ideal **3:17 boot/build overlap envelope**; slow build includes an unexplained **4:19 prelude** | Contention can erase benefit. Join both results before install and retain all embedded targets; do not sum independent overlap envelopes |
| **P2** | Evaluate two balanced UI partitions on isolated simulators/runners, preserving hosted tests and all UI coverage | UI accounts for **93.2%** of recent full-job time; splitting test work has more room than caching a **1:13 median build** | Extra builds, simulator startups, artifacts, and runner occupancy; one monolithic test class is not automatically balanced. No sharding speedup was measured |
| **P2** | Shared cheap metadata preflight, built-product entitlement checks, precise release preconditions/outcomes | Historical metadata rejection occurred after successful archive/export; current release summary can mislabel a failed upload | Reuse existing validations, include every shipped component, preserve archive/runtime verification; do not mistake a read-only capability check for proof of App Group assignment |
| **P3** | Cache/preprovision only after timing restore/save and invalidation; narrow legacy export fallback | Linux container/build cost tens of seconds; release archive costs minutes; **43/43 exports already use the primary method successfully** | Cache keys must distinguish toolchain/SDK/platform/architecture/dependencies/settings. Never cache signing secrets or restore a signed old build as a new release. **No demonstrated fallback-removal speedup** |

### Recommended failure policy

There are two different goals; they should not be conflated:

1. **Earlier useful signal without losing information:** immediately annotate the first native issue, identify the failing test/stage, and continue collecting the rest of the suite. This is the lowest-risk first change. It improves feedback, but the workflow still finishes later.
2. **Earlier terminal failure and less wasted execution:** run a small, explicit gate first—shared metadata/build checks, hosted runtime/container checks, and a few high-value UI behaviors—then run the remaining, nonduplicated coverage only after the gate passes. A failed gate is a real failure, not a green partial suite. A successful delivery still requires every partition. Keep an intentional diagnostic mode that runs all partitions to collect multiple failures.

Simply reordering the current single xcodebuild invocation is insufficient: the attachment failure is already early, but XCTest proceeds to other tests. Likewise, `continueAfterFailure = false` is already present. Do not kill xcodebuild on an arbitrary log substring: it risks false positives and incomplete xcresults. A supported test-plan/partition boundary with normal nonzero exit is safer. Benchmark the extra warm invocation/startup overhead; focused tests here still sometimes spent over five minutes before the suite began.

Independent GitHub jobs do not fail-fast merely because another job fails. For example, in run `34119922075`, Watch verification failed at **12:28:50**, but CI did not finish until **12:57:01**—another **28:11**. Matrix `fail-fast` applies only if work is actually arranged as matrix siblings; it is not a switch for today's unrelated jobs. Serializing all Watch and iOS work would make healthy runs longer. If terminal workflow failure speed is paramount, explicitly design coordinated cancellation/failure propagation while preserving the original failing check and bounded diagnostics; do not blindly cancel the whole workflow into an uninformative cancelled result.

### What not to optimize first

- Checkout, XcodeGen checksum verification, ordinary artifact upload, and certificate cleanup: seconds, not the dominant minutes.
- Removing Linux tests: the actual suite runs in a few seconds and has already provided a prompt meaningful compiler signal.
- Disabling full-history checkout: the build's generated changelog needs it.
- Blanket retries or shorter outer job timeouts: they do not fix deterministic assertions, entitlements, or missing metadata and can destroy evidence.
- Replacing real Watch delivery/offline relaunch, SpringBoard interactions, or intentionally per-character date input with cheaper substitutes: these would change the tested contracts.
- Parallel signing or asynchronous “fire-and-forget” TestFlight upload: unsafe with current cleanup/numbering and not equivalent to accepted delivery.

## 10. Verification criteria for follow-on optimizations

A useful before/after evaluation should record **both speed and failure quality**:

- Same SHA, Xcode build, runtime/device tuple, full test plan/count, and snapshot-export mode. Compare multiple complete attempts; do not compare today's 34-test main suite with an older 23-test or two-test diagnostic run.
- Job occupancy and workflow critical-path time separately; report queue delay, runner image, and all retried attempts. No speedup credit for dropping tests or counting carried-forward jobs twice.
- First concrete failure timestamp, time to visible meaningful annotation, time to failing-check completion, and remaining workflow/diagnostic time.
- Controlled failures for compiler error, effective App Group mismatch, app launch/process death, a true UI assertion, missing runtime, Watch protocol/content mismatch, and reply timeout. Each should remain nonzero with a precise signal and usable evidence; do not require a new permanent test for every measurement.
- Preserve a known slow successful Watch delivery and the expensive real SpringBoard scenarios when selecting deadlines. A timeout that rejects known healthy behavior is not an optimization.
- For overlap/sharding/caching, measure runner occupancy, cache restore/save, invalidation correctness, test isolation, and repeated-run variance, not only a single faster green result.
- For release preflight, keep a real signed archive/export and accepted TestFlight upload as the final proof when implementation work is eventually delivered. Read-only checks cannot substitute for Apple's binary validation.

No before/after gains are claimed here: this report analyzes existing execution evidence. No workflow, application, or test changes were made. The measurement phase used existing runs only; required CI verification of the subsequent report-only commit is separate from, and excluded from, this fixed dataset. This documentation-only delivery does not require a TestFlight release.

## 11. Sources and reproduction

### Inspected source

- [CI workflow at the source baseline](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/.github/workflows/ci.yml): independent jobs; iOS build/test at lines 199–231; diagnostics at 233–262; Watch sequencing at 324–356.
- [Watch smoke helper](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/.github/scripts/watch_smoke.py): subprocess wrapper 21–27, preparation 60–91, polling 98–115, live/offline verification 130–172, diagnostics 175–189.
- [Release workflow](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/.github/workflows/release.yml): prerequisites 39–161, archive/guards 178–306, export fallback 308–366, upload/cleanup/summary 376–442.
- [Project configuration](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/project.yml), [UI tests](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/OTodoUITests/OTodoUITests.swift), [certificate lifecycle helper](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/.github/scripts/manage_api_certificates.py), and [release documentation](https://github.com/plastic-karma/otodo-app/blob/0e4bf90bd69701e3494ffaeb15b18ff35282713f/docs/RELEASE.md).
- [GitHub concurrency semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency), [Apple app lookup](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps), and [Apple Bundle ID capabilities](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-bundleids-_id_-bundleidcapabilities). Capability checks have the limitations described above.

Every detailed example links its run/job or artifact. Job links retain attempt-specific job IDs; rerun numbers are identified where needed. Workflow artifacts have finite retention—currently seven days for CI evidence—so linked diagnostic downloads are not permanent archives.

### Read-only API collection

Authenticated commands used, with placeholders for individual IDs:

```sh
gh api --paginate --slurp 'repos/plastic-karma/otodo-app/actions/runs?per_page=100'
gh api --paginate --slurp 'repos/plastic-karma/otodo-app/actions/runs/<run-id>/jobs?filter=all&per_page=100'
gh api 'repos/plastic-karma/otodo-app/actions/runs/<run-id>/attempts/<attempt>'
gh api 'repos/plastic-karma/otodo-app/actions/jobs/<job-id>/logs' --allow-escape-sequences
gh api 'repos/plastic-karma/otodo-app/check-runs/<check-id>/annotations?per_page=100'
```

To reproduce the distributions, freeze the run list first; fetch every page and every prior attempt; deduplicate inherited job execution intervals; exclude skipped records and unfinished-run cohorts; compute elapsed seconds and nearest-rank percentiles. Use `run_started_at` from the correct attempt, not the latest rerun timestamp attached to an old successful job or the original creation time spanning a human repair gap. Determine filters from the **actual Command line invocation**, not inactive `-only-testing` branches printed in shell groups. Do not count echoed legacy-fallback warning code as an executed retry.

The analysis retained raw snapshots and computed measurements as session evidence, outside the repository: `local://actions-runs-snapshot.json`, `local://actions-jobs-snapshot.json`, `local://actions-attempts-snapshot.json`, `local://actions-deduplicated-jobs.json`, `local://actions-performance-measurements.json`, and `local://actions-ios-first-signals.json`. These session URIs are for this investigation, not portable repository files; the commands and linked run IDs above are the portable reproduction path. Internal consistency checks passed for run/attempt counts, execution deduplication, nonnegative non-skipped durations, correct attempt scheduling, and full/focused success cohorts.
