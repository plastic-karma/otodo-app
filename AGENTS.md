# Repository agent instructions

## Local xtool verification before workflows

Run from the current repository checkout, not an old staged project or IPA. Use Python 3.11+ and Swift 6.1+. The full `build` command below requires **local macOS with full Xcode selected**, including iOS/watchOS SDKs 26+. It installs checksum-pinned xtool 1.19.2; no Apple signing credentials are needed.

Set `GITHUB_CLIENT_ID` to the public repository variable `GH_OAUTH_CLIENT_ID` before running. An authenticated `gh variable get GH_OAUTH_CLIENT_ID` lookup is optional.

```sh
set -e
: "${GITHUB_CLIENT_ID:?Set the public GH_OAUTH_CLIENT_ID value}"
work="$(mktemp -d /tmp/otodo-xtool.XXXXXX)"
python3 -m venv "$work/venv"
. "$work/venv/bin/activate"
python -m pip install -r .github/scripts/requirements.txt
export TMPDIR="$work/tmp" XDG_CACHE_HOME="$work/cache"
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"
swift test --scratch-path "$work/core"
python -m unittest discover -s .github/scripts -p 'test_*.py'
python .github/scripts/xtool_build.py build \
  --workspace "$work/build" --version 1.0 --build-number 1 \
  --client-id "$GITHUB_CLIENT_ID"
```

- Keep build scratch, caches, and virtual environments on a native filesystem (`/tmp`, not the shared `/mnt/mac` mount). Always choose a fresh workspace. The version/build above are local verification values, not publication numbering.
- The helper runs actual `xtool dev build -c release --triple …` commands for `arm64-apple-ios`, `arm64-apple-watchos`, and `arm64_32-apple-watchos`. Keep this wrapper: it adapts the Watch recipe, uses native single-triple SwiftPM, and checks all five targets, unchanged Swift 6 sources, Core resources, and packed binaries. Require exit zero and retain `$work/build/xtool-build.json` plus `$work/build/logs/`.
- **On Linux**, run the portable tests and replace `build` with `prepare` in the last command. This writes `$work/build/xtool-prepare.json` and checks staging only; it does **not** compile the apps. The checked-in full-build helper rejects Linux. Report that limitation rather than claiming a full local build passed.
- Fix local failures before dispatching workflows. Compilation is not running iOS/watchOS apps: `ci.yml` uses Xcode and Apple simulators to test the source, not the xtool-built release IPA. Signing, Apple validation, and upload remain separate; see [the xtool release instructions](docs/RELEASE.md#run-manually-xtool-compilation-and-testflight). Report only stages actually verified; successful compilation does not make the products TestFlight-ready.

## Required end-of-work verification

- After local coding and local tests are complete, push the completed commit(s) to their intended remote ref and run `.github/workflows/ci.yml` against that exact ref. Wait for the workflow to finish successfully; local compilation or tests do not replace this CI check.
- Treat product failures as actionable: diagnose, fix, retest locally, push, and rerun CI. Retry transient GitHub-hosted runner or simulator infrastructure failures, and confirm a successful final attempt.

## Required TestFlight delivery

- A completed product feature request must be delivered to TestFlight after CI succeeds. Run `.github/workflows/release.yml` against the exact verified ref with `publish_testflight=true`, then monitor it through a successful App Store Connect upload.
- The feature request itself authorizes the required push, CI dispatch, and TestFlight dispatch. Do not pause or ask the user for separate permission.
- Report the commit SHA, CI run, release run, marketing version, build number, and App Store Connect upload result.
