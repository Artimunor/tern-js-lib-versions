--!strict
-- Catalogs of pnpm-workspace.yaml / .yarnrc.yml: the top-level `catalog:` and
-- `catalogs:` block mappings, read line by line. Only a YAML subset is
-- understood: block mappings by space indentation, `#` comments, blank
-- lines, LF or CRLF, plain or quoted keys and values. Other top-level keys
-- and everything nested under them are skipped unread.

local jsonspan = require("./jsonspan")

export type Entry = jsonspan.Entry
export type Catalog = { keypath: { string }, entries: { Entry } } -- {"catalog"} or {"catalogs", name}

-- A catalog being filled, with its entry positions by key (a repeated key
-- replaces the earlier entry in place).
type Acc = { cat: Catalog, index: { [string]: number } }

local M = {}

-- Escapes understood in double-quoted scalars.
local DQ_ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	n = "\n",
	t = "\t",
	r = "\r",
}

local function fail(what: string, line: number)
	error("unsupported YAML in catalog: " .. what .. " (line " .. line .. ")", 0)
end

-- The quoted scalar whose opening quote is at `q` in `line`: decoded text and
-- the position of the closing quote. nil plus a reason when it doesn't close
-- on this line or uses an escape this reader doesn't know.
local function quoted(line: string, q: number): (string?, number, string?)
	if string.sub(line, q, q) == "'" then
		local p = q + 1
		while true do
			local at = string.find(line, "'", p, true)
			if at == nil then
				return nil, 0, "multi-line quoted scalar"
			end
			if string.sub(line, at + 1, at + 1) == "'" then
				p = at + 2 -- '' is an escaped quote
			else
				return (string.gsub(string.sub(line, q + 1, at - 1), "''", "'")), at, nil
			end
		end
	end
	local parts: { string } = {}
	local p = q + 1
	local seg = p
	while true do
		local at = string.find(line, '["\\]', p)
		if at == nil then
			return nil, 0, "multi-line quoted scalar"
		end
		if string.byte(line, at) == 34 then
			table.insert(parts, string.sub(line, seg, at - 1))
			return table.concat(parts), at, nil
		end
		local e = string.sub(line, at + 1, at + 1)
		local ch = DQ_ESCAPES[e]
		if ch == nil then
			return nil, 0, "escape \\" .. e
		end
		table.insert(parts, string.sub(line, seg, at - 1))
		table.insert(parts, ch)
		p = at + 2
		seg = p
	end
end

-- The mapping key starting at `c`: the key and the position after its `:`,
-- or nil plus a reason when the line is not `key:` / `key: value`.
local function keyAt(line: string, c: number): (string?, number, string?)
	local ch = string.sub(line, c, c)
	if ch == "'" or ch == '"' then
		local key, close, bad = quoted(line, c)
		if key == nil then
			return nil, 0, bad
		end
		local _, colon = string.find(line, "^[ \t]*:", close + 1)
		if colon == nil then
			return nil, 0, "quoted key without `:`"
		end
		return key, colon + 1, nil
	end
	local p = c
	while true do
		local at = string.find(line, ":", p, true)
		if at == nil then
			return nil, 0, "line without `key:`"
		end
		local nx = string.sub(line, at + 1, at + 1)
		if nx == "" or nx == " " or nx == "\t" then
			local key = string.match(string.sub(line, c, at - 1), "^(.-)[ \t]*$") :: string
			if key == "" then
				return nil, 0, "empty key"
			end
			if string.find(key, "[ \t]#") then
				return nil, 0, "line without `key:`"
			end
			return key, at + 1, nil
		end
		p = at + 1
	end
end

-- The value after a key's colon (from `p`): text and content span (relative to
-- `line`) and the quote when quoted. Text nil for an empty or null value.
-- The last result is a reason when the value is outside the supported subset.
local function valueAt(line: string, p: number): (string?, number, number, string?, string?)
	local _, e = string.find(line, "^[ \t]*", p)
	local v = (e :: number) + 1
	local ch = string.sub(line, v, v)
	if ch == "" or ch == "#" then
		return nil, 0, 0, nil, nil
	end
	if ch == "'" or ch == '"' then
		local text, close, bad = quoted(line, v)
		if text == nil then
			return nil, 0, 0, nil, bad
		end
		if not string.find(line, "^[ \t]*$", close + 1) and not string.find(line, "^[ \t]+#", close + 1) then
			return nil, 0, 0, nil, "text after a quoted value"
		end
		return text, v + 1, close - 1, ch, nil
	end
	if ch == "{" then
		return nil, 0, 0, nil, "flow mapping"
	elseif ch == "[" then
		return nil, 0, 0, nil, "flow sequence"
	elseif ch == "&" then
		return nil, 0, 0, nil, "anchor"
	elseif ch == "*" then
		return nil, 0, 0, nil, "alias"
	elseif ch == "!" then
		return nil, 0, 0, nil, "tag"
	elseif ch == "|" or ch == ">" then
		return nil, 0, 0, nil, "block scalar"
	end
	local hash = string.find(line, "[ \t]#", v)
	local last = if hash then hash - 1 else #line
	while last > v do
		local b = string.byte(line, last)
		if b ~= 32 and b ~= 9 then
			break
		end
		last -= 1
	end
	local text = string.sub(line, v, last)
	if text == "~" or text == "null" or text == "Null" or text == "NULL" then
		return nil, 0, 0, nil, nil
	end
	return text, v, last, nil, nil
end

-- One `key: value` line of a catalog, its content starting at `c`; `base` is
-- the byte offset of the line in the file.
local function entry(line: string, c: number, base: number, acc: Acc, n: number)
	local ch = string.sub(line, c, c)
	local nx = string.sub(line, c + 1, c + 1)
	if ch == "-" and (nx == "" or nx == " " or nx == "\t") then
		fail("sequence", n)
	elseif ch == "?" and (nx == "" or nx == " " or nx == "\t") then
		fail("complex key", n)
	elseif ch == "&" then
		fail("anchor", n)
	elseif ch == "*" then
		fail("alias", n)
	end
	local key, after, bad = keyAt(line, c)
	if key == nil then
		fail(bad or "line without `key:`", n)
		return
	end
	local text, from, to, quote, vbad = valueAt(line, after)
	if vbad ~= nil then
		fail(vbad, n)
		return
	end
	if text == nil then
		return -- a null member: nothing to show
	end
	local e: Entry = { key = key, value = text, from = base + from, to = base + to, quote = quote }
	local at = acc.index[key]
	if at then
		acc.cat.entries[at] = e
	else
		table.insert(acc.cat.entries, e)
		acc.index[key] = #acc.cat.entries
	end
end

-- Every catalog in the file, in file order. `catalog:` and `catalogs: default:`
-- are both kept under their own keypaths.
local function scan(text: string): { Catalog }
	local list: { Catalog } = {}
	local accs: { [string]: Acc } = {}
	local function open(keypath: { string }): Acc
		local id = table.concat(keypath, "\0")
		local acc = accs[id]
		if acc == nil then
			local made: Acc = { cat = { keypath = keypath, entries = {} }, index = {} }
			accs[id] = made
			table.insert(list, made.cat)
			return made
		end
		return acc
	end

	local section = "" -- "catalog", "catalogs", or anything else (skipped)
	local nameIndent = 0 -- `catalogs:` children
	local entryIndent = 0 -- entries of the current catalog
	local cur: Acc? = nil
	local len = #text
	local pos = if string.sub(text, 1, 3) == "\239\187\191" then 4 else 1
	local n = 0
	while pos <= len do
		n += 1
		local nl = string.find(text, "\n", pos, true)
		local stop = if nl then nl - 1 else len
		if stop >= pos and string.byte(text, stop) == 13 then
			stop -= 1 -- CRLF
		end
		local line = string.sub(text, pos, stop)
		local base = pos - 1
		pos = if nl then nl + 1 else len + 1

		local _, ie = string.find(line, "^ *")
		local indent = ie :: number
		local c = indent + 1
		if string.find(line, "^[ \t]*$", c) or string.find(line, "^[ \t]*#", c) then
			continue -- blank or comment
		end
		local inCatalog = section == "catalog" or section == "catalogs"

		if indent == 0 then
			if string.sub(line, 1, 1) == "\t" then
				if inCatalog then
					fail("tab indentation", n)
				end
				continue
			end
			if line == "---" or line == "..." or string.find(line, "^%-%-%-[ \t]") then
				section = ""
				continue
			end
			local key, after = keyAt(line, 1)
			if key == "catalog" or key == "catalogs" then
				local value, _, _, _, bad = valueAt(line, after)
				if bad ~= nil then
					fail(bad, n)
				elseif value ~= nil then
					fail("`" .. key .. "` is not a block mapping", n)
				end
				section = key
				entryIndent = 0
				nameIndent = 0
				cur = if key == "catalog" then open({ "catalog" }) else nil
			else
				section = "other"
			end
			continue
		end
		if not inCatalog then
			continue
		end

		if section == "catalogs" then
			if nameIndent == 0 then
				nameIndent = indent
			end
			if indent == nameIndent then
				local key, after, bad = keyAt(line, c)
				if key == nil then
					fail(bad or "line without `key:`", n)
					continue
				end
				local value, _, _, _, vbad = valueAt(line, after)
				if vbad ~= nil then
					fail(vbad, n)
				elseif value ~= nil then
					fail("catalog `" .. key .. "` is not a block mapping", n)
				end
				cur = open({ "catalogs", key })
				entryIndent = 0
				continue
			elseif indent < nameIndent then
				fail("inconsistent indentation", n)
			end
		end

		local acc = cur
		if acc == nil then
			continue
		end
		if entryIndent == 0 then
			entryIndent = indent
		end
		if indent > entryIndent then
			fail("nested block", n)
		elseif indent < entryIndent then
			fail("inconsistent indentation", n)
		end
		entry(line, c, base, acc, n)
	end
	return list
end

function M.catalogs(text: string): { [string]: Catalog }
	local list = scan(text)
	local top = false
	for _, cat in list do
		if cat.keypath[1] == "catalog" then
			top = true
		end
	end
	local out: { [string]: Catalog } = {}
	for _, cat in list do
		local kp = cat.keypath
		if kp[1] == "catalog" then
			out.default = cat
		elseif kp[2] == "default" then
			if not top then
				out.default = cat
			end
		else
			out[kp[2]] = cat
		end
	end
	return out
end

function M.find(text: string, keypath: { string }, key: string): Entry?
	for _, cat in scan(text) do
		local kp = cat.keypath
		if #kp == #keypath and kp[1] == keypath[1] and kp[2] == keypath[2] then
			for _, e in cat.entries do
				if e.key == key then
					return e
				end
			end
			return nil
		end
	end
	return nil
end

-- A one-line flow sequence of scalars starting at its `[` (position `p`):
-- the items (`[]` gives none), or nil when it doesn't close on the line or nests.
local function flowSeq(line: string, p: number): { string }?
	local items: { string } = {}
	p += 1
	while true do
		local _, e = string.find(line, "^[ \t]*", p)
		p = (e :: number) + 1
		local ch = string.sub(line, p, p)
		if ch == "]" then
			break
		elseif ch == "" then
			return nil
		elseif ch == "'" or ch == '"' then
			local text, close = quoted(line, p)
			if text == nil then
				return nil
			end
			table.insert(items, text)
			p = close + 1
		else
			local stop = string.find(line, "[,%]]", p)
			if stop == nil then
				return nil
			end
			local text = string.match(string.sub(line, p, stop - 1), "^(.-)[ \t]*$") :: string
			if string.find(text, "^[%[{&%*!|>#]") then
				return nil
			end
			table.insert(items, text)
			p = stop
		end
		local _, e2 = string.find(line, "^[ \t]*", p)
		p = (e2 :: number) + 1
		ch = string.sub(line, p, p)
		if ch == "]" then
			break
		elseif ch ~= "," then
			return nil
		end
		p += 1
	end
	if not string.find(line, "^[ \t]*$", p + 1) and not string.find(line, "^[ \t]+#", p + 1) then
		return nil
	end
	return items
end

-- A top-level key's value and how it stood: "ok" (a scalar or a list, possibly empty), "null" (`~`, `null`, or
-- nothing), "absent", or "bad" (present in a shape this reader doesn't support — callers must not read it as absent).
function M.top(text: string, key: string): ((string | { string })?, "ok" | "null" | "absent" | "bad")
	local len = #text
	local pos = if string.sub(text, 1, 3) == "\239\187\191" then 4 else 1
	local items: { string }? = nil -- collecting the block sequence of `key`
	while pos <= len do
		local nl = string.find(text, "\n", pos, true)
		local stop = if nl then nl - 1 else len
		if stop >= pos and string.byte(text, stop) == 13 then
			stop -= 1 -- CRLF
		end
		local line = string.sub(text, pos, stop)
		pos = if nl then nl + 1 else len + 1

		local _, ie = string.find(line, "^[ \t]*")
		local c = (ie :: number) + 1
		if c > #line or string.sub(line, c, c) == "#" then
			continue -- blank or comment
		end
		local list = items
		if list ~= nil then
			local nx = string.sub(line, c + 1, c + 1)
			if string.sub(line, c, c) == "-" and (nx == "" or nx == " " or nx == "\t") then
				local value, _, _, _, bad = valueAt(line, c + 1)
				if bad ~= nil then
					return nil, "bad"
				end
				if value ~= nil then
					table.insert(list, value)
				end
				continue
			elseif c > 1 then
				return nil, "bad" -- a nested shape this reader doesn't know
			end
			if #list > 0 then
				return list, "ok"
			end
			return nil, "null"
		end
		if c == 1 then
			local k, after = keyAt(line, 1)
			if k == key then
				local _, e = string.find(line, "^[ \t]*", after)
				local v = (e :: number) + 1
				local ch = string.sub(line, v, v)
				if ch == "[" then
					local seq = flowSeq(line, v)
					if seq == nil then
						return nil, "bad"
					end
					return seq, "ok"
				elseif ch == "" or ch == "#" then
					items = {}
					continue
				end
				local value, _, _, _, bad = valueAt(line, after)
				if bad ~= nil then
					return nil, "bad"
				end
				if value == nil then
					return nil, "null"
				end
				return value, "ok"
			end
		end
	end
	local list = items
	if list == nil then
		return nil, "absent"
	end
	if #list > 0 then
		return list, "ok"
	end
	return nil, "null"
end

return M
