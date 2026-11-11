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
- A dashboard canvas lists every project with its agents, their spawned subagents and omp's
  internal subagents, with buttons to focus, start, stop and open things.

## Install

```sh
tern plugin link ~/src/tern-projects    # use it where it is; saving a file reloads it
tern plugin list                        # projects … window  ready
```

`tern plugin unlink projects` removes it. For type-checking, `tern plugin types ~/src/tern-projects`
writes `tern.d.luau` (git-ignored) for luau-lsp.

## Commands and keys

All commands are in the palette's **Projects** group, as actions `plugin.projects.<id>`. On Linux and
Windows the chords use `Ctrl+Alt+Shift` instead of `⌘⌥⇧`.

| Command | Action | Keys | Does |
| --- | --- | --- | --- |
| Add project | `add` | | Asks for the root (default: the git root above the focused pane's folder) and a name. Worktrees are on when the root is a repository's top folder. |
| Remove project (keeps files) | `remove` | | Forgets a project and its agents' records. Never deletes files, sessions or worktrees. |
| Open project | `open` | `⌘⌥⇧L` | Switches to the project's session, creating it at the root when missing. |
| New agent in project | `new_agent` | `⌘⌥⇧A` | Project of the focused pane (else a picker), then the task: makes the worktree, opens the agent tab in the project's session with the task as its first prompt. |
| New subagent of focused agent | `new_subagent` | `⌘⌥⇧U` | Asks for a task and starts a child agent split beside the focused agent, with report-back. |
| Toggle projects dashboard | `dashboard` | `⌘⌥⇧D` | Opens or closes the dashboard canvas as a left sidebar (28%) beside the focused pane. |
| Jump to next agent waiting for input | `next_waiting` | `⌘⌥⇧J` | Focuses the next agent (by pane id, wrapping) whose state is `waiting_input`, switching session when needed. |
| Remove a finished agent's worktree | `cleanup` | | Picks a worktree no running agent (or subagent) works in; `git worktree remove`, asking first when it has uncommitted changes (then `--force`). The branch is kept. |

The status line always has a Projects segment: `<project> · N working · M waiting` for a focused
pane inside a project, else `Projects` (with the waiting count across all projects when any agent
needs input). A click toggles the dashboard, as does the sidebar button in the Files pane's header
(`⌘O`). A toast tells you when an agent you are not looking at needs input, finishes or fails.

### Dashboard

One card per project (Open, New agent), each agent as a row with Focus, Subagent and Stop buttons
(also on its right-click menu), spawned subagents and omp's internal subagents drawn indented
beneath it, agents outside every project under *Unassigned*, and a dock with Add project and
Refresh. It redraws on agent, pane and session events and every 2 s while it is open; surfaces
are read for working agents on each redraw and for the rest every 10 s.

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

Files: `plugin.toml`, `window.luau` (commands, events, chrome, canvas, worktrees), `model.luau`
(data and persistence), `subagents.luau` (omp surface → subagents), `dashboard.luau` (snapshot →
canvas nodes), `tests/` (pure tests: `luau tests/<file>.luau`).

## Limits

- Pane ids key the records: agents restored by a Tern restart that changes pane ids lose their
  title, worktree and parent links (they still show, attributed by folder).
- Report-back fires on every turn end of a spawned subagent (`done` or `failed`) that produced a new
  answer (omp's stats footer stripped), while the parent agent is alive. Reports to a working parent
  wait for its next idle; one Tern refuses is retried at the parent's next state change (a toast says
  so). The in-memory queue is lost on a plugin reload.
- omp-internal subagents are read from at most 2000 surface nodes per agent; a longer transcript
  can hide older ones. They are read only while the dashboard is open.
- Paths are local: projects on remote hosts aren't supported (git and file checks run on this
  machine).
- The dashboard opens in the current tab; switching sessions leaves it behind (toggle it again in
  the other session).
- `cleanup` removes only worktrees no live agent works in, never branches.
