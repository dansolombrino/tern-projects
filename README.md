# Projects & Agents (`projects`)

A Tern plugin (host and window halves, public plugin SDK) that ports the left sidebar of the Orca macOS
app (v1.4.253, new card style) and its workflow: **projects** in **project groups**, several **omp
agents per project** (each a workspace card), and **subagents per agent**.

- A project is a folder (usually a git repository's root). Each project gets its own Tern session,
  named exactly like the project.
- A new agent is an omp agent block opened as a tab in the project's session, named after its task.
  In a git project each agent works in a git worktree of its own.
- A subagent is a child omp agent started from a parent agent: it opens as a split beside the
  parent, in the parent's folder (and worktree). When the child's turn ends, its last message is
  sent to the parent (report-back, through the fleet mailbox).
- A **fleet mailbox** takes messages for agents from scripts (agent-fleet) over a Unix socket and
  delivers each into its agent's chat when the agent is idle (see *Fleet mailbox*).
- omp's own subagents (its task tool) are read from the parent's surface and shown nested under the
  agent, read-only.

## Install

```sh
tern plugin link ~/src/tern-projects    # use it where it is; saving a file reloads it
tern plugin list                        # projects … host, window  ready
```

`tern plugin unlink projects` removes it. For type-checking, `tern plugin types ~/src/tern-projects`
writes `tern.d.luau` (git-ignored) for luau-lsp.

## Sidebar

Orca's layout, top to bottom (`sidebar.luau`, `sidebar.css`):

- **Search** pill: the switcher over every agent (subagents indented) and project. Its keycaps show
  on hover.
- **Projects** header (*Workspaces* when not grouped by project): collapse or expand all (shown on
  hover; also Alt-click any header), the **Activity** bell with its count (agents needing input, else
  working), **Workspace options**, **Add project**, **New agent**.
- The list: *Fleets* (one section per agent fleet, see below), a *Pinned* section, then project
  groups with their projects, then ungrouped projects, then *Unassigned* for agents outside every
  project. Top-level headers stick while their section scrolls.
- Footer: **Settings**, **Help**, and **Reveal active workspace** (expands the groups above the
  focused agent's card and glows it).

### Project groups and projects

- A group header (tree glyph) nests its projects. Its `…` button and right-click: Rename group,
  Delete group (its projects become ungrouped, or are removed with it; files are never touched).
- A project header shows the project's icon (one of Orca's icon choices that Tern has, or an emoji)
  in one of Orca's eight colors (neutral by default). Hover actions: chevron, `…`, `+` (New agent).
  `…` and right-click: Project Settings (rename, color, worktrees, move up or down, copy path, open
  in Finder), Change Project Icon (icon, emoji, color, reset), New group from project, Move to
  group…, Remove from group, Open session, Remove Project.

### Workspace cards

One card per top-level agent, in Orca's new card style:

- Status lane: working spinner, needs-permission question mark, failed and interrupted dots, done
  check; a quiet agent shows a branch glyph (a green dot without a branch), a sleeping one a moon.
  An amber dot marks unread. The title is dimmed once read and bold while unread; a house marks the
  agent that works in the project root.
- The agent row: status, the omp glyph, the task, then the running tool or the last message, the
  model and the time since it finished (else started). Subagents sit collapsed behind `+N` and a
  chevron in the time slot; expanded, they are rows on a rail (only running ones of omp's own, two
  or more idle ones folded into *N idle*).
- Click focuses the agent (switching session when needed) and never takes focus from your terminal;
  double-click the card renames it. Right-click (the card or any row in it): Rename, Open in Finder,
  Copy Path, Copy Worktree Name, Pin/Unpin, Mark Unread/Read, New Child Agent…, Sleep, Delete (on the
  primary card: Remove Project).
- **Sleep** closes the agent and its subagents; while it owns a worktree its card stays, dimmed, and
  a click wakes it (a new agent on the same task in the same worktree).
- **Delete** asks first (the folder, its uncommitted changes; "don't ask again" is offered), stops
  every agent in the worktree, removes the worktree with `--force`, then deletes its branch with
  `git branch -d`. A branch git won't delete safely is kept, and you are offered to force it.

### Fleets

Agent fleets started with the agent-fleet skill's Tern adapter (`tern_fleet.py`) show above the
projects the way Orca shows them: one section per fleet, its groups as containers, their workers as
cards. Live: the host half re-reads the fleet state every 2 s and the sidebar redraws only the fleet
that changed.

- **Fleet row**: the fleet's name and a summary of its workers (`1 asks · 2 working · 1 done`). A
  click collapses it.
- **Coordinator card** (`L0 <fleet>`): its state (working, idle, needs you, gone), the session its
  tab is in now, and how many mailbox messages wait for it. A click focuses it.
- **Group row** (`G <group> · <fleet>`, or `l0-<group>` for a legacy group): a click shows the group's
  session, or opens it again in the container worktree when it was ended; `…` collapses it. Every tab
  of a group's session gets the group's color (one per group, stable), once per tab and only when the
  tab has none, so a color you set stays.
- **Worker card** (`L1 <group>/<item>`): a status dot and badge, *Working*, *Idle*, *Asks* (it asked
  the coordinator and waits for the answer), *Needs you* (its agent waits for input in its pane),
  *Done*, *Failed*, *Starting* or *Gone* (no pane in its worktree; dimmed); its branch; mail still
  queued for it; and its last report (`ask: …`, `done: …`, `failed: …`) with its age. A report that
  came after the coordinator was last focused is unread (amber dot, bold title) until you focus the
  coordinator. A click focuses the worker (a gone one shows its group's session).
- A fleet's coordinator and workers show only here, not again as project or *Unassigned* cards.
- A group closed out (`close-out --confirm` archives it to `.closed/`) leaves the sidebar on the
  next scan; a closed item (status `removed`) and a coordinator chat with no group left are hidden.

Where it reads: the adapter's state root, `$AGENT_FLEET_STATE_DIR`, else `$XDG_STATE_HOME/agent-fleet`,
else `~/.local/state/agent-fleet`, as Tern's daemon sees its environment; under it `.tern/<repo id>/`
holds the coordinator chats (`chats/<key>/state.json`) and legacy `l0-<group>` groups
(`<group>/state.json`). The plugin only reads them: a state file the script is replacing (missing
beside its `.state.json.<pid>.tmp`, or half written) keeps the last good read, and a corrupt one with
no earlier read is skipped. The model goes to `<data>/fleet.json` (`fleet.luau`, `fleets.luau`).

### Pull requests and issues

Orca's PR and issue views, read with the GitHub CLI (`gh`, logged in: `gh auth login`). Only repositories with a
github.com remote take part (`origin`, else the first github.com remote); a folder with no remote, or another host,
shows nothing and costs no `gh` call.

- **PR badge** on every card whose branch has a pull request: project worktree cards, fleet worker cards and fleet
  group rows. It shows the number and state (`#12 open`, `draft`, `merged`, `closed`, in GitHub's colors), a CI dot
  (green pass, red fail, amber running; none without checks), the review mark (✓ approved, ✗ changes requested,
  • review required) and `!` on conflicts; the tooltip spells it out. A click opens the PR in the system browser.
  The PR of a branch is its open PR, else the newest merged one, else the newest closed one; a PR from a fork is
  never matched to a local branch of the same name.
- **PRs & issues** under each GitHub project (collapsed by default; a click on its row expands it): the open PRs you
  authored or are asked to review (`review asked`), then the open issues assigned to you, 8 of each with a
  "N more on GitHub" row. Its row shows both counts and the data's age, `↻` refreshes now and `↗` opens the
  repository's pull requests in the browser. The project header shows the counts too (`2 PRs · 1 issue`).
- **Stale data.** When a refresh fails (offline, `gh` missing or logged out, an API error) the last good data stays,
  dimmed and dashed, with `stale · 12m` on the row and `· stale` in the header; the row's tooltip names the error.
  Data older than 15 min is stale too. The last good data is kept in `<data>/gh.json` and survives reloads.
- **Create pull request for focused worktree** (palette): asks first, then pushes the focused agent's branch to
  `origin` (`git push --set-upstream`) and runs `gh pr create --fill --head <branch>`; a toast gives the new PR's URL
  or gh's error. It refuses a branch that already has an open PR, or a folder outside GitHub.
- PRs and issues open in the system browser, never in a Tern browser pane (which would open in whatever session
  is current), and only `https://github.com/…` links open.

**Rate-limit policy.** `gh` runs only in the host half, as `tern.process.spawn` children, one at a time plugin-wide.
Each repository is refreshed at most every 60 s while the sidebar shows and every 5 min while it is hidden: one
`gh pr list --state open --limit 50` (with checks and reviews), one `gh issue list --assignee @me --limit 30`, and at
most 4 `gh pr list --head <branch> --state all` lookups for shown branches with no open PR, each branch at most every
5 min. A branch a card has just started to show is looked up within a few seconds instead (once, 4 per round, only
while the repository's last refresh succeeded). So a project costs about 2 calls a minute (120 an hour) in steady
state, well inside GitHub's 5000 GraphQL points an hour (measured: 3 repositories, 24 calls in 4 min). A failure
backs that repository off, doubling from the interval up to 30 min, and at least 15 min
after a rate-limit error; the refresh button asks for a refresh no sooner than 15 s after the last try and resets the
backoff to one step. Each folder's remote is read with `git remote -v` (local, no network) at most every 10 min.
No conditional requests (ETags): `gh pr list` and `gh issue list` go through GraphQL, which has none. status.json
reports `gh_calls` (this host run), `gh_calls_hour` (the last hour) and `gh_last_ms` (the last process's run time).

Settings, in kv key `projects.gh.v1` (no UI): `{"path": "/opt/homebrew/bin/gh"}` names the gh executable (default
`gh` on the daemon's `PATH`), `{"off": true}` stops all GitHub calls. `gh` keeps its own token; the plugin never reads,
stores or logs one (error lines are cut to their first line with anything token-shaped masked).

### Automations

Orca's automations (`orca automations …`, the desktop Automations page): an agent prompt that runs on a schedule in
a project or folder, with run history, enable/disable and Run now. The **Automations** section sits below the projects.

- **Header**: the count (`2 · 1 running`), `…` opens `automations.json`, `+` adds one; a click collapses it.
- **Row** per automation: its name, `next in 4m` (or `next 14:30`, `next Tue 09:00`, `paused`) and the schedule; then
  the active run (`Queued`, `Precheck`, `Starting`, `Running`) or the latest finished one (`Done: <first line of the
  answer>`, `Failed: …`, `Timed out`, `Missed ×12`, `Skipped (busy)`, `Skipped (precheck)`, `Canceled`, `Lost`) with
  its age. Hover: `▶` Run now, `⏸`/`⏵` pause or enable, `↗` open the latest output. A click lists its runs (open one,
  stop a running one); right-click: Run now, Pause/Enable, Open latest output, Runs…, Edit automations.json.
- Problems in the file show as amber lines at the top of the section (the entry is left out, the rest run).
- Palette: **New automation** (name, schedule, prompt, where, how), **Edit automations (automations.json)**,
  **Automation runs**, **Run automation now**.

**Definitions** are a JSON file you edit, `<data>/automations.json` (`<data>` is the plugin's data dir, see *Fleet
mailbox*); the palette's New automation and the pause switch write it too (pretty-printed, keys in a fixed order,
unknown keys kept). A file that is not valid JSON keeps the last good definitions and says so in the section.

```json
{
  "version": 1,
  "max_concurrent": 2,
  "automations": [
    {
      "id": "nightly-review",
      "name": "Nightly review",
      "enabled": true,
      "schedule": "weekdays 18:00",
      "run_in": "headless",
      "project": "app",
      "prompt": "Review today's commits on main and list anything risky.",
      "model": "sonnet",
      "missed": "run_once",
      "grace_minutes": 120,
      "timeout_minutes": 30,
      "precheck": "git log --since=today --oneline | grep -q ."
    }
  ]
}
```

| Key | Meaning |
|---|---|
| `id` | Stable id (letters, digits, `-`, `_`); default: a slug of `name`. Runs are `<id>-<n>`. |
| `name` | Required. |
| `enabled` | Default `true`. A paused automation keeps its history; enabling it schedules from now on (nothing for the paused time). |
| `schedule` | `every 2m`, `every 90m`, `every 2h` (absolute: counted from the Unix epoch, so `every 2m` is every even minute); `hourly`, `hourly :15`; `daily 09:00`; `weekdays 09:00`; `weekly mon 09:00` (or `0`-`6`, Sunday `0`); or 5-field cron (`0 9 * * 1-5`: lists, ranges, steps, month and day names, `7` = Sunday; with both day fields restricted either matches, as in Vixie cron). A schedule that never comes (`0 0 31 2 *`) is refused. |
| `project` or `cwd` | Where it runs: a project (id or name; its root) or an absolute folder (`~` allowed). |
| `run_in` | `headless` (default): `omp -p` as a process, output saved. `pane`: an agent tab, see below. |
| `prompt` | Required: the first (and only) prompt. |
| `model` | Optional `--model` (`omp --model <m>` for a pane run). |
| `args` | Optional extra `omp` arguments for headless runs, e.g. `["--thinking", "low"]`. |
| `missed` | `run_once` (default): occurrences missed while Tern was not running (or the Mac slept) run once at the next start, as a `catchup` run. `skip`: they are recorded as one `Missed ×N` row. |
| `grace_minutes` | With `run_once`: catch up only when the latest missed occurrence is at most this old (Orca's missed-run grace); default: any age. |
| `timeout_minutes` | Default 30. Headless: `omp --max-time`, killed 2 min after that. Pane: the run is marked `Timed out` and the agent keeps its pane. |
| `precheck` | Optional shell command run in the folder before a *scheduled* run (not Run now, as in Orca); exit 0 runs, anything else is `Skipped (precheck)`. `precheck_timeout` (s, default 60). |
| `max_concurrent` | Top level: runs at once across all automations (default 2, at most 8). |

**Scheduling** (`sched.luau`, `automate.luau`, `autohost.luau`). The host half owns the schedules: its 2 s clock runs
in Tern's daemon with no window open. Wall-clock schedules follow the daemon's local zone. Daylight saving: a time
the spring-forward gap skips does not occur that day (`daily 02:30` skips it); a time the fall-back hour repeats
runs once, at the first instant. An occurrence is on time up to 90 s late; later it was missed and `missed` decides.
Only the latest missed occurrence ever runs, whatever the count. One run at a time per automation (Orca's lane): an
occurrence due while the previous run is active is `Skipped (busy)` (consecutive skips fold into one row, `×N`).
Runs over the `max_concurrent` cap wait `Queued` (precheck, starting and running runs hold a slot).

**Headless runs** run `omp -p --max-time <s> [--model m] [args] <prompt>` in the folder, through a small `sh` wrapper
(stdin closed) started with `tern.process.run`: the answer goes to `<data>/autoruns/<run>.md` (after a header naming
the run), stderr to `<run>.err`, the agent's pid to `<run>.pid` and its exit code to `<run>.status`. The status file
ends the run, so a run outliving a plugin reload or a daemon upgrade still ends right; one whose process is gone
with no status file (a daemon restart) is `Lost`. Exit 0 is `Done` with the answer's first line as its summary;
anything else `Failed` with the error's last line (exit 3: the cost limit).

**Pane runs** need a window (`cx.agents` exists only there). The host marks the run `Starting` and wakes the windows;
the window that delivers mail (the mailbox's leader) starts the agent with `cx.agents:start` in the project's session
(a folder's go to an **Automations** session), as a tab named `⏱ <name> #<n>`, without taking your view: it starts in
the current session, moves to its own (`move_to_new_tab`, no focus) and gives focus back. A session made for it
loses its first shell. The run ends when the agent's turn ends (`agent_finished`, or the leader seeing it idle
after it worked), with its last answer as the summary. With no window within 20 s the run goes headless instead
(`no Tern window: ran headless`). An automation keeps the pane of its latest run; older finished ones close when the
next starts (Orca's terminal retention), unless focused or working.

**History**: the last 50 finished runs per automation (Orca keeps 100; each kv write rewrites the whole history),
active ones always; removing an automation from the file cancels its queued runs and drops its history and output
files. State is in kv `automations.v1`, written by the host half only; windows send requests through
`<data>/spool/` (`auto_run`, `auto_enable`, `auto_create`, `auto_started`, `auto_finished`, `auto_stop`, …) and read
`<data>/autos.json` when `auto_sig` changes (status.json, and the tiny `<data>/autos.sig` they check on each mailbox
watcher line). status.json also reports `auto_ms`/`auto_ms_max`, the scheduler tick's last and longest time.

What maps to Orca, and what doesn't:

| Orca | Here |
|---|---|
| `automations create/edit/remove`, desktop editor | `automations.json` (edit it, or New automation); remove = delete the entry |
| `automations list/show`, the Automations page | the sidebar section and its runs picker |
| `automations run` (Run now, bypasses the precheck) | `▶`, Run automation now (bypasses the precheck too) |
| `--enabled/--disabled` | `enabled`, the `⏸`/`⏵` switch |
| `--trigger` presets, 5-field cron | the same presets and cron, plus `every N m/h` |
| `--trigger` RRULE | not supported (cron covers the presets) |
| `--timezone <IANA>` | not supported: the daemon's local zone (Luau has no zone database) |
| `--missed-run-grace-minutes`, `run_once_within_grace` | `grace_minutes` with `missed: run_once`; plus `missed: skip` |
| `--precheck`, `--precheck-timeout`, `skipped_precheck` | `precheck`, `precheck_timeout`, `Skipped (precheck)` |
| `--provider <agent>`, `--extra-agent-args` | omp only; `model`, `args` |
| `--workspace` (existing worktree) | `project` (its root) or `cwd` |
| `--repo` / `--workspace-mode new-per-run` (a worktree per run), `--setup`, `--base-branch` | not supported: runs share the folder (worktrees per run would pile up with every-few-minutes schedules) |
| `--reuse-session` | not supported: every run is a fresh agent; the latest run's pane is kept |
| run history (100 per automation), statuses | 50 per automation; Done, Failed, Timed out, Missed, Skipped (busy, precheck), Canceled, Lost |
| one dispatch lane per automation | one active run per automation (`Skipped (busy)`) |
| bot automations, event triggers (`--on slack.mentioned`, `github.ci_failed`, …), `--once` waits, results to Slack/Linear | not supported: no connectors in Tern |
| remote hosts (`--host`, SSH, paired servers) | this machine only |
| usage (tokens) per run | not shown (the pane shows omp's own; headless output has the answer only) |
| (Orca needs its window open: #7270) | the host half schedules with no window; a pane run goes headless when no window is open |

### Activity view

The bell swaps the list for every agent, grouped by status (Needs you, Working, Done, Idle), each
with its project. The bell again returns to the projects.

### Workspace options

A picker that reopens after each choice: Group by (Project, None), Sort by (Name, Agent Activity,
Recent, Manual), Project order (Manual, Recent), Card display (Branch name, Agent statuses, Agent
model), Filters (Hide sleeping). The sliders button counts the active filters.

## Commands and keys

All commands are in the palette's **Projects** group, as actions `plugin.projects.<id>`. On Linux and
Windows the chords use `Ctrl` instead of `⌘`.

| Command | Action | Keys | Orca's keys |
| --- | --- | --- | --- |
| Toggle sidebar | `toggle_sidebar` | `⌥⌘B` (also `⌃⌘E` and the title-bar button) | `⌘B` |
| Search agents and projects | `search` | `⌘⌥⇧K` | `⌘J` |
| New agent in project | `new_agent` | `⌘⌥⇧A` | `⌘N` |
| Previous / next agent | `prev_agent`, `next_agent` | `⌘⌥⇧,`, `⌘⌥⇧.` (Tern's presets own `⌘⌥⇧↑`/`↓`) | `⇧⌘↑`, `⇧⌘↓` |
| Rename focused agent | `rename` | `⌘⌥⇧R` | `⌥⌘R` |
| Delete focused agent's workspace | `delete` | `⌘⌥⇧⌫` | `⇧⌘⌫` |
| Collapse or expand all projects | `collapse_all` | `⌘⌥⇧P` | `⌥⌘P` |
| New subagent of focused agent | `new_subagent` | `⌘⌥⇧U` | |
| Jump to next agent waiting for input | `next_waiting` | `⌘⌥⇧J` | |
| Open project | `open` | `⌘⌥⇧L` | |
| Add project | `add` | | |
| Remove project (keeps files) | `remove` | | |
| Reveal active workspace | `reveal` | | |
| Delete a sleeping workspace | `cleanup` | | |
| Create pull request for focused worktree | `create_pr` | | |
| New automation | `new_automation` | | |
| Edit automations (automations.json) | `edit_automations` | | |
| Automation runs | `automation_runs` | | |
| Run automation now | `run_automation` | | |
| Workspace options | `options` | | |
| Sidebar settings | `settings` | | |
| Use Orca shortcuts | `use_orca_keys` | | |
| Release Orca shortcuts (back to Tern's) | `release_orca_keys` | | |

**Use Orca shortcuts** binds the *Orca's keys* column in your keybinds, all together; Tern's presets
use most of those chords, so it is opt-in, and **Release** removes only these binds. Previous and
next walk the cards as the list shows them, wrapping, skipping collapsed sections.

The status line always has a Projects segment: `<project> · N working · M waiting` for a focused
pane inside a project, else `Projects` (with the waiting count across all projects when any agent
needs input). A click toggles the sidebar. A toast tells you when an agent you are not looking at
needs input, finishes or fails (not for subagents that report back to their parent).

### The title-bar button (Files takeover)

Orca keeps its sidebar toggle at the leading edge of the title bar. Tern has no plugin slot there, so
the plugin takes over Tern's **Files** button: `chrome.css` moves it to the leading edge (before the
session pill), draws Orca's PanelLeft glyph (32×24, radius 4, muted until hovered) and retitles its
tooltip "Toggle sidebar", and `tern.override("files", …)` makes it, and `⌃⌘E`, toggle the sidebar.
Files stays reachable: `⇧⌘E` (Focus Files) still opens it, and *Show/hide Files* in the sidebar
settings runs Tern's own Files action. Uninstalling the plugin gives the button back.

### Placement and width

Hiding parks the sidebar's pane (kept out of the park pile by `chrome.css`); showing unparks it and
docks it left of the tab's leftmost pane. It follows you to other tabs and sessions while shown. Its
width is Orca's 280 px by default, or the width you last dragged it to (220 to 500 px), and is kept
through splits opening and closing beside it.

There is one sidebar canvas, ever: only the toggle opens one. A plugin load, reload or window relaunch
takes up the sidebar that exists (shown again when it was shown) and opens none; any extra sidebar
canvas it finds (left by an older version or another run) is closed, then and every 30 s while shown.

It refreshes on agent, pane, focus and session events and on a 2 s tick while shown, within Tern's
window budget (50 ms per callback, see *Budget*): each tick re-reads the agents and the host half's
status, and draws only when something it shows changed (or every 20 s, for the "5m" labels), sending
only the changed sections.

## Budget

Tern pauses every timer of a plugin for 5 s (doubling up to 5 min) when one window callback runs over
50 ms of Lua or 500 ms with native calls (`tern: timer exceeded 50 ms` in `~/Library/Logs/Tern/tern.log`).
The plugin keeps under it the way Overseer's `budget.luau` does (`budget.luau` here):

- The window entry's load is a hook too (500 ms of wall time, `require`'s compile included). Compiling every
  module in the load took 57-62 ms in a freshly started window with four cores busy, but 240-310 ms in a window
  that had been running for 40 minutes with many plugin reloads (Tern 0.9.29) and 350-470 ms there under load,
  sometimes over 500 (`plugin window entry failed to load … load exceeded 500 ms`, the whole window half gone
  for the run). So the load requires only `base.luau` and `budget.luau` and registers commands, hooks and the
  status segment (1-2 ms fresh, 2-14 ms in
  the slow window under load); every other module compiles in a timer callback of its own (`STAGES` in
  window.luau, dependencies first so each compiles one file; the largest, sidebar.luau, 10 ms fresh and 35-125 ms
  in the slow window), then one callback runs the installers, one `init`, and one the hooks that arrived before
  `init` (queued, in order; until then the status segment is the plain sidebar toggle). All the stages' timers
  start at load, so they run within a turn or two (`init` about 75 ms after the load fresh, 0.4-0.7 s in the
  slow window); a stage is logged as slow past 250 ms. `python3 tests/test_window_load.py` checks the load
  compiles nothing else and each stage one module.
- Work runs in labelled timer callbacks; event, click and command hooks only queue it. Each callback
  does one heavy thing: the sidebar's placement check, the agent scan (`cx.agents:list()`), one surface
  or transcript read, one draw, one mailbox delivery. A callback over 25 ms is logged with its label;
  a pause names the label of the callback that ran last.
- Git never runs on a window's UI thread in a hot path: branches are read by the host half, which
  writes them to `<data>/status.json` with every pane's omp session file; worktree commands run as
  `tern.process.spawn` children.
- The sidebar's width is re-measured (three `resize` probes) at most every 10 s, not every tick.
- Reads are capped: 600 surface nodes per agent, every 6 s while it works and every 30 s while idle;
  6 transcript messages per prompt read; the keymap is read at most every 30 s.
- Fleet state files are read and parsed by the host half (2 s budget, on its 2 s clock; an unchanged
  file's text skips the parse), never by a window: a window re-reads the small `<data>/fleet.json`
  only when `fleet_sig` in status.json changed. status.json also carries `fleet_ms` and
  `fleet_ms_max`, the host's last and longest fleet scan (a scan over 200 ms is logged).
- GitHub output is parsed by the host half (gh.luau, on its 5 s clock); a window re-reads the compact `<data>/gh.json`
  only when `gh_sig` in status.json changed, in a timer callback of its own (logged when over 25 ms), and a change
  redraws only the sections it touches (a project's section, a fleet).
- Automations are scheduled by the host half (2 s clock; a tick re-reads `automations.json` only when its text
  changed, and takes well under 1 ms with a few automations: `auto_ms` in status.json). A window reads the small
  `autos.sig` on each mailbox watcher line (about every 3 s) and `autos.json` only when it changed, in a callback of
  its own; the leader starts at most one pane run per callback, and checks running pane runs (one
  `cx.agents:list()`) only while some run. The section is one list part, so a change redraws only it.

## Fleet mailbox

Scripts (the agent-fleet skill) send messages to agents through the plugin: durable, delivered with
`cx.agents:ask` (one atomic omp send) only while the agent is idle or waiting for input, never
mid-turn (tern-sdk#320).

**Where.** When its helper is up, the plugin writes `mailbox.json` into its data dir,
`<config>/plugin-data/projects/`, where `<config>` is `$TERN_CONFIG_DIR`, else on macOS
`~/Library/Application Support/Tern` (Linux: `~/.config/tern`, unverified):

```json
{"version": 1, "socket": "/Users/me/Library/Application Support/Tern/plugin-data/projects/mailbox.sock", "pid": 4242, "started_at": "2026-11-19T16:20:00+00:00"}
```

The socket is `mailbox.sock` in that dir, or `$TMPDIR/tern-projects-<uid>/mailbox.sock` when that
path is over 100 bytes (Unix socket paths are short). The file is replaced when the helper restarts
and removed when it stops (a killed helper leaves it: check that `pid` lives).

**Protocol v1.** A Unix stream socket (mode 0600); one JSON object per line, one request per
connection, the reply, then close.

| Request | Reply |
|---|---|
| `{"op":"ping"}` | `{"ok":true,"version":1}` |
| `{"op":"deliver","id":"<idempotency key>","target":{"pane":<id or null>,"cwd":"<abs path or null>","session_file":"<omp session file or null>"},"text":"<message>","from":"<label>"}` | `{"ok":true,"id":"…","state":"queued"\|"delivered"}` |
| `{"op":"status","id":"…"}` | `{"ok":true,"id":"…","state":"queued"\|"delivered"\|"failed"\|"unknown","error":null\|"…"}` |

Errors are `{"ok":false,"error":"<code>","message":"…"}`: `bad-request` (malformed request, text over
64 KiB, id over 200 bytes), `no-target` (no live agent matches the target now; the message is not
stored), `busy` (500 queued messages, or 50 for one target; or the host half did not answer within
8 s: retry).

**Semantics.**

- `queued` means the message is in `kv.json` (key `mailbox.v1`): it survives plugin reloads and Tern
  restarts. The same `id` again is the same message (its current state comes back), never a second
  delivery. Delivered and failed messages are kept for `status` (and that rule) for 7 days, at most
  5000 of them; a message still queued after 7 days fails as `expired`.
- The target is resolved when the message goes out: the live agent in `pane`, else the agent whose
  omp session file is `session_file` (a restart gives panes new ids; `omp --restore` reopens the same
  file), else the one agent whose folder is `cwd`. Messages to one agent go out in order, one per turn
  of the agent: the next waits until its turn ended.
- `text` is sent exactly as given; `from` is a label for logs.
- An ask Tern refuses is retried every 10 s and fails after 5 tries (`status` gives Tern's error).

**How.** The host half (`host.luau`, in Tern's daemon) owns the queue (the only writer of
`mailbox.v1`) and starts the helper `mailbox.py serve` with `tern.process.spawn`: Python 3 standard
library, no dependencies. The helper relays each request to the host as a stdout line and the reply
back. Every window half starts `mailbox.py watch`, which keeps a connection to the helper and prints
a line on new mail and every 3 s: each line wakes the window, whose timers Tern stalls while nothing
redraws it (tern-sdk#235). The first window watching delivers; it reports each delivery to the host
through a file in `<data>/spool/`, written in the same callback as the ask, so a reload never sends a
message twice. Subagent report-backs go into the same queue the same way.

**Limits.**

- Delivery needs an open Tern window (`cx.agents` exists only in a window). With none, messages wait
  queued, and `deliver` still answers.
- Only omp agents Tern knows as agents (`cx.agents`), in this Tern, are targets.
- Delivery is into the agent's chat as a prompt; nothing shows a message before then.

## Adding projects, agents and worktrees

- **Add project** offers Orca's three ways: Browse folder (the system folder dialog on macOS),
  Clone from URL, Create new project. A folder outside any repository is added after an "Open as
  Folder" confirmation, a subfolder of a repository directly; either way as a plain folder (its
  agents share it, no worktrees). The project's session opens once added.
- **New agent** asks for the task, which becomes the agent's first prompt and its name.
- Worktrees live beside the root: `<root>/../.tern-worktrees/<project id>/<name>` (`-2`, `-3`, … when
  taken). The branch is `<prefix>/<name>`, the prefix being `git config github.user`, else
  `user.username`, else none. It starts from the remote's default branch (`origin/HEAD`, then
  `origin/main`, `origin/master`, `main`, `master`, else `HEAD`) without tracking it.

## Data model

Stored with `tern.kv` (the plugin's `kv.json`, shared by every window) under `projects.v1`:

```
{
  projects = { { id, name, root, color, icon?, worktrees, created, group? } },
  groups = { { id, name, created } },
  agents = { ["<key>"] = { project, title, task, worktree?, branch?, parent?, report_back?, started, closed?, closed_at?, pane?, session_file?, cwd?, lost_at? } }
}
```

- `id` is a slug of the first name; `name` is the session name; `color` is one of `neutral`, `red`,
  `orange`, `yellow`, `green`, `teal`, `purple`, `pink`; `icon` is `{ kind = "icon", name }` or
  `{ kind = "emoji", emoji }`.
- Agents are keyed by an opaque record key, not by pane id (pane ids change across Tern restarts).
  A record carries its last pane, its omp session file and its folder; after every agent scan
  `identity.luau` binds each record to a live pane: its last pane while live, else the pane running
  its omp session file, else (a worktree owner) the one agent in its worktree, else the one agent in
  its folder. `parent` is the parent's record key. 0.2's pane-keyed records migrate on load.
- An agent started by hand (no record) still belongs to the project whose root, or worktree folder,
  holds its folder (the longest root wins).
- A closed agent's record stays (`closed = true`) while it owns a worktree: that is its sleeping
  card. Other records go when their block closes, or an hour after their pane vanished without a
  close (a restart that did not bring it back).

The fleet mailbox is under `mailbox.v1` (written by the host half only). GitHub settings are under
`projects.gh.v1` (see *Pull requests and issues*); the GitHub data itself is in `<data>/gh.json`, not kv. Automation
state (each automation's next run and run counter, the run history) is under `automations.v1` (written by the host
half only); the definitions are `<data>/automations.json` and headless output is in `<data>/autoruns/` (see
*Automations*).

The sidebar's state is under `projects.ui.v1`: whether it shows, its width, the collapsed sections,
the list shown (projects or Activity), the workspace options, the pinned and unread cards, whether
Delete asks, when each fleet's coordinator was last focused (`fleet_seen`, for unread reports), and
which projects' "PRs & issues" are expanded (`prs_open`). The Automations section's collapsed state is
`collapsed.automations`.

Files: `plugin.toml` (manifest; `styles` loads the two sheets), `host.luau` (the host half: mailbox
queue and helper, pane sessions and branches, the fleet scan, GitHub polling), `mailbox.py` (the socket helper), `window.luau`
(commands, hooks, chrome and staged loading), `base.luau` (the constants the load needs), `events.luau` (what the
hooks, clicks and status segment do, and `init`), `core.luau` (the shared state, the agent scan, lookups),
`budget.luau` (labelled, timed callbacks), `identity.luau` (records ↔ panes), `mailq.luau` (the
mailbox queue), `mail.luau` (mailbox delivery and report-back in a window), `placement.luau` (the
sidebar's docking, width and refresh), `snapshot.luau` (what the sidebar draws), `agents.luau`
(starting agents, worktrees, report-back, sleep, wake, delete), `projects.luau` (project and group
flows), `pickers.luau` (search, options, settings, help, Orca shortcuts), `model.luau` (data,
ordering and persistence), `subagents.luau` (omp surface → subagents), `fleet.luau` (agent-fleet
state → the fleet model, pure), `fleets.luau` (fleets in a window: states, clicks, unread, tab colors),
`gh.luau` (GitHub remotes, gh JSON, CI rollup, branch → PR, the refresh clock; pure), `ghpoll.luau` (gh polling in
the host half), `prs.luau` (PRs and issues in a window: badges, lists, open, refresh, create), `sched.luau`
(schedules and their occurrences; pure), `automate.luau` (automation definitions, the scheduler tick, history; pure),
`autohost.luau` (automations in the host half: the clock, runs, files), `autowin.luau` (automations in a window: the
section, pane runs, actions),
`sidebar.luau` (snapshot → canvas nodes), `sidebar.css` (the sidebar), `chrome.css` (its pane chrome
and the title-bar toggle), `tests/` (pure tests: `luau tests/<file>.luau`; `python3 tests/test_mailbox.py`;
`python3 tests/test_window_load.py`).

`window.luau` stays small on purpose: Luau allows 200 locals in a file's top level, which one file
holding everything exceeded (`luau-compile -O0 --binary <file>` checks a file loads).

## Limits

What Orca's sidebar does and this port can't, for lack of a Tern plugin API:

- Dragging: reordering projects and cards, drop indicators, dropping a folder to add a project.
  Projects move with *Move up* / *Move down* in Project Settings.
- Renaming in place: canvases take no text input, so renaming is a prompt.
- Scrolling the list to a card (Reveal only expands and glows), the jump-to-top button, keyboard
  navigation inside the list, a delete shortcut for the hovered card (the command acts on the
  focused agent).
- Menus: no submenus, headings, disabled items or shortcuts in them, and a left click can't open
  one, so the `…` buttons open pickers and "Move to group" and the options are pickers too (a picker
  reopens with its first row selected). Tern appends its own *Copy* item to every right-click menu.
- Tooltip styling and delay, a live minimum and maximum while dragging the divider, the sidebar's
  tint behind the title bar, toast buttons, selecting several cards, image project icons, colors
  other than Orca's eight presets.
- Orca's nav rows (Tasks, Agent Dashboard, Orca Mobile; Automations is the section above), workspace board, hosts,
  issue trackers other than GitHub's and setup scripts have no counterpart here.

And the port's own:

- Records re-attach after a restart by omp session file or worktree; an agent with neither whose
  folder holds several agents stays unattached (it still shows, attributed by folder).
- Report-back fires on every turn end of a spawned subagent (`done` or `failed`) that produced a new
  answer (omp's stats footer stripped), while the parent agent has a live pane or a known session
  file. It goes through the fleet mailbox: durable, delivered at the parent's next idle.
- An agent's finished, failed or interrupted state is kept in memory: a plugin reload forgets it.
- omp-internal subagents are read from at most 600 surface nodes per agent; a longer transcript
  can hide older ones. They are read only while the sidebar shows.
- Paths are local: projects on remote hosts aren't supported (git and file checks run on this
  machine).
- The sidebar is a pane of the tab's split tree: it docks left of the tab's leftmost (top-left)
  pane, so in a tab split top/bottom it is as tall as that pane, not the window.
- The title-bar button and `⌃⌘E` toggle the sidebar instead of Files while the plugin is installed.
- `chrome.css` hides the parked sidebar's card by its label (`Projects · …`), so a parked pane of
  your own titled "Projects" is hidden from the park pile too.
- The sidebar follows you into a fleet group's session; a close-out that ends that session while
  the sidebar shows there ends the sidebar with it (Tern gives no event before a session ends), and
  the toggle opens it again.
