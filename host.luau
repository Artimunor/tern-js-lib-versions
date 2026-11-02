--!strict
-- The `deps` block: a package.json as a table of its dependencies with the latest minor and major npm versions,
-- an update button for each and "Update all minor" / "Update all major" beside the counts, holding back versions
-- younger than the package manager's minimum release age.
-- The file path is the block's first launch argument (the window's route, "Open with › JS Lib Versions", or
-- `cx:new_block("js-lib-versions.deps", { path })`).
--
-- One poll loop serves every open block: every 2 s it drops blocks whose pane is gone and re-reads the files each
-- remaining block depends on (package.json, catalog, package-manager configs), re-rendering only those that changed.
--
-- Keys: r refreshes from the registry, o opens the file as text.

local deps = require("./lib/deps")
local registry = require("./lib/registry")
local view = require("./lib/view")
local textlink = require("./lib/textlink")
local policy = require("./lib/policy")
local time = require("./lib/time")

type State = view.State

local POLL_MS = 2000
-- Fetches settle in bursts; renders for one block are coalesced over this window.
local RENDER_MS = 120

-- Open blocks by pane id.
local live: { [number]: State } = {}
local ticking = false
local renderQueued: { [number]: boolean } = {}

local function render_soon(st: State)
	local pane = st.cx.pane
	if renderQueued[pane] then
		return
	end
	renderQueued[pane] = true
	tern.timer(RENDER_MS, function()
		renderQueued[pane] = nil
		if live[pane] == st then
			st.cx:render()
		end
	end)
end

registry.init(function(name: string)
	for _, st in live do
		local doc = st.doc
		if doc and doc.names[name] then
			render_soon(st)
		end
	end
end, function(name: string): boolean
	for _, st in live do
		local doc = st.doc
		if doc and doc.names[name] then
			return true
		end
	end
	return false
end)

-- Re-reads the block's files; true when the doc changed (the caller renders).
local function reload(st: State, force: boolean): boolean
	local doc = deps.load(st.path, if force then nil else st.doc)
	if doc == nil then
		return false
	end
	st.doc = doc
	registry.ensure(doc.list, false)
	return true
end

local function tick()
	local alive: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		alive[p.pane] = true
	end
	for pane, st in live do
		if not alive[pane] then
			live[pane] = nil
		elseif reload(st, false) then
			st.cx:render()
		end
	end
	if next(live) then
		tern.timer(POLL_MS, tick)
	else
		ticking = false
	end
end

-- Reads the files again and asks the registry again for every package of the block, cache or not.
local function refresh(st: State)
	reload(st, true)
	local doc = st.doc
	if doc == nil then
		return
	end
	registry.forget(doc.list)
	registry.ensure(doc.list, true)
end

local function open_as_text(st: State, cx: BlockCx)
	-- A block's open is a link: the window's route.link turns this URL into a plain file open, so the
	-- package.json route doesn't send it back here.
	cx:open(textlink.url(st.path))
end

-- Every block reading an edited file (a shared catalog or config) shows the change now, not at the next tick; the
-- block that handled the event renders after it anyway.
local function reload_all(st: State)
	for _, other in live do
		if reload(other, false) and other ~= st then
			other.cx:render()
		end
	end
end

local function update(st: State, id: string, newSpec: string, cx: BlockCx)
	-- The button was drawn from the files as of the last poll; a just-tightened minimum release age (or any other
	-- edit) must not be bypassed in the gap, so a changed file only re-renders.
	if reload(st, false) then
		cx:toast("info", "Files changed", "Check the versions again")
		return
	end
	local doc = st.doc
	local row = if doc then doc.rows[id] else nil
	local target = if row then row.target else nil
	if doc == nil or row == nil or target == nil then
		cx:toast("error", "Nothing to update", "The row changed; try again")
		return
	end
	local applied, errors = deps.apply_all({ { target = target, spec = newSpec, name = row.name } }, doc.watch)
	if #applied > 0 then
		local where = string.match(target.file, "([^/]+)$") or target.file
		cx:toast("success", row.name .. " " .. target.spec .. " → " .. newSpec, where .. " › " .. table.concat(target.keypath, "."))
	else
		cx:toast("error", "Didn't update " .. row.name, errors[1])
	end
	reload_all(st)
end

-- "Update all minor/major": the edits are recomputed now (the gate moves with the clock), from files the reload
-- guard just confirmed, and written all or nothing.
local function update_all(st: State, kind: view.Kind, cx: BlockCx)
	if reload(st, false) then
		cx:toast("info", "Files changed", "Check the versions again")
		return
	end
	local doc = st.doc
	if doc == nil then
		return
	end
	local edits = view.bulk(doc, kind, os.time())
	if #edits == 0 then
		cx:toast("info", "No " .. kind .. " updates", "Nothing the release age allows moves a spec")
		return
	end
	local applied, errors = deps.apply_all(edits, doc.watch)
	local names: { string } = {}
	for i, e in applied do
		if i > 5 then
			table.insert(names, "+" .. (#applied - 5) .. " more")
			break
		end
		table.insert(names, e.name .. " " .. e.spec)
	end
	local plural = if #applied == 1 then "" else "s"
	if #errors == 0 then
		cx:toast("success", "Updated " .. #applied .. " " .. kind .. " version" .. plural, table.concat(names, ", "))
	elseif #applied == 0 then
		cx:toast("error", "Didn't update " .. kind .. " versions", errors[1])
	else
		cx:toast("error", "Updated " .. #applied .. " of " .. #edits .. "; " .. errors[1], table.concat(names, ", "))
	end
	reload_all(st)
end

-- Writes the minimum release age picked in the head's select into the project's config file.
local function set_age(st: State, seconds: number?, cx: BlockCx)
	local pol = if st.doc then st.doc.policy else nil
	if pol == nil or seconds == nil or seconds < 0 then
		return
	end
	if pol.problem then
		cx:toast("error", "Min release age not changed", pol.problem)
		return
	end
	local ok, where = policy.set(pol, seconds)
	if ok then
		cx:toast("success", "Min release age " .. (if seconds == 0 then "off" else time.span(seconds)), where)
	else
		cx:toast("error", "Min release age not changed", where)
	end
	reload_all(st)
end

tern.block.define("deps", {
	font = "sans",

	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local path = args[1] or ""
		if path ~= "" and string.sub(path, 1, 1) ~= "/" and cx.cwd then
			path = cx.cwd .. "/" .. path
		end
		local st: State = { cx = cx, path = path, doc = nil }
		if path ~= "" then
			live[cx.pane] = st
			reload(st, true)
			if not ticking then
				ticking = true
				tern.timer(POLL_MS, tick)
			end
		end
		return st
	end,

	title = function(st: State): string?
		return view.title(st)
	end,

	view = function(st: State, cx: BlockCx): BlockView
		return view.render(st, cx)
	end,

	key = function(st: State, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta or st.path == "" then
			return false
		end
		local k = key.text or key.name
		if k == "r" then
			refresh(st)
			return true
		elseif k == "o" then
			open_as_text(st, cx)
			return false
		end
		return false
	end,

	event = function(st: State, ev: UiEvent, cx: BlockCx)
		if st.path == "" then
			return
		end
		if ev.ev == "change" and ev.id == "main.head.end.age" and type(ev.value) == "string" then
			set_age(st, tonumber(ev.value), cx)
		elseif ev.ev ~= "action" then
			return
		elseif ev.act == "refresh" then
			refresh(st)
		elseif ev.act == "text" then
			open_as_text(st, cx)
		elseif ev.act == "set" and type(ev.item) == "string" and type(ev.value) == "string" then
			update(st, ev.item, ev.value, cx)
		elseif ev.act == "all" and (ev.value == "minor" or ev.value == "major") then
			update_all(st, ev.value :: view.Kind, cx)
		end
	end,
})
