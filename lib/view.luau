--!strict
-- The block's view: a head row, a stats strip and one table per dependency map. Reads versions from the registry's
-- memory only; never fetches and never touches files.
--
-- The Minor and Major columns show the newest version the package manager's minimum release age allows, with an
-- update button when it moves the spec; a newer version the gate holds back is named in the row's tooltip. The head
-- shows the age as a select whose change the host writes to the project's config file. Beside the stats strip,
-- "Update all minor" / "Update all major" write every update of a column; `M.bulk` recomputes their edits at the
-- click from the same row decisions.

local ui = tern.ui
local spec = require("./spec")
local registry = require("./registry")
local deps = require("./deps")
local policy = require("./policy")
local time = require("./time")

type Doc = deps.Doc
type Row = deps.Row
type Policy = policy.Policy
type Pick = registry.Pick
type Offer = registry.Offer

export type State = { cx: BlockCx, path: string, doc: Doc? }

local M = {}

local COLS: { Col } = {
	{ id = "name", head = "Package", grow = 1, priority = 10, mono = true },
	{ id = "spec", head = "Version", priority = 9, mono = true },
	{ id = "minor", head = "Minor", priority = 8, mono = true },
	{ id = "major", head = "Major", priority = 7, mono = true },
	{ id = "source", head = "Source", priority = 2 },
}

-- How a row stands, for its dot.
type Status = "skip" | "complex" | "pending" | "error" | "missing" | "major" | "minor" | "held" | "ok"

local DOT: { [Status]: string } = {
	skip = "muted",
	complex = "muted",
	pending = "pending",
	error = "error",
	missing = "muted",
	major = "warning",
	minor = "accent",
	held = "pending",
	ok = "success",
}

-- What a version column offers: an update, only held versions, the current version, or nothing.
type Offered = "update" | "held" | "current" | "none"

-- What a row contributes to the page: its status and which kinds of updates it offers.
type Tally = { status: Status, minor: boolean, major: boolean, held: boolean }

local function muted(t: string): Cell
	return { ui.span(t, "muted") }
end

-- The major a row's newest-in-major lookup uses: only specs that can move within a major (`^18` can't).
local function want_major(row: Row): number?
	local s = row.spec
	if s.kind == "range" and (s.nums or 0) >= 2 then
		return s.major
	end
	return nil
end

-- Why `p` is held back by the policy's gate.
local function held_reason(p: Pick, pol: Policy, now: number): string
	if pol.problem then
		return pol.problem .. ": every update is held"
	end
	local parts = { "published " .. time.span(math.max(0, now - p.t)) .. " ago" }
	if pol.minAge > 0 then
		table.insert(parts, "min release age " .. time.span(pol.minAge))
	end
	local before = pol.before
	if before then
		table.insert(parts, "npm before " .. os.date("!%Y-%m-%d", before))
	end
	local text = table.concat(parts, "; ")
	if pol.source then
		text ..= " (" .. pol.source .. ")"
	end
	return text
end

-- Whether moving the row's spec to `p` is an update: newer than the spec's lower bound, a different spec at the
-- spec's precision, and (major column) in a newer major than the spec's.
local function newer(row: Row, p: Pick?, above: number?): boolean
	if p == nil then
		return false
	end
	if above and (spec.major(p.v) or 0) <= above then
		return false
	end
	local bumped = spec.bump(row.spec, p.v)
	return bumped ~= nil and bumped ~= row.spec.raw and spec.compare(p.v, row.spec.base or "0.0.0") > 0
end

-- What one version column decides: what it offers, the version it shows (`pick`), the spec an update writes, a
-- warning when the spec already asks for a release the gate holds, and a note naming a newer held version.
type Decision = { offered: Offered, pick: Pick?, spec: string?, warn: string?, note: string? }

-- A version column's decision: the newest version the minimum release age allows - an update when it moves the
-- spec, else current. `above`: the major column, which counts only newer majors.
local function decide(row: Row, offer: Offer?, above: number?, pol: Policy, now: number): Decision
	if offer == nil then
		return { offered = "none" }
	end
	local ok, newest = offer.ok, offer.newest
	local note: string? = nil
	if newest and newer(row, newest, above) and (ok == nil or ok.v ~= newest.v) then
		note = newest.v .. " held: " .. held_reason(newest, pol, now)
	end
	if ok and newer(row, ok, above) then
		return { offered = "update", pick = ok, spec = spec.bump(row.spec, ok.v), note = note }
	end
	if above == nil and ok then
		if newest and newest.v ~= ok.v and spec.compare(ok.v, row.spec.base or "0.0.0") < 0 then
			-- The spec already asks for a release younger than the gate allows.
			local why = row.spec.raw .. " is newer than " .. ok.v .. ", the newest release old enough to install"
			return { offered = "held", pick = ok, warn = why, note = why }
		end
		return { offered = "current", pick = ok, note = note }
	end
	return { offered = if note then "held" else "none", note = note }
end

-- Everything a row's cells, tally and the "update all" buttons are drawn from. `state` "checked" carries both
-- columns' decisions; `minor` is nil when the spec can't move within its major ("in range").
type Plan = {
	state: "skip" | "pending" | "missing" | "error" | "complex" | "checked",
	info: registry.Info?,
	minor: Decision?,
	major: Decision?,
}

local function plan(row: Row, pol: Policy, now: number): Plan
	local pkg = row.pkg
	if pkg == nil then
		return { state = "skip" }
	end
	local info = registry.get(pkg, want_major(row), policy.gate(pol, pkg, now))
	if info.state ~= "ok" then
		return { state = info.state, info = info }
	elseif row.spec.kind == "complex" then
		return { state = "complex", info = info }
	end
	return {
		state = "checked",
		info = info,
		minor = if want_major(row) ~= nil then decide(row, info.minor, nil, pol, now) else nil,
		major = decide(row, info.major, row.spec.major or 0, pol, now),
	}
end

local function column_cell(row: Row, d: Decision): Cell
	local pick = d.pick
	if d.offered == "update" and pick then
		if row.target == nil or d.spec == nil then
			return { text = pick.v, title = row.note }
		end
		return { button = { text = pick.v, act = "set=" .. (d.spec :: string), icon = "arrow-up" } }
	elseif pick and d.warn then
		return { text = pick.v, icon = "warn", tone = "warning", title = d.warn }
	elseif pick and d.offered == "current" then
		return { text = pick.v, icon = "check", tone = "success", title = "Up to date" }
	end
	return muted("—")
end

local function row_view(row: Row, p: Plan): (TableRow, Tally)
	local tally: Tally = { status = "ok", minor = false, major = false, held = false }
	local notes: { string } = {}
	local minor: Cell, major: Cell
	local info = p.info
	if p.state == "skip" then
		tally.status = "skip"
		minor, major = muted("—"), muted("—")
	elseif p.state == "pending" then
		tally.status = "pending"
		minor, major = muted("checking…"), muted("checking…")
	elseif p.state == "missing" then
		tally.status = "missing"
		minor = { text = { ui.span("not on npm", "muted") }, icon = "slash", title = "npm has no package " .. tostring(row.pkg) }
		major = muted("—")
	elseif p.state == "error" then
		tally.status = "error"
		minor = { text = "error", icon = "warn", tone = "error", title = if info then info.err else nil }
		major = minor
	elseif p.state == "complex" then
		tally.status = "complex"
		minor = { text = { ui.span("—", "muted") }, title = row.note }
		major = { text = (if info then info.latest else nil) or "?", title = "Latest release; " .. (row.note or "complex range") }
	else
		local dmin, dmaj = p.minor, p.major :: Decision
		if dmin then
			minor = column_cell(row, dmin)
		else
			local s = row.spec
			minor = { text = { ui.span("in range", "muted") }, title = s.raw .. " already allows every " .. tostring(s.major) .. ".x release" }
		end
		major = column_cell(row, dmaj)
		for _, d in { dmin, dmaj } do
			if d and d.note then
				table.insert(notes, d.note :: string)
			end
		end
		tally.minor = dmin ~= nil and dmin.offered == "update"
		tally.major = dmaj.offered == "update"
		tally.held = (dmin ~= nil and dmin.offered == "held") or dmaj.offered == "held" or #notes > 0
		tally.status = if tally.major then "major" elseif tally.minor then "minor" elseif tally.held then "held" else "ok"
		local any = info and info.major and info.major.newest
		if tally.status == "ok" and any == nil then
			-- Every release is deprecated or a prerelease (left-pad, eslint 8): nothing to compare with.
			tally.status = "complex"
			table.insert(notes, "no stable, non-deprecated release to compare with")
		end
	end

	local source: Cell = ""
	if row.source then
		source = { badge = { text = row.source :: string, title = row.sourceTitle } }
	end
	-- The version as the dependency resolves it; a catalog reference shows the catalog's spec.
	local version: Cell = row.spec.raw
	if row.spec.kind ~= "range" and row.spec.kind ~= "complex" then
		version = { ui.span(row.raw, "muted") }
	end
	local title: { string } = {}
	for _, n in { row.note or row.sourceTitle } do
		table.insert(title, n)
	end
	for _, n in notes do
		table.insert(title, n)
	end
	local tip = if #title > 0 then table.concat(title, "\n") else nil
	local cells: { Cell } = {
		{ text = row.name, dot = DOT[tally.status], title = tip },
		version,
		minor,
		major,
		source,
	}
	return { id = row.id, cells = cells, title = tip }, tally
end

-- The edits an "update all minor/major" click writes: one per entry (rows sharing a catalog entry write it once),
-- in row order, only where the column offers an update and the row has a place to write it.
export type Kind = "minor" | "major"
type Batch = { edits: { deps.Edit }, seen: { [string]: boolean } }

local function add(b: Batch, row: Row, d: Decision?)
	local t = row.target
	if t == nil or d == nil or d.offered ~= "update" or d.spec == nil then
		return
	end
	local id = t.file .. "\0" .. table.concat(t.keypath, "\0") .. "\0" .. t.key
	if not b.seen[id] then
		b.seen[id] = true
		table.insert(b.edits, { target = t, spec = d.spec :: string, name = row.name })
	end
end

-- The edits "Update all `kind`" writes for `doc` at time `now` (the host recomputes them at the click).
function M.bulk(doc: Doc, kind: Kind, now: number): { deps.Edit }
	local pol = doc.policy
	local b: Batch = { edits = {}, seen = {} }
	if pol == nil then
		return b.edits
	end
	for _, section in doc.sections do
		for _, row in section.rows do
			local p = plan(row, pol, now)
			add(b, row, if kind == "minor" then p.minor else p.major)
		end
	end
	return b.edits
end

local function key_of(section: string): string
	return (string.gsub(section, "[^%w]", "_"))
end

local function home(path: string): string
	local h = tern.getenv("HOME")
	if h and h ~= "" and string.sub(path, 1, #h + 1) == h .. "/" then
		return "~" .. string.sub(path, #h + 1)
	end
	return path
end

-- The package manager and where its gate comes from: "bun · bunfig.toml", "npm · before 2024-06-01 · .npmrc".
local function gate_text(pol: Policy): string
	local parts: { string } = { pol.pm }
	local before = pol.before
	if before then
		table.insert(parts, "before " .. os.date("!%Y-%m-%d", before))
	end
	if pol.source then
		table.insert(parts, pol.source)
	end
	return table.concat(parts, " · ")
end

local DAY = 86400
-- The ages the select offers; the current one joins them when it isn't one of these.
local PRESETS: { { number | string } } = {
	{ 0, "Off" },
	{ DAY, "1 day" },
	{ 2 * DAY, "2 days" },
	{ 3 * DAY, "3 days" },
	{ 7 * DAY, "1 week" },
	{ 14 * DAY, "2 weeks" },
	{ 30 * DAY, "30 days" },
}

-- The minimum release age as a select; picking one writes it to the project's config file (host `set_age`).
local function age_select(pol: Policy): Node
	local options: { { [string]: any } } = {}
	local current = false
	for _, preset in PRESETS do
		local secs = preset[1] :: number
		if not current and pol.minAge > 0 and pol.minAge < secs then
			table.insert(options, { value = tostring(pol.minAge), label = time.span(pol.minAge) })
			current = true
		end
		table.insert(options, { value = tostring(secs), label = preset[2] :: string })
		current = current or secs == pol.minAge
	end
	if not current then
		table.insert(options, { value = tostring(pol.minAge), label = time.span(pol.minAge) })
	end
	-- An unreadable gate holds everything; showing its fallback age ("Off") would claim the opposite.
	local value = tostring(pol.minAge)
	if pol.problem then
		value = "?"
		table.insert(options, { value = value, label = "unreadable" })
	end
	local file = policy.setting(pol)
	local from = if pol.source then "From " .. pol.source .. ". " else ""
	return ui.node("select", {
		key = "age",
		variant = "quiet",
		label = "Min release age",
		value = value,
		options = options,
		title = from .. "Changing it writes " .. file .. ".",
		disabled = if pol.problem then pol.problem else nil,
		basis = "content", -- a row's children shrink by default; a squeezed select draws its label over its neighbours
	})
end

-- "Update all minor/major": the tooltip lists the specs it writes; with none it is disabled, saying why.
local function bulk_button(kind: Kind, edits: { deps.Edit }): Node
	local n = #edits
	local lines: { string } = {}
	for i, e in edits do
		if i > 8 then
			table.insert(lines, "+" .. (n - 8) .. " more")
			break
		end
		table.insert(lines, e.name .. " → " .. e.spec)
	end
	return ui.button("Update all " .. kind, {
		key = "all-" .. kind,
		icon = "arrow-up",
		disabled = if n == 0 then "No " .. kind .. " updates the release age allows" else nil,
		title = if n > 0 then "Writes " .. n .. (if n == 1 then " spec" else " specs") .. ":\n" .. table.concat(lines, "\n") else nil,
		actions = { click = "all=" .. kind },
	})
end

local function head(st: State, doc: Doc?, busy: boolean): Node
	local name = if doc and doc.pkgName then doc.pkgName else "package.json"
	local meta: { string } = {}
	if doc and doc.pkgVersion then
		table.insert(meta, doc.pkgVersion)
	end
	table.insert(meta, home(st.path))
	if doc and doc.catalogLabel then
		table.insert(meta, "catalog in " .. doc.catalogLabel)
	end
	local controls: { Node } = {}
	local pol = if doc then doc.policy else nil
	if pol then
		table.insert(meta, gate_text(pol))
		table.insert(controls, age_select(pol))
	end
	table.insert(
		controls,
		ui.button("Refresh", { key = "refresh", icon = "repeat", keys = { "r" }, busy = busy, actions = { click = "refresh" } })
	)
	table.insert(controls, ui.button("Open as text", { key = "text", icon = "doc", keys = { "o" }, actions = { click = "text" } }))
	-- The controls keep their size; the name and meta wrap beside them, and the controls drop below when the block
	-- is too narrow for both.
	return ui.node("row", { key = "head", justify = "between", align = "center", wrap = true, gap = "md" }, {
		ui.text({ ui.span(name, "title"), ui.span("   " .. table.concat(meta, " · "), "muted") }),
		ui.node("row", { key = "end", gap = "sm", align = "center", basis = "content" }, controls),
	})
end

local function legend(note: string?): Node
	local spans: { Span } = {
		ui.span("r", "key"),
		ui.span(" refresh   ", "muted"),
		ui.span("o", "key"),
		ui.span(" open as text", "muted"),
	}
	if note then
		table.insert(spans, ui.span("   ·   " .. note, "dim"))
	end
	return ui.col({ ui.text(spans) })
end

local function problem_view(st: State, doc: Doc): BlockView
	local problem = doc.problem or { msg = "unknown problem" }
	local where = if problem.line then " (line " .. problem.line .. ", column " .. (problem.col or 1) .. ")" else ""
	local card = ui.card({ ui.span("Can't read " .. home(st.path), "strong") }, {
		ui.text({ ui.span(problem.msg .. where) }),
		ui.node("row", { key = "actions", gap = "sm" }, {
			ui.button("Open as text", { key = "text", icon = "doc", size = "sm", actions = { click = "text" } }),
			ui.button("Reload", { key = "reload", icon = "repeat", size = "sm", actions = { click = "refresh" } }),
		}),
	}, { icon = "warn", tone = "error" })
	return { main = ui.col({ head(st, nil, false), card }), dock = legend(nil) }
end

function M.title(st: State): string?
	local doc = st.doc
	if doc and doc.pkgName then
		return doc.pkgName .. " · package.json"
	end
	return "package.json"
end

function M.render(st: State, _cx: BlockCx): BlockView
	local doc = st.doc
	if st.path == "" then
		return {
			main = ui.col({
				ui.node("empty", {
					key = "nofile",
					icon = "app-node",
					title = "No package.json",
					text = "Open a package.json from the Files pane, or choose Open with › JS Lib Versions in its menu.",
				}),
			}),
		}
	end
	if doc == nil then
		return { main = ui.col({ head(st, nil, true), ui.progress(nil, "Reading package.json…") }) }
	end
	local pol = doc.policy
	if doc.problem or pol == nil then
		return problem_view(st, doc)
	end

	local counts = { pending = 0, skip = 0, error = 0, minor = 0, major = 0, held = 0 }
	local total = 0
	local oldest: number? = nil
	local tables: { Node } = {}
	local now = os.time()
	local minorB: Batch = { edits = {}, seen = {} }
	local majorB: Batch = { edits = {}, seen = {} }
	for _, section in doc.sections do
		local rows: { TableRow } = {}
		for _, row in section.rows do
			local p = plan(row, pol, now)
			add(minorB, row, p.minor)
			add(majorB, row, p.major)
			local r, tally = row_view(row, p)
			table.insert(rows, r)
			if tally.status == "pending" or tally.status == "skip" or tally.status == "error" then
				counts[tally.status] += 1
			end
			if tally.minor then
				counts.minor += 1
			end
			if tally.major then
				counts.major += 1
			end
			if tally.held then
				counts.held += 1
			end
			if row.pkg then
				total += 1
				local at = registry.get(row.pkg :: string, nil, nil).at
				if at and (oldest == nil or at < (oldest :: number)) then
					oldest = at
				end
			end
		end
		local tbl = ui.table(COLS, rows)
		local tp: { [string]: any } = tbl.p or {}
		tp.key = "table"
		tbl.p = tp
		local sec = ui.section({ ui.span(section.name, "strong"), ui.span("  " .. #section.rows, "muted") }, { tbl })
		local sp: { [string]: any } = sec.p or {}
		sp.key = key_of(section.name)
		sec.p = sp
		table.insert(tables, sec)
	end

	local page: { Node } = { head(st, doc, counts.pending > 0) }
	if #doc.sections == 0 then
		table.insert(
			page,
			ui.node("empty", {
				key = "empty",
				icon = "box",
				title = "No dependencies",
				text = "This package.json lists no dependencies.",
			})
		)
		return { main = ui.node("col", { gap = "lg" }, page), dock = legend(nil) }
	end

	local stats: { StatItem } = {
		{
			label = "Packages",
			value = tostring(total),
			sub = if counts.pending > 0
				then "checking " .. counts.pending .. "…"
				elseif counts.skip > 0 then counts.skip .. " more not checked"
				else nil,
		},
		{ label = "Minor updates", value = tostring(counts.minor), tone = if counts.minor > 0 then "accent" else nil },
		{ label = "Major updates", value = tostring(counts.major), tone = if counts.major > 0 then "warning" else nil },
	}
	if counts.held > 0 then
		table.insert(stats, {
			label = "Held back",
			value = tostring(counts.held),
			tone = "pending",
			sub = "too new for the release age gate",
		})
	end
	if counts.error > 0 then
		table.insert(stats, { label = "Errors", value = tostring(counts.error), tone = "error", sub = "hover a row for why" })
	end
	local strip = ui.stats(stats)
	local stp: { [string]: any } = strip.p or {}
	stp.key = "stats"
	strip.p = stp
	-- The bulk buttons sit beside the counts they act on, dropping below the strip when the block is narrow.
	table.insert(
		page,
		ui.node("row", { key = "summary", justify = "between", align = "center", wrap = true, gap = "md" }, {
			strip,
			ui.node("row", { key = "bulk", gap = "sm", align = "center", basis = "content" }, {
				bulk_button("minor", minorB.edits),
				bulk_button("major", majorB.edits),
			}),
		})
	)
	if pol.problem then
		table.insert(page, ui.text({ ui.span(pol.problem .. ": every update is held until it can be read", "warning") }))
	end
	if doc.catalogProblem then
		table.insert(page, ui.text({ ui.span(doc.catalogProblem, "warning") }))
	end
	for _, t in tables do
		table.insert(page, t)
	end

	local note: string? = nil
	if oldest then
		note = "registry checked at " .. os.date("%H:%M", oldest :: number)
	end
	return { main = ui.node("col", { gap = "lg" }, page), dock = legend(note) }
end

return M
