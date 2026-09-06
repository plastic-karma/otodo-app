# Release OTodo to an IPA or TestFlight

The [`Release IPA`](../.github/workflows/release.yml) workflow generates `OTodo.xcodeproj`, archives OTodo, signs it through Apple cloud signing, exports one App Store `.ipa`, and always uploads the signed file as the `otodo-ipa` workflow artifact. A manual run uploads to TestFlight only when **publish_testflight** is selected, even if the selected ref is a tag. A pushed `v*` tag always uploads.

The workflow cannot create the external Apple or GitHub registrations below. Complete every one-time user action before the first run.

## Exact identities

| Item | Required value |
| --- | --- |
| Product/app name | `OTodo` |
| Xcode project | `OTodo.xcodeproj` (generated from `project.yml`) |
| Xcode scheme | `OTodo` |
| Platform/minimum OS | iOS / iOS 17 |
| Apple Team ID | `9492A97LWY` |
| Explicit application bundle ID | `plastickarma.otodo` |
| Explicit widget extension bundle ID | `plastickarma.otodo.widget` |
| Explicit Share extension bundle ID | `plastickarma.otodo.share` |
| Explicit Watch application bundle ID | `plastickarma.otodo.watchkitapp` |
| Explicit Watch complication bundle ID | `plastickarma.otodo.watchkitapp.widget` |
| Watch platform/minimum OS | watchOS / watchOS 10 |
| Shared App Group | `group.plastickarma.otodo` |
| GitHub workflow | `Release IPA` / `.github/workflows/release.yml` |
| IPA artifact | `otodo-ipa`, retained for 30 days |
| Public OAuth Actions variable | `GH_OAUTH_CLIENT_ID` |
| Xcode OAuth build setting | `GITHUB_CLIENT_ID` |

OTodo ships a Today widget, a Share extension, and an embedded Apple Watch app with WidgetKit complications. The iPhone application and widget share their snapshot through the App Group above; the application, Share extension, and Add Todo App Intent use the same durable workspace and outbox in that container. WatchConnectivity sends a dated-task snapshot to the Watch, where the Watch app and complication share a separate device-local App Group container.

## One-time Apple registration

> **One-time external user action:** GitHub Actions cannot create the Apple Developer membership, accept agreements, register the identifiers and App Group, or create the App Store Connect app record. A user with the necessary Apple account access must complete these steps.

### 1. Confirm the Apple team

Sign in to the [Apple Developer account](https://developer.apple.com/account/) belonging to Team ID **`9492A97LWY`**. Make sure the Apple Developer Program membership and any current App Store Connect agreements are active.

### 2. Register the App Group and explicit bundle identifiers

In **Certificates, Identifiers & Profiles → Identifiers**, select **+**, choose **App Groups**, and register:

- **Description:** `OTodo`
- **Identifier:** `group.plastickarma.otodo`

Then register or update these five **App IDs → App** identifiers:

| Description | Explicit bundle ID |
| --- | --- |
| `OTodo` | `plastickarma.otodo` |
| `OTodo Today Widget` | `plastickarma.otodo.widget` |
| `OTodo Share` | `plastickarma.otodo.share` |
| `OTodo Watch` | `plastickarma.otodo.watchkitapp` |
| `OTodo Watch Today & Overdue` | `plastickarma.otodo.watchkitapp.widget` |

Enable the **App Groups** capability on all five identifiers, choose **Configure**, and assign `group.plastickarma.otodo`. Existing provisioning profiles that predate this capability must be regenerated; the release workflow's automatic cloud signing creates current distribution profiles after the identifiers are configured. The extensions and companion Watch app do not need separate App Store Connect app records.

### 3. Create the App Store Connect app record

In [App Store Connect](https://appstoreconnect.apple.com) open **My Apps → + → New App** and enter:

- **Platforms:** iOS
- **Name:** `OTodo`
- **Primary language:** English (U.S.)
- **Bundle ID:** `plastickarma.otodo`
- **SKU:** `plastickarma.otodo`
- **User Access:** Full Access

This app record is separate from the Developer portal bundle identifier and must exist before a TestFlight upload. The workflow does not create it. If the public storefront name `OTodo` is unavailable, resolve the final product name in App Store Connect, but do not change the bundle ID or SKU used here.

### 4. Request App Store Connect API access and create an Admin Team Key

For an Apple account that has not enabled the App Store Connect API before, complete the access request first:

1. Sign in to App Store Connect as the team's **Account Holder** and open **Users and Access → Integrations → App Store Connect API**.
2. Select **Request Access**, review and accept Apple's terms, and submit the request.
3. Wait until Apple approves the request and the Team Keys controls become available. Do not try to create the workflow credentials before approval.

After approval, the **Account Holder** or an **Admin** creates the Team Key:

1. Open **Users and Access → Integrations → App Store Connect API → Team Keys** and select **Generate API Key**.
2. Give the key a recognizable name and select the **Admin** access role. Admin is required for Xcode cloud signing to create/use an Apple Distribution certificate and provisioning profile; an App Manager or Developer key may archive but then fail during export.
3. Select **Generate**, then record the **Key ID** and **Issuer ID**.
4. Download `AuthKey_<KEYID>.p8`. Apple permits this private-key download only once. Store it in a password manager or other approved secret store.

No `.p12`, distribution-certificate secret, or provisioning-profile secret is required. The workflow uses automatic cloud signing for team `9492A97LWY`, all five bundle identifiers, and their shared App Group.

## One-time GitHub OAuth and repository setup

> **One-time external user action:** register and enable the GitHub OAuth App as documented in [the README](../README.md#one-time-github-oauth-registration). A workflow cannot create or enable that OAuth App.

The OAuth App must have:

- **Application name:** `OTodo`
- **Enable Device Flow:** selected
- **Requested scope:** `repo` (the app requests this during Device Flow)
- **Credential used by this repository:** the public Client ID only

Do not configure an OAuth client secret or a personal access token. Device Flow requires neither.

> **One-time external user action:** create and initialize the GitHub repository containing the Obsidian Todo v1 store, including `.todo/config.toml`. The app and workflows do not create that external store. See [Repository and store onboarding](../README.md#repository-and-store-onboarding).

## Configure GitHub Actions

A repository administrator configures all four values at **Repository → Settings → Secrets and variables → Actions**.

### Repository secrets

Under **Secrets → New repository secret**, create exactly:

| Secret name | Exact source/value |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | The App Store Connect API key's Key ID, for example `2X9R4HXF34` |
| `APP_STORE_CONNECT_API_ISSUER_ID` | The issuer UUID shown on the App Store Connect API page |
| `APP_STORE_CONNECT_API_KEY` | The entire contents of `AuthKey_<KEYID>.p8`, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |

Paste the `.p8` as a multiline secret. Do not base64-encode it and do not add shell quotes. The workflow writes it to a permission-restricted temporary file, validates it, and does not include it in the IPA artifact.

### Repository variable

Under **Variables → New repository variable**, create exactly:

| Variable name | Exact source/value |
| --- | --- |
| `GH_OAUTH_CLIENT_ID` | The public Client ID shown on the `OTodo` GitHub OAuth App page |

This is intentionally an Actions **variable**, not a secret. During archive the workflow passes it to `GITHUB_CLIENT_ID`; XcodeGen places it in the app's `GitHubClientID` Info.plist entry. No client secret or PAT is accepted or needed.

The release job checks these names before doing expensive work. A missing value produces one of these exact annotations:

- `Missing required secret: APP_STORE_CONNECT_API_KEY_ID`
- `Missing required secret: APP_STORE_CONNECT_API_ISSUER_ID`
- `Missing required secret: APP_STORE_CONNECT_API_KEY`
- `Missing required Actions variable: GH_OAUTH_CLIENT_ID`

## Before every release

1. Ensure CI is green for the exact commit: Linux **Swift package tests**, macOS **iOS simulator**, and **Apple Watch companion**.
2. Confirm the Apple Developer membership and App Store Connect agreements are current.
3. Confirm all five App IDs in **Exact identities** use `group.plastickarma.otodo`, and that the main app's App Store Connect record still belongs to team `9492A97LWY`.
4. Choose a marketing version containing one to three dot-separated integers, such as `1.2.0`. Do not reuse an App Store Connect version train that is closed.
5. Decide whether this is an artifact-only build or a TestFlight upload. A manual run follows **publish_testflight** regardless of whether its selected ref is a branch or tag; a pushed `v*` tag is never artifact-only.

All release runs share one global concurrency queue: only one release job runs at a time, queued runs are not cancelled, and different refs do not run concurrently. The workflow sets `CFBundleVersion` to the UTC epoch seconds at build time; global serialization makes each run's numeric build number unique. A blank manual marketing version keeps `MARKETING_VERSION` from `project.yml` (currently `1.0`), while a nonblank manual value is always honored even when the selected ref is a tag. Only a pushed `v*` tag derives its marketing version from the text after `v`.

The Watch companion job installs the embedded watchOS app and its complication on a paired simulator, verifies real WatchConnectivity delivery, then shuts down the phone and verifies cached Watch relaunch and the complication deep link. Its `watch-smoke` artifact includes screenshots and delivery diagnostics. Physical devices are still required to check watch-face placement, large-file transfers, and expedited complication updates. The release archive rejects missing Watch binaries, incorrect companion identifiers, and mismatched marketing versions or build numbers before export.

## Run manually: artifact only

In GitHub:

1. Open **Actions → Release IPA → Run workflow**.
2. Select the branch or tag to build. The selected ref does not change the manual inputs' behavior.
3. Set **marketing_version** to the intended version, for example `1.2.0`, or leave it blank to use the project's value.
4. Leave **publish_testflight** unchecked.
5. Select **Run workflow**.

Equivalent GitHub CLI commands:

```sh
gh workflow run release.yml --ref <branch> -f marketing_version=1.2.0
gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

After success, open the workflow run's **Artifacts** section and download **`otodo-ipa`**. It is retained for 30 days. This manual mode does not upload to TestFlight—even when run against a tag—and does not create a GitHub Release.

The exported IPA uses App Store distribution and cannot be sideloaded directly onto an iPhone. Upload it later with Apple's Transporter app, Xcode Organizer, or an authenticated Apple upload tool, or rerun the workflow with TestFlight publishing enabled.

## Run manually: artifact and TestFlight

In **Actions → Release IPA → Run workflow**, enter the marketing version and select **publish_testflight**. With the GitHub CLI:

```sh
gh workflow run release.yml --ref <branch> \
  -f marketing_version=1.2.0 \
  -f publish_testflight=true
gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

This produces the same `otodo-ipa` artifact first, then uploads it to the existing `plastickarma.otodo` app record. A green upload means Apple accepted the package; App Store Connect processing still happens asynchronously.

Internal testers must be App Store Connect users with access to OTodo; an ordinary Apple ID cannot be added directly to an Internal Testing group. For each new tester, open **Users and Access**, select **+**, invite the person with a role eligible for internal testing, grant access to **OTodo**, and have them accept the invitation. Then open **My Apps → OTodo → TestFlight**, wait for the build to finish processing, open or create an Internal Testing group, select **Testers → +**, choose those App Store Connect users, and add the build. Internal testing does not require Beta App Review. External testing requires the usual TestFlight metadata and Beta App Review.

## Release by tag: artifact and TestFlight

Push a version tag whose name is `v` followed by one to three dot-separated integers:

```sh
git tag v1.2.0
git push origin v1.2.0
```

For every pushed `v*` tag, the workflow:

1. validates that the suffix is one to three dot-separated integers, then derives the marketing version from it (`v1.2.0` becomes `1.2.0`);
2. sets the UTC-epoch build number after the run reaches the global release queue;
3. archives, signs, and exports the IPA;
4. uploads the `otodo-ipa` workflow artifact for 30 days; and
5. always uploads that IPA to TestFlight.

Valid examples are `v1`, `v1.2`, and `v1.2.0`. The workflow rejects a bare `v`, empty components, more than three components, and nonnumeric suffixes before archiving. This automatic version derivation and TestFlight upload apply only to a tag **push** event; manually dispatching the workflow at the same tag still honors **marketing_version** and **publish_testflight**. Tag-push runs do **not** create a GitHub Release or attach an asset outside the workflow artifact.

## What the workflow controls

The workflow selects the newest Xcode installed on GitHub's current macOS runner, downloads XcodeGen 2.46.0, verifies the archive against SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`, and regenerates the project. It archives with automatic signing and App Store Connect API authentication, exporting first with `app-store-connect` and retrying the legacy `app-store` export method when necessary.

Workflow permissions are least privilege (`contents: read`). Third-party actions are pinned to full commit SHAs. Secrets are provided only to steps that require them and are not uploaded as artifacts. All release runs use one global concurrency group, so runs for every branch and tag queue behind an in-progress signing/upload operation instead of running concurrently or cancelling it.

## Troubleshooting

### A prerequisite annotation names a missing secret or variable

Create the value under the exact category and spelling shown above. `GH_OAUTH_CLIENT_ID` belongs under Actions **Variables**; the three `APP_STORE_CONNECT_API_*` values belong under Actions **Secrets**. Environment-level values do not satisfy the workflow unless that environment is wired into the job.

### `APP_STORE_CONNECT_API_KEY is not a valid .p8 private key`

Replace the secret with the literal contents of the downloaded `AuthKey_<KEYID>.p8`, including both boundary lines. Do not store the filename, JSON, base64 output, escaped `\n` text, or a client secret. Confirm the file's Key ID matches `APP_STORE_CONNECT_API_KEY_ID`.

### `Cloud signing permission error`, `No profiles for ... were found`, or provisioning fails

Check all of the following:

- the API key is an **Admin** Team Key, not an Individual Key with insufficient access;
- it belongs to Apple team `9492A97LWY`;
- the Developer portal contains all five explicit App IDs listed in **Exact identities**;
- all five App IDs have the App Groups capability assigned to `group.plastickarma.otodo`;
- the Developer Program membership and agreements are active; and
- the team can create/use an Apple Distribution certificate.

An existing non-Admin key cannot simply be made sufficient in all cases; create a new Admin key, download its `.p8`, and replace all three secrets together.

### TestFlight reports no suitable application record or app not found

The Developer portal App ID alone is not enough. Create the separate App Store Connect **My Apps** record for bundle ID `plastickarma.otodo`, then rerun. The workflow deliberately does not attempt this external registration.

### TestFlight rejects the marketing version

For a closed version train or a message that `CFBundleShortVersionString` must be higher, run manually with a higher `marketing_version` or push a higher `v*` tag. The automatically unique build number does not make a closed marketing version reusable.

### TestFlight requires a newer iOS SDK

The newest Xcode installed on the selected GitHub runner is still older than Apple's current upload requirement. Update `runs-on` in the workflow to a runner image that contains the required Xcode/SDK, keeping the selection and signing steps intact.

### The run is green but the build is absent from TestFlight

For a manual run, verify **publish_testflight** was selected; artifact-only is the default even when the manual run targets a tag. A pushed `v*` tag always publishes. If upload succeeded, wait for App Store Connect processing and check email/App Store Connect for processing issues. The `otodo-ipa` artifact being present proves export, not TestFlight publication.

### TestFlight shows Missing Compliance

OTodo's generated Info.plist sets `ITSAppUsesNonExemptEncryption` to `false`, because it uses standard system networking encryption and no non-exempt encryption. If App Store Connect still asks, verify the archived app contains that key and answer Apple's export-compliance prompt accurately.

### GitHub sign-in in the released app says OAuth is not configured

Confirm `GH_OAUTH_CLIENT_ID` exists as a repository Actions variable and contains the OAuth App's public Client ID, then rebuild. Confirm **Enable Device Flow** remains selected on that OAuth App. Do not substitute a client secret or PAT. Organization access may also require an organization owner to approve the OAuth App or authorize it for SAML SSO.

### The IPA will not install directly on a device

This is expected: `otodo-ipa` is App Store-distribution signed. Publish it to TestFlight and install through Apple's TestFlight app; it is not an ad hoc or development-signed IPA.
