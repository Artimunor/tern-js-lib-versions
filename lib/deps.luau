--!strict
-- The only reader and writer of project files. `load` turns a package.json (and the workspace catalog its
-- `catalog:` specs point at) into a `Doc` of rows; `apply` rewrites one spec in place.
--
-- Catalogs: pnpm `pnpm-workspace.yaml` (`catalog:` / `catalogs:`), Bun root package.json
-- (`workspaces.catalog(s)` or top-level `catalog(s)`) and Yarn `.yarnrc.yml` (`catalog:` / `catalogs:`), found by
-- walking up from the package.json's folder to the first workspace root (or the folder holding `.git`).
--
-- The project's package manager and its minimum release age come from `policy` (config files only). A doc keeps
-- the exact bytes of every file it was built from (`watch`), the presence of every path that decided its root,
-- catalog or package manager (`present`) and its policy's files, so a change to any of them rebuilds it.

local spec = require("./spec")
local jsonspan = require("./jsonspan")
local yamlcat = require("./yamlcat")
local policy = require("./policy")

type Spec = spec.Spec
type Entry = jsonspan.Entry
type JNode = jsonspan.JNode
type Policy = policy.Policy

-- Larger files are refused: a package.json or workspace file is a few KiB.
local MAX_BYTES = 1024 * 1024

-- Dependency maps of a package.json, in the order they are shown.
local SECTIONS = { "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }

local M = {}

-- Where an update writes: the string value of `key` in the object at `keypath` of `file`.
export type Target = { file: string, fmt: "json" | "yaml", keypath: { string }, key: string, spec: string }

-- Lockfiles and workspace files that mark a project root, as the package manager would see it.
local ROOT_MARKERS = { "bun.lock", "bun.lockb", "pnpm-lock.yaml", "yarn.lock", "package-lock.json", "npm-shrinkwrap.json", "pnpm-workspace.yaml" }

export type Row = {
	id: string, -- "<section>|<name>": unique in the doc, the table row id
	section: string,
	name: string, -- the dependency name as written
	raw: string, -- the spec as written in package.json
	spec: Spec, -- the effective spec (a catalog reference resolved)
	pkg: string?, -- registry name to check (the alias target for npm: specs); nil when not checked
	target: Target?, -- where an update writes; nil when the row can't be updated
	source: string?, -- "catalog", "catalog:legacy", "npm:semver", …
	sourceTitle: string?, -- e.g. "pnpm-workspace.yaml › catalogs.legacy"
	note: string?, -- why the row isn't checked or can't be updated
}

export type Section = { name: string, rows: { Row } }

export type Doc = {
	path: string,
	pkgName: string?,
	pkgVersion: string?,
	sections: { Section },
	rows: { [string]: Row },
	names: { [string]: boolean }, -- registry names the rows check
	list: { string }, -- the same names, as a list for registry.ensure
	root: string, -- the project root the policy was read from
	policy: Policy?, -- nil while package.json can't be parsed
	watch: { [string]: string | false }, -- project files the doc was built from → the exact bytes read (false: absent)
	present: { [string]: boolean }, -- paths whose existence decided the root, the catalog or the package manager
	catalogFile: string?, -- the workspace file the catalog came from
	catalogLabel: string?, -- its file name
	problem: { msg: string, line: number?, col: number? }?,
	catalogProblem: string?,
}

type CatalogMap = { [string]: { keypath: { string }, map: { [string]: Entry } } }

type Catalogs = {
	file: string,
	fmt: "json" | "yaml",
	label: string,
	cats: CatalogMap,
}

-- Reads a project file of at most MAX_BYTES. The capped read also refuses symlinks; project files come from the
-- repository, so a refused one is never read uncapped (a symlink to a device would never end).
local function read(path: string): (string?, string?)
	local ok, res = pcall(tern.fs.read, path, MAX_BYTES)
	if ok then
		return res, nil
	end
	return nil, tostring(res)
end

-- A watched file's state: its text, "\0" when it exists but can't be read, false when absent.
local function snap(path: string): string | false
	local text = read(path)
	if text then
		return text
	end
	return if tern.fs.exists(path) then "\0" else false
end

-- What a doc was built from, so `load` can tell when to rebuild: files by their exact bytes as read for the build,
-- and paths whose mere presence decided something (lockfiles, workspace files, `.git`).
type Seen = { watch: { [string]: string | false }, present: { [string]: boolean } }

local function probe(seen: Seen, path: string): boolean
	local yes = tern.fs.exists(path)
	seen.present[path] = yes
	return yes
end

-- Reads `path` for a build and records exactly what was read.
local function take(seen: Seen, path: string): (string?, string?)
	local text, err = read(path)
	seen.watch[path] = if text then text elseif tern.fs.exists(path) then "\0" else false
	return text, err
end

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function dirname(path: string): string?
	local dir = string.match(path, "^(.*)/[^/]*$")
	if dir == nil then
		return nil
	end
	return if dir == "" then "/" else dir
end

local function join(dir: string, name: string): string
	return if dir == "/" then "/" .. name else dir .. "/" .. name
end

local function concat(a: { string }, b: { string }): { string }
	local out = table.clone(a)
	for _, s in b do
		table.insert(out, s)
	end
	return out
end

local function index(entries: { Entry }): { [string]: Entry }
	local map: { [string]: Entry } = {}
	for _, e in entries do
		map[e.key] = e
	end
	return map
end

-- Catalogs a package.json defines: `workspaces.catalog(s)` (Bun) or top-level `catalog(s)`; the first base that
-- defines any wins. Each comes with the keypath of its object, for showing and for edits.
local function json_catalogs(root: JNode): { { label: string, keypath: { string }, name: string, entries: { Entry } } }
	for _, base in { { "workspaces" }, {} } do
		local found = {}
		local default = jsonspan.get(root, concat(base, { "catalog" }))
		if default and default.kind == "object" then
			table.insert(found, {
				label = table.concat(concat(base, { "catalog" }), "."),
				keypath = concat(base, { "catalog" }),
				name = "default",
				entries = jsonspan.strings(default),
			})
		end
		for _, named in jsonspan.objects(jsonspan.get(root, concat(base, { "catalogs" }))) do
			local keypath = concat(base, { "catalogs", named.key })
			table.insert(found, {
				label = table.concat(keypath, "."),
				keypath = keypath,
				name = named.key,
				entries = jsonspan.strings(named.node),
			})
		end
		if #found > 0 then
			return found
		end
	end
	return {}
end

local function json_catalog_map(root: JNode): CatalogMap
	local cats: CatalogMap = {}
	for _, c in json_catalogs(root) do
		-- `catalogs.default` stands in for the default catalog only when there is no `catalog`.
		if cats[c.name] == nil then
			cats[c.name] = { keypath = c.keypath, map = index(c.entries) }
		end
	end
	return cats
end

local function yaml_catalog_map(text: string): CatalogMap
	local cats: CatalogMap = {}
	for name, c in yamlcat.catalogs(text) do
		cats[name] = { keypath = c.keypath, map = index(c.entries) }
	end
	return cats
end

-- The workspace catalogs for a package.json at `path` (whose parsed root is `own`), or nil and why not.
local function find_catalogs(seen: Seen, path: string, own: JNode): (Catalogs?, string?)
	local dir = dirname(path)
	while dir do
		local pnpm = join(dir, "pnpm-workspace.yaml")
		if probe(seen, pnpm) then
			local text, err = take(seen, pnpm)
			if text == nil then
				return nil, err
			end
			local ok, cats = pcall(yaml_catalog_map, text)
			if not ok then
				return nil, "pnpm-workspace.yaml: " .. tostring(cats)
			end
			return { file = pnpm, fmt = "yaml", label = "pnpm-workspace.yaml", cats = cats }, nil
		end

		local manifest = join(dir, "package.json")
		local root: JNode? = nil
		if manifest == path then
			root = own
		elseif probe(seen, manifest) then
			local text = take(seen, manifest)
			if text then
				local ok, parsed = pcall(jsonspan.parse, text)
				if ok and parsed.kind == "object" then
					root = parsed
				end
			end
		end
		if root then
			local cats = json_catalog_map(root)
			if next(cats) then
				local label = if manifest == path then "package.json" else "root package.json"
				return { file = manifest, fmt = "json", label = label, cats = cats }, nil
			end
		end

		local yarnrc = join(dir, ".yarnrc.yml")
		if probe(seen, yarnrc) then
			local text = take(seen, yarnrc)
			if text then
				local ok, cats = pcall(yaml_catalog_map, text)
				if not ok then
					return nil, ".yarnrc.yml: " .. tostring(cats)
				end
				if next(cats) then
					return { file = yarnrc, fmt = "yaml", label = ".yarnrc.yml", cats = cats }, nil
				end
			end
		end

		-- A workspace root or the repository's top ends the walk.
		if (root and jsonspan.get(root, { "workspaces" })) or probe(seen, join(dir, ".git")) then
			break
		end
		dir = if dir == "/" then nil else dirname(dir)
	end
	return nil, "no workspace catalog found"
end

-- A row for dependency `e` of the map at `keypath`, resolving catalog references through `catalogs`.
local function make_row(
	section: string,
	keypath: { string },
	path: string,
	e: Entry,
	ownCatalog: boolean,
	catalogs: Catalogs?,
	catalogErr: string?
): Row
	local s = spec.parse(e.value)
	local row: Row = { id = section .. "|" .. e.key, section = section, name = e.key, raw = e.value, spec = s }
	local target: Target? = { file = path, fmt = "json", keypath = keypath, key = e.key, spec = e.value }

	if s.kind == "catalog" then
		target = nil
		local name = s.catalog or "default"
		if ownCatalog then
			row.note = "a catalog entry can't point at a catalog"
		elseif catalogs == nil then
			row.note = catalogErr or "no workspace catalog found"
		else
			local cat = catalogs.cats[name]
			local ce = if cat then cat.map[e.key] else nil
			if cat == nil then
				row.note = "no catalog `" .. name .. "` in " .. catalogs.label
			elseif ce == nil then
				row.note = "`" .. e.key .. "` isn't in " .. catalogs.label .. " › " .. table.concat(cat.keypath, ".")
			else
				row.spec = spec.parse(ce.value)
				row.source = if name == "default" then "catalog" else "catalog:" .. name
				row.sourceTitle = catalogs.label .. " › " .. table.concat(cat.keypath, ".")
				target = {
					file = catalogs.file,
					fmt = catalogs.fmt,
					keypath = cat.keypath,
					key = e.key,
					spec = ce.value,
				}
			end
		end
	end

	local eff = row.spec
	if eff.kind == "range" or eff.kind == "complex" then
		row.pkg = eff.alias or e.key
		if eff.alias then
			local alias = "npm:" .. eff.alias
			row.source = if row.source then row.source .. " · " .. alias else alias
		end
		if eff.kind == "range" then
			row.target = target
		else
			row.note = row.note or "complex range: edit it by hand"
		end
	elseif eff.kind == "catalog" then
		row.note = row.note or "the catalog entry is itself a catalog reference"
	elseif row.note == nil then
		row.note = eff.reason
	end
	return row
end

-- The project root as the package manager sees it: the nearest folder (from the package.json's up) holding a
-- lockfile or pnpm-workspace.yaml, else the one holding `.git`, else the package.json's own folder. Every marker
-- looked for is recorded, so one appearing later moves the root.
local function find_root(seen: Seen, path: string): string
	local own = dirname(path) or "/"
	local git: string? = nil
	local dir: string? = own
	while dir do
		local found = false
		for _, marker in ROOT_MARKERS do
			if probe(seen, join(dir, marker)) then
				found = true
			end
		end
		if found then
			return dir
		end
		if probe(seen, join(dir, ".git")) and git == nil then
			git = dir
		end
		dir = if dir == "/" then nil else dirname(dir)
	end
	return git or own
end

local function build(path: string, text: string?, readErr: string?, seen: Seen): Doc
	local doc: Doc = {
		path = path,
		sections = {},
		rows = {},
		names = {},
		list = {},
		root = dirname(path) or "/",
		watch = seen.watch,
		present = seen.present,
	}
	if text == nil then
		doc.problem = { msg = readErr or "unreadable" }
		return doc
	end
	local ok, parsed = pcall(jsonspan.parse, text)
	if not ok then
		local err: any = parsed
		if type(err) == "table" and type(err.msg) == "string" and type(err.pos) == "number" then
			local line, col = jsonspan.line(text, err.pos)
			doc.problem = { msg = err.msg, line = line, col = col }
		else
			doc.problem = { msg = tostring(err) }
		end
		return doc
	end
	local root: JNode = parsed
	if root.kind ~= "object" then
		doc.problem = { msg = "package.json must hold a JSON object" }
		return doc
	end
	local name = jsonspan.get(root, { "name" })
	if name and name.kind == "string" then
		doc.pkgName = name.value
	end
	local version = jsonspan.get(root, { "version" })
	if version and version.kind == "string" then
		doc.pkgVersion = version.value
	end

	type List = { label: string, keypath: { string }, entries: { Entry }, own: boolean }
	local lists: { List } = {}
	local refs = false
	for _, section in SECTIONS do
		local entries = jsonspan.strings(jsonspan.get(root, { section }))
		if #entries > 0 then
			table.insert(lists, { label = section, keypath = { section }, entries = entries, own = false })
			for _, e in entries do
				if string.sub(e.value, 1, 8) == "catalog:" then
					refs = true
				end
			end
		end
	end
	-- Catalogs this package.json defines itself (a Bun workspace root) are dependencies too.
	for _, c in json_catalogs(root) do
		if #c.entries > 0 then
			table.insert(lists, { label = c.label, keypath = c.keypath, entries = c.entries, own = true })
		end
	end

	local catalogs: Catalogs? = nil
	local catalogErr: string? = nil
	if refs then
		catalogs, catalogErr = find_catalogs(seen, path, root)
		if catalogs then
			doc.catalogLabel = catalogs.label
			if catalogs.file ~= path then
				doc.catalogFile = catalogs.file
			end
		elseif catalogErr ~= "no workspace catalog found" then
			doc.catalogProblem = catalogErr
		end
	end

	-- The package manager's minimum release age, from the project root's config files and the user's.
	doc.root = find_root(seen, path)
	-- Which package manager runs here also depends on files that only have to exist.
	probe(seen, join(doc.root, ".yarnrc.yml"))
	local manifest: JNode? = root
	local rootManifest = join(doc.root, "package.json")
	if rootManifest ~= path then
		manifest = nil
		local rtext = take(seen, rootManifest)
		if rtext then
			local okr, parsedRoot = pcall(jsonspan.parse, rtext)
			if okr and parsedRoot.kind == "object" then
				manifest = parsedRoot
			end
		end
	end
	doc.policy = policy.detect(doc.root, manifest)

	for _, list in lists do
		local section: Section = { name = list.label, rows = {} }
		for _, e in list.entries do
			local row = make_row(list.label, list.keypath, path, e, list.own, catalogs, catalogErr)
			table.insert(section.rows, row)
			doc.rows[row.id] = row
			local pkg = row.pkg
			if pkg and not doc.names[pkg] then
				doc.names[pkg] = true
				table.insert(doc.list, pkg)
			end
		end
		table.insert(doc.sections, section)
	end
	return doc
end

-- Whether anything a doc was built from changed: a watched file's bytes, a probed path's presence, or a
-- package-manager config file.
local function stale(doc: Doc): boolean
	for file, was in doc.watch do
		if snap(file) ~= was then
			return true
		end
	end
	for file, was in doc.present do
		if tern.fs.exists(file) ~= was then
			return true
		end
	end
	local p = doc.policy
	return p ~= nil and policy.changed(p)
end

-- The doc for the package.json at `path`; nil when `prev` is given and nothing it was built from changed.
function M.load(path: string, prev: Doc?): Doc?
	if prev and not stale(prev) then
		return nil
	end
	local seen: Seen = { watch = {}, present = {} }
	local text, err = take(seen, path)
	return build(path, text, err, seen)
end

-- Characters a plain YAML scalar can't start with.
local YAML_INDICATOR = "^[>|*&!%%@`'\"{}%[%],#?:]"

-- `s` as a YAML scalar replacing one written with `quote`: single quotes doubled inside '…', a plain scalar quoted
-- when YAML would read it as something else. (Double-quoted values never get here: `apply_all` refuses `"` and `\`.)
local function yaml_scalar(s: string, quote: string?): string
	if quote == "'" then
		return (string.gsub(s, "'", "''"))
	elseif quote == nil and (string.find(s, YAML_INDICATOR) or string.find(s, ": ", 1, true) or string.find(s, " #", 1, true) or string.find(s, ":$") or string.find(s, "%s$")) then
		return "'" .. string.gsub(s, "'", "''") .. "'"
	end
	return s
end

-- One spec change: the entry at `target` set to `spec`. `name` is the dependency it updates, for reports.
export type Edit = { target: Target, spec: string, name: string }

-- A file being edited: its text, its entries by keypath (joined by "\0") and key, the splices planned (by entry
-- start, so two edits of one entry collapse or conflict), the edits they carry and, once planned, the new text.
type Splice = { entry: Entry, spec: string, value: string }
type FileEdit = {
	file: string,
	text: string,
	root: JNode?, -- JSON: entries are indexed per keypath on first use
	entries: { [string]: { [string]: Entry } },
	splices: { [number]: Splice },
	edits: { Edit },
	out: string?,
}

-- Reads `file` for editing; nil and why when it isn't exactly `expect` any more or no longer parses.
local function open_edit(file: string, fmt: "json" | "yaml", expect: string | false | nil): (FileEdit?, string?)
	local text, err = read(file)
	if text == nil then
		return nil, basename(file) .. ": " .. tostring(err)
	end
	if text ~= expect then
		return nil, basename(file) .. " changed since it was read; check the versions again"
	end
	local f: FileEdit = { file = file, text = text, entries = {}, splices = {}, edits = {} }
	if fmt == "json" then
		local ok, root = pcall(jsonspan.parse, text)
		if not ok then
			return nil, basename(file) .. " isn't valid JSON now"
		end
		f.root = root
	else
		local ok, cats = pcall(yamlcat.catalogs, text)
		if not ok then
			return nil, basename(file) .. ": " .. tostring(cats)
		end
		for _, c in cats do
			f.entries[table.concat(c.keypath, "\0")] = index(c.entries)
		end
	end
	return f, nil
end

local function entries_at(f: FileEdit, keypath: { string }): { [string]: Entry }
	local k = table.concat(keypath, "\0")
	local map = f.entries[k]
	if map == nil then
		map = if f.root then index(jsonspan.strings(jsonspan.get(f.root, keypath))) else {}
		f.entries[k] = map
	end
	return map
end

-- Writes `edits`, all or nothing: every touched file must still be exactly `watch[file]` (the bytes the doc was
-- built from, so an edit made since - say a tightened release age - is never written over) and hold each edit's
-- old spec, else nothing is written. Each file is read, parsed and written once. A write that fails can't be undone:
-- it is reported, and files already written stay written. Returns the edits written and the errors.
function M.apply_all(edits: { Edit }, watch: { [string]: string | false }): ({ Edit }, { string })
	local files: { [string]: FileEdit } = {}
	local order: { FileEdit } = {}
	for _, e in edits do
		local t = e.target
		if string.find(e.spec, '["\\%c]') then
			return {}, { "refusing to write " .. e.spec }
		end
		local f = files[t.file]
		if f == nil then
			local opened, err = open_edit(t.file, t.fmt, watch[t.file])
			if opened == nil then
				return {}, { err or basename(t.file) }
			end
			f = opened
			files[t.file] = opened
			table.insert(order, opened)
		end
		local where = basename(t.file) .. " › " .. table.concat(t.keypath, ".")
		local entry = entries_at(f, t.keypath)[t.key]
		if entry == nil then
			return {}, { "`" .. t.key .. "` is no longer in " .. where }
		end
		if entry.value ~= t.spec then
			return {}, { where .. " changed: `" .. t.key .. "` is " .. entry.value .. " now" }
		end
		local prev = f.splices[entry.from]
		if prev == nil then
			local value = if t.fmt == "yaml" then yaml_scalar(e.spec, entry.quote) else e.spec
			f.splices[entry.from] = { entry = entry, spec = e.spec, value = value }
			table.insert(f.edits, e)
		elseif prev.spec ~= e.spec then
			return {}, { where .. ": `" .. t.key .. "` can't become both " .. prev.spec .. " and " .. e.spec }
		end
	end

	-- Every file's new text, built in one pass from its splices in file order.
	for _, f in order do
		local starts: { number } = {}
		for at in f.splices do
			table.insert(starts, at)
		end
		table.sort(starts)
		local parts: { string } = {}
		local pos = 1
		for _, at in starts do
			local s = f.splices[at]
			if at < pos then
				return {}, { basename(f.file) .. ": overlapping edits" }
			end
			table.insert(parts, string.sub(f.text, pos, at - 1))
			table.insert(parts, s.value)
			pos = s.entry.to + 1
		end
		table.insert(parts, string.sub(f.text, pos))
		f.out = table.concat(parts)
	end

	local applied: { Edit } = {}
	local errors: { string } = {}
	for _, f in order do
		local ok, werr = pcall(tern.fs.write, f.file, f.out :: string)
		if ok then
			for _, e in f.edits do
				table.insert(applied, e)
			end
		else
			table.insert(errors, basename(f.file) .. ": " .. tostring(werr))
		end
	end
	return applied, errors
end

return M
