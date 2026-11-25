-- Cursor-style live view of agent edits.
--
-- While an agent CLI runs in a Neovim terminal, the project folder is watched.
-- When a file changes on disk and Neovim did not write it, the file is loaded
-- (or reloaded), shown in the editor window at the spot that changed, and every
-- change since the agent first touched it is drawn inline: removed lines in red
-- above, new lines in green. Each change can be kept or undone, one at a time
-- or per file, the way Cursor's Keep / Undo works.
--
-- This works with any agent and any permission mode, because it only looks at
-- the files. Claude's own permission prompts are shown by claudecode.nvim.
local M = {}

local uv = vim.uv or vim.loop
local api = vim.api
local diff = (vim.text and vim.text.diff) or vim.diff

---@class lazyvim_agent.follow.Opts
M.opts = {
	-- watch the project while an agent CLI runs in a Neovim terminal
	watch = true,
	-- show each file the agent edits in the editor window, at the edited spot
	follow = true,
	-- terminal commands that count as agents
	agents = {
		"claude", "codex", "opencode", "cursor-agent", "copilot", "gemini",
		"aider", "crush", "qwen", "grok", "amp", "pi", "q", "goose",
	},
	-- while one of these runs in a terminal (branch switch, stash...), changed
	-- files are only reloaded, not marked as agent edits
	pause_for = { "lazygit", "gitui", "tig" },
	-- a burst touching more files than this is a checkout or a formatter run:
	-- reload only
	max_batch = 30,
	max_file_size = 1024 * 1024,
	-- folders watched at most, for huge projects
	max_dirs = 4000,
}

---@class lazyvim_agent.follow.File
---@field base string[] content before the agent's first change
---@field unknown boolean the file was neither open nor in git, so base is a guess (empty)
---@field opened boolean this module opened the buffer
---@field hunks lazyvim_agent.follow.Hunk[]

---@class lazyvim_agent.follow.Hunk
---@field a1 integer first base line (insertion point when ca == 0)
---@field ca integer base line count
---@field b1 integer first current line (line below the removal when cb == 0)
---@field cb integer current line count

M.files = {} ---@type table<string, lazyvim_agent.follow.File>

local ns = api.nvim_create_namespace("lazyvim_agent_changes")
local ns_hint = api.nvim_create_namespace("lazyvim_agent_hint")
local group = api.nvim_create_augroup("lazyvim_agent_follow", { clear = true })

local root ---@type string? folder being watched
local is_git = false
local manual = false -- watching was turned on by hand
local watchers = {} ---@type table<string, uv.uv_fs_event_t>
local warned_cap = false
local pending = {} ---@type table<string, boolean>
local timer ---@type uv.uv_timer_t?
local agent_terms = {} ---@type table<integer, boolean>
local pause_terms = {} ---@type table<integer, boolean>
local reviewed = {} ---@type table<string, integer> files just reviewed in a Claude diff
local notified = {} ---@type table<string, integer>
local agents_set, pause_set = {}, {}

local skip_dirs = {
	[".git"] = true, node_modules = true, target = true, dist = true, build = true,
	[".venv"] = true, venv = true, __pycache__ = true, [".cache"] = true, vendor = true,
}
local temp_patterns = { "~$", "%.sw[a-p]$", "^%.#", "%.tmp$", "%.tmp%.", "^4913$", "%.lock$" }

-- ── helpers ───────────────────────────────────────────────────────────────

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent" })
end

local function rel(path)
	return root and path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or vim.fn.fnamemodify(path, ":~")
end

---@param lines string[]
local function norm(lines)
	if #lines == 1 and lines[1] == "" then
		return {}
	end
	return lines
end

local function buf_lines(buf)
	return norm(api.nvim_buf_get_lines(buf, 0, -1, false))
end

local function same(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

---@return string[]?
local function read_lines(path)
	local fd = io.open(path, "rb")
	if not fd then
		return
	end
	local data = fd:read("*a")
	fd:close()
	if not data or data:find("\0", 1, true) then
		return -- binary
	end
	local lines = vim.split(data, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	for i, l in ipairs(lines) do
		if l:sub(-1) == "\r" then
			lines[i] = l:sub(1, -2)
		end
	end
	return lines
end

---@return lazyvim_agent.follow.Hunk[]
local function hunks(a, b)
	if #a == 0 and #b == 0 then
		return {}
	end
	local ta = #a > 0 and table.concat(a, "\n") .. "\n" or ""
	local tb = #b > 0 and table.concat(b, "\n") .. "\n" or ""
	local ret = {}
	for _, h in ipairs(diff(ta, tb, { result_type = "indices", algorithm = "histogram" }) or {}) do
		local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
		ret[#ret + 1] = { a1 = ca == 0 and sa + 1 or sa, ca = ca, b1 = cb == 0 and sb + 1 or sb, cb = cb }
	end
	return ret
end

local function find_buf(path)
	for _, b in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_get_name(b) == path then
			return b
		end
	end
end

local function buf_path(buf)
	local name = api.nvim_buf_get_name(buf)
	return name ~= "" and M.files[name] and name or nil
end

local function git(args)
	if not (root and is_git) then
		return
	end
	local cmd = { "git", "-C", root }
	vim.list_extend(cmd, args)
	local ok, res = pcall(function()
		return vim.system(cmd, { text = true }):wait(3000)
	end)
	return ok and res or nil
end

local function is_ignored(path)
	local res = git({ "check-ignore", "-q", "--", path })
	return res and res.code == 0
end

-- the index version, the same baseline gitsigns uses
---@return string[]?
local function git_base(path)
	local res = git({ "show", ":" .. rel(path) })
	if not res or res.code ~= 0 then
		return
	end
	local lines = vim.split(res.stdout or "", "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

local function is_temp(name)
	for _, p in ipairs(temp_patterns) do
		if name:find(p) then
			return true
		end
	end
	return false
end

-- ── drawing ───────────────────────────────────────────────────────────────

local function set_hl()
	local function color(name, attr)
		local hl = api.nvim_get_hl(0, { name = name, link = false })
		if hl.reverse then
			attr = attr == "bg" and "fg" or "bg"
		end
		return hl[attr]
	end
	api.nvim_set_hl(0, "LazyVimAgentAdd", { bg = color("DiffAdd", "bg") or 0x2a4a2a, default = true })
	api.nvim_set_hl(0, "LazyVimAgentDelete", {
		bg = color("DiffDelete", "bg") or 0x4a2a2a,
		fg = color("Normal", "fg"),
		default = true,
	})
	api.nvim_set_hl(0, "LazyVimAgentHint", { link = "DiagnosticVirtualTextHint", default = true })
end

local function key_label(lhs)
	local leader = vim.g.mapleader or "\\"
	return (lhs:gsub("<leader>", leader == " " and "␣" or leader))
end

---@param buf integer
---@return lazyvim_agent.follow.Hunk?, integer?
local function hunk_at_cursor(buf)
	local path = buf_path(buf)
	local f = path and M.files[path]
	if not f or not f.hunks then
		return
	end
	local win = api.nvim_get_current_win()
	if api.nvim_win_get_buf(win) ~= buf then
		win = vim.fn.bufwinid(buf)
		if win == -1 then
			return
		end
	end
	local l = api.nvim_win_get_cursor(win)[1]
	local n = api.nvim_buf_line_count(buf)
	for i, h in ipairs(f.hunks) do
		if h.cb > 0 and l >= h.b1 and l < h.b1 + h.cb then
			return h, i
		end
		if h.cb == 0 and (l == h.b1 or (h.b1 > n and l == n)) then
			return h, i
		end
	end
end

local function update_hint(buf)
	if not api.nvim_buf_is_valid(buf) then
		return
	end
	api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
	local h = hunk_at_cursor(buf)
	if not h then
		return
	end
	local row = math.min(math.max(h.b1 - 1, 0), api.nvim_buf_line_count(buf) - 1)
	local text = ("  agent: +%d −%d · keep %s · undo %s "):format(h.cb, h.ca, key_label("<leader>ay"), key_label("<leader>an"))
	api.nvim_buf_set_extmark(buf, ns_hint, row, 0, {
		virt_text = { { text, "LazyVimAgentHint" } },
		virt_text_pos = "eol",
		hl_mode = "combine",
	})
end

local function delete_buf(buf, force)
	if _G.Snacks and Snacks.bufdelete then
		Snacks.bufdelete({ buf = buf, force = force })
	else
		pcall(vim.cmd, (force and "bdelete! " or "bdelete ") .. buf)
	end
end

local function untrack(path)
	M.files[path] = nil
	local buf = find_buf(path)
	if buf and api.nvim_buf_is_valid(buf) then
		api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
	end
end

---@param buf integer
function M.render(buf)
	if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
		return
	end
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local path = buf_path(buf)
	local f = path and M.files[path]
	if not f then
		return
	end
	local cur = buf_lines(buf)
	f.hunks = hunks(f.base, cur)
	if #f.hunks == 0 then
		untrack(path)
		return
	end
	local n = #cur
	local width = vim.o.columns
	local tab = string.rep(" ", vim.bo[buf].tabstop)
	for _, h in ipairs(f.hunks) do
		for l = h.b1, h.b1 + h.cb - 1 do
			api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { line_hl_group = "LazyVimAgentAdd", priority = 20 })
		end
		if h.ca > 0 then
			local virt = {}
			for l = h.a1, h.a1 + h.ca - 1 do
				local text = (f.base[l] or ""):gsub("\t", tab)
				local pad = math.max(0, width - vim.fn.strdisplaywidth(text))
				virt[#virt + 1] = { { text .. string.rep(" ", pad), "LazyVimAgentDelete" } }
			end
			local row, above = h.b1 - 1, true
			if row >= n then
				row, above = math.max(n - 1, 0), n == 0
			end
			api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = virt, virt_lines_above = above })
		end
	end
	update_hint(buf)
end

local function attach(buf)
	if vim.b[buf].lazyvim_agent_attached then
		return
	end
	vim.b[buf].lazyvim_agent_attached = true
	local scheduled = false
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		buffer = buf,
		callback = function()
			if scheduled or not buf_path(buf) then
				return
			end
			scheduled = true
			vim.defer_fn(function()
				scheduled = false
				M.render(buf)
			end, 50)
		end,
	})
	api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			update_hint(buf)
		end,
	})
end

-- ── following ─────────────────────────────────────────────────────────────

local function editor_win()
	local function usable(win)
		if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
			return false
		end
		local b = api.nvim_win_get_buf(win)
		local ft = vim.bo[b].filetype
		return (vim.bo[b].buftype == "" and ft ~= "neo-tree" and ft ~= "NvimTree") or ft == "snacks_dashboard"
	end
	local prev = vim.fn.win_getid(vim.fn.winnr("#"))
	if prev ~= 0 and usable(prev) then
		return prev
	end
	local best, size
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if usable(win) then
			local s = api.nvim_win_get_width(win) * api.nvim_win_get_height(win)
			if not best or s > size then
				best, size = win, s
			end
		end
	end
	return best
end

local function in_diffview()
	local ok, lib = pcall(require, "diffview.lib")
	return ok and lib.get_current_view() ~= nil
end

local function follow(buf, line)
	if not M.opts.follow or in_diffview() then
		return
	end
	local win = editor_win()
	if not win then
		return
	end
	if win == api.nvim_get_current_win() and api.nvim_win_get_buf(win) ~= buf then
		-- you are working in this window: tell, don't pull the file away
		local path = api.nvim_buf_get_name(buf)
		if (notified[path] or 0) + 3000 < uv.now() then
			notified[path] = uv.now()
			notify(("Agent changed %s · %s jumps there"):format(rel(path), key_label("]x")))
		end
		return
	end
	if api.nvim_win_get_buf(win) ~= buf then
		api.nvim_win_set_buf(win, buf)
	end
	line = math.min(math.max(line, 1), api.nvim_buf_line_count(buf))
	api.nvim_win_set_cursor(win, { line, 0 })
	api.nvim_win_call(win, function()
		vim.cmd("normal! zz")
	end)
end

-- ── handling file changes ─────────────────────────────────────────────────

local watch_dir

local function reload(buf)
	vim.bo[buf].autoread = true
	api.nvim_buf_call(buf, function()
		vim.cmd("silent! checktime " .. buf)
	end)
end

---@return {buf: integer, line: integer}?
local function handle(path, depth)
	local stat = uv.fs_stat(path)
	if not stat then
		-- removed: forget a file the agent created and then deleted
		local f = M.files[path]
		if f then
			local buf = find_buf(path)
			untrack(path)
			if f.opened and buf and not vim.bo[buf].modified then
				delete_buf(buf, false)
			end
		end
		return
	end
	if stat.type == "directory" then
		if (depth or 0) < 3 and not (is_git and is_ignored(path)) and not skip_dirs[vim.fs.basename(path)] then
			watch_dir(path)
			for name, t in vim.fs.dir(path) do
				if t == "file" then
					handle(path .. "/" .. name, (depth or 0) + 1)
				end
			end
		end
		return
	end
	if stat.type ~= "file" or stat.size > M.opts.max_file_size or is_temp(vim.fs.basename(path)) then
		return
	end

	local buf = find_buf(path)
	local loaded = buf and api.nvim_buf_is_loaded(buf)
	if not loaded and is_ignored(path) then
		return
	end
	local new = read_lines(path)
	if not new then
		return
	end
	local prev = loaded and buf_lines(buf) or nil
	if prev and same(prev, new) then
		return -- Neovim wrote it, or nothing changed
	end
	if loaded and vim.bo[buf].modified then
		notify(("Agent changed %s, but it has unsaved edits here. Save it or run :e! to take one side"):format(rel(path)), vim.log.levels.WARN)
		return
	end

	local just_reviewed = reviewed[path] and reviewed[path] + 10000 > uv.now()
	reviewed[path] = nil
	local f = M.files[path]
	if not f and not just_reviewed then
		local base = prev or git_base(path)
		f = { base = base or {}, unknown = base == nil, opened = not loaded, hunks = {} }
		M.files[path] = f
	end

	if loaded then
		reload(buf)
	else
		buf = vim.fn.bufadd(path)
		vim.bo[buf].buflisted = true
		vim.fn.bufload(buf)
	end
	if not M.files[path] then
		return -- reviewed in a Claude diff already: reloaded, nothing to mark
	end
	attach(buf)
	M.render(buf)
	if not M.files[path] then
		return -- the agent put the file back as it was
	end
	local first = hunks(prev or M.files[path].base, buf_lines(buf))[1]
	return { buf = buf, line = first and first.b1 or 1 }
end

local function paused()
	for b in pairs(pause_terms) do
		if api.nvim_buf_is_valid(b) then
			return true
		end
		pause_terms[b] = nil
	end
	return false
end

local function flush()
	local list = vim.tbl_keys(pending)
	pending = {}
	if #list == 0 then
		return
	end
	if paused() or #list > M.opts.max_batch then
		vim.cmd("silent! checktime")
		return
	end
	table.sort(list)
	local last
	for _, path in ipairs(list) do
		local ok, res = pcall(handle, path)
		if ok and res then
			last = res
		elseif not ok then
			notify("lazyvim-agent: " .. tostring(res), vim.log.levels.ERROR)
		end
	end
	if last then
		follow(last.buf, last.line)
	end
end

-- ── watching ──────────────────────────────────────────────────────────────

function watch_dir(dir)
	if watchers[dir] then
		return
	end
	if vim.tbl_count(watchers) >= M.opts.max_dirs then
		if not warned_cap then
			warned_cap = true
			notify(("Watching only the first %d folders of this project"):format(M.opts.max_dirs), vim.log.levels.WARN)
		end
		return
	end
	local w = uv.new_fs_event()
	if not w then
		return
	end
	local ok = w:start(dir, {}, function(err, name)
		if err or not name or name == ".git" then
			return
		end
		pending[dir .. "/" .. name] = true
		if timer and not timer:is_active() then
			timer:start(150, 0, vim.schedule_wrap(flush))
		end
	end)
	if ok then
		watchers[dir] = w
	else
		w:close()
	end
end

local function watch_tree(dir)
	watch_dir(dir)
	if is_git then
		vim.system({ "git", "-C", dir, "ls-files", "-co", "--exclude-standard", "-z" }, { text = true }, function(res)
			if res.code ~= 0 then
				return
			end
			vim.schedule(function()
				if root ~= dir then
					return
				end
				local dirs = {}
				for file in (res.stdout or ""):gmatch("[^%z]+") do
					local d = vim.fs.dirname(file)
					while d and d ~= "." and d ~= "" and not dirs[d] do
						dirs[d] = true
						d = vim.fs.dirname(d)
					end
				end
				for d in pairs(dirs) do
					watch_dir(dir .. "/" .. d)
				end
			end)
		end)
	else
		for name, t in vim.fs.dir(dir, {
			depth = 12,
			skip = function(n)
				local b = vim.fs.basename(n)
				return not skip_dirs[b] and b:sub(1, 1) ~= "."
			end,
		}) do
			if t == "directory" and not skip_dirs[vim.fs.basename(name)] and vim.fs.basename(name):sub(1, 1) ~= "." then
				watch_dir(dir .. "/" .. name)
				if vim.tbl_count(watchers) >= M.opts.max_dirs then
					break
				end
			end
		end
	end
end

---@param dir string
function M.start(dir)
	dir = vim.fs.root(dir, ".git") or dir
	dir = uv.fs_realpath(dir) or dir
	if root == dir then
		return
	end
	M.stop()
	root = dir
	is_git = uv.fs_stat(dir .. "/.git") ~= nil
	warned_cap = false
	timer = timer or uv.new_timer()
	watch_tree(dir)
end

function M.stop()
	for _, w in pairs(watchers) do
		if not w:is_closing() then
			w:stop()
			w:close()
		end
	end
	watchers = {}
	pending = {}
	root = nil
end

function M.watching()
	return root
end

-- ── actions ───────────────────────────────────────────────────────────────

local function save(buf)
	local af = vim.b[buf].autoformat
	vim.b[buf].autoformat = false -- write back exactly what was there
	api.nvim_buf_call(buf, function()
		vim.cmd("silent! lockmarks write")
	end)
	vim.b[buf].autoformat = af
end

local function current()
	local buf = api.nvim_get_current_buf()
	local path = buf_path(buf)
	if not path then
		notify("No agent changes in this file")
		return
	end
	return buf, path, M.files[path]
end

-- the file did not exist for Neovim or git before the agent wrote it
local function undo_unknown(buf, path)
	local choice = vim.fn.confirm(
		("%s was not open and is not in git, so it is probably new.\nDelete it?"):format(rel(path)),
		"&Delete\n&Cancel",
		2
	)
	if choice ~= 1 then
		return
	end
	untrack(path)
	os.remove(path)
	delete_buf(buf, true)
end

---@param scope "hunk"|"file"|"all"
function M.keep(scope)
	if scope == "all" then
		local n = vim.tbl_count(M.files)
		for path in pairs(M.files) do
			untrack(path)
		end
		notify(n > 0 and ("Kept the agent's changes in %d file(s)"):format(n) or "No agent changes")
		return
	end
	local buf, path, f = current()
	if not buf then
		return
	end
	if scope == "file" then
		untrack(path)
		return
	end
	local h = hunk_at_cursor(buf)
	if not h then
		notify("No agent change under the cursor · " .. key_label("]x") .. " jumps to the next one")
		return
	end
	local cur = buf_lines(buf)
	local base = {}
	vim.list_extend(base, f.base, 1, h.a1 - 1)
	vim.list_extend(base, cur, h.b1, h.b1 + h.cb - 1)
	vim.list_extend(base, f.base, h.a1 + h.ca, #f.base)
	f.base = base
	f.unknown = false
	M.render(buf)
end

---@param scope "hunk"|"file"
function M.undo(scope)
	local buf, path, f = current()
	if not buf then
		return
	end
	if f.unknown then
		return undo_unknown(buf, path)
	end
	if scope == "file" then
		api.nvim_buf_set_lines(buf, 0, -1, false, f.base)
	else
		local h = hunk_at_cursor(buf)
		if not h then
			notify("No agent change under the cursor · " .. key_label("]x") .. " jumps to the next one")
			return
		end
		local old = vim.list_slice(f.base, h.a1, h.a1 + h.ca - 1)
		if #buf_lines(buf) == 0 then
			api.nvim_buf_set_lines(buf, 0, -1, false, old)
		else
			api.nvim_buf_set_lines(buf, h.b1 - 1, h.b1 - 1 + h.cb, false, old)
		end
	end
	save(buf)
	M.render(buf)
end

---@param dir 1|-1
function M.jump(dir)
	local buf = api.nvim_get_current_buf()
	local path = buf_path(buf)
	if path then
		local f = M.files[path]
		local l = api.nvim_win_get_cursor(0)[1]
		local n = api.nvim_buf_line_count(buf)
		local lines = {}
		for _, h in ipairs(f.hunks or {}) do
			lines[#lines + 1] = math.min(math.max(h.b1, 1), n)
		end
		for i = dir > 0 and 1 or #lines, dir > 0 and #lines or 1, dir do
			if (dir > 0 and lines[i] > l) or (dir < 0 and lines[i] < l) then
				api.nvim_win_set_cursor(0, { lines[i], 0 })
				vim.cmd("normal! zz")
				return
			end
		end
	end
	-- no more changes here: go to the next file with changes
	local paths = vim.tbl_keys(M.files)
	if #paths == 0 then
		notify("No agent changes to review")
		return
	end
	table.sort(paths)
	local idx = 0
	for i, p in ipairs(paths) do
		if p == path then
			idx = i
		end
	end
	local target = paths[((idx - 1 + dir) % #paths) + 1]
	if idx == 0 then
		target = dir > 0 and paths[1] or paths[#paths]
	end
	vim.cmd.edit(vim.fn.fnameescape(target))
	local tbuf = api.nvim_get_current_buf()
	attach(tbuf)
	M.render(tbuf)
	local f = M.files[target]
	local hs = f and f.hunks or {}
	local h = dir > 0 and hs[1] or hs[#hs]
	if h then
		api.nvim_win_set_cursor(0, { math.min(math.max(h.b1, 1), api.nvim_buf_line_count(tbuf)), 0 })
		vim.cmd("normal! zz")
	end
end

function M.list()
	local items = {}
	for path, f in pairs(M.files) do
		for _, h in ipairs(f.hunks or {}) do
			items[#items + 1] = {
				filename = path,
				lnum = math.max(h.b1, 1),
				text = ("agent: +%d −%d"):format(h.cb, h.ca),
			}
		end
	end
	if #items == 0 then
		notify("No agent changes to review")
		return
	end
	table.sort(items, function(a, b)
		return a.filename == b.filename and a.lnum < b.lnum or a.filename < b.filename
	end)
	vim.fn.setqflist({}, " ", { title = "Agent changes", items = items })
	if _G.Snacks and Snacks.picker then
		Snacks.picker.qflist()
	else
		vim.cmd("copen")
	end
end

function M.toggle_follow()
	M.opts.follow = not M.opts.follow
	notify(M.opts.follow and "Following agent edits" or "Not following agent edits (changes are still marked)")
end

-- for agents running outside Neovim (another terminal window)
function M.toggle_watch()
	if root then
		manual = false
		M.stop()
		notify("Stopped watching for agent edits")
	else
		manual = true
		local dir = (_G.LazyVim and LazyVim.root and LazyVim.root()) or vim.fn.getcwd()
		M.start(dir)
		notify("Watching " .. vim.fn.fnamemodify(root or dir, ":~") .. " for agent edits")
	end
end

-- ── setup ─────────────────────────────────────────────────────────────────

---@param name string
---@return string? cwd, string? exe
local function parse_term(name)
	local cwd, cmd = name:match("^term://(.-)//%d+:(.*)$")
	if not cmd then
		return
	end
	local first = vim.split(vim.trim(cmd), "%s+")[1] or ""
	return vim.fn.expand(cwd), vim.fs.basename(first)
end

local function on_term(buf)
	local cwd, exe = parse_term(api.nvim_buf_get_name(buf))
	if not exe then
		return
	end
	if pause_set[exe] then
		pause_terms[buf] = true
	end
	if agents_set[exe] then
		agent_terms[buf] = true
		if M.opts.watch then
			M.start(cwd ~= "" and cwd or vim.fn.getcwd())
		end
	end
end

local function on_term_gone(buf)
	pause_terms[buf] = nil
	if not agent_terms[buf] then
		return
	end
	agent_terms[buf] = nil
	for b in pairs(agent_terms) do
		if api.nvim_buf_is_valid(b) then
			return
		end
		agent_terms[b] = nil
	end
	if not manual then
		M.stop() -- marked changes stay until you keep or undo them
	end
end

---@param opts? lazyvim_agent.follow.Opts
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
	agents_set, pause_set = {}, {}
	for _, a in ipairs(M.opts.agents) do
		agents_set[a] = true
	end
	for _, a in ipairs(M.opts.pause_for) do
		pause_set[a] = true
	end
	api.nvim_clear_autocmds({ group = group })
	set_hl()
	api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
	api.nvim_create_autocmd("TermOpen", {
		group = group,
		callback = function(ev)
			on_term(ev.buf)
		end,
	})
	api.nvim_create_autocmd({ "TermClose", "BufWipeout" }, {
		group = group,
		callback = function(ev)
			on_term_gone(ev.buf)
		end,
	})
	-- a tracked file opened again after its buffer was deleted
	api.nvim_create_autocmd("BufReadPost", {
		group = group,
		callback = function(ev)
			if buf_path(ev.buf) then
				attach(ev.buf)
				vim.schedule(function()
					M.render(ev.buf)
				end)
			end
		end,
	})
	-- you already reviewed this edit in a Claude diff: don't mark it again
	api.nvim_create_autocmd("User", {
		group = group,
		pattern = "ClaudeCodeDiffClosed",
		callback = function(ev)
			local p = ev.data and ev.data.file_path
			if p then
				reviewed[uv.fs_realpath(p) or p] = uv.now()
			end
		end,
	})
	api.nvim_create_user_command("AgentChanges", function(cmd)
		local sub = cmd.fargs[1] or "list"
		local actions = {
			list = M.list,
			next = function() M.jump(1) end,
			prev = function() M.jump(-1) end,
			keep = function() M.keep("hunk") end,
			undo = function() M.undo("hunk") end,
			keep_file = function() M.keep("file") end,
			undo_file = function() M.undo("file") end,
			keep_all = function() M.keep("all") end,
			follow = M.toggle_follow,
			watch = M.toggle_watch,
		}
		if not actions[sub] then
			return notify("Unknown action: " .. sub, vim.log.levels.ERROR)
		end
		actions[sub]()
	end, {
		nargs = "?",
		desc = "Review agent edits",
		complete = function()
			return { "list", "next", "prev", "keep", "undo", "keep_file", "undo_file", "keep_all", "follow", "watch" }
		end,
	})
	-- agents started before this module loaded
	for _, b in ipairs(api.nvim_list_bufs()) do
		if vim.bo[b].buftype == "terminal" then
			on_term(b)
		end
	end
end

return M
