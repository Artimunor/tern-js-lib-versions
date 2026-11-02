--!strict
-- Which minimum release age applies to a project: detects the package manager
-- and reads its project and user config files (Bun `minimumReleaseAge`, pnpm
-- `minimumReleaseAge`, Yarn `npmMinimalAgeGate`, npm `min-release-age` /
-- `before`) with minimal, never-raising TOML / INI / YAML readers.
-- SECURITY: config texts (`~/.npmrc` may hold auth tokens) stay in
-- `Policy.files`; never log, show or persist them.

local jsonspan = require("./jsonspan")
local yamlcat = require("./yamlcat")
local time = require("./time")

export type PM = "bun" | "pnpm" | "yarn" | "npm"
export type Policy = {
	pm: PM,
	root: string, -- the project root the files were read from (edits go to its config file)
	minAge: number, -- seconds; 0 = no relative gate
	before: number?, -- npm `before` absolute cutoff (epoch)
	source: string?, -- where the effective gate came from, for display
	names: { string }, -- exempt names/globs (every version)
	versions: { [string]: { [string]: boolean } }, -- exempt exact versions by package name
	files: { [string]: string | false }, -- every config path consulted → `M.read(path, user[path])`
	user: { [string]: boolean }, -- the user-level ones among them (outside the project)
	problem: string?, -- a gate value or config file that couldn't be read → hold every update
}
export type Gate = { cutoff: number, allow: { [string]: boolean }? }

-- A config value as read: a number, a string, a list of strings, or `bad`
-- when present but outside the supported subset.
type Val = { n: number?, s: string?, list: { string }?, bad: boolean? }
type Kind = "toml" | "yaml" | "ini"
-- A config file and the keys it may hold.
type Source = { path: string, label: string, kind: Kind, gate: string, excl: string?, before: string?, user: boolean }

local MAX_BYTES = 256 * 1024
local UNREADABLE = "\0"
local PNPM_DEFAULT = 1440 * 60

local M = {}

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") :: string)
end

-- A TOML key or table name as the reader matches it: quotes dropped, spaces around dots removed.
local function tomlKey(raw: string): string
	local k = string.gsub(trim(raw), "%s*%.%s*", ".")
	return (string.gsub(k, "[\"']", ""))
end

local function exists(path: string): boolean
	local ok, yes = pcall(tern.fs.exists, path)
	return ok and yes == true
end

-- A file's text; false when absent; "\0" when it exists but can't be read (or is larger than 256 KiB). A capped
-- read refuses symlinks; only a user-level file (`trusted`: in the home or config folder, often a symlinked
-- dotfile) is read again uncapped. A project file comes from the repository, which could point a symlink at a
-- device that never ends, so a refused one stays unreadable (and holds every update).
function M.read(path: string, trusted: boolean?): string | false
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	if ok and type(text) == "string" then
		return text
	end
	if not exists(path) then
		return false
	end
	if trusted then
		local ok2, text2 = pcall(tern.fs.read, path)
		if ok2 and type(text2) == "string" and #text2 <= MAX_BYTES then
			return text2
		end
	end
	return UNREADABLE
end

-- Whether any config file `p` was read from changed, appeared or disappeared since.
function M.changed(p: Policy): boolean
	for path, was in p.files do
		if M.read(path, p.user[path]) ~= was then
			return true
		end
	end
	return false
end

-- INI (.npmrc, pnpm rc): `key=value` lines, last one wins. `#`/`;` comments,
-- optional surrounding quotes, `[section]` lines ignored.
local function iniRead(text: string): { [string]: string }
	local out: { [string]: string } = {}
	local len = #text
	local pos = 1
	while pos <= len do
		local nl = string.find(text, "\n", pos, true)
		local stop = if nl then nl - 1 else len
		local line = trim(string.sub(text, pos, stop))
		pos = if nl then nl + 1 else len + 1
		local first = string.sub(line, 1, 1)
		if line == "" or first == "#" or first == ";" or first == "[" then
			continue
		end
		local eq = string.find(line, "=", 1, true)
		if eq == nil then
			continue
		end
		local key = trim(string.sub(line, 1, eq - 1))
		local value = trim(string.sub(line, eq + 1))
		local q = string.sub(value, 1, 1)
		if (q == '"' or q == "'") and #value >= 2 and string.sub(value, -1) == q then
			value = string.sub(value, 2, -2)
		else
			value = trim(string.match(value, "^[^;#]*") :: string) -- an inline comment
		end
		if key ~= "" then
			out[key] = value
		end
	end
	return out
end

local TOML_ESCAPES: { [string]: string } = {
	b = "\b",
	t = "\t",
	n = "\n",
	f = "\f",
	r = "\r",
	['"'] = '"',
	["\\"] = "\\",
}

-- TOML subset: values of the `[install]` table and of top-level dotted
-- `install.<key>` keys, by `<key>`. Integers (underscores allowed), floats,
-- one-line basic/literal strings, string arrays (may span lines), `#` comments.
local function tomlInstall(text: string): { [string]: Val }
	local out: { [string]: Val } = {}
	local len = #text
	local pos = if string.sub(text, 1, 3) == "\239\187\191" then 4 else 1

	local function lineEnd(p: number): number
		return string.find(text, "\n", p, true) or len + 1
	end

	-- skips spaces, line breaks and comments
	local function blank(p: number): number
		while true do
			local _, e = string.find(text, "^[ \t\r\n]*", p)
			p = (e :: number) + 1
			if string.sub(text, p, p) ~= "#" then
				return p
			end
			p = lineEnd(p)
		end
	end

	-- the one-line string whose quote is at `p`: text and the position after
	-- its closing quote, or nil
	local function str(p: number): (string?, number)
		local q = string.sub(text, p, p)
		if string.sub(text, p, p + 2) == string.rep(q, 3) then
			return nil, p -- multi-line strings are not supported
		end
		if q == "'" then
			local close = string.find(text, "['\n]", p + 1)
			if close == nil or string.byte(text, close) ~= 39 then
				return nil, p
			end
			return string.sub(text, p + 1, close - 1), close + 1
		end
		local parts: { string } = {}
		local i = p + 1
		while true do
			local at = string.find(text, '["\\\n]', i)
			if at == nil or string.byte(text, at) == 10 then
				return nil, p
			end
			table.insert(parts, string.sub(text, i, at - 1))
			if string.byte(text, at) == 34 then
				return table.concat(parts), at + 1
			end
			local e = string.sub(text, at + 1, at + 1)
			if e == "u" or e == "U" then
				local width = if e == "u" then 4 else 8
				local hex = string.match(text, "^" .. string.rep("%x", width), at + 2)
				local code = if hex then tonumber(hex, 16) else nil
				if code == nil or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
					return nil, p
				end
				table.insert(parts, utf8.char(code))
				i = at + 2 + width
			else
				local ch = TOML_ESCAPES[e]
				if ch == nil then
					return nil, p
				end
				table.insert(parts, ch)
				i = at + 2
			end
		end
	end

	-- the value at `p`, and the position after it
	local function value(p: number): (Val, number)
		local ch = string.sub(text, p, p)
		if ch == '"' or ch == "'" then
			local s, after = str(p)
			if s == nil then
				return { bad = true }, lineEnd(p)
			end
			return { s = s }, after
		elseif ch == "[" then
			local list: { string } = {}
			p += 1
			while true do
				p = blank(p)
				local c = string.sub(text, p, p)
				if c == "]" then
					return { list = list }, p + 1
				elseif c ~= '"' and c ~= "'" then
					return { bad = true }, lineEnd(p)
				end
				local s, after = str(p)
				if s == nil then
					return { bad = true }, lineEnd(p)
				end
				table.insert(list, s)
				p = blank(after)
				c = string.sub(text, p, p)
				if c == "]" then
					return { list = list }, p + 1
				elseif c ~= "," then
					return { bad = true }, lineEnd(p)
				end
				p += 1
			end
		end
		local tok = string.match(text, "^[%w%+%-%._:]+", p)
		if tok == nil then
			return { bad = true }, lineEnd(p)
		end
		local after = p + #tok
		local clean = string.gsub(tok, "_", "")
		if string.sub(clean, 1, 1) == "+" then
			clean = string.sub(clean, 2)
		end
		local n = if string.find(clean, "^%-?%d") then tonumber(clean) else nil
		if n == nil or n ~= n or n == math.huge or n == -math.huge then
			return { bad = true }, after
		end
		return { n = n }, after
	end

	local tbl = ""
	while true do
		pos = blank(pos)
		if pos > len then
			break
		end
		local le = lineEnd(pos)
		if string.sub(text, pos, pos) == "[" then
			local close = string.find(text, "]", pos, true)
			if close ~= nil and close < le then
				tbl = tomlKey((string.gsub(string.sub(text, pos + 1, close - 1), "^%[", "")))
			else
				tbl = "\0" -- a header this reader can't name: none of its keys matter
			end
			pos = le
			continue
		end
		local eq = string.find(text, "=", pos, true)
		if eq == nil or eq > le then
			pos = le -- not `key = value`: skipped
			continue
		end
		local k = tomlKey(string.sub(text, pos, eq - 1))
		local full = if tbl == "" then k else tbl .. "." .. k
		local _, ws = string.find(text, "^[ \t]*", eq + 1)
		local v, after = value((ws :: number) + 1)
		local name = string.match(full, "^install%.([^%.]+)$")
		if name ~= nil then
			out[name] = v
		end
		pos = lineEnd(after)
	end
	return out
end

-- Reads values by key from one config file's text. A file or value it can't parse reads as `bad`, never as
-- absent, so a gate written in an unsupported form holds updates instead of disappearing.
local BAD: Val = { bad = true }
local function reader(kind: Kind, text: string): (string) -> Val?
	if kind == "toml" then
		local ok, vals = pcall(tomlInstall, text)
		return function(k: string): Val?
			return if ok then vals[k] else BAD
		end
	elseif kind == "ini" then
		local ok, vals = pcall(iniRead, text)
		return function(k: string): Val?
			if not ok then
				return BAD
			end
			local s = vals[k]
			return if s ~= nil then { s = s } else nil
		end
	end
	return function(k: string): Val?
		local ok, v, state = pcall(yamlcat.top, text, k)
		if not ok or state == "bad" then
			return BAD
		elseif state ~= "ok" then
			return nil -- absent, or explicitly null: not set
		elseif type(v) == "string" then
			return { s = v }
		end
		return { list = v :: { string } }
	end
end

local function seconds(v: Val, unit: number): number?
	if v.n ~= nil then
		return time.duration(v.n, unit)
	elseif v.s ~= nil then
		return time.duration(v.s, unit)
	end
	return nil
end

-- One exclusion entry: a name/glob (every version) or `name@v1 || v2`.
local function exclude(p: Policy, raw: string)
	local s = trim(raw)
	if s == "" then
		return
	end
	local at: number? = nil
	local i = 2 -- an `@` at position 1 starts a scoped name
	while true do
		local f = string.find(s, "@", i, true)
		if f == nil then
			break
		end
		at = f
		i = f + 1
	end
	if at == nil then
		table.insert(p.names, s)
		return
	end
	local name = trim(string.sub(s, 1, at - 1))
	local vers = trim(string.sub(s, at + 1))
	if string.sub(vers, 1, 4) == "npm:" then
		vers = trim(string.sub(vers, 5)) -- a Yarn locator
	end
	if name == "" then
		return
	end
	local set: { [string]: boolean }? = nil
	local pos = 1
	while pos <= #vers + 1 do
		local bar = string.find(vers, "||", pos, true)
		local v = trim(string.sub(vers, pos, if bar then bar - 1 else #vers))
		if v ~= "" then
			local cur = set or p.versions[name] or {}
			set = cur
			cur[v] = true
		end
		pos = if bar then bar + 2 else #vers + 2
	end
	if set ~= nil then
		p.versions[name] = set
	end
end

local function asPM(name: string): PM?
	if name == "bun" then
		return "bun"
	elseif name == "pnpm" then
		return "pnpm"
	elseif name == "yarn" then
		return "yarn"
	elseif name == "npm" then
		return "npm"
	end
	return nil
end

local function env(name: string): string?
	local v = tern.getenv(name)
	if v == nil or v == "" then
		return nil
	end
	return (string.gsub(v, "[/\\]+$", ""))
end

function M.detect(root: string, manifest: jsonspan.JNode?): Policy
	root = string.gsub(root, "[/\\]+$", "")
	local home = env("HOME")
	local xdg = env("XDG_CONFIG_HOME")

	-- package manager
	local pm: PM? = nil
	local major: number? = nil
	local pmNode = jsonspan.get(manifest, { "packageManager" })
	local pmText = if pmNode ~= nil and pmNode.kind == "string" then pmNode.value else nil
	if pmText ~= nil then
		local name, ver = string.match(pmText, "^%s*(%a+)@(.*)$")
		if name ~= nil and ver ~= nil then
			pm = asPM(name)
			if pm ~= nil then
				local m = string.match(ver, "^%s*v?(%d+)")
				major = if m then tonumber(m) else nil
			end
		end
	end
	local function has(name: string): boolean
		return exists(root .. "/" .. name)
	end
	if pm == nil then
		if has("bun.lock") or has("bun.lockb") then
			pm = "bun"
		elseif has("pnpm-lock.yaml") then
			pm = "pnpm"
		elseif has("yarn.lock") then
			pm = "yarn"
		elseif has("package-lock.json") or has("npm-shrinkwrap.json") then
			pm = "npm"
		elseif has("pnpm-workspace.yaml") then
			pm = "pnpm"
		elseif has(".yarnrc.yml") then
			pm = "yarn"
		end
	end
	local which: PM = pm or "npm"

	-- config files, highest precedence first
	local sources: { Source } = {}
	local function project(name: string, kind: Kind, gate: string, excl: string?, before: string?)
		table.insert(sources, {
			path = root .. "/" .. name,
			label = name,
			kind = kind,
			gate = gate,
			excl = excl,
			before = before,
			user = false,
		})
	end
	-- A file outside the project: the user's own (`trusted`) or a parent folder's.
	local function outside(path: string?, kind: Kind, gate: string, excl: string?, before: string?, trusted: boolean)
		if path == nil then
			return
		end
		local label = path
		if home ~= nil and string.sub(path, 1, #home + 1) == home .. "/" then
			label = "~" .. string.sub(path, #home + 1)
		end
		table.insert(sources, { path = path, label = label, kind = kind, gate = gate, excl = excl, before = before, user = trusted })
	end
	local function user(path: string?, kind: Kind, gate: string, excl: string?, before: string?)
		outside(path, kind, gate, excl, before, true)
	end
	local function under(dir: string?, name: string): string?
		return if dir ~= nil then dir .. "/" .. name else nil
	end
	local unit = 1
	if which == "bun" then
		project("bunfig.toml", "toml", "minimumReleaseAge", "minimumReleaseAgeExcludes")
		user(under(xdg or home, ".bunfig.toml"), "toml", "minimumReleaseAge", "minimumReleaseAgeExcludes")
	elseif which == "pnpm" then
		unit = 60
		local cfg: string?
		if xdg ~= nil then
			cfg = xdg .. "/pnpm"
		elseif tern.runtime.os == "macos" then
			cfg = under(home, "Library/Preferences/pnpm")
		elseif tern.runtime.os == "windows" then
			cfg = under(env("LOCALAPPDATA"), "pnpm/config")
		else
			cfg = under(home, ".config/pnpm")
		end
		project("pnpm-workspace.yaml", "yaml", "minimumReleaseAge", "minimumReleaseAgeExclude")
		project(".npmrc", "ini", "minimum-release-age")
		user(under(cfg, "config.yaml"), "yaml", "minimumReleaseAge", "minimumReleaseAgeExclude")
		user(under(cfg, "rc"), "ini", "minimum-release-age")
		user(under(home, ".npmrc"), "ini", "minimum-release-age")
	elseif which == "yarn" then
		unit = 60
		project(".yarnrc.yml", "yaml", "npmMinimalAgeGate", "npmPreapprovedPackages")
		-- Yarn also reads the .yarnrc.yml of every parent folder, nearer first; the home folder's keeps its place in
		-- that chain, else comes last.
		local homeRc = under(home, ".yarnrc.yml")
		local homeSeen = false
		local dir: string? = string.match(root, "^(.*)/[^/]*$")
		while dir ~= nil do
			local rc = dir .. "/.yarnrc.yml"
			homeSeen = homeSeen or rc == homeRc
			outside(rc, "yaml", "npmMinimalAgeGate", "npmPreapprovedPackages", nil, rc == homeRc)
			dir = if dir == "" then nil else string.match(dir, "^(.*)/[^/]*$")
		end
		if not homeSeen then
			user(homeRc, "yaml", "npmMinimalAgeGate", "npmPreapprovedPackages")
		end
	else
		unit = 86400
		project(".npmrc", "ini", "min-release-age", nil, "before")
		user(under(home, ".npmrc"), "ini", "min-release-age", nil, "before")
	end

	local p: Policy = { pm = which, root = root, minAge = 0, names = {}, versions = {}, files = {}, user = {} }
	local gateDone, exclDone, beforeDone = false, false, false
	for _, src in sources do
		local text = p.files[src.path]
		if text == nil then
			text = M.read(src.path, src.user)
			p.files[src.path] = text
			p.user[src.path] = src.user or nil
		end
		if text == UNREADABLE then
			p.problem = p.problem or ("can't read " .. src.label)
			continue
		elseif type(text) ~= "string" then
			continue
		end
		local get = reader(src.kind, text :: string)
		if not gateDone then
			local v = get(src.gate)
			if v ~= nil then
				gateDone = true
				local secs = seconds(v, unit)
				if secs == nil then
					p.problem = p.problem or ("can't read " .. src.gate .. " in " .. src.label)
				else
					p.minAge = secs
					p.source = p.source or src.label
				end
			end
		end
		local bkey = src.before
		if bkey ~= nil and not beforeDone then
			local v = get(bkey)
			if v ~= nil then
				beforeDone = true
				local at = if v.s ~= nil then time.iso(v.s) else nil
				if at == nil then
					p.problem = p.problem or ("can't read " .. bkey .. " in " .. src.label)
				else
					p.before = at
					p.source = p.source or src.label
				end
			end
		end
		local ekey = src.excl
		if ekey ~= nil and not exclDone then
			local v = get(ekey)
			if v ~= nil then
				-- Present, even as an empty list, it replaces every lower-precedence list.
				exclDone = true
				local list = v.list
				if v.bad then
					p.problem = p.problem or ("can't read " .. ekey .. " in " .. src.label)
				elseif list ~= nil then
					for _, e in list do
						exclude(p, e)
					end
				elseif v.s ~= nil then
					exclude(p, v.s)
				end
			end
		end
	end
	if which == "pnpm" and not gateDone then
		if major ~= nil and pm == "pnpm" and major < 11 then
			p.minAge = 0
		else
			p.minAge = PNPM_DEFAULT
			p.source = "pnpm default"
		end
	end
	return p
end

-- Whether `name` matches an exclusion glob (`*` = any run of characters).
local function matches(glob: string, name: string): boolean
	if not string.find(glob, "*", 1, true) then
		return glob == name
	end
	local pat = string.gsub(glob, "[%^%$%(%)%%%.%[%]%+%-%?%*]", "%%%0")
	pat = string.gsub(pat, "%%%*", ".*")
	return string.find(name, "^" .. pat .. "$") ~= nil
end

function M.gate(p: Policy, name: string, now: number): Gate?
	-- An unreadable config might override the exemptions too, so it holds everything, exempt or not.
	if p.problem ~= nil then
		return { cutoff = 0 }
	end
	for _, g in p.names do
		if matches(g, name) then
			return nil
		end
	end
	local before = p.before
	if p.minAge <= 0 and before == nil then
		return nil
	end
	local cutoff = if p.minAge > 0 then now - p.minAge else math.huge
	if before ~= nil and before < cutoff then
		cutoff = before
	end
	return { cutoff = cutoff, allow = p.versions[name] }
end

-- Where an edit of the minimum release age goes: the project config file of the package manager, its key, and the
-- key's unit in seconds.
type Setting = { name: string, kind: Kind, key: string, unit: number }
local SETTINGS: { [PM]: Setting } = {
	bun = { name = "bunfig.toml", kind = "toml", key = "minimumReleaseAge", unit = 1 },
	pnpm = { name = "pnpm-workspace.yaml", kind = "yaml", key = "minimumReleaseAge", unit = 60 },
	yarn = { name = ".yarnrc.yml", kind = "yaml", key = "npmMinimalAgeGate", unit = 60 },
	npm = { name = ".npmrc", kind = "ini", key = "min-release-age", unit = 86400 },
}

-- The project file an edit writes and the smallest age it can express (npm counts whole days).
function M.setting(p: Policy): (string, number)
	local s = SETTINGS[p.pm]
	return s.name, s.unit
end

-- Splits text into lines (without their endings) and finds its line ending.
local function lines(text: string): ({ string }, string)
	local nl = if string.find(text, "\r\n", 1, true) then "\r\n" else "\n"
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n") do
		table.insert(out, (string.gsub(line, "\r$", "")))
	end
	local last = string.match(text, "([^\n]*)$") or ""
	if last ~= "" then
		table.insert(out, (string.gsub(last, "\r$", "")))
	end
	return out, nl
end

local function escape(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- `text` with `key` set to `value`: the key's line replaced where it is (its trailing comment dropped, as it would
-- describe the old value), else a line added where the format expects it.
local function put(kind: Kind, text: string, key: string, value: string): string
	local ls, nl = lines(text)
	local k = escape(key)
	if kind == "ini" then
		-- npm reads the last occurrence, so that is the one to change.
		local at: number? = nil
		for i, l in ls do
			if string.find(l, "^%s*" .. k .. "%s*=") then
				at = i
			end
		end
		if at then
			ls[at] = key .. "=" .. value
		else
			table.insert(ls, key .. "=" .. value)
		end
	elseif kind == "yaml" then
		for i, l in ls do
			if string.find(l, "^" .. k .. "%s*:") or string.find(l, "^[\"']" .. k .. "[\"']%s*:") then
				ls[i] = key .. ": " .. value
				return table.concat(ls, nl) .. nl
			end
		end
		-- At the top, after a document marker.
		table.insert(ls, if ls[1] == "---" then 2 else 1, key .. ": " .. value)
	else
		-- TOML: the key inside [install], or the dotted top-level form, named as the reader names them (so a quoted
		-- key is replaced, not shadowed by a second one).
		local table_: string? = nil
		local header: number? = nil
		for i, l in ls do
			local t = string.match(l, "^%s*%[([^%]]-)%]")
			local lhs = if t == nil then string.match(l, "^%s*([^#=][^=]-)=") else nil
			if t then
				table_ = tomlKey(t)
				if table_ == "install" and header == nil then
					header = i
				end
			elseif lhs and table_ == "install" and tomlKey(lhs) == key then
				ls[i] = (string.match(l, "^(%s*)") or "") .. key .. " = " .. value
				return table.concat(ls, nl) .. nl
			elseif lhs and table_ == nil and tomlKey(lhs) == "install." .. key then
				ls[i] = "install." .. key .. " = " .. value
				return table.concat(ls, nl) .. nl
			end
		end
		if header then
			table.insert(ls, header + 1, key .. " = " .. value)
		else
			if #ls > 0 and ls[#ls] ~= "" then
				table.insert(ls, "")
			end
			table.insert(ls, "[install]")
			table.insert(ls, key .. " = " .. value)
		end
	end
	return table.concat(ls, nl) .. nl
end

-- Writes the minimum release age `age` (seconds; 0 turns the gate off) into the project's config file for its package
-- manager, in that file's unit, rounded up so the gate never gets shorter than asked. A user-level value is
-- overridden, not changed. Returns the file's name, or false and why.
function M.set(p: Policy, age: number): (boolean, string)
	local s = SETTINGS[p.pm]
	local path = p.root .. "/" .. s.name
	local text = M.read(path)
	if text == UNREADABLE then
		return false, "can't read " .. s.name
	end
	local count = math.ceil(math.max(0, age) / s.unit)
	local out = put(s.kind, if text then text :: string else "", s.key, tostring(count))
	-- The edited file must read back as the age written; a layout the writer doesn't know (a duplicate, an anchor,
	-- a key in another form) is left for a person to edit rather than half-changed.
	local back = reader(s.kind, out)(s.key)
	if back == nil or seconds(back, s.unit) ~= count * s.unit then
		return false, "can't change " .. s.key .. " in " .. s.name .. " safely; edit it by hand"
	end
	local ok, err = pcall(tern.fs.write, path, out)
	if not ok then
		return false, tostring(err)
	end
	return true, s.name
end

return M
