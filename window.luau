--!strict
-- The window half: package.json opens go to the JS Lib Versions block instead of the editor, unless the command
-- "Toggle JS lib versions for package.json opens" turned that off. The block's "Open as text" comes back here as a
-- `js-lib-versions:text?path=…` link and opens the file in the editor without passing the route again.

local textlink = require("./lib/textlink")

local KIND = "js-lib-versions.deps"
-- The kv key of the switch; absent means on.
local SWITCH = "route_package_json"

-- Opens a person asked for: the Files pane, the palette, a path clicked in a pane, `tern open`.
-- Drops, the system and Carly keep the editor.
local ORIGINS: { [string]: boolean } = { files = true, palette = true, link = true, cli = true }
-- Placements a block decision honors (beside the focused pane, below it, a new tab); `tern open` asks for beside.
local PLACEMENTS: { [string]: boolean } = { default = true, beside = true, below = true, tab = true, split = true }

local function enabled(): boolean
	return tern.kv.get(SWITCH) ~= false
end

-- Whether `host` is this machine: the block opens on the file's host, which needs this plugin installed there.
local function is_local(host: string, cx: WindowCx): boolean
	if host == "" or host == "local" then
		return true
	end
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if not ok then
		return true
	end
	for _, h in hosts do
		if h.kind == "local" and h.name == host then
			return true
		end
	end
	return false
end

tern.route.open(function(req: OpenRequest, cx: WindowCx): RouteDecision?
	if not string.find(req.path, "[/\\]package%.json$") or string.find(req.path, "[/\\]node_modules[/\\]") then
		return nil
	end
	-- In place (replace, a link in a file block), the preview slot, or a line to reveal ask for the editor.
	if not PLACEMENTS[req.how] or req.line ~= nil or not ORIGINS[req.origin] then
		return nil
	end
	if not enabled() or not is_local(req.host, cx) then
		return nil
	end
	return { block = KIND, args = { req.path } }
end)

tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
	local path = textlink.path(link.url)
	if path == nil then
		return nil
	end
	-- Beside the block, which keeps following the file as it is edited.
	return { path = path, how = "beside" }
end)

tern.command({
	id = "toggle_route",
	title = "Toggle JS lib versions for package.json opens",
	icon = "app-node",
	run = function(cx: WindowCx)
		local on = not enabled()
		tern.kv.set(SWITCH, on)
		if on then
			cx:toast("success", "package.json opens in JS Lib Versions", "Open as text still opens the editor")
		else
			cx:toast("info", "package.json opens in the editor", "Open with › JS Lib Versions still works")
		end
	end,
})
