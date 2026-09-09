# OTodo

OTodo is an offline-first iOS client for Obsidian Todo schema-1 and schema-2 stores kept in a GitHub repository. It signs in through GitHub's OAuth Device Flow, discovers stores on a selected branch, and lets you create projects plus create, edit, complete, and delete todos without making a local Git checkout.

The workspace uses a compact typographic heading, a neutral canvas, quiet row dividers, and a floating quick-add control while retaining native iOS interactions and accessibility. It displays active todos due today or overdue by default, with filters for every active todo or all todos including terminal states. The Projects sidebar filters projects; project names become lowercase, hyphenated slugs and direct Markdown project records. By default, todos are ordered by due date and time, configured workflow-state order, name, and ULID. Swipe right on a todo to reveal Done and Reschedule; swipe left to reveal Delete. Touch and hold a todo and choose Reschedule to shift its due date with the calendar or a relative phrase while preserving every other field. The editor supports the name, state, projects, tags, due date with optional exact time, and Markdown body. New todos and the reschedule sheet calculate an exact due date and time from phrases such as `in 3 days`, `in 6 hours`, or `in 6 months`; supported units are minutes, hours, days, weeks, months, and years. GitHub tokens are stored in the device Keychain; repository workspaces and their pending changes are stored on the device.

Open **Sort todos** (the up/down arrows beside Filters) in Todos to choose **Due date (earliest first)**, **Created date (newest first)**, or **Alphabetical (A–Z)**. Due-date order puts undated todos last. Creation order uses the timestamped ULIDs already in task filenames; alphabetical order follows the device locale, ignores case, and orders numbers naturally. The choice is saved on this device across workspaces without changing task records, filters, or project scope. Upcoming always orders each section by due date and time; returning to Todos restores your chosen sort order.

Tap a todo's circle to complete it without opening the editor. Completed todos remain available in **All**; tap their checked circle to reopen them in the configured default state. Tapping the title or details still opens the editor, and both state changes use the same durable offline save and sync path as editing.

Each todo shows its title and at most one quiet metadata line. The deadline takes priority, followed by a repeat icon and one context: ancestry, the first project, or the first tag. Additional projects or tags use a `+N` count instead of wrapping. The completion circle carries state; the editor and VoiceOver retain the full state, ancestry, projects, tags, and schedule.

Workspace counts sit beside the title, and the selected Home filter uses a solid accent. Custom query syntax stays in the Filters library. Completed dates use a neutral style instead of an overdue warning.

Sidebar badges count only open todos across all dates, independent of the selected filter or project. **Inbox** counts todos without an assigned project, including undated work; its badge updates when a todo is created, organized, completed, reopened, or deleted. Configured terminal states are excluded from Inbox, individual project counts, and the **All Todos** count.

Touch and hold a todo for **Done**, **Reschedule**, **Add Subtask**, and **Delete**. Done is available only for open todos; Delete is available for both open and completed todos but refuses tasks that still have children.

Update and sync information stays pinned beside **+** at the bottom of the workspace. Todo scrolling does not move it, and the list reserves space so the final todo remains reachable without overlapping the status or quick-add controls.

At accessibility text sizes, the pinned status becomes a compact **Offline**, sync, or **Needs attention** control. Tap it to expand scrollable details and the existing sync and repair actions without permanently crowding out the todo list. Conflict, relationship, and attachment-update warnings remain available.

Touch and hold OTodo's Home Screen icon and choose **New Todo** to open task creation directly.
Tap **+** to add a todo. Touch and hold **+** to choose **New Todo**, **Bulk Add**, or **New Project**.
The sidebar separates **Todos**, **Upcoming**, and **Inbox** from project scope. Tap **+** beside its **Projects** heading to create a project directly. At accessibility text sizes, it uses the full width and scrolls utility controls with its content.

**Bulk Add** accepts one todo per nonblank line and previews each stripped name and resulting date/time. From **Today**, names without schedule phrases default to today; other views keep them undated. A date phrase overrides the view default, and a clock alone means today. Detected phrases are removed on save. The entire batch is validated and saved together on the device, so an invalid line cannot leave a partially created batch.

In the **New Todo** editor, **Save & Create Another** saves without closing, confirms the save, and returns focus to a fresh name. It keeps the selected parent, state, projects, and tags, but clears notes, the link, queued subtasks, recurrence, and the previous todo's schedule. From **Today**, the next draft starts due today again; other views start undated. Normal **Save** still saves and closes; editing an existing todo does not offer repeated creation.

The new/edit editor starts with a prominent title and immediately editable Markdown notes. Tap **Add notes…** to write multiple lines; notes use the same durable offline save as the rest of the todo and remain available after restarting the app. **Schedule** expands date, optional time, relative-date entry for new todos, and repeat controls. **Details** expands state, parent, projects, and tags. Both rows summarize existing values while collapsed, and saving without opening either panel preserves those values. **Save & Create Another** returns to the focused, collapsed layout.

Editors use grouped native surfaces and put State and Parent together under **Details**. **Save & Create Another** reserves its own space above the keyboard at standard text sizes; at accessibility sizes it appears at the end of the form instead of covering fields. Cancel and Save remain in the navigation bar.

Add OTodo's **Today** widget to the Home Screen to see active todos due today or overdue without opening the app. The widget refreshes when OTodo's tasks change and at the next local day boundary.

The shared palette follows the system appearance: light mode uses indigo accents, while dark mode uses legible lavender foregrounds, neutral raised surfaces, and subdued dark fills behind white labels.

The app, Share capture, widgets, and Watch use native **SF Rounded** with semantic text styles and Dynamic Type. The task-name field follows the same design without rebuilding its font on every keystroke; no downloaded font files are required.

Task names recognize full weekday names and common abbreviations (`Sun`, `Mon`, `Tue`/`Tues`, `Wed`, `Thu`/`Thur`/`Thurs`, `Fri`, `Sat`), plus `today`/`tod`, `tomorrow`, `in N days`, `in N weeks`, `in N months`, `next week`, and `next month`. Matching is case-insensitive and uses whole words; abbreviations can have a trailing period. `today` and `tod` mean the current day in the device's local calendar. A weekday means its next occurrence, including next week when entered on that weekday.

Names also recognize 24-hour `HH:mm` clocks (`00:00`–`23:59`) and 12-hour `h[:mm] am/pm` clocks (`9am`, `3:05 PM`, `12 am`), optionally preceded by `at`. Bare hours and ambiguous one-digit 24-hour clocks such as `9:30` are not recognized; use `09:30` or `9:30 am`. Invalid clocks such as `25:00`, `12:60`, or `13 pm`, embedded identifiers, and URL/path tokens stay untouched. `in N hours` and `in N minutes` use the same positive-integer relative-date rules as the Schedule field, including rounding forward to the next minute and crossing local midnight or daylight-saving transitions.

The last date phrase and last time phrase each win independently. An explicit date overrides the editor's selected calendar date; an explicit time overrides its selected time. A clock without a date keeps an already-selected calendar date, otherwise it defaults to local today (even if that clock has already passed). Relative hours/minutes supply both date and time. Date-only phrases preserve a selected time. The editor highlights only the contributing phrases, and saving removes those phrases with surrounding separator cleanup, not intervening title words: `Call tomorrow with Alex at 3 pm` saves as `Call with Alex` with `due_date` and `due_time`. Share and Shortcuts captures remain intentionally undated and do not parse schedule phrases from names.

Due reminders are opt-in. Open **Due reminders** in the Projects sidebar, then **Enable Reminders** and allow iOS notifications. **At due time** uses each active dated todo's exact time, or 9:00 AM in the device time zone for date-only todos. Choose **5 minutes before**, **1 hour before**, or a custom positive number of hours or calendar days, then **Apply Timing**. The saved setting applies to all due reminders on this device without changing Git records; invalid input leaves it unchanged. Calendar days preserve the local clock across daylight-saving transitions, while hours are elapsed time.

Elapsed, undelivered reminders are scheduled shortly. Completed, deleted, and rescheduled tasks reconcile their alerts, and already-delivered occurrences are not repeated when timing changes. iOS allows up to 64 pending reminders; delivered occurrences do not consume those slots. Alerts can appear while OTodo is foregrounded as well as in the background, subject to iOS notification permissions and Focus. The settings screen exposes authorization errors, scheduling failures, a retry action, and the app's iOS notification settings.

Tapping a due reminder opens that exact todo in its editor, including after a cold start and when the current filter or project hides it. The request waits for the cached workspace to load, so it also works offline. If another editor or sheet is open, finish or dismiss it first; the reminder never replaces unsaved work. A reminder for a task no longer in the workspace is ignored rather than opening a different task.

Open **Changelog** from the sidebar to review product features and visible improvements, newest first. Each entry shows its commit's exact UTC timestamp. The history is bundled with the app and available offline; CI and repository-maintenance changes are excluded.

## Task links

Use **Link** in the new/edit editor to store an optional HTTP or HTTPS URL. **Open Link** opens it only after an explicit tap; the clear button removes it on Save. Links survive offline relaunch, completion, rescheduling, and unrelated edits.

The shared Markdown field is an optional quoted `url`, written after `parent` and before `due_date` and omitted when absent. It works in schema 1 and 2 without changing schema assets or upgrading stores. The matching Rust CLI supports `add --url`, `edit --url`, and `edit --clear-url`, and advertises `task_urls` through `capabilities`. Both clients reject malformed/non-web URLs and preserve valid spelling after trimming explicit input.

## Attachments

Files and Photos can be selected in the todo editor, and files or images can be sent to OTodo from the system Share sheet. Selections are staged until Save; Save & Create Another starts with no selected files. Each file is limited to **20 MiB**, preserves its original bytes, and is stored at `Attachments/<ULID>/<sanitized filename>` in the selected todo store. Images use Markdown embeds; other files use links relative to the actual task location. Explicit Markdown links and Obsidian wikilinks into this folder are also recognized, including manually placed files. Shortened wikilinks need an explicit `Attachments/...` path to appear in the attachment list. Links inside code examples are ignored.

Open an attachment to download and preview it, use Share to export it, or choose Keep Offline. Ordinary task sync downloads only the file catalog. The local cache uses a 256 MiB LRU budget; pinned files and pending imports are exempt. Pinned files refresh after sync; failed replacements retain an explicitly labeled older cached version. Missing or oversized files and download failures do not prevent ordinary todo editing. Remove Link only changes that todo's Markdown; completing, recurring, and deleting a todo retain vault files. Multiple tasks can share a file and children do not inherit attachments.

Attachments work in store schemas **1 and 2** without an upgrade or configuration/frontmatter fields. A configured record directory overlapping `Attachments/` disables attachment operations. Existing custom properties, including a property named `attachments`, remain untouched. The local workspace persistence format is **3**; formats 1 and 2 migrate on save. Older app versions cannot open format 3. Files, body links, and pending binary uploads are saved together locally and published in one Git tree/commit. Different-content collisions require discarding the import and importing again under a fresh path.

Desktop synchronization must include `Attachments/` along with tasks and projects. To paste files there from Obsidian, set **Settings → Files and links → Default location for new attachments → In the folder specified below**, then enter the vault-relative path to the todo store's `Attachments` folder. OTodo does not change vault-wide settings. Camera capture, scanning, Watch attachment controls, file deletion, and repository cleanup are outside this release.

## Weekly Stats

Open **Stats** in the Projects sidebar for an offline, workspace-scoped weekly review.
Previous/next-week controls and **This week** follow the device calendar's first
weekday and time zone, with an exclusive end boundary. The screen updates from
the same retained task records and pending offline changes as the todo list.

- **Finished total** counts recorded completions, not distinct tasks. A recurring
  occurrence, an explicit nonterminal-to-terminal transition (including Finish
  series), and reopening then recompleting each count once. Creating a task
  directly in a terminal state also records a completion. Metadata-only terminal
  edits, reopening, and rescheduling do not add or erase completion events.
- **Finished on time** compares the pre-completion due schedule, not the next
  recurrence date or a date changed in the same edit. Date-only tasks allow the
  whole local day; timed tasks must finish at or before the exact deadline.
  Undated completions and dated completions without enough time evidence are
  excluded from the denominator and separately identified.
- **Created** decodes the timestamp already embedded in each retained task's
  ULID. Import or sync time is not creation time.
- **Most active projects and labels** rank creations plus recorded completions
  during the week. Each activity contributes once to each assigned category.
  Completions use historical category snapshots; creations use current task
  categories because historical creation metadata is not available. Unassigned
  activity contributes to totals but not rankings; the top five categories show.
- **Most overdue projects and labels · now** rank current nonterminal overdue
  tasks, using current metadata and exact due times where present. These are
  explicitly current counts, not reconstructed historical overdue states.
- **Advanced features** shows both weekly completed occurrences and current
  retained tasks using subtasks, attachments, or recurrence. Subtasks includes a
  child or a parent with children. Attachments means at least one recognized local
  attachment link in the task body, using the shared attachment-link parser; it
  does not claim that a file has been downloaded or still exists. Usage is a
  task/occurrence count rather than a count of individual files or children.

Completion evidence lives in the namespaced `otodo_completion_history`
frontmatter property in both schema 1 and schema 2, serialized through the normal
task/outbox/sync path, not a parallel analytics database. It is an append-only
YAML sequence of mappings. Each version-1 mapping contains `version: 1`, a UUID
`id`, UTC Unix-millisecond `completed_at_ms`, local civil `completed_on`,
the saved `due_date`/`due_time` (nullable), nullable Boolean `on_time`, `projects`
and `tags` string sequences, and Boolean `subtasks`, `attachments`, and
`recurring` snapshots. Week membership uses the completion timestamp in the
viewer's current time zone; the recorded on-time assessment does not change
when the task is edited or the viewer travels. An explicitly supplied historical
completion day without exact-time evidence leaves same-day timed assessment
unknown. Identical event IDs are counted once per retained task.

Unrelated frontmatter and unknown event mappings are preserved. Unsupported
entries are excluded with a visible coverage count; an existing non-sequence
value under this namespaced key is never silently reinterpreted or overwritten
and must be safeguarded/relocated before recording a completion. Legacy completed
tasks, including recurrence's old `last_completed_date`, are not backfilled with
invented timestamps. **History coverage** identifies retained completed/previously
recurring records without readable events, unsupported entries, and the earliest
retained event without claiming that coverage is continuous. Counts do not claim
complete Git history: deletions, external clients that do not record events,
remote edits, and conflict choices can reduce evidence. No analytics backend or
telemetry is used.

## Subtasks

Schema-2 stores support one optional parent per task at arbitrary depth. Choose
**Add Subtask** on a task, or use the editor's **Details → Parent** picker to attach,
reparent, or choose **No Parent** to detach. Search covers the complete cached
workspace, including terminal tasks and tasks outside the current filter.
Candidates show their full IDs; the current task and its descendants are excluded.

Both **New Todo** and **Edit Todo** also have a **Subtasks** section. Enter a child name and tap **Add Subtask** to queue it; remove queued children before saving if needed. Existing direct children are shown in the parent editor. **Save** publishes the parent and every queued child atomically to the durable offline workspace and outbox. A bad child name, stale parent, conflict, or failed save publishes none of the batch. Unqueued text must be added or cleared before saving. Explicit date phrases in child names use the existing name parser.

New subtasks start with their parent's projects. Queued children use the projects
being saved in the parent editor, including changes made before Save; **Add Subtask**
and choosing a parent in a new draft prefill the same projects instead of the current
filter's projects. Previously saved children keep their own projects when a parent
is edited or they are reparented. Queued children start in the configured default
state without tags, a schedule, or a link unless their own name explicitly supplies
a date/time. Each task keeps its own schedule, recurrence, and Today/Watch/widget
eligibility; reminders use that task's schedule and the device's reminder settings.

Completing a parent also completes every active descendant, including subtasks
outside the current filter and below already-terminal children. Recurring tasks
complete their current occurrence and advance their own schedule. Choosing a
terminal State or **Finish series** instead closes the whole active subtree without
advancing its schedules. Children queued in that same save are included, including
when creating a parent directly in a terminal state. Already-terminal descendants,
unrelated tasks, and their history remain unchanged. Every changed task records its
own completion; a descendant conflict, invalid recurrence/history, or failed save
rejects the entire local transaction. Reopening a parent does not reopen children,
and adding a child to an already-terminal parent does not complete it automatically.
Deleting any task with direct children is refused, including terminal children;
explicitly detach, reparent, or delete those children first.

All, Active, and custom task lists indent matching relatives without inserting
filtered-out ancestors. Ancestry labels retain context outside the filter.
Today, Upcoming, and Inbox keep their date ordering and independent eligibility,
so a matching child remains visible even when its parent is not.

**Save & Create Another** keeps the chosen parent for sibling creation. A fresh
global **+** or Home Screen **New Todo** request starts a root draft; Share,
Shortcuts/App Intent, and Bulk Add remain root-only. Filter-derived project/tag
defaults still apply to root creation; a new child's parent supplies its initial projects.

The pinned **Relationships** review shows missing parents, cycles, and durable
relationship blocks across the whole workspace, independently of the active
filter and same-file conflicts. Open a task there to repair its parent. Sync
checks both the complete local/remote overlay and the actual subset it can
publish, withholding unsafe related changes while allowing unrelated safe work
to sync. Repairs are reevaluated on subsequent synchronization.

Schema-1 stores stay flat and editable; the picker explains that an explicit
CLI upgrade is required. First reconcile and safeguard pending work and stop
all writers/sync, then run `otodo --root <store> upgrade --to 2 --dry-run` followed
by `otodo --root <store> upgrade --to 2`. Any legacy top-level `parent` property
blocks activation until deliberately relocated or removed. Sync the upgraded
metadata before restarting updated clients. OTodo never upgrades the Git store
automatically.

## Inbox and system capture

**Inbox** is a first-class view of active todos with no assigned projects, including undated work. Open it from the Home filters or the sidebar. It is not an Inbox project or tag. Assign a project or complete a todo to remove it from Inbox; use the existing editor to organize projects, tags, and dates.

Choose **OTodo** in the iOS Share sheet to capture text, URLs, files, or images. Review the proposed title and Markdown context, then **Save**. Safari capture preserves the webpage title, link, and selected text. In Shortcuts, use OTodo's **Add Todo** action with supplied **Todo** text and an optional **Source URL**. Siri's “Add a todo in OTodo” phrase prompts for the text rather than opening an empty editor.

System captures start without a parent, project, or deadline. After connecting a workspace, they save directly to the normal local workspace and outbox, including offline; OTodo reloads external captures and synchronizes through its normal path when activated. No separate capture database or direct GitHub writes are used.

Open OTodo once after upgrading an existing installation. The app atomically moves its complete private workspace directory, including pending changes, saved filters, and repository selection, into the shared App Group before opening stores. Migration errors are shown instead of silently starting an empty workspace. App and extension saves coordinate revision checks with a cross-process lock.

## Upcoming and weekly review

Open **Upcoming** from the sidebar to review active work using cached task fields. It keeps the selected project; **All projects** clears that scope. The filter strip and library can narrow the agenda without losing its project scope. **Todos** switches back to the flat list, and **Inbox** leaves the agenda for projectless work.

The six sections use the device's local Gregorian calendar:

| Section | Due date |
| --- | --- |
| Overdue | Before today |
| Today | Today |
| Tomorrow | The next calendar day |
| Next seven days | After tomorrow, through today + 7 days |
| Later | After today + 7 days |
| No date | No due date |

Sections never duplicate a task and exclude configured terminal states. They are based on dates, not time of day: elapsed times on today's tasks still appear under Today with an overdue marker. Optional times remain visible. Relative filters and sections refresh on local day changes, significant clock/time-zone changes, and returning to the app.

Tap a section heading to fold or unfold its todos. **No date** starts folded; dated sections start open. Headings retain their counts and date ranges while folded, and your choices survive switching between Todos and Upcoming in the current workspace. Folding does not change filters or selections: **Select all** still includes folded sections.

Tap **Select**, choose several rows (or **Select all** for the current scope), then **Reschedule**. The shared calendar and relative-date controls support a weekly review without opening each todo. Bulk edits initially keep every date and time; explicitly set or remove either field. A date-only edit keeps each todo's own time. Relative days/weeks/months/years change dates, while minutes/hours set both date and time. Removing dates also removes times; recurring todos still require dates.

The entire batch is validated and saved atomically to the normal durable outbox, including offline. Names, states, parents, projects, tags, notes, recurrence metadata, and custom front matter are preserved. A stale/conflicted task or invalid schedule prevents the whole batch from saving. No external calendar or generated recurring occurrences are involved.

## Recurring todos

In the todo editor, open **Schedule**, choose **Repeat → Daily, Weekly, Monthly, or Yearly**, enter a positive interval, and set a due date. Weekly rules can select weekdays; monthly and yearly rules can select days of the month; yearly rules can also select months. Empty selections use the anchor date's corresponding values. The current due date must match explicit selections before the todo can be saved.

**Count from → Scheduled date** retains the scheduled cadence and skips missed occurrences. **Completion date** starts from the day you complete the occurrence. Calendar dates that do not exist are skipped rather than shortened: a monthly January 31 occurrence advances to March 31, and a February 29 yearly occurrence waits for a leap year.

Tap the circle or choose **Done** to complete the current occurrence. OTodo advances the same task record, keeps its parent, exact due time, notes, projects, tags, and custom front matter, records the completion date, and returns it to the configured default state. The next date is strictly after the completion day (and after the current due date when counting from schedule). The change is durable offline and uses the normal coalesced outbox; reminders, Today widgets, and Watch snapshots then reflect the next due date.

Touch and hold an open recurring todo and choose **Finish series**, or select a terminal State in the editor, to end the series without scheduling another occurrence. Reopening restores the existing date and rule. **Repeat → None** removes the recurrence rule, anchor, and `last_completed_date` scheduling marker and makes it a one-off todo. Previously recorded Stats completions in `otodo_completion_history` are retained. Invalid rules, dates outside the supported calendar, stale edits, or unresolved conflicts leave the saved task unchanged.

## Saved filters

Open **Filters** from the top-right of the workspace, then **+** to save a name and text query. Tap a filter to open it; star it to put it on the app's Home filter strip. Touch and hold a saved filter (or swipe left) to edit or delete it. **Today**, **Active**, **All**, and **Inbox** are predefined queries: their definitions cannot change, but their Home stars can.

The query editor suggests projects and tags from the current workspace as you type `project:` or `tag:`. Tap a suggestion to complete the value at the cursor, including when editing in the middle of a query. Matching ignores case while insertion preserves the stored spelling and quotes or escapes special characters automatically. Suggestions work offline and leave the surrounding query unchanged.

Filters are saved offline on this device, separately for each repository, branch, and store path. They do not alter the Obsidian store or sync through GitHub. Selecting a filter from the library clears project scope in Todos but preserves it in Upcoming. Selecting a Home filter retains that scope except for Inbox, which always shows projectless work. Selecting a project from Inbox switches to that project's Active view.

Creating a todo from a filtered view preselects its required projects and tags, plus the selected sidebar project. `AND` combines requirements; `OR` keeps only labels shared by every branch. Negated expressions and ambiguous alternatives are not used to guess labels. Only existing projects and valid tags are inherited. The editor keeps these fields editable, and **Save & Create Another** retains your choices. **Bulk Add** applies the same labels to every todo in its atomic batch. In **Today**, **New Todo**, **Add Subtask**, repeated creation, and **Bulk Add** all default to the current local date, including within a project. The date remains editable and a date phrase in the name takes precedence. Other views, including Upcoming, keep fresh todos undated unless a date is entered; names and workflow states are never inferred from a filter.

The language uses explicit boolean operators, inspired by [Todoist's text filters](https://www.todoist.com/help/articles/introduction-to-filters-V98wIH):

| Query | Matches |
| --- | --- |
| `all` | Every todo, including terminal states |
| `active` | Todos outside the configured terminal states |
| `today` | Active todos due today or overdue |
| `inbox` | Active todos with no assigned projects, regardless of due date |
| `overdue` | Active todos dated before today |
| `tomorrow` | Active todos dated the next local calendar day |
| `next-seven-days` | Active todos from tomorrow through today + 7 days, inclusive |
| `undated` | Active todos without a due date |
| `due:2026-09-05` | Active todos on that exact date |
| `due:2026-09-01..2026-09-07` | Active todos in the inclusive date range |
| `(overdue OR next-seven-days) AND project:work AND NOT tag:waiting` | Approaching or late work, excluding waiting tasks |
| `project:work AND tag:focus` | Exact project slug and tag |
| `active AND NOT tag:waiting` | Active todos without the tag |
| `(project:home OR project:work) AND today` | Today's focus in either project |
| `name:/report/i` | Case-insensitive name regex |
| `description:/invoice\|receipt/i` | Regex against the Markdown body |

`AND`, `OR`, and `NOT` are case-insensitive; `&`, `|`, and `!` are equivalent. `NOT` binds first, then `AND`, then `OR`; parentheses override this order. Atoms and field names are lowercase. Tag/project values follow the colon immediately and match exactly, including case. Double-quote values containing operators, for example `tag:"a|b"`; inside quotes, `\"` and `\\` escape a quote and backslash.

Date literals must be valid `YYYY-MM-DD` Gregorian dates; ranges require both endpoints in ascending order. Every date predicate excludes terminal tasks. `next-seven-days` includes tomorrow when used as a query, while the agenda places those tasks only in its separate Tomorrow section.

Name and description patterns use ICU regular expressions between `/` delimiters. Escape a literal slash as `\/`. Optional flags are `i` (ignore case), `m` (line anchors), and `s` (dot matches newlines); omit them for case-sensitive matching. Invalid syntax is shown in the editor and cannot be saved. Compiled queries are cached; matching runs off the UI thread and is cancelled when the selected query or tasks change.

## Apple Watch

Install OTodo on your paired Apple Watch (watchOS 10 or later), then open OTodo on iPhone with a connected workspace. The Watch app shows open todos in **Overdue** and **Today** sections across all projects. Tap a row to read its full name, due date, and optional exact time. Editing remains on iPhone.

Add **OTodo → Today & Overdue** to a compatible watch-face complication slot. Circular and corner layouts show the combined count; inline and rectangular layouts show separate Today and Overdue counts. The rectangular layout also shows the first overdue or today's todo. Tapping the complication opens the Watch list.

Workspace changes are sent through WatchConnectivity and saved atomically on Watch; no GitHub credentials or direct GitHub access are needed there. The saved snapshot includes future dated todos, so they move into Today and Overdue at local day boundaries even when the phone is unavailable. Completed and undated todos are excluded. **Saved on Watch** shows when the snapshot last changed, and **Refresh from iPhone** requests the latest available data. Delivery depends on the paired devices and watchOS scheduling; the Watch displays its last received snapshot while disconnected.

CI builds both Watch targets and exercises live delivery and offline relaunch on paired simulators. Watch-face placement and complication tap routing, large-file transfers, and expedited complication updates require a physical paired device check.

## Requirements

- Swift 6.1 for the Swift package and Linux development
- macOS with Xcode and an installed iOS 17-or-newer simulator for the app
- XcodeGen **2.46.0** to generate `OTodo.xcodeproj` from `project.yml`
- Python 3.12 or newer for CI/release helpers, their pinned `.github/scripts/requirements.txt` dependencies, and Git with complete repository history for iOS app builds
- iOS 17 or later to run OTodo
- watchOS 10 or later and a paired iPhone for the optional Watch companion

The application scheme is `OTodo`, the generated project is `OTodo.xcodeproj`, and the application bundle identifier is `plastickarma.otodo`.

## Obsidian Todo compatibility

OTodo explicitly supports store schema versions **1 and 2** and rejects other versions. A store is a repository root or subdirectory containing `.todo/config.toml`. OTodo discovers these files; it does not create a repository, initialize a store, or automatically upgrade one.

A minimal compatible configuration is:

```toml
schema_version = 2
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

Task identity belongs in the filename, not frontmatter. OTodo creates files as `<tasks_directory>/<26-character-uppercase-ULID>.md`. A root task in either supported version has YAML frontmatter followed by an arbitrary Markdown body:

```markdown
---
name: "Buy milk"
state: open
projects:
  - "[[Projects/home]]"
tags:
  - errands
due_date: 2026-09-03
due_time: "14:30"
---
Optional Markdown notes.
```

The exact record contract is:

- Required: nonempty single-line `name`, configured `state`, `projects` list, and `tags` list.
- Optional: `due_date` and `last_completed_date` as real `YYYY-MM-DD` civil dates; `due_time` as a 24-hour `HH:mm` value that requires `due_date`; `recurrence`; and `recurrence_from`, which is `schedule` or `completion`.
- Schema 2 optionally recognizes `parent` as a full same-store ULID, emitted quoted and uppercase immediately after `tags`. A missing property means root; null, empty, nonstring, prefix, path, and wikilink values are rejected. Parent identity follows the recursive task filename, not its path. Self-links, cycles, missing targets, and duplicate identities require repair. Schema 1 preserves any safely representable `parent` value as unknown metadata instead.
- Project slugs match `[a-z0-9][a-z0-9-]*` and are unique per task. Project links must be `[[<obsidian_link_prefix>/<projects_directory>/<slug>]]`, with the empty prefix omitting that first component.
- Tags must be unique, nonempty strings without whitespace, control characters, commas, brackets, or braces, and cannot begin with `#`.
- `id` frontmatter is rejected. Other frontmatter properties and the Markdown body are preserved when OTodo edits a task. Core fields are emitted canonically.
- Recurrence supports `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, positive `INTERVAL`, non-ordinal `BYDAY` for weekly rules, `BYMONTHDAY=1..31` for monthly/yearly rules, and `BYMONTH=1..12` for yearly rules. A recurring task requires both `due_date` and `recurrence_from`, and its due date must match its selection clauses. The editor supports these fields; occurrence completion advances the same record and updates `last_completed_date`.
- The configuration limit is 1 MiB; each selected task/project record is limited to 8 MiB; at most 10,000 selected files and 64 MiB of decoded selected content are loaded.

`Sources/OTodoCore/Resources/schema.json` and `schema-v2.json` are the version-selected bundled structural schemas, retaining the app's existing due-time extension. Runtime validation additionally enforces configuration, paths, project existence, dates, times, recurrence, filename identity, and schema-2 relationships. These independent bundled assets are not compared for equality with a Rust-generated deployed schema.

## Offline, outbox, and conflict behavior

The first connection to a store requires GitHub access so OTodo can validate and save a complete snapshot. After that:

1. Every project or todo creation, edit, completion, or deletion is atomically saved to the durable local workspace and outbox before the operation reports success.
2. Repeated local changes to the same path coalesce into one pending change while retaining the original remote base. Deleting a never-synchronized todo cancels its pending creation.
3. OTodo synchronizes after a local save when online, when connectivity returns, on launch with a saved workspace, and on pull-to-refresh. Failed pushes remain pending for a later attempt.
4. Sync first pulls the current branch snapshot, applies unrelated remote changes, and sends safe pending paths together in one `Sync OTodo changes` commit. The branch ref is updated with compare-and-swap semantics; OTodo never force-pushes.
5. If GitHub and this device changed the same path from the same base, OTodo preserves the local version—including a local deletion—and durable outbox entry, records a conflict, and does not push that path. Unrelated safe paths can still synchronize.
6. **Keep My Version** rebases and queues the device's content or deletion to replace GitHub on the next sync. **Use GitHub Version** discards the device's pending version and adopts GitHub's file; if GitHub deleted it, the local task is removed. Resolution is explicit and cannot be undone in the app.
7. Parent relationships are checked again against the actual publishable subset, not merely the visible local overlay. Related unsafe paths stay pending with durable **Relationships** diagnostics until repaired; same-file conflict actions remain separate.
8. Local cache envelope 2 imports envelope-1 workspaces through the normal load and revision-check paths, preserving raw records, pending changes/deletions, conflict evidence, base SHAs, and revisions. This cache migration does not activate schema 2 in the remote store.

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

Portable workflow checks run without Xcode:

```sh
python3 -m venv /tmp/otodo-ci-python
/tmp/otodo-ci-python/bin/python -m pip install -r .github/scripts/requirements.txt
/tmp/otodo-ci-python/bin/python .github/scripts/validate_bundles.py source
/tmp/otodo-ci-python/bin/python -m unittest discover -s .github/scripts -p 'test_*.py'
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
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  GITHUB_CLIENT_ID="$GH_OAUTH_CLIENT_ID"
```

Simulator builds use ad-hoc signing so App Group entitlements are available to the app and extensions. Disabling signing prevents shared workspace capture from running.

To run or test, open `OTodo.xcodeproj`, select scheme `OTodo` and any installed iOS 17-or-newer iPhone simulator, then Run/Test. Regenerate the project after changing `project.yml`; do not hand-edit generated project settings.

### Visual design survey

The UI suite includes light/dark captures of the workspace, sidebar, filter library, project creation, and todo/bulk capture, plus the largest accessibility text size. To run only this visual survey on a branch:

```sh
gh workflow run ci.yml --ref your-branch \
  -f design_survey_only=true -f export_ui_snapshots=true
```

Download the run's `ui-snapshots` artifact for full-resolution images and its attachment manifest. This focused run is not the full CI gate: omit `design_survey_only` (or set it to `false`) to run the complete core, iOS, and Watch checks. `export_ui_snapshots=true` also works with full CI.

### Product changelog entries

Mark each new product-feature commit with a `Changelog: feature` trailer:

```sh
git commit -m "Add a product feature" -m "Changelog: feature"
```

The app build generates `Changelog.json` from those commits and a fixed historical feature backfill, using Git's subjects and committer timestamps. Do not add maintenance commits to the backfill. This generation runs locally without fetching history; shallow clones must run `git fetch --unshallow` before building. Simulator CI and release builds fetch complete history automatically.

## CI and releases

[`CI`](.github/workflows/ci.yml) runs automatically for pull requests. Delivery verification is explicitly dispatched for the intended branch; pushes no longer launch an equivalent second simulator run:

```sh
gh workflow run ci.yml --ref <branch>
```

The canonical **CI / full verification** check requires portable metadata checks, the complete Linux Swift suite, real live/offline Watch verification, and every enabled compiled iOS test. iOS builds once, checks effective signed App Groups, and runs hosted application tests plus critical add/edit/attachment behavior first. Remaining tests run on two isolated simulator runners using that exact run's executable products; the real SpringBoard/widget scenarios stay together in the integration partition. The planner discovers tests from Xcode, uses `.github/ci-test-durations.json` only for load balancing, and assigns new tests even without a recorded timing. The final check rejects missing, skipped, duplicate, foreign-SHA, or stale failed-attempt coverage.

Native compiler/XCTest errors become immediate file/test annotations. Commands have explicit deadlines, a separate native-test startup allowance, and bounded cancellation; per-test native limits do not replace whole-phase limits. Watch boot and build run concurrently, retain the absolute 300-second snapshot budgets, expose opt-in app-owned readiness/reply state, and preserve phone logs before offline shutdown. No fake snapshot replaces real delivery.

Modes have separate run identities and concurrency groups. A superseded full run cannot be cancelled by a focused diagnostic:

```sh
# Full coverage; screenshot export does not reduce the test plan.
gh workflow run ci.yml --ref <branch> -f export_ui_snapshots=true
# Keep running remaining partitions after a smoke assertion fails.
gh workflow run ci.yml --ref <branch> -f complete_diagnostics=true
# Focused diagnosis cannot satisfy the full release check.
gh workflow run ci.yml --ref <branch> \
  -f test_filter=OTodoUITests/OTodoUITests/testAttachmentSelectionSavesOfflineAndClearsForAnotherTodo
```

Complete-diagnostics mode preserves later independent failures but never substitutes for canonical full verification. Ordinary full mode stops remaining iOS work after a definite smoke failure and cancels sibling matrix work on partition failure. Hosted, functional, integration, and Watch coverage remain mandatory for a successful release.

Every attempt retains small `*-evidence-*`/`watch-smoke-*` timing and coverage artifacts for seven days. Failed iOS jobs retain attempt/partition-specific `iOS-test-results-*` bundles; requested/failure screenshots use `ui-snapshots-*`. Metrics distinguish command elapsed time, native test startup, build milestones, and the first actionable issue. Downloaded test products are bound to the exact run, SHA, Xcode/SDK/architecture, and simulator type; archive transport preserves executable bits and safe internal links. A rerun may reuse prior successful partitions, but a newer failed observation cannot be replaced by older green evidence.

Exact-input Linux `.build` cache reuse is enabled by default; use `use_build_cache=false` for cold comparisons. Keys include the pinned Swift 6.1.3 container digest, actual compiler identity, architecture, package inputs, sources and tests; there is no stale-prefix restore or signed-product/keychain cache. In the initial same-commit experiment, core job time fell from 86 to 58 seconds with identical 37-second container initialization: the core command fell from 31 to 12 seconds, warm restore cost one second, and the cold save cost nine seconds. These are measured samples, not a guaranteed hit rate or whole-CI speedup. All Actions are pinned to full commit SHAs; shared setup uses an isolated Python environment and checksum-verified XcodeGen 2.46.0. Apple package resolution runs as its own bounded preflight before simulator boot/build overlap, rather than hiding package fetching in a concurrent build.

See [`docs/RELEASE.md`](docs/RELEASE.md) for the one-time Apple setup, signing secrets, artifact-only builds, and TestFlight releases.
