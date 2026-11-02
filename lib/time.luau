--!strict
-- Time helpers: RFC 3339 / ISO 8601 timestamps to epoch seconds, duration
-- strings ("3d", "12 hours") to seconds, and short spans for messages.
-- UTC math is done by hand (days from civil): `os.time(table)` reads local time.

local M = {}

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local UNITS: { [string]: number } = {
	s = 1,
	sec = 1,
	secs = 1,
	second = 1,
	seconds = 1,
	m = 60,
	min = 60,
	mins = 60,
	minute = 60,
	minutes = 60,
	h = 3600,
	hr = 3600,
	hrs = 3600,
	hour = 3600,
	hours = 3600,
	d = 86400,
	day = 86400,
	days = 86400,
	w = 604800,
	wk = 604800,
	wks = 604800,
	week = 604800,
	weeks = 604800,
}

local function leap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function monthDays(y: number, m: number): number
	if m == 2 and leap(y) then
		return 29
	end
	return DAYS_IN_MONTH[m]
end

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil).
local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = if m > 2 then m - 3 else m + 9
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

function M.iso(s: string): number?
	local ys, mos, ds, rest = string.match(s, "^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)(.-)%s*$")
	if ys == nil or mos == nil or ds == nil or rest == nil then
		return nil
	end
	local y, mo, d = tonumber(ys) :: number, tonumber(mos) :: number, tonumber(ds) :: number
	if mo < 1 or mo > 12 or d < 1 or d > monthDays(y, mo) then
		return nil
	end
	local secs = 0
	if rest ~= "" then
		local hs, mis, tail = string.match(rest, "^[Tt ](%d%d):(%d%d)(.*)$")
		if hs == nil or mis == nil or tail == nil then
			return nil
		end
		local h, mi = tonumber(hs) :: number, tonumber(mis) :: number
		local sec = 0
		local ss, frac, after = string.match(tail, "^:(%d%d)([%.,]?%d*)(.*)$")
		if ss ~= nil and frac ~= nil and after ~= nil then
			sec = tonumber(ss) :: number
			if frac ~= "" and not string.find(frac, "^[%.,]%d+$") then
				return nil
			end
			tail = after
		end
		local offset = 0
		if tail == "Z" or tail == "z" then
			offset = 0
		elseif tail ~= "" then
			local sign, ohs, oms = string.match(tail, "^([%+%-])(%d%d):?(%d%d)$")
			if sign == nil then
				sign, ohs = string.match(tail, "^([%+%-])(%d%d)$")
				oms = "00"
			end
			if sign == nil or ohs == nil or oms == nil then
				return nil
			end
			local oh, om = tonumber(ohs) :: number, tonumber(oms) :: number
			if oh > 23 or om > 59 then
				return nil
			end
			offset = (oh * 3600 + om * 60) * (if sign == "-" then -1 else 1)
		end
		if h > 23 or mi > 59 or sec > 60 then
			return nil
		end
		if tail == "" then
			-- A date-time without a zone is local time, as JavaScript's Date (npm's `before`) reads it; Tern's
			-- os.time reads a date table as local time.
			return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
		end
		-- fractional seconds are dropped: whole epoch seconds are precise enough
		secs = h * 3600 + mi * 60 + sec - offset
	end
	return daysFromCivil(y, mo, d) * 86400 + secs
end

function M.duration(v: string | number, unit: number): number?
	if type(v) == "number" then
		if v ~= v or v < 0 or v == math.huge then
			return nil
		end
		return v * unit
	end
	local num, word = string.match(v, "^%s*(%d*%.?%d*)%s*(%a*)%s*$")
	if num == nil or word == nil or not string.find(num, "%d") then
		return nil
	end
	local n = tonumber(num)
	if n == nil then
		return nil
	end
	if word == "" then
		return n * unit
	end
	local per = UNITS[string.lower(word)]
	if per == nil then
		return nil
	end
	return n * per
end

local function plural(n: number, one: string, many: string): string
	return tostring(n) .. " " .. (if n == 1 then one else many)
end

function M.span(s: number): string
	if s ~= s or s < 0 then
		s = 0
	end
	if s < 60 then
		return math.floor(s) .. " s"
	elseif s < 3600 then
		return math.floor(s / 60) .. " min"
	elseif s < 86400 then
		return math.floor(s / 3600) .. " h"
	elseif s < 14 * 86400 then
		return plural(math.floor(s / 86400), "day", "days")
	end
	return plural(math.floor(s / 604800), "week", "weeks")
end

return M
