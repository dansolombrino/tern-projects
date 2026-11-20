--!strict
-- projects, base: the few constants window.luau needs while its module loads (the plugin id, the platform, command
-- ids and the chord modifiers). It requires nothing, so the window entry's load stays cheap; core.luau re-exports
-- them with the rest.

local ID = tern.plugin.id
local MACOS = tern.runtime.os == "macos"

local function action_id(cmd: string): string
	return "plugin." .. ID .. "." .. cmd
end

return {
	ID = ID,
	MACOS = MACOS,
	action_id = action_id,
	TOGGLE = action_id("toggle_sidebar"),
	MOD = if MACOS then "cmd+alt+shift+" else "ctrl+alt+shift+",
	PRIMARY = if MACOS then "cmd+" else "ctrl+",
}
