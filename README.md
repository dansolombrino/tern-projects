# Projects & Agents (`projects`)

A Tern plugin (window half only, public plugin SDK) that ports the left sidebar of the Orca macOS
app (v1.4.253, new card style) and its workflow: **projects** in **project groups**, several **omp
agents per project** (each a workspace card), and **subagents per agent**.

- A project is a folder (usually a git repository's root). Each project gets its own Tern session,
  named exactly like the project.
- A new agent is an omp agent block opened as a tab in the project's session, named after its task.
  In a git project each agent works in a git worktree of its own.
- A subagent is a child omp agent started from a parent agent: it opens as a split beside the
  parent, in the parent's folder (and worktree). When the child's turn ends, its last message is
  sent to the parent (report-back).
- omp's own subagents (its task tool) are read from the parent's surface and shown nested under the
  agent, read-only.

## Install

```sh
tern plugin link ~/src/tern-projects    # use it where it is; saving a file reloads it
tern plugin list                        # projects … window  ready
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
- The list: a *Pinned* section, then project groups with their projects, then ungrouped projects,
  then *Unassigned* for agents outside every project. Top-level headers stick while their section
  scrolls.
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
docks it left of the tab's leftmost pane. It follows you to other tabs and sessions while shown, and
reopens with the window when it was shown. Its width is Orca's 280 px by default, or the width you
last dragged it to (220 to 500 px), and is kept through splits opening and closing beside it.

It redraws on agent, pane, focus and session events and every 2 s while shown.

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
  agents = { ["<pane>"] = { project, title, task, worktree?, branch?, parent?, report_back?, started, closed?, closed_at? } }
}
```

- `id` is a slug of the first name; `name` is the session name; `color` is one of `neutral`, `red`,
  `orange`, `yellow`, `green`, `teal`, `purple`, `pink`; `icon` is `{ kind = "icon", name }` or
  `{ kind = "emoji", emoji }`.
- Agents are keyed by pane id. An agent started by hand (no record) still belongs to the project
  whose root, or worktree folder, holds its folder (the longest root wins).
- A closed agent's record stays (`closed = true`) while it owns a worktree: that is its sleeping
  card. Other records go when their block closes.

The sidebar's state is under `projects.ui.v1`: whether it shows, its width, the collapsed sections,
the list shown (projects or Activity), the workspace options, the pinned and unread cards and whether
Delete asks.

Files: `plugin.toml` (manifest; `styles` loads the two sheets), `window.luau` (commands, events,
chrome and wiring), `core.luau` (the shared state, the agent scan, lookups), `placement.luau` (the
sidebar's docking, width and refresh), `snapshot.luau` (what the sidebar draws), `agents.luau`
(starting agents, worktrees, report-back, sleep, wake, delete), `projects.luau` (project and group
flows), `pickers.luau` (search, options, settings, help, Orca shortcuts), `model.luau` (data,
ordering and persistence), `subagents.luau` (omp surface → subagents), `sidebar.luau` (snapshot →
canvas nodes), `sidebar.css` (the sidebar), `chrome.css` (its pane chrome and the title-bar
toggle), `tests/` (pure tests: `luau tests/<file>.luau`).

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

- Pane ids key the records: agents restored by a Tern restart that changes pane ids lose their
  title, worktree and parent links (they still show, attributed by folder).
- Report-back fires on every turn end of a spawned subagent (`done` or `failed`) that produced a new
  answer (omp's stats footer stripped), while the parent agent is alive. Reports to a working parent
  wait for its next idle; one Tern refuses is retried at the parent's next state change (a toast says
  so). The in-memory queue is lost on a plugin reload.
- An agent's finished, failed or interrupted state is kept in memory: a plugin reload forgets it.
- omp-internal subagents are read from at most 2000 surface nodes per agent; a longer transcript
  can hide older ones. They are read only while the sidebar shows.
- Paths are local: projects on remote hosts aren't supported (git and file checks run on this
  machine).
- The sidebar is a pane of the tab's split tree: it docks left of the tab's leftmost (top-left)
  pane, so in a tab split top/bottom it is as tall as that pane, not the window.
- The title-bar button and `⌃⌘E` toggle the sidebar instead of Files while the plugin is installed.
- `chrome.css` hides the parked sidebar's card by its label (`Projects · …`), so a parked pane of
  your own titled "Projects" is hidden from the park pile too.
