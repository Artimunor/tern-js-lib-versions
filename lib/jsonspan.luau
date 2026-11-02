--!strict
-- Position-aware strict JSON. Like `tern.json.decode`, but objects keep their
-- member order, numbers stay as written, and every string remembers the byte
-- span of its content in the source, so a viewer can point into the file.

-- A string member of a mapping. `from..to` is the byte span of the value's
-- content in the source (inside the quotes when quoted; `to = from - 1` for an
-- empty string). `quote` is set by the YAML reader only.
export type Entry = { key: string, value: string, from: number, to: number, quote: string? }

export type JNode = {
	kind: "object" | "array" | "string" | "number" | "boolean" | "null",
	keys: { string }?, -- object: member names in file order
	items: { JNode }?, -- object: values parallel to `keys`; array: elements
	value: string?, -- string: decoded text; number/boolean/null: literal as written
	from: number?, -- string: content span between the quotes
	to: number?,
}

type ParseError = { msg: string, pos: number }

-- Containers nested deeper than this are refused (the parser recurses).
local MAX_DEPTH = 256

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

local M = {}

-- Parses JSON text; raises a `ParseError` table at the first fault.
function M.parse(src: string): JNode
	local pos = 1

	local function fail(msg: string, at: number?)
		local err: ParseError = { msg = msg, pos = at or pos }
		error(err, 0)
	end

	local function skip()
		pos = string.find(src, "[^ \t\r\n]", pos) or #src + 1
	end

	local function expect(byte: number, what: string)
		skip()
		if string.byte(src, pos) ~= byte then
			fail(if pos > #src then "unexpected end of file, expected " .. what else "expected " .. what)
		end
		pos += 1
	end

	-- The string at `pos` (its opening quote): decoded text and the span of
	-- its raw content between the quotes.
	local function str(): (string, number, number)
		local open = pos
		local from = pos + 1
		pos = from
		local parts: { string }? = nil
		local seg = pos
		while true do
			local at = string.find(src, '["\\%c]', pos)
			if at == nil then
				fail("unterminated string", open)
				return "", from, from - 1
			end
			local b = string.byte(src, at)
			if b == 34 then -- the closing quote
				pos = at + 1
				local last = string.sub(src, seg, at - 1)
				if parts == nil then
					return last, from, at - 1
				end
				table.insert(parts, last)
				return table.concat(parts), from, at - 1
			elseif b == 92 then -- a backslash escape
				local acc = parts or {}
				parts = acc
				table.insert(acc, string.sub(src, seg, at - 1))
				local e = string.sub(src, at + 1, at + 1)
				if e == "u" then
					local hex = string.match(src, "^%x%x%x%x", at + 2)
					if hex == nil then
						fail("\\u needs four hex digits", at)
						return "", from, from - 1
					end
					local code = tonumber(hex, 16) :: number
					local after = at + 6
					if code >= 0xD800 and code <= 0xDBFF then
						local lo = string.match(src, "^\\u(%x%x%x%x)", after)
						local low = if lo then tonumber(lo, 16) :: number else 0
						if low >= 0xDC00 and low <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
							after += 6
						else
							code = 0xFFFD -- a lone high surrogate
						end
					elseif code >= 0xDC00 and code <= 0xDFFF then
						code = 0xFFFD -- a lone low surrogate
					end
					table.insert(acc, utf8.char(code))
					pos = after
				else
					local ch = ESCAPES[e]
					if ch == nil then
						fail("invalid escape \\" .. e, at)
						return "", from, from - 1
					end
					table.insert(acc, ch)
					pos = at + 2
				end
				seg = pos
			elseif b == 127 then
				pos = at + 1 -- DEL may appear unescaped
			else
				fail("control character in a string; it must be escaped", at)
				return "", from, from - 1
			end
		end
	end

	local function number(): JNode
		local start = pos
		if string.byte(src, pos) == 45 then -- -
			pos += 1
		end
		local _, int = string.find(src, "^0", pos)
		if int == nil then
			_, int = string.find(src, "^[1-9]%d*", pos)
		end
		if int == nil then
			fail("invalid number", start)
			return { kind = "null", value = "null" }
		end
		pos = int + 1
		if string.byte(src, pos) == 46 then -- .
			local _, frac = string.find(src, "^%.%d+", pos)
			if frac == nil then
				fail("a digit must follow the decimal point")
				return { kind = "null", value = "null" }
			end
			pos = frac + 1
		end
		local e = string.byte(src, pos)
		if e == 101 or e == 69 then -- e E
			local _, exp = string.find(src, "^[eE][%+%-]?%d+", pos)
			if exp == nil then
				fail("invalid exponent")
				return { kind = "null", value = "null" }
			end
			pos = exp + 1
		end
		return { kind = "number", value = string.sub(src, start, pos - 1) }
	end

	local function literal(word: string)
		if string.sub(src, pos, pos + #word - 1) ~= word then
			fail("unexpected `" .. string.sub(src, pos, pos) .. "`")
		end
		pos += #word
	end

	local value: (depth: number) -> JNode

	local function container(depth: number, object: boolean): JNode
		if depth >= MAX_DEPTH then
			fail("nested deeper than " .. MAX_DEPTH .. " levels")
		end
		local close = if object then 125 else 93 -- } ]
		pos += 1
		local items: { JNode } = {}
		local keys: { string } = {}
		local seen: { [string]: number } = {}
		skip()
		if string.byte(src, pos) == close then
			pos += 1
		else
			while true do
				if object then
					skip()
					if string.byte(src, pos) ~= 34 then
						fail("expected a member name in double quotes")
					end
					local key = str()
					expect(58, "`:` after the member name")
					local v = value(depth + 1)
					local at = seen[key]
					if at then
						items[at] = v -- a duplicate name replaces the earlier value in place
					else
						table.insert(keys, key)
						table.insert(items, v)
						seen[key] = #items
					end
				else
					table.insert(items, value(depth + 1))
				end
				skip()
				local b = string.byte(src, pos)
				if b == close then
					pos += 1
					break
				elseif b ~= 44 then -- ,
					fail(
						if b == nil
							then "unexpected end of file"
							elseif object then "expected `,` or `}`"
							else "expected `,` or `]`"
					)
				end
				pos += 1
			end
		end
		if object then
			return { kind = "object", keys = keys, items = items }
		end
		return { kind = "array", items = items }
	end

	value = function(depth: number): JNode
		skip()
		local b = string.byte(src, pos)
		if b == 123 then -- {
			return container(depth, true)
		elseif b == 91 then -- [
			return container(depth, false)
		elseif b == 34 then -- "
			local text, from, to = str()
			return { kind = "string", value = text, from = from, to = to }
		elseif b == 116 then
			literal("true")
			return { kind = "boolean", value = "true" }
		elseif b == 102 then
			literal("false")
			return { kind = "boolean", value = "false" }
		elseif b == 110 then
			literal("null")
			return { kind = "null", value = "null" }
		elseif b == 45 or (b ~= nil and b >= 48 and b <= 57) then
			return number()
		elseif b == nil then
			fail("unexpected end of file, expected a value")
		else
			fail("unexpected `" .. string.sub(src, pos, pos) .. "`")
		end
		return { kind = "null", value = "null" }
	end

	if string.sub(src, 1, 3) == "\239\187\191" then
		pos = 4 -- a UTF-8 byte order mark
	end
	local root = value(0)
	skip()
	if pos <= #src then
		fail("unexpected text after the JSON value")
	end
	return root
end

-- The member `name` of an object node, or nil.
local function member(node: JNode, name: string): JNode?
	local keys, items = node.keys, node.items
	if node.kind ~= "object" or keys == nil or items == nil then
		return nil
	end
	for i, k in keys do
		if k == name then
			return items[i]
		end
	end
	return nil
end

function M.get(node: JNode?, keypath: { string }): JNode?
	local cur = node
	for _, name in keypath do
		if cur == nil then
			return nil
		end
		cur = member(cur, name)
	end
	return cur
end

function M.strings(node: JNode?): { Entry }
	local out: { Entry } = {}
	if node == nil or node.kind ~= "object" then
		return out
	end
	local keys, items = node.keys, node.items
	if keys == nil or items == nil then
		return out
	end
	for i, k in keys do
		local v = items[i]
		local text, from, to = v.value, v.from, v.to
		if v.kind == "string" and text ~= nil and from ~= nil and to ~= nil then
			table.insert(out, { key = k, value = text, from = from, to = to })
		end
	end
	return out
end

function M.objects(node: JNode?): { { key: string, node: JNode } }
	local out: { { key: string, node: JNode } } = {}
	if node == nil or node.kind ~= "object" then
		return out
	end
	local keys, items = node.keys, node.items
	if keys == nil or items == nil then
		return out
	end
	for i, k in keys do
		local v = items[i]
		if v.kind == "object" then
			table.insert(out, { key = k, node = v })
		end
	end
	return out
end

-- The 1-based line and byte column of byte `pos` in `text`.
function M.line(text: string, pos: number): (number, number)
	local n, start = 1, 1
	while true do
		local nl = string.find(text, "\n", start, true)
		if nl == nil or nl >= pos then
			break
		end
		n += 1
		start = nl + 1
	end
	return n, pos - start + 1
end

return M
