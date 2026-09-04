# OTodo

OTodo is an offline-first iOS client for an Obsidian Todo v1 store kept in a GitHub repository. It signs in through GitHub's OAuth Device Flow, discovers stores on a selected branch, and lets you create projects plus create, edit, complete, and delete todos without making a local Git checkout.

The app displays active todos due today or overdue by default, with filters for every active todo or all todos including terminal states. The Projects sidebar creates and filters projects; project names become lowercase, hyphenated slugs and direct Markdown project records. Todos are ordered by due date, configured workflow-state order, name, and ULID. Swipe right on a todo to reveal Done; swipe left to reveal Delete. The editor supports the name, state, projects, tags, due date, and Markdown body. GitHub tokens are stored in the device Keychain; repository workspaces and their pending changes are stored on the device.

## Requirements

- Swift 6.1 for the Swift package and Linux development
- macOS with Xcode and an installed iOS 17-or-newer simulator for the app
- XcodeGen **2.46.0** to generate `OTodo.xcodeproj` from `project.yml`
- iOS 17 or later to run OTodo

The application scheme is `OTodo`, the generated project is `OTodo.xcodeproj`, and the application bundle identifier is `plastickarma.otodo`.

## Obsidian Todo v1 compatibility

OTodo intentionally supports store schema version **1 only**. A store is a repository root or subdirectory containing `.todo/config.toml`. OTodo discovers these files; it does not create a repository or initialize a store.

A minimal compatible configuration is:

```toml
schema_version = 1
tasks_directory = "Tasks"
projects_directory = "Projects"
obsidian_link_prefix = ""
default_state = "open"

[[states]]
id = "open"
name = "Open"
terminal = false

[[states]]
id = "done"
name = "Done"
terminal = true
```

The configuration is strict: all five top-level keys are required, only `[[states]]` tables are accepted, and each state requires exactly `id`, `name`, and `terminal`. State IDs match `[a-z0-9][a-z0-9_-]*`, must be unique, and the default state must exist and be nonterminal. Task and project directories must be normalized relative POSIX paths, must not begin with `.todo`, and must be distinct and non-overlapping. `projects_directory` and a nonempty `obsidian_link_prefix` cannot contain `[`, `]`, `|`, `#`, or `^`; the prefix may be empty and otherwise is prepended to generated Obsidian links.

Project records are direct Markdown children of `projects_directory`; the filename without `.md` is the project slug. A task may reference only an existing project. Nested project records are not supported.

Task identity belongs in the filename, not frontmatter. OTodo creates files as `<tasks_directory>/<26-character-uppercase-ULID>.md`. A v1 task has YAML frontmatter followed by an arbitrary Markdown body:

```markdown
---
name: "Buy milk"
state: open
projects:
  - "[[Projects/home]]"
tags:
  - errands
due_date: 2026-09-03
---
Optional Markdown notes.
```

The exact record contract is:

- Required: nonempty single-line `name`, configured `state`, `projects` list, and `tags` list.
- Optional: `due_date` and `last_completed_date` as real `YYYY-MM-DD` civil dates; `recurrence`; and `recurrence_from`, which is `schedule` or `completion`.
- Project slugs match `[a-z0-9][a-z0-9-]*` and are unique per task. Project links must be `[[<obsidian_link_prefix>/<projects_directory>/<slug>]]`, with the empty prefix omitting that first component.
- Tags must be unique, nonempty strings without whitespace, control characters, commas, brackets, or braces, and cannot begin with `#`.
- `id` frontmatter is rejected. Other frontmatter properties and the Markdown body are preserved when OTodo edits a task. Core fields are emitted canonically.
- Recurrence supports `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, positive `INTERVAL`, non-ordinal `BYDAY` for weekly rules, `BYMONTHDAY=1..31` for monthly/yearly rules, and `BYMONTH=1..12` for yearly rules. A recurring task requires both `due_date` and `recurrence_from`, and its due date must match its selection clauses. The current UI preserves existing recurrence fields but does not edit them or calculate a next occurrence.
- The configuration limit is 1 MiB; each selected task/project record is limited to 8 MiB; at most 10,000 selected files and 64 MiB of decoded selected content are loaded.

`Sources/OTodoCore/Resources/schema.json` is the bundled structural schema. Runtime validation additionally enforces the configuration, paths, project existence, dates, recurrence subset, and filename identity described above.

## Offline, outbox, and conflict behavior

The first connection to a store requires GitHub access so OTodo can validate and save a complete snapshot. After that:

1. Every project or todo creation, edit, completion, or deletion is atomically saved to the durable local workspace and outbox before the operation reports success.
2. Repeated local changes to the same path coalesce into one pending change while retaining the original remote base. Deleting a never-synchronized todo cancels its pending creation.
3. OTodo synchronizes after a local save when online, when connectivity returns, on launch with a saved workspace, and on pull-to-refresh. Failed pushes remain pending for a later attempt.
4. Sync first pulls the current branch snapshot, applies unrelated remote changes, and sends safe pending paths together in one `Sync OTodo changes` commit. The branch ref is updated with compare-and-swap semantics; OTodo never force-pushes.
5. If GitHub and this device changed the same path from the same base, OTodo preserves the local version—including a local deletion—and durable outbox entry, records a conflict, and does not push that path. Unrelated safe paths can still synchronize.
6. **Keep My Version** rebases and queues the device's content or deletion to replace GitHub on the next sync. **Use GitHub Version** discards the device's pending version and adopts GitHub's file; if GitHub deleted it, the local task is removed. Resolution is explicit and cannot be undone in the app.

Losing connectivity, a failed API request, or expired authorization does not discard saved todos or pending changes. Reauthorize to resume synchronization.

## One-time GitHub OAuth registration

> **One-time external user action:** a repository workflow cannot create or configure a GitHub OAuth App. An owner of the GitHub account or organization must do this in the GitHub web UI.

1. Open GitHub **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Enter these values:
   - **Application name:** `OTodo`
   - **Homepage URL:** the HTTPS GitHub URL of this repository (`https://github.com/<OWNER>/<REPOSITORY>`)
   - **Application description:** `Offline-first iOS client for Obsidian Todo stores` (optional)
   - **Authorization callback URL:** the same repository URL. GitHub requires this registration field, but Device Flow does not redirect to it.
3. Create the application, then open its settings and select **Enable Device Flow**.
4. Copy the OAuth app's public **Client ID**. Do **not** generate or configure a client secret.
5. In this repository, open **Settings → Secrets and variables → Actions → Variables → New repository variable** and create:

   | Name | Value |
   | --- | --- |
   | `GH_OAUTH_CLIENT_ID` | the OAuth app's public Client ID |

OTodo requests the GitHub `repo` scope so the user can explicitly approve access to public and private repositories. The client sends only the public client ID during Device Flow. It requires **no OAuth client secret, personal access token, or GitHub password**. If an organization enforces SAML SSO or OAuth App restrictions, its owner must separately approve/authorize the OAuth App for that organization.

At build time, the public Actions variable is passed to the Xcode build setting `GITHUB_CLIENT_ID`; `project.yml` writes that value to the app's `GitHubClientID` Info.plist key. For a local build, pass the same setting explicitly as shown below.

## Repository and store onboarding

> **One-time external user action:** create the GitHub repository and commit a compatible `.todo/config.toml`, project records, and any existing task records before connecting OTodo. Neither the app nor CI creates this external repository/store registration.

In OTodo:

1. Tap **Continue with GitHub**, open the verification page, enter the one-time code, and approve the requested `repo` scope.
2. Select a repository. Its default branch is filled automatically; enter another branch if needed.
3. Tap **Find Todo Stores**. Select the repository root or a subdirectory found through its `.todo/config.toml`.
4. Tap **Connect Repository**. The initial snapshot must validate before it becomes the saved offline workspace.

## Develop and test

### Swift package on Linux or macOS

The Swift package contains the platform-neutral core and its tests:

```sh
swift build
swift test
```

### Generate and build the iOS app on macOS

Install the pinned XcodeGen binary without relying on a floating Homebrew version:

```sh
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_DIR="$(mktemp -d)"
curl --fail --silent --show-error --location --retry 3 \
  --output "$XCODEGEN_DIR/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
echo "${XCODEGEN_SHA256}  ${XCODEGEN_DIR}/xcodegen.zip" | shasum -a 256 --check
unzip -q "$XCODEGEN_DIR/xcodegen.zip" -d "$XCODEGEN_DIR"
export PATH="$XCODEGEN_DIR/xcodegen/bin:$PATH"
xcodegen --version
```

Generate the project, then build for a generic simulator:

```sh
export GH_OAUTH_CLIENT_ID='<public OAuth Client ID>'
xcodegen generate --spec project.yml
xcodebuild build \
  -project OTodo.xcodeproj \
  -scheme OTodo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  GITHUB_CLIENT_ID="$GH_OAUTH_CLIENT_ID"
```

To run or test, open `OTodo.xcodeproj`, select scheme `OTodo` and any installed iOS 17-or-newer iPhone simulator, then Run/Test. Regenerate the project after changing `project.yml`; do not hand-edit generated project settings.

## CI and releases

[`CI`](.github/workflows/ci.yml) runs on every push and pull request and can be dispatched for any branch:

```sh
gh workflow run ci.yml --ref <branch>
```

It runs `swift test` in the Swift 6.1 Linux container and, independently, checksum-installs XcodeGen 2.46.0 on macOS, generates the project, builds for an available iPhone simulator, and runs the UI tests. A failed iOS job retains `iOS-test-results` `.xcresult` artifacts for 7 days. The workflow has read-only repository contents permission, and every third-party action is pinned to a full commit SHA.

See [`docs/RELEASE.md`](docs/RELEASE.md) for the one-time Apple setup, signing secrets, artifact-only builds, and TestFlight releases.
