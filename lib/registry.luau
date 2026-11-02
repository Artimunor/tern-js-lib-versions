--!strict
-- npm version lookups (host half): the plugin's only network caller. One deps.dev request per package gives every
-- version with its publish time and the latest tag; the gate (minimum release age) is applied per query in `get`.
-- One cache per host VM, shared by every block; persisted to <data>/registry.json once per batch.
local spec = require("./spec")
local time = require("./time")

export type Pick = { v: string, t: number } -- version, publish time (epoch s)
export type Offer = { ok: Pick?, newest: Pick? } -- ok: newest the gate allows; newest: ignoring the gate
export type Gate = { cutoff: number, allow: { [string]: boolean }? }
export type Info = {
	state: "ok" | "pending" | "missing" | "error",
	err: string?,
	at: number?,
	latest: string?, -- deps.dev isDefault version (= npm latest tag)
	minor: Offer?, -- candidates in `major` (nil when major nil)
	major: Offer?, -- candidates <= latest (all when latest unknown), any major
}

type Rec = { v: string, t: number, m: number } -- a candidate; m = its major
-- vs: stable, non-deprecated versions, semver-descending: those published within WINDOW before `at`, plus per
-- major the highest older one (answers any gate up to WINDOW exactly).
type Entry = { at: number, missing: boolean?, latest: string?, vs: { Rec } }
type Err = { msg: string, at: number }

local TTL = 3600
local ERROR_WINDOW = 300
local COOLDOWN = 60
local KEEP = 7 * 24 * 3600
local WINDOW = 90 * 24 * 3600
local MAX_INFLIGHT = 6
local TIMEOUT_MS = 15000
local MAX_CACHE_BYTES = 4 * 1024 * 1024
local DEPSDEV = "https://api.deps.dev/v3/systems/npm/packages/"
local HEADERS: { [string]: string } = { Accept = "application/json" }

local entries: { [string]: Entry } = {}
local errs: { [string]: Err } = {} -- by name, memory only
local pending: { [string]: boolean } = {} -- names queued or in flight
local queue: { string } = {}
local qhead, qtail = 1, 0
local inflight = 0
local pausedUntil = 0
local dirty = false
local loaded = false
local path = ""
local settledCb: (string) -> () = function(_: string) end
local wantedCb: (string) -> boolean = function(_: string): boolean
	return true
end

local M = {}

local function warn(...: any)
	tern.log.warn("js-lib-versions registry:", ...)
end

local function short(msg: string): string
	if #msg > 120 then
		return string.sub(msg, 1, 117) .. "..."
	end
	return msg
end

local function descending(a: Rec, b: Rec): boolean
	return spec.compare(a.v, b.v) > 0
end

local function fail(name: string, msg: string, now: number)
	errs[name] = { msg = msg, at = now }
end

local function notify(name: string)
	local ok, err = pcall(settledCb, name)
	if not ok then
		warn("settled callback failed", err)
	end
end

local function persist()
	if not dirty then
		return
	end
	dirty = false
	local now = os.time()
	local out: { [string]: any } = {}
	for name, e in entries do
		if now - e.at < KEEP then
			local vs: { any } = table.create(#e.vs)
			for i, r in e.vs do
				vs[i] = { v = r.v, t = r.t }
			end
			out[name] = { at = e.at, missing = e.missing, latest = e.latest, vs = vs }
		end
	end
	local ok, res = pcall(tern.json.encode, { v = 2, entries = out })
	if not ok then
		warn("cannot encode cache", res)
		return
	end
	local okw, err = pcall(tern.fs.write, path, res)
	if not okw then
		warn("cannot write cache", err)
		dirty = true -- retried when the next batch drains
	end
end

-- The batch is over when nothing is queued or in flight: write the cache.
local function settleBatch()
	if inflight == 0 and qhead > qtail then
		table.clear(queue)
		qhead, qtail = 1, 0
		persist()
	end
end

-- Builds the cache entry from a deps.dev package document fetched at `now`; nil when it has no version list.
local function build(doc: any, now: number): Entry?
	local versions = if type(doc) == "table" then doc.versions else nil
	if type(versions) ~= "table" then
		return nil
	end
	local latest: string? = nil
	local vs: { Rec } = {}
	local older: { [number]: Rec } = {} -- per major, the highest candidate published before the window
	local since = now - WINDOW
	for _, item in versions do
		if type(item) ~= "table" then
			continue
		end
		local key = item.versionKey
		local v = if type(key) == "table" then key.version else nil
		if type(v) ~= "string" then
			continue
		end
		if item.isDefault == true then
			latest = v
		end
		local published = item.publishedAt
		if item.isDeprecated == true or type(published) ~= "string" or not spec.stable(v) then
			continue
		end
		local t = time.iso(published)
		local m = spec.major(v)
		if t == nil or m == nil then
			continue
		end
		local r: Rec = { v = v, t = t, m = m }
		if t >= since then
			table.insert(vs, r)
		else
			local best = older[m]
			if best == nil or spec.compare(v, best.v) > 0 then
				older[m] = r
			end
		end
	end
	for _, r in older do
		table.insert(vs, r)
	end
	table.sort(vs, descending)
	return { at = now, latest = latest, vs = vs }
end

-- Applies one response; raises on a body it can't decode (the caller turns that into an error).
local function handle(name: string, r: FetchResult, now: number)
	local err = r.error
	if err ~= nil then
		pausedUntil = now + COOLDOWN
		fail(name, if r.timed_out then "timed out" else short(err), now)
		return
	end
	local status = r.status
	if status == 429 or status >= 500 then
		pausedUntil = now + COOLDOWN
		fail(name, "HTTP " .. tostring(status), now)
		return
	end
	if status == 404 then
		entries[name] = { at = now, missing = true, vs = {} }
		errs[name] = nil
		dirty = true
		return
	end
	if status ~= 200 then
		fail(name, "HTTP " .. tostring(status), now)
		return
	end
	local okd, doc = pcall(tern.json.decode, r.body)
	if not okd then
		fail(name, "bad JSON", now)
		return
	end
	local e = build(doc, now)
	if e == nil then
		fail(name, "no versions in response", now)
		return
	end
	entries[name] = e
	errs[name] = nil
	dirty = true
end

local complete: (string, FetchResult) -> ()

-- Starts one request; false when tern.fetch raised (the name is then failed, not in flight). The name is one URL
-- path segment: everything but unreserved characters and the scope's `@` is percent-encoded.
local function start(name: string): boolean
	local seg = string.gsub(name, "[^%w%-%._~@]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end)
	local url = DEPSDEV .. seg
	inflight += 1
	local ok, err = pcall(function()
		tern.fetch(url, { headers = HEADERS, timeout_ms = TIMEOUT_MS }, function(r: FetchResult, _cx: any)
			complete(name, r)
		end)
	end)
	if not ok then
		inflight -= 1
		pending[name] = nil
		warn("fetch raised", url, err)
		fail(name, "bad request", os.time())
		return false
	end
	return true
end

-- Starts queued names up to the in-flight cap; returns the names that failed without a request.
local function pump(): { string }
	local failed: { string } = {}
	local now = os.time()
	while inflight < MAX_INFLIGHT and qhead <= qtail do
		local name = queue[qhead]
		queue[qhead] = nil
		qhead += 1
		local okw, keep = pcall(wantedCb, name)
		if not okw then
			warn("wanted callback failed", keep)
		end
		if okw and not keep then
			pending[name] = nil
		elseif now < pausedUntil then
			pending[name] = nil
			fail(name, "deps.dev unavailable, retry later", now)
			table.insert(failed, name)
		elseif not start(name) then
			table.insert(failed, name)
		end
	end
	return failed
end

complete = function(name: string, r: FetchResult)
	local now = os.time()
	local ok, err = pcall(handle, name, r, now)
	if not ok then
		warn("bad response", name, err)
		fail(name, "bad response", now)
	end
	pending[name] = nil
	inflight -= 1
	local failed = pump()
	settleBatch()
	notify(name)
	for _, n in failed do
		notify(n)
	end
end

function M.init(settled: (name: string) -> (), wanted: (name: string) -> boolean)
	if loaded then
		return
	end
	loaded = true
	settledCb = settled
	wantedCb = wanted
	path = tern.plugin.data .. "/registry.json"
	if not tern.fs.exists(path) then
		return
	end
	local ok, text = pcall(tern.fs.read, path, MAX_CACHE_BYTES)
	if not ok then
		warn("cannot read cache", text)
		return
	end
	local okd, doc = pcall(tern.json.decode, text)
	if not okd or type(doc) ~= "table" or type(doc.entries) ~= "table" then
		warn("ignoring bad cache", path)
		return
	end
	if doc.v ~= 2 then
		return -- an older format: refetched on demand
	end
	local now = os.time()
	for name, raw in doc.entries do
		if type(name) ~= "string" or type(raw) ~= "table" or type(raw.at) ~= "number" or now - raw.at >= KEEP then
			continue
		end
		local vs: { Rec } = {}
		if type(raw.vs) == "table" then
			for _, item in raw.vs do
				if type(item) == "table" and type(item.v) == "string" and type(item.t) == "number" then
					local m = spec.major(item.v)
					if m ~= nil then
						table.insert(vs, { v = item.v, t = item.t, m = m })
					end
				end
			end
		end
		entries[name] = {
			at = raw.at,
			missing = if raw.missing == true then true else nil,
			latest = if type(raw.latest) == "string" then raw.latest else nil,
			vs = vs,
		}
	end
end

local function eligible(r: Rec, gate: Gate?): boolean
	if gate == nil or r.t <= gate.cutoff then
		return true
	end
	local allow = gate.allow
	return allow ~= nil and allow[r.v] == true
end

-- The first (newest by semver) record passing `keep`, and the first that also passes the gate.
local function offer(vs: { Rec }, gate: Gate?, keep: (Rec) -> boolean): Offer
	local out: Offer = {}
	for _, r in vs do
		if keep(r) then
			if out.newest == nil then
				out.newest = { v = r.v, t = r.t }
			end
			if eligible(r, gate) then
				out.ok = { v = r.v, t = r.t }
				break
			end
		end
	end
	return out
end

function M.get(name: string, major: number?, gate: Gate?): Info
	local info: Info = { state = "pending" }
	local e = entries[name]
	if e == nil then
		local err = errs[name]
		if err and not pending[name] then
			info.state = "error"
			info.err = err.msg
		end
		return info
	end
	info.at = e.at
	if e.missing then
		info.state = "missing"
		return info
	end
	info.state = "ok" -- also while a refetch runs: stale values stay usable
	local latest = e.latest
	info.latest = latest
	info.major = offer(e.vs, gate, function(r: Rec): boolean
		return latest == nil or spec.compare(r.v, latest) <= 0
	end)
	if major ~= nil then
		local cap = if latest ~= nil and spec.major(latest) == major then latest else nil
		info.minor = offer(e.vs, gate, function(r: Rec): boolean
			return r.m == major and (cap == nil or spec.compare(r.v, cap) <= 0)
		end)
	end
	return info
end

function M.ensure(names: { string }, force: boolean)
	local now = os.time()
	for _, name in names do
		if name == "" or pending[name] then
			continue
		end
		if not force then
			local e = entries[name]
			if e and now - e.at < TTL then
				continue
			end
			local err = errs[name]
			if err and now - err.at < ERROR_WINDOW then
				continue
			end
		end
		pending[name] = true
		qtail += 1
		queue[qtail] = name
	end
	local failed = pump()
	settleBatch()
	for _, name in failed do
		notify(name)
	end
end

-- Clears in-memory errors and the provider pause (used by Refresh before ensure(…, true)).
function M.forget(names: { string })
	for _, name in names do
		errs[name] = nil
	end
	if #names > 0 then
		pausedUntil = 0
	end
end

return M
