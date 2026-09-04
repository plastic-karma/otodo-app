# Repository agent instructions

## Required end-of-work verification

- After local coding and local tests are complete, push the completed commit(s) to their intended remote ref and run `.github/workflows/ci.yml` against that exact ref. Wait for the workflow to finish successfully; local compilation or tests do not replace this CI check.
- Treat product failures as actionable: diagnose, fix, retest locally, push, and rerun CI. Retry transient GitHub-hosted runner or simulator infrastructure failures, and confirm a successful final attempt.

## Required TestFlight delivery

- A completed product feature request must be delivered to TestFlight after CI succeeds. Run `.github/workflows/release.yml` against the exact verified ref with `publish_testflight=true`, then monitor it through a successful App Store Connect upload.
- The feature request itself authorizes the required push, CI dispatch, and TestFlight dispatch. Do not pause or ask the user for separate permission.
- Report the commit SHA, CI run, release run, marketing version, build number, and App Store Connect upload result.
