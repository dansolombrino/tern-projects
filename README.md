# Projects & Agents (`projects`)

A Tern plugin (window half only, public plugin SDK) for an Orca-like multi-agent workflow:
**projects**, several **omp agents per project**, and **subagents per agent**.

- A project is a folder (usually a git repository's root). Each project gets its own Tern session,
  named exactly like the project.
- A new agent is an omp agent block opened as a tab in the project's session, named after its task
  and colored with the project's color. In a git project each agent works in a git worktree of its
  own, on branch `agent/<slug>`.
- A subagent is a child omp agent started from a parent agent: it opens as a split beside the
  parent, in the parent's folder (and worktree). When the child's turn ends, its last message is
  sent to the parent (report-back).
- omp's own subagents (its task tool) are read from the parent's surface and shown nested under the
  agent, read-only.
- An Orca-style left sidebar lists every project with its agents (one card each), their spawned
  subagents and omp's internal subagents. It docks at the left of the tab you work in, follows you to
  other tabs and sessions, and is shown and hidden from the title bar, like Orca's sidebar.

## Install

```sh
tern plugin link ~/src/tern-projects    # use it where it is; saving a file reloads it
tern plugin list                        # projects … window  ready
```

`tern plugin unlink projects` removes it. For type-checking, `tern plugin types ~/src/tern-projects`
writes `tern.d.luau` (git-ignored) for luau-lsp.

## Commands and keys

All commands are in the palette's **Projects** group, as actions `plugin.projects.<id>`. On Linux and
Windows the chords use `Ctrl` instead of `⌘` (`Ctrl+Alt+B`, `Ctrl+Alt+Shift+…`).

| Command | Action | Keys | Does |
| --- | --- | --- | --- |
| Toggle sidebar | `toggle_sidebar` | `⌥⌘B` (also `⌃⌘E` and the title-bar button) | Shows or hides the Projects sidebar. |
| Search agents and projects | `search` | `⌘⌥⇧K` | Orca's switcher: a picker over every agent (subagents indented) and project; an agent is focused, a project's session opened. |
| Add project | `add` | | Asks for the root (default: the git root above the focused pane's folder) and a name. Worktrees are on when the root is a repository's top folder. |
| Remove project (keeps files) | `remove` | | Forgets a project and its agents' records. Never deletes files, sessions or worktrees. |
| Open project | `open` | `⌘⌥⇧L` | Switches to the project's session, creating it at the root when missing. |
| New agent in project | `new_agent` | `⌘⌥⇧A` | Project of the focused pane (else a picker), then the task: makes the worktree, opens the agent tab in the project's session with the task as its first prompt. |
| New subagent of focused agent | `new_subagent` | `⌘⌥⇧U` | Asks for a task and starts a child agent split beside the focused agent, with report-back. |
| Jump to next agent waiting for input | `next_waiting` | `⌘⌥⇧J` | Focuses the next agent (by pane id, wrapping) whose state is `waiting_input`, switching session when needed. |
| Remove a finished agent's worktree | `cleanup` | | Picks a worktree no running agent (or subagent) works in; `git worktree remove`, asking first when it has uncommitted changes (then `--force`). The branch is kept. |
| Sidebar options | `options` | | The sidebar's options picker (below). |
| Use ⌘B to toggle the sidebar | `use_cmd_b` | | Opt-in: binds `⌘B` (`Ctrl+B`) to `toggle_sidebar` in your keybinds, as Orca does. Tern's presets use `⌘B` (new branch, bold, the vertical-tab sidebar), so it is off by default. Shown while unbound. |
| Release ⌘B (back to Tern's) | `release_cmd_b` | | Removes only that keybind, so `⌘B` does what Tern's presets say again. Shown while bound. |

The status line always has a Projects segment: `<project> · N working · M waiting` for a focused
pane inside a project, else `Projects` (with the waiting count across all projects when any agent
needs input). A click toggles the sidebar. A toast tells you when an agent you are not looking at
needs input, finishes or fails.

### The title-bar button (Files takeover)

Orca keeps its sidebar toggle at the leading edge of the title bar. Tern has no plugin slot there, so
the plugin takes over Tern's **Files** button: `chrome.css` moves it to the leading edge (before the
session pill), draws Orca's PanelLeft glyph (32×24, radius 4, muted until hovered) and retitles its
tooltip "Toggle sidebar", and `tern.override("files", …)` makes it, and `⌃⌘E`, toggle the sidebar.
Files stays reachable: `⇧⌘E` (Focus Files) still opens it, and *Show/hide Files* in the sidebar
options runs Tern's own Files action. Uninstalling the plugin gives the button back.

### Sidebar

Laid out after Orca's left sidebar (`sidebar.luau`, `sidebar.css`): a Search pill (the `search`
picker), a *Projects* header (collapse or expand all, the waiting-agents bell, options, Add
project, New agent), one collapsible group per project (its color, `+` New agent, `…` and
right-click: New agent, Open session, Remove project), then *Unassigned* for agents outside every
project, and a footer (options, clean up worktrees, next waiting agent, hide).

- A card per top-level agent: status (working spinner, waiting question mark, idle, done), title
  with a *primary* mark when it works in the project root (no worktree), branch or folder, and a row
  with its last message, model and age. The focused agent's card is highlighted; one that finished or
  asked for input while you looked elsewhere is bold with a bell until you focus it. Spawned and
  omp-internal subagents are nested rows under it.
- Click focuses an agent (switching session when needed), double-click renames it (title and tab
  name), right-click: Focus, Rename, New subagent, Open project session, Stop. Clicks never take
  focus from your terminal.
- Options: Add project, Remove project, Clean up worktrees, Collapse or expand all projects, Use (or
  stop using) ⌘B for the sidebar, Show/hide Files, Refresh, Hide sidebar.
- Hiding parks the sidebar's pane (kept out of the park pile by `chrome.css`); showing unparks it,
  docks it left of the tab's leftmost pane and sizes it to the remembered width: Orca's 280 px by
  default, or the width you last dragged it to (kept in cells). It follows you to other tabs and
  sessions while shown, and reopens with the window when it was shown.
- It redraws on agent, pane, focus and session events and every 2 s while shown; surfaces are read
  for working agents on each redraw and for the rest every 10 s.

## Data model

Stored with `tern.kv` (the plugin's `kv.json`, shared by every window) under `projects.v1`:

```
{
  projects = { { id, name, root, color, worktrees, created } },
  agents = { ["<pane>"] = { project, title, task, worktree?, branch?, parent?, report_back?, started, closed? } }
}
```

- `id` is a slug of the first name; `name` is the session name; `color` a tab color.
- Agents are keyed by pane id. An agent started by hand (no record) still belongs to the project
  whose root, or worktree folder, holds its folder (the longest root wins).
- Worktrees live beside the root: `<root>/../.tern-worktrees/<project id>/<slug>`, branch
  `agent/<slug>` (`-2`, `-3`, … when taken).
- A closed agent's record stays (`closed = true`) while it owns a worktree, so `cleanup` can find
  it; other records go when their block closes.

The sidebar's state is under `projects.ui.v1`: `{ visible, want_cols?, collapsed = { [project id] = true } }`.

Files: `plugin.toml` (manifest; `styles` loads the two sheets), `window.luau` (commands, events,
chrome, the sidebar's placement, worktrees), `model.luau` (data and persistence), `subagents.luau`
(omp surface → subagents), `sidebar.luau` (snapshot → canvas nodes), `sidebar.css` (the sidebar),
`chrome.css` (its pane chrome and the title-bar toggle), `tests/` (pure tests:
`luau tests/<file>.luau`).

## Limits

- Pane ids key the records: agents restored by a Tern restart that changes pane ids lose their
  title, worktree and parent links (they still show, attributed by folder).
- Report-back fires on every turn end of a spawned subagent (`done` or `failed`) that produced a new
  answer (omp's stats footer stripped), while the parent agent is alive. Reports to a working parent
  wait for its next idle; one Tern refuses is retried at the parent's next state change (a toast says
  so). The in-memory queue is lost on a plugin reload.
- omp-internal subagents are read from at most 2000 surface nodes per agent; a longer transcript
  can hide older ones. They are read only while the sidebar shows.
- Paths are local: projects on remote hosts aren't supported (git and file checks run on this
  machine).
- The sidebar is a pane of the tab's split tree: it docks left of the tab's leftmost (top-left)
  pane, so in a tab split top/bottom it is as tall as that pane, not the window. Its width is a
  share of that split, so resizing the window changes it until it is next shown or follows you.
- The title-bar button and `⌃⌘E` toggle the sidebar instead of Files while the plugin is installed.
- `chrome.css` hides the parked sidebar's card by its label (`Projects · …`), so a parked pane of
  your own titled "Projects" is hidden from the park pile too.
- `cleanup` removes only worktrees no live agent works in, never branches.
