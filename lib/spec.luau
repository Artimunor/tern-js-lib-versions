--!strict
-- npm dependency specs: classification, version comparison, and rewriting a
-- simple range to a newer version in the style it was written.

export type Spec = {
	kind: "range" | "complex" | "catalog" | "skip",
	raw: string,
	catalog: string?, -- kind "catalog": "default" for "catalog:" and "catalog:default", else the name
	alias: string?, -- "npm:<name>@<range>": the registry package name to check
	aliasPrefix: string?, -- exactly "npm:<name>@" as written
	prefix: string?, -- kind "range": "", "^", "~", ">=" or "="
	v: string?, -- "v" when written with a leading v, else ""
	nums: number?, -- numeric components written before any wildcard (1..3)
	wild: string?, -- wildcard tail as written: "", ".x", ".*", ".x.x" …
	base: string?, -- normalized lower bound "M.m.p" or "M.m.p-pre"
	major: number?, -- kind "range" only
	reason: string?, -- kind "skip"/"complex": why it isn't a simple range
}

local M = {}

local LOCAL_PREFIXES = { "file:", "link:", "portal:", "patch:", "exec:" }
local GIT_PREFIXES = { "git+", "git:", "git@", "github:", "gitlab:", "bitbucket:", "gist:" }

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) :: string
end

local function starts(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

local function startsAny(s: string, prefixes: { string }): boolean
	for _, p in prefixes do
		if starts(s, p) then
			return true
		end
	end
	return false
end

-- A digit string without leading zeros ("007" → "7", "0" stays "0").
local function num(d: string): string
	return (string.gsub(d, "^0+(%d)", "%1"))
end

-- Dot-separated prerelease/build identifiers: none of them empty.
local function validIdents(body: string): boolean
	return not (
		string.sub(body, 1, 1) == "."
		or string.sub(body, -1) == "."
		or string.find(body, "..", 1, true) ~= nil
	)
end

-- "M.m.p" from up to three digit strings, missing parts 0.
local function normalized(parts: { string }): string
	return num(parts[1]) .. "." .. (if parts[2] then num(parts[2]) else "0") .. "." .. (if parts[3]
		then num(parts[3])
		else "0")
end

-- Step 6: a single comparator. Fills `out` and returns true when `s` is one.
local function single(s: string, out: Spec): boolean
	local p = 1
	local prefix = ""
	if string.sub(s, 1, 2) == ">=" then
		prefix = ">="
		p = 3
	else
		local c = string.sub(s, 1, 1)
		if c == "^" or c == "~" or c == "=" then
			prefix = c
			p = 2
		end
	end
	if prefix ~= "" then
		local _, e = string.find(s, "^%s*", p)
		p = (e :: number) + 1
	end
	local v = ""
	if string.sub(s, p, p) == "v" then
		v = "v"
		p += 1
	end
	local first = string.match(s, "^%d+", p)
	if first == nil then
		return false
	end
	local parts: { string } = { first }
	p += #first
	local wildFrom = 0 -- position of the "." that starts the wildcard tail
	for _ = 1, 2 do
		if string.sub(s, p, p) ~= "." then
			break
		end
		local d = string.match(s, "^%d+", p + 1)
		if d ~= nil and wildFrom == 0 then
			table.insert(parts, d)
			p += 1 + #d
		elseif string.find(s, "^[xX%*]", p + 1) then
			if wildFrom == 0 then
				wildFrom = p
			end
			p += 2
		else
			return false
		end
	end
	local pre: string? = nil
	if #parts == 3 then
		local a, b = string.find(s, "^%-[0-9A-Za-z%-%.]+", p)
		if a ~= nil and b ~= nil then
			local body = string.sub(s, a + 1, b)
			if not validIdents(body) then
				return false
			end
			pre = body
			p = b + 1
		end
		local c, d = string.find(s, "^%+[0-9A-Za-z%-%.]+", p)
		if c ~= nil and d ~= nil then
			if not validIdents(string.sub(s, c + 1, d)) then
				return false
			end
			p = d + 1
		end
	end
	if p <= #s then
		return false
	end
	out.kind = "range"
	out.prefix = prefix
	out.v = v
	out.nums = #parts
	out.wild = if wildFrom > 0 then string.sub(s, wildFrom) else ""
	out.base = normalized(parts) .. (if pre then "-" .. pre else "")
	out.major = tonumber(parts[1])
	return true
end

-- Step 7: the first version-looking text in a complex range, normalized.
local function firstVersion(s: string, at: number): string
	local first = string.match(s, "^%d+", at) :: string
	local parts: { string } = { first }
	local p = at + #first
	for _ = 1, 2 do
		local d = string.match(s, "^%.(%d+)", p)
		if d == nil then
			break
		end
		table.insert(parts, d)
		p += 1 + #d
	end
	local base = normalized(parts)
	if #parts == 3 then
		local pre = string.match(s, "^%-([0-9A-Za-z%-%.]+)", p)
		if pre ~= nil and validIdents(pre) then
			base ..= "-" .. pre
		end
	end
	return base
end

-- Steps 3–7 for a trimmed spec (or the range part of an npm: alias).
local function classify(s: string, out: Spec)
	if starts(s, "workspace:") then
		out.reason = "workspace"
		return
	end
	if
		startsAny(s, LOCAL_PREFIXES)
		or starts(s, ".")
		or starts(s, "/")
		or starts(s, "~/")
	then
		out.reason = "local path"
		return
	end
	if startsAny(s, GIT_PREFIXES) then
		out.reason = "git"
		return
	end
	if starts(s, "http://") or starts(s, "https://") then
		out.reason = "url"
		return
	end
	if string.find(s, "/", 1, true) and not starts(s, "@") and not string.find(s, "%s") then
		out.reason = "git" -- owner/repo shorthand
		return
	end
	if
		s == ""
		or string.find(s, "^[xX%*]$")
		or string.find(s, "^[xX%*]%.[xX%*]$")
		or string.find(s, "^[xX%*]%.[xX%*]%.[xX%*]$")
	then
		out.reason = "any version"
		return
	end
	if string.find(s, "^%a") and not string.find(s, "^v%d") and not string.find(s, "%s") then
		out.reason = "dist-tag"
		return
	end
	if single(s, out) then
		return
	end
	local digit = string.find(s, "%d")
	if digit ~= nil then
		out.kind = "complex"
		out.reason = "complex range"
		out.base = firstVersion(s, digit)
		return
	end
	out.reason = "invalid"
end

function M.parse(raw: string): Spec
	local out: Spec = { kind = "skip", raw = raw }
	local s = trim(raw)
	if starts(s, "catalog:") then
		local name = trim(string.sub(s, 9))
		out.kind = "catalog"
		out.catalog = if name == "" then "default" else name
		return out
	end
	if starts(s, "npm:") then
		-- A scoped name starts with "@"; the separator is the next "@".
		local at = string.find(s, "@", if string.sub(s, 5, 5) == "@" then 6 else 5, true)
		if at == nil or at == 5 then
			out.reason = "invalid"
			return out
		end
		local name = string.sub(s, 5, at - 1)
		-- npm package name characters only, so the name can't reshape the registry URL or the file it's written to.
		if not (string.find(name, "^[%w%-%._~]+$") or string.find(name, "^@[%w%-%._~]+/[%w%-%._~]+$")) then
			out.reason = "invalid"
			return out
		end
		out.alias = name
		out.aliasPrefix = string.sub(s, 1, at)
		classify(trim(string.sub(s, at + 1)), out)
		return out
	end
	classify(s, out)
	return out
end

-- A version's numeric core as written (up to three digit strings) and its
-- prerelease; nil when it doesn't start with a number. Leading "v"/"=" ignored.
local function split(version: string): ({ string }?, string?)
	local _, e = string.find(version, "^%s*[=vV]*%s*")
	local p = (e :: number) + 1
	local first = string.match(version, "^%d+", p)
	if first == nil then
		return nil, nil
	end
	local parts: { string } = { first }
	p += #first
	for _ = 1, 2 do
		local d = string.match(version, "^%.(%d+)", p)
		if d == nil then
			break
		end
		table.insert(parts, d)
		p += 1 + #d
	end
	local pre = string.match(version, "^%-([0-9A-Za-z%-%.]+)", p)
	return parts, pre
end

function M.bump(s: Spec, version: string): string?
	if s.kind ~= "range" then
		return nil
	end
	local parts, pre = split(version)
	if parts == nil then
		return nil
	end
	local n = s.nums or 3
	local shown: { string } = {}
	for i = 1, n do
		table.insert(shown, parts[i] or "0")
	end
	local out = (s.aliasPrefix or "") .. (s.prefix or "") .. (s.v or "") .. table.concat(shown, ".") .. (s.wild or "")
	if n == 3 and pre ~= nil then
		out ..= "-" .. pre -- a prerelease target keeps its tag; otherwise the range wouldn't admit it
	end
	return out
end

-- Compares digit strings of any length numerically.
local function cmpNum(a: string, b: string): number
	local x, y = num(a), num(b)
	if #x ~= #y then
		return if #x < #y then -1 else 1
	end
	if x == y then
		return 0
	end
	return if x < y then -1 else 1
end

local function cmpPre(a: string?, b: string?): number
	if a == nil then
		return if b == nil then 0 else 1 -- a release outranks a prerelease
	end
	if b == nil then
		return -1
	end
	local ia, ib = string.split(a, "."), string.split(b, ".")
	for i = 1, math.max(#ia, #ib) do
		local x: string?, y: string? = ia[i], ib[i]
		if x == nil then
			return -1
		end
		if y == nil then
			return 1
		end
		if x ~= y then
			local xn = string.find(x, "^%d+$") ~= nil
			local yn = string.find(y, "^%d+$") ~= nil
			if xn and yn then
				local c = cmpNum(x, y)
				if c ~= 0 then
					return c
				end
			elseif xn then
				return -1
			elseif yn then
				return 1
			else
				return if x < y then -1 else 1
			end
		end
	end
	return 0
end

local ZERO = { "0", "0", "0" }

function M.compare(a: string, b: string): number
	local pa, prea = split(a)
	local pb, preb = split(b)
	local xa = pa or ZERO
	local xb = pb or ZERO
	for i = 1, 3 do
		local c = cmpNum(xa[i] or "0", xb[i] or "0")
		if c ~= 0 then
			return c
		end
	end
	return cmpPre(prea, preb)
end

function M.major(version: string): number?
	local parts = split(version)
	if parts == nil then
		return nil
	end
	return tonumber(parts[1])
end

function M.stable(version: string): boolean
	local parts, pre = split(version)
	return parts ~= nil and pre == nil
end

return M
