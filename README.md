# LaunchInspector

A macOS (SwiftUI) app that lists **your** cron jobs and launchd `.plist` files, with what each one does, its schedule, and its live state.

![LaunchInspector demo](docs/demo.gif)

## Install

**Homebrew:**

```sh
brew install --cask vincentbattez/tap/launch-inspector
```

**Or download** the latest `.dmg` from the
[Releases](https://github.com/vincentbattez/launchs-and-crons-inspector/releases) page,
open it, and drag **LaunchInspector** into **Applications**.

The build is unsigned, so on **first launch right-click the app → Open** once to get past
Gatekeeper. After that, the app **updates itself** (Sparkle) — no need to reinstall.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0 / Xcode 16 (to build)

## Features

- **Focused scan** — user crontab + personal and global LaunchAgents/Daemons. Apple's `/System` daemons are ignored.
- **Per-job detail** — full command, schedule translated to plain language, and multi-dimensional state (enabled, loaded, running, run count).
- **Metadata** — install date, load session, `.app` version, triggering Mach service.
- **Organization** — collapsible groups, rename + describe, hide rows, show/hide columns (right-click the header), sort by column.
- **Actions** (right-click, with confirmation) — **Enable/Disable** and **Delete** any item; built-in **Trash** to **restore**. A single admin password for `/Library` items.
- **Search & filters** — search bar (name, command, project), filter by type, "enabled only".
- **Visual cues** — colored status dot, dormant jobs dimmed.
- **Auto-refresh** every 10s (+ ⟳ / ⌘R).
- **Claude Code-editable config** — names, descriptions, and groups filled in automatically (ready-to-use prompts below).
- **Headless modes** — `--dump` (text list) and `--dump-json` (full export).

## What it scans

Scope is "mine only" — Apple daemons in `/System/Library` are intentionally skipped:

| Source | Type |
|---|---|
| `crontab -l` (user) | Cron |
| `~/Library/LaunchAgents` | LaunchAgent (user) |
| `/Library/LaunchAgents` | LaunchAgent (global) |
| `/Library/LaunchDaemons` | LaunchDaemon (global) |

## Per-job detail

- **Name / Label**, and for symlinked `.plist` files the originating **project** (e.g. `auto-switch-mic`).
- **What it runs** — program, arguments, full command line.
- **Schedule** in plain language: `StartInterval`, `StartCalendarInterval` (dict or array), `WatchPaths`, `KeepAlive`, `RunAtLoad`, and cron expressions.
- **State** across distinct dimensions (not a single boolean):
  - **Enabled/disabled** — read from the launchd overrides database (`launchctl print-disabled`), not just the file's `Disabled` key.
  - **Loaded** — present in `launchctl list` or `launchctl print` (daemons included, without root).
  - **Running** — real PID + last exit code.
  - **Activity** — run count since load (`runs` from `launchctl print`), for agents **and** daemons without root. Approximates "did it run this session": `0` = never, `26×` = 26 times. launchd does **not** expose a last-run timestamp — this is a counter, not a date. Unavailable for crons.
- **Metadata** — install date (`.plist` creation time, approximate), load session (`LimitLoadToSessionType`), app version (`CFBundleShortVersionString` when the program lives in an `.app`), Mach service (the on-demand trigger from `MachServices`).
- **Raw file contents** — binary `.plist` files are converted to XML for display.

## Organize

- **Collapsible groups** — right-click one or more rows → *Move to ▸* (existing group, new group, or none). Each group collapses/expands; state is remembered.
- **Rename + describe** — detail pane → *Customization* (display name + free-form description). Also editable by Claude Code in the config file.
- **Hide rows** — right-click → *Hide* moves the job to the collapsed **Hidden** section at the bottom.
- **Show/hide columns** — right-click the table **header** to toggle and reorder columns (Type, Scope, Schedule, State, Activity, Installed, Version…). *Not persisted across launches yet.*
- **Sort** — click a column header, including **Activity**, **Installed** (by date), and **Version**.
- **Dimmed dormant jobs** — a job that isn't running (launchd with no PID, disabled cron) is shown at reduced opacity; running jobs stand out.

## Actions

Unlike the rest of the app (read-only), these actions **modify** the system. They always go through a **right-click**, require confirmation, and are reversible.

- **Enable/Disable** — (un)loads the job via `launchctl enable|disable` + `bootstrap|bootout`; for a cron, (un)comments the line.
- **Delete…** (confirmation required) — unloads the job, then moves the `.plist` to the app's **internal trash** (a cron is removed from `crontab`, its exact line preserved). No permanent `rm` until the trash is emptied.
- **Trash** (toolbar button) — lists deleted items; **Restore** puts them back in place (`root:wheel` permissions restored for daemons) and reloads them.
- **Admin password** — requested once per action for `/Library` items (global agents + daemons). Crons and your `~/Library` agents don't need it.

## Build & run

**In Xcode** (recommended) — uses DerivedData, so no Google Drive sync issues:
```sh
open Package.swift   # then Cmd+R
```

**Command line** — keep the build cache outside Google Drive (a `.build/` inside a synced folder causes `build.db disk I/O` errors and stale binaries):
```sh
swift build --scratch-path /tmp/li-build && /tmp/li-build/debug/LaunchInspector
```

**Headless** (terminal list, config applied, no window):
```sh
/tmp/li-build/debug/LaunchInspector --dump
```

**JSON** (all resolved jobs — exact config key, command, schedule, originating project — to stdout). Used by Claude Code to fill `name`/`description` in `config.json` without locating or parsing `.plist` files:
```sh
/tmp/li-build/debug/LaunchInspector --dump-json > /tmp/li-jobs.json
```

## Configuration

`~/Library/Application Support/LaunchInspector/config.json` — created on first launch with an **empty stub per job** (the key is pre-filled; you only fill in the values). Schema:

```jsonc
{
  "_help": "…inline doc…",
  "version": 1,
  "groups": [
    { "id": "printer", "name": "Printer", "collapsed": false }
  ],
  "items": {
    // key = launchd Label, or "cron: <schedule> <command>"
    "com.vincent.printer-maintenance": {
      "name": "Nozzle maintenance",       // empty = original label
      "description": "…",                  // note shown in the detail pane
      "group": "printer",                  // a group id (absent = ungrouped)
      "hidden": false                      // true = "Hidden" section
    }
  },
  "ungroupedCollapsed": false,
  "hiddenCollapsed": true
}
```

Designed to be edited by **Claude Code**: tolerant decoding (a missing field falls back to its default), stable keys provided, `_help` documents the schema. Preserve `collapsed` / `*Collapsed` (UI state) when editing. The app **hot-reloads** the file (mtime polling) — no need to restart it.

### Fill the config automatically with Claude Code

[Claude Code](https://claude.com/claude-code) can fill in `name`, `description`, **and** the split into `groups`. **First**, export the resolved job list (from the project folder):

```sh
swift build --scratch-path /tmp/li-build
/tmp/li-build/debug/LaunchInspector --dump-json > /tmp/li-jobs.json
```

Then pick one of two modes.

#### Quick mode (non-interactive)

Fills `name` + `description` in one shot, no questions asked (edits auto-accepted):

```sh
claude -p --permission-mode acceptEdits "$(cat <<'PROMPT'
Fill the "name" and "description" fields of every item in
~/Library/Application Support/LaunchInspector/config.json.

Data source: /tmp/li-jobs.json — a JSON array whose "configKey" field on each entry
matches EXACTLY a key in the config.json "items" object (it provides the command,
the program, the schedule, and for personal jobs the project).

For each item:
- name        : a short, clear name, 2 to 4 words (not the raw technical label).
- description : one sentence in English explaining what the job is for.

Known third-party jobs → describe from the program/path. Personal jobs ("project"
or "symlinkTarget" field) → read the project files to be precise. Never make things up.

Only modify "name" and "description". Preserve everything else: "_help", "groups"
(and their "collapsed"), each item's existing "group"/"hidden", "ungroupedCollapsed",
"hiddenCollapsed". Don't invent keys. Finish by checking the JSON is still well-formed.
PROMPT
)"
```

#### Interactive mode — you choose what to fill (name / description / group)

Claude Code **first shows what it can do**, offers a **menu**, then applies **only what you chose**. Run it without `-p` (interactive — it asks its questions in the terminal):

```sh
claude "$(cat <<'PROMPT'
Help me customize the file
~/Library/Application Support/LaunchInspector/config.json from
/tmp/li-jobs.json (JSON array; each entry's "configKey" field matches EXACTLY a key
in "items" and provides command / program / schedule / project).

1. First, briefly tell me what you can do:
   - "name"        : a short, clear name (2-4 words) per item;
   - "description" : one sentence in English explaining what each job is for;
   - "group"       : split items into groups BY FUNCTION (e.g. Updates, Audio &
     capture, Displays, Network & security, System & battery…).

2. Then ASK me what I want, as a menu (wait for my answer before writing anything):
   (a) Everything: names + descriptions + groups
   (b) Names + descriptions only
   (c) (Re)group by function only
   (d) I'll define the groups / grouping axis myself

3. If I ask for groups, first propose the list of intended groups and their contents,
   and let me approve or adjust BEFORE writing.

4. Write ONLY the fields I chose; preserve everything else: "_help", "groups" and their
   "collapsed", and the "name"/"description"/"group"/"hidden" I didn't ask you to touch.
   Never invent a key (use only the provided "configKey"). Finish by checking the JSON
   is still well-formed.
PROMPT
)"
```

To avoid rewriting everything on a re-run, ask Claude to "only process items whose `name` is empty".

## Files on disk

The app only touches the system on **explicit action** (Enable/Disable/Delete, with confirmation) — never in the background, nothing in `/System`, no daemon installed. It writes these files:

| File | Purpose | Managed by |
|---|---|---|
| `~/Library/Application Support/LaunchInspector/config.json` | Your customizations: groups, names, descriptions, hides, collapsed states. | App + Claude Code |
| `~/Library/Application Support/LaunchInspector/trash/` | Trash: deleted `.plist` files + `trash.json` (restore manifest). | App |
| `~/Library/Preferences/LaunchInspector.plist` | macOS window state: position/size, sidebar column widths. | macOS (automatic) |

**Clean uninstall**: delete the `LaunchInspector` folder in `Application Support` and `LaunchInspector.plist` in `Preferences`.

## License

[MIT](LICENSE) © 2026 Vincent Battez
