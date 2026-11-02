--!strict
-- The "open as text" link: a URL carrying a file path, percent-encoded so any
-- byte survives the trip through a link.

local M = {}

local PREFIX = "js-lib-versions:text?path="

local function encodeByte(c: string): string
	return string.format("%%%02X", string.byte(c))
end

local function decodeHex(h: string): string
	return string.char(tonumber(h, 16) :: number)
end

-- Every byte except A-Z a-z 0-9 - . _ ~ / becomes %XX (uppercase hex).
function M.url(path: string): string
	return PREFIX .. (string.gsub(path, "[^A-Za-z0-9%-%._~/]", encodeByte))
end

-- The path in a link made by `url`; nil for any other URL. A `%` not followed
-- by two hex digits is kept as written.
function M.path(url: string): string?
	if string.sub(url, 1, #PREFIX) ~= PREFIX then
		return nil
	end
	return (string.gsub(string.sub(url, #PREFIX + 1), "%%(%x%x)", decodeHex))
end

return M
