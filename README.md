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

The fleet mailbox is under `mailbox.v1` (written by the host half only).

The sidebar's state is under `projects.ui.v1`: whether it shows, its width, the collapsed sections,
the list shown (projects or Activity), the workspace options, the pinned and unread cards, whether
Delete asks, and when each fleet's coordinator was last focused (`fleet_seen`, for unread reports).

Files: `plugin.toml` (manifest; `styles` loads the two sheets), `host.luau` (the host half: mailbox
queue and helper, pane sessions and branches, the fleet scan), `mailbox.py` (the socket helper), `window.luau`
(commands, events, chrome and wiring), `core.luau` (the shared state, the agent scan, lookups),
`budget.luau` (labelled, timed callbacks), `identity.luau` (records ↔ panes), `mailq.luau` (the
mailbox queue), `mail.luau` (mailbox delivery and report-back in a window), `placement.luau` (the
sidebar's docking, width and refresh), `snapshot.luau` (what the sidebar draws), `agents.luau`
(starting agents, worktrees, report-back, sleep, wake, delete), `projects.luau` (project and group
flows), `pickers.luau` (search, options, settings, help, Orca shortcuts), `model.luau` (data,
ordering and persistence), `subagents.luau` (omp surface → subagents), `fleet.luau` (agent-fleet
state → the fleet model, pure), `fleets.luau` (fleets in a window: states, clicks, unread, tab colors),
`sidebar.luau` (snapshot → canvas nodes), `sidebar.css` (the sidebar), `chrome.css` (its pane chrome
and the title-bar toggle), `tests/` (pure tests: `luau tests/<file>.luau`; `python3 tests/test_mailbox.py`).

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
- Orca's nav rows (Tasks, Automations, Agent Dashboard, Orca Mobile), workspace board, hosts, pull
  requests, issue trackers and setup scripts have no counterpart here.

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
