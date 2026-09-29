# Local OTodo releases and TestFlight

OTodo is tested locally and released with native xtool. `scripts/build-release.sh`
and `xtool-release.yml` are the only release build/sign/upload entrypoint and
manifest. GitHub Actions is disabled and the workflows, composite action,
cloud-signing helpers and automatic PR/tag publishing have been removed. Nothing
uploads merely because a test, commit, push, or pull request completes.

## Product graph and external prerequisites

Keep every shipping component and its entitlements:

| Target | Bundle identifier | Minimum platform |
| --- | --- | --- |
| OTodo | `plastickarma.otodo` | iOS 17 |
| OTodoWidget | `plastickarma.otodo.widget` | iOS 17 |
| OTodoShareExtension | `plastickarma.otodo.share` | iOS 17 |
| OTodoWatch | `plastickarma.otodo.watchkitapp` | watchOS 10 |
| OTodoWatchWidget | `plastickarma.otodo.watchkitapp.widget` | watchOS 10 |

The Apple team is `9492A97LWY`, the shared App Group is
`group.plastickarma.otodo`, and the existing App Store Connect app ID is
`6808334170`. The extensions and Watch app do not need separate App Store Connect
app records. The iPhone app/widget/Share extension share the workspace; the Watch
app/complication share a separate device-local group container and receive data
through WatchConnectivity.

Before an actual distribution build, maintain an active Apple Developer membership,
accepted agreements, the existing App Store Connect app record, and all five
explicit App IDs with the App Groups capability. Have a matching distribution
certificate/private key and valid App Store provisioning profiles for every
bundle. Do not create/revoke identities or change capabilities as a side effect of
testing. Native xtool, the manifest-selected Swift **6.3.3**, Apple SDKs and the
native asset/signing tools must be installed outside this repository.

The app's optional GitHub OAuth/sync functionality is unchanged. The public client
identifier remains in `xtool-release.yml` under `settings.GITHUB_CLIENT_ID`; a
command-scoped `GITHUB_CLIENT_ID` overrides it. See the
[OAuth registration instructions](../README.md#one-time-github-oauth-registration-for-synced-workspaces).
Do not configure an OAuth client secret or GitHub Actions variable for releases.

## Local verification

Use the application compiler declared by `xtool-release.yml`, not a different
compiler selected only to run native host tools. On the current Linux workstation:

```sh
source /home/benni/.local/share/swiftly/xtool-env.sh
PATH=/home/benni/.local/share/swiftly/toolchains/6.3.3/usr/bin:$PATH ./.codex/setup.sh
PATH=/home/benni/.local/share/swiftly/toolchains/6.3.3/usr/bin:$PATH ./scripts/test.sh
```

The setup installs only repository-local Python dependencies and resolves Swift
packages. It does not overwrite xtool, change shell startup files, or install
credentials. The portable runner validates metadata/App Groups for all five
bundles, runs local helper regressions, and runs the entire core Swift suite.

On a local Mac with Xcode, XcodeGen 2.46.0 and compatible preinstalled iOS/watchOS
simulators, run `scripts/test.sh --apple`. It additionally builds the full app
and extension graph, enumerates and runs all hosted and UI tests without sharding,
checks actual signed simulator App Group entitlements in every Mach-O slice, and
verifies real live WatchConnectivity delivery and cached relaunch with the phone
shut down. No fake snapshot substitutes for transport. Boot migration must report
`Finished`; a zero exit alone does not pass. The fixed ten-minute snapshot wait
includes cold-pair readiness and request/reply delivery.

The runner honors your selected Xcode or command-scoped `DEVELOPER_DIR`, creates
and removes its own test simulators, and retains local evidence under
`.build/local-tests/apple-*/`. Open `ios/tests.xcresult` in Xcode for UI screenshots
or export its attachments with `xcrun xcresulttool`. Watch screenshots, snapshots,
progress and pre-shutdown phone diagnostics stay in the sibling `watch` directory.
It does not download runtimes, switch Xcode globally, or upload evidence.

Physical-device checks still include large-file WatchConnectivity delivery,
expedited complication updates, watch-face placement and complication tap routing.
Linux cannot execute any Apple simulator tests; the runner fails clearly rather
than claiming a skip as success.

## Prepare and build locally

For the installed CLI on the current workstation, source its compatibility
environment and set the launcher override command-scoped:

```sh
source /home/benni/.local/share/swiftly/xtool-env.sh
XTOOL=/home/benni/.local/share/xtool/native/bin/xtool \
  ./scripts/build-release.sh --prepare-only --unsigned
```

This parses the complete manifest/project graph and prepares `.xtool/workspace/app`
and `.xtool/workspace/project.json`. It does not compile, sign, upload, or validate
Apple acceptance. It requires no distribution credentials.

For a real ad-hoc local smoke build, use the same launcher with `--unsigned`:

```sh
XTOOL=/home/benni/.local/share/xtool/native/bin/xtool \
  ./scripts/build-release.sh --unsigned
```

An unsigned/ad-hoc smoke artifact is not a TestFlight-installable distribution IPA.
Do not remove the Share extension, widgets, Watch targets, resources, capabilities
or entitlements to make it build.

## External signing and explicit TestFlight delivery

Keep the signing configuration **outside** the repository. Native xtool accepts
`--signing /private/path/otodo.yml`, `XTOOL_SIGNING_CONFIG`, or its default
`$XDG_CONFIG_HOME/xtool/signing/plastickarma.otodo.yml` (with `~/.config` as the
configuration-home default). Its configuration uses these fields:

```yaml
certificate: distribution.cer
privateKey: distribution.key
profiles:
  plastickarma.otodo: otodo.mobileprovision
  plastickarma.otodo.widget: widget.mobileprovision
  plastickarma.otodo.share: share.mobileprovision
  plastickarma.otodo.watchkitapp: watch.mobileprovision
  plastickarma.otodo.watchkitapp.widget: watch-widget.mobileprovision
```

Paths are relative to that external configuration or absolute. The certificate
is DER; the matching private key and every profile must stay outside the project.
Use private directory/file permissions (0700/0600) and never commit, print or copy
credentials into public evidence. Configure App Store Connect authentication for
the installed `asc` CLI externally; no repository secret file or Apple login is
needed for portable tests or prepare-only.

For a completed product feature request, or a separately requested TestFlight
delivery, publish through the local native path after appropriate local verification
using the existing external identities. Infrastructure/documentation-only cleanup
does not require a new upload:

```sh
source /home/benni/.local/share/swiftly/xtool-env.sh
XTOOL=/home/benni/.local/share/xtool/native/bin/xtool \
  ./scripts/build-release.sh --signing /private/path/otodo.yml --upload
```

Omit `--upload` for a distribution-signed local artifact only. `--unsigned` cannot
be combined with signing or upload. Use the marketing version in `project.yml`
and a fresh numeric build number (`--build-number` can set it explicitly); never
overwrite historical accepted artifacts or reuse an accepted upload's number.
Run deliveries sequentially and preserve release/verification/upload receipts.
Native release artifacts live under `.xtool/releases/` by default; `--output`
chooses another release parent and each build has its own directory.

Report the exact source revision, version/build, artifact path and checksum,
upload outcome, and actual Apple processing/tester availability observed. A local
build or upload transport success alone does not prove Apple acceptance or an
installed-device check. Verify the exact build in App Store Connect/TestFlight;
do not submit a public App Store release as a substitute for internal testing.

`xtool-release.yml` pins the existing **Internal Testers** group
(`2a16b67b-f282-48d0-bf9f-42696c0bf03b`). The uploader requires that exact group
relationship on the processed build, not merely membership in any beta group.

## Cleanup verification recorded on 2026-09-29

- The actual portable entrypoint passed source metadata checks, **16 Python tests,
  290 XCTest tests and 8 Swift Testing tests**, using the declared Swift 6.3.3.
- An initial attempt with host-tools Swift 6.4 failed compiling unchanged
  `Sources/OTodoCore/SyncEngine.swift:550`: `sending 'originalPaths' risks causing
  data races`, with later actor-isolated accesses at lines 559/566. Product source
  and concurrency checks were not changed; the documented command selects the
  existing manifest compiler rather than suppressing the failure.
- The installed native launcher completed `--prepare-only --unsigned`, producing
  the workspace paths above. No full native app build, signing, upload, identity
  change, or Apple processing check was performed in this cleanup.
- `scripts/test.sh --apple` on Linux exited 1 with the explicit local-Mac
  requirement. Hosted/UI/Watch simulator coverage remains runnable on a Mac, but
  was not executed here.
- The repository-local backlog skill now uses the same local verification and
  native TestFlight path; obsolete workflow dispatch and automatic-push steps
  have been removed while preserving issue discovery and completion logic.
