-- Pick a saved agent session of the current folder and resume it.
--
-- Lists the sessions Claude Code, Codex and OpenCode saved for the current
-- working directory, newest first, in one picker. The chosen one opens where
-- that agent normally lives: Claude through claudecode.nvim (so it stays
-- connected to Neovim), the others in a sidekick.nvim panel.
--
-- Where the sessions come from:
--   Claude Code  ~/.claude/projects/<folder name with non-alphanumerics as ->/<id>.jsonl
--   Codex        ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, first line has id + cwd;
--                names from ~/.codex/session_index.jsonl
--   OpenCode     `opencode session list --format json` (its sessions live in SQLite)
local M = {}

local uv = vim.uv or vim.loop

---@class lazyvim_agent.Session
---@field agent "claude"|"codex"|"opencode"
---@field id string
---@field title string
---@field time integer last activity, seconds since the epoch
---@field cwd string

M.max_codex_files = 400 -- newest rollout files looked at
M.head_bytes = 256 * 1024 -- how much of a session file is read to find its title

local agents = {
	claude = { label = "Claude", hl = "Special" },
	codex = { label = "Codex", hl = "Function" },
	opencode = { label = "OpenCode", hl = "Constant" },
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent sessions" })
end

local function read_head(path, max)
	local fd = uv.fs_open(path, "r", 438)
	if not fd then
		return
	end
	local data = uv.fs_read(fd, max, 0)
	uv.fs_close(fd)
	return data
end

local function decode(line)
	if line == "" then
		return
	end
	local ok, obj = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	return ok and type(obj) == "table" and obj or nil
end

local function mtime(path)
	local st = uv.fs_stat(path)
	return st and st.mtime.sec or 0
end

--- One line, trimmed, without markup noise.
local function clean(text)
	text = tostring(text or ""):gsub("%s+", " ")
	text = vim.trim(text)
	if #text > 160 then
		text = vim.fn.strcharpart(text, 0, 157) .. "…"
	end
	return text
end

--- Prompts that are not something a person typed: command wrappers, injected context.
local function is_noise(text)
	text = vim.trim(text or "")
	return text == "" or text:sub(1, 1) == "<" or text:find("^Caveat:") ~= nil
end

-- ── Claude Code ───────────────────────────────────────────────────────────

local function claude_projects()
	local home = os.getenv("CLAUDE_CONFIG_DIR") or (vim.env.HOME .. "/.claude")
	return home .. "/projects"
end

--- Claude names a project folder after the path, every non-alphanumeric
--- character (UTF-16 unit, so 2 for characters outside the BMP) turned into "-".
local function claude_folder(cwd)
	return (
		cwd:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
			if #ch == 1 and ch:match("%w") then
				return ch
			end
			return #ch == 4 and "--" or "-"
		end)
	)
end

local function find_claude_dir(cwd)
	local projects = claude_projects()
	local dir = projects .. "/" .. claude_folder(cwd)
	if uv.fs_stat(dir) then
		return dir
	end
	-- very long or unusual paths: look for a session that records this cwd
	local needle = '"cwd":' .. vim.json.encode(cwd)
	for name, t in vim.fs.dir(projects) do
		if t == "directory" then
			for file in vim.fs.dir(projects .. "/" .. name) do
				if file:match("%.jsonl$") then
					local head = read_head(projects .. "/" .. name .. "/" .. file, 64 * 1024) or ""
					if head:find(needle, 1, true) then
						return projects .. "/" .. name
					end
					break
				end
			end
		end
	end
end

local function claude_text(content)
	if type(content) == "string" then
		return content
	end
	if type(content) == "table" then
		for _, part in ipairs(content) do
			if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
				return part.text
			end
		end
	end
end

---@param cwd string
---@return lazyvim_agent.Session[]
function M.claude(cwd)
	local dir = find_claude_dir(cwd)
	if not dir then
		return {}
	end
	local ret = {}
	for file, t in vim.fs.dir(dir) do
		local id = t == "file" and file:match("^(.+)%.jsonl$")
		if id then
			local path = dir .. "/" .. file
			local head = read_head(path, M.head_bytes) or ""
			local title, prompt
			for line in head:gmatch("[^\n]+") do
				local o = decode(line)
				if o then
					if type(o.type) == "string" and o.type:find("title") then
						title = o.customTitle or o.title or o.aiTitle or title
					elseif o.type == "summary" and type(o.summary) == "string" then
						title = title or o.summary
					elseif
						not prompt
						and o.type == "user"
						and not o.isSidechain
						and not o.isMeta
						and type(o.message) == "table"
					then
						local text = claude_text(o.message.content)
						if text and not is_noise(text) then
							prompt = text
						end
					end
				end
			end
			-- a session nobody typed into is not worth resuming
			if prompt or title then
				ret[#ret + 1] = { agent = "claude", id = id, title = clean(title or prompt), time = mtime(path), cwd = cwd }
			end
		end
	end
	return ret
end

-- ── Codex ─────────────────────────────────────────────────────────────────

local function codex_home()
	return os.getenv("CODEX_HOME") or (vim.env.HOME .. "/.codex")
end

local function codex_names()
	local names = {}
	local fd = io.open(codex_home() .. "/session_index.jsonl", "r")
	if not fd then
		return names
	end
	for line in fd:lines() do
		local o = decode(line)
		if o and o.id and type(o.thread_name) == "string" and o.thread_name ~= "" then
			names[o.id] = o.thread_name -- later lines win
		end
	end
	fd:close()
	return names
end

local function codex_prompt(o)
	local p = o.payload
	if type(p) ~= "table" then
		return
	end
	if p.type == "message" and p.role == "user" and type(p.content) == "table" then
		for _, part in ipairs(p.content) do
			if type(part) == "table" and type(part.text) == "string" and not is_noise(part.text) then
				return part.text
			end
		end
	elseif p.type == "user_message" and type(p.message) == "string" and not is_noise(p.message) then
		return p.message
	end
end

---@param cwd string
---@return lazyvim_agent.Session[]
function M.codex(cwd)
	local root = codex_home() .. "/sessions"
	if not uv.fs_stat(root) then
		return {}
	end
	local files = {}
	for name, t in vim.fs.dir(root, { depth = 4 }) do
		if t == "file" and name:match("rollout%-.*%.jsonl$") then
			local path = root .. "/" .. name
			files[#files + 1] = { path = path, time = mtime(path) }
		end
	end
	table.sort(files, function(a, b)
		return a.time > b.time
	end)
	local names, ret = nil, {}
	for i = 1, math.min(#files, M.max_codex_files) do
		local f = files[i]
		local head = read_head(f.path, M.head_bytes) or ""
		local first = head:match("^[^\n]+")
		local meta = first and decode(first)
		local p = meta and meta.type == "session_meta" and meta.payload
		-- sub-agent sessions (review, workers) record a table as their source
		if type(p) == "table" and p.cwd == cwd and type(p.id) == "string" and type(p.source) ~= "table" then
			names = names or codex_names()
			local title = names[p.id]
			if not title then
				for line in head:sub(#first + 2):gmatch("[^\n]+") do
					local o = decode(line)
					title = o and codex_prompt(o)
					if title then
						break
					end
				end
			end
			if title then
				ret[#ret + 1] = { agent = "codex", id = p.id, title = clean(title), time = f.time, cwd = cwd }
			end
		end
	end
	return ret
end

-- ── OpenCode ──────────────────────────────────────────────────────────────

---@param cwd string
---@param cb fun(sessions: lazyvim_agent.Session[])
function M.opencode(cwd, cb)
	if vim.fn.executable("opencode") ~= 1 then
		return cb({})
	end
	local ok = pcall(
		vim.system,
		{ "opencode", "session", "list", "--format", "json", "-n", "50" },
		{ cwd = cwd, text = true, timeout = 5000, stdin = false },
		vim.schedule_wrap(function(res)
			local ret = {}
			local list = res.code == 0 and decode(res.stdout or "") or nil
			for _, s in ipairs(type(list) == "table" and list or {}) do
				if type(s) == "table" and type(s.id) == "string" then
					local title = clean(s.title ~= nil and s.title ~= "" and s.title or s.id)
					if s.directory and s.directory ~= cwd then
						title = title .. "  · " .. vim.fn.fnamemodify(s.directory, ":~")
					end
					local time = tonumber(s.updated or s.created) or 0
					ret[#ret + 1] = {
						agent = "opencode",
						id = s.id,
						title = title,
						time = math.floor(time > 1e11 and time / 1000 or time),
						cwd = cwd,
					}
				end
			end
			cb(ret)
		end)
	)
	if not ok then
		cb({})
	end
end

-- ── collecting and picking ────────────────────────────────────────────────

---@param cwd string
---@param cb fun(sessions: lazyvim_agent.Session[])
function M.collect(cwd, cb)
	local all = {}
	for _, source in ipairs({ M.claude, M.codex }) do
		local ok, list = pcall(source, cwd)
		if ok then
			vim.list_extend(all, list)
		end
	end
	M.opencode(cwd, function(list)
		vim.list_extend(all, list)
		table.sort(all, function(a, b)
			return a.time > b.time
		end)
		cb(all)
	end)
end

function M.ago(time, now)
	local d = (now or os.time()) - time
	if d < 60 then
		return "just now"
	elseif d < 3600 then
		return ("%d min ago"):format(d / 60)
	elseif d < 86400 then
		return ("%d h ago"):format(d / 3600)
	elseif d < 2 * 86400 then
		return "yesterday"
	elseif d < 30 * 86400 then
		return ("%d days ago"):format(d / 86400)
	end
	return os.date("%Y-%m-%d", time)
end

local function preview(s)
	local a = agents[s.agent]
	return table.concat({
		"# " .. s.title,
		"",
		("- **Agent:** %s"):format(a.label),
		("- **Last activity:** %s (%s)"):format(os.date("%Y-%m-%d %H:%M", s.time), M.ago(s.time)),
		("- **Session:** `%s`"):format(s.id),
		("- **Folder:** `%s`"):format(vim.fn.fnamemodify(s.cwd, ":~")),
	}, "\n")
end

--- Ask before replacing a session that is running.
local function replace_ok(what, title)
	return vim.fn.confirm(
		("%s is already running a session here.\nClose it and resume “%s”?"):format(what, title),
		"&Resume\n&Cancel",
		2
	) == 1
end

local function resume_claude(s)
	pcall(function()
		require("lazy").load({ plugins = { "claudecode.nvim" } })
	end)
	local ok, term = pcall(require, "claudecode.terminal")
	if ok and term.get_active_terminal_bufnr and term.get_active_terminal_bufnr() then
		if not replace_ok("Claude", s.title) then
			return
		end
		term.close()
	end
	vim.cmd("ClaudeCode --resume " .. s.id)
end

local commands = {
	codex = function(id)
		return { "codex", "resume", id }
	end,
	opencode = function(id)
		return { "opencode", "--session", id }
	end,
}

--- Open `cmd` as a sidekick session of `name`, so the usual sidekick keys work on it.
local function open_sidekick(name, cmd, title)
	pcall(function()
		require("lazy").load({ plugins = { "sidekick.nvim" } })
	end)
	local State = require("sidekick.cli.state")
	local Session = require("sidekick.cli.session")
	local Config = require("sidekick.config")
	Session.setup() -- registers the terminal backend; sidekick does it lazily on first use
	local running = State.get({ name = name, attached = true, cwd = true })
	if #running > 0 then
		if not replace_ok(agents[name].label, title) then
			return true
		end
		for _, st in ipairs(running) do
			State.detach(st)
		end
	end
	local tool = Config.get_tool(name):clone({ cmd = cmd })
	local session = Session.new({ tool = tool })
	State.attach(State.get_state(session), { show = true, focus = true })
end

---@param s lazyvim_agent.Session
function M.resume(s)
	if s.agent == "claude" then
		return resume_claude(s)
	end
	local cmd = commands[s.agent](s.id)
	if vim.fn.executable(cmd[1]) ~= 1 then
		return notify(("`%s` is not installed"):format(cmd[1]), vim.log.levels.ERROR)
	end
	local ok, err = pcall(open_sidekick, s.agent, cmd, s.title)
	if ok then
		return
	end
	if pcall(require, "sidekick") then
		notify("Couldn't open it in sidekick, using a plain terminal: " .. tostring(err), vim.log.levels.WARN)
	end
	-- no sidekick (or its internals changed): a plain terminal on the right
	if _G.Snacks and Snacks.terminal then
		Snacks.terminal(cmd, { cwd = s.cwd, win = { position = "right", width = 0.4 } })
	else
		vim.cmd("botright vsplit")
		vim.fn.jobstart(cmd, { term = true, cwd = s.cwd })
		vim.cmd("startinsert")
	end
end

--- Show the picker for the current folder.
---@param opts? {cwd?: string}
function M.pick(opts)
	local cwd = (opts and opts.cwd) or vim.fn.getcwd()
	M.collect(cwd, function(sessions)
		if #sessions == 0 then
			return notify("No saved Claude, Codex or OpenCode sessions in " .. vim.fn.fnamemodify(cwd, ":~"))
		end
		local width = 0
		for _, s in ipairs(sessions) do
			width = math.max(width, #M.ago(s.time))
		end
		local function format_item(s)
			return ("%-8s  %-" .. width .. "s  %s"):format(agents[s.agent].label, M.ago(s.time), s.title)
		end
		if _G.Snacks and Snacks.picker then
			local items = {}
			for i, s in ipairs(sessions) do
				items[i] = {
					text = agents[s.agent].label .. " " .. s.title,
					session = s,
					preview = { text = preview(s), ft = "markdown" },
				}
			end
			Snacks.picker.pick({
				title = "Agent sessions · " .. vim.fn.fnamemodify(cwd, ":~"),
				items = items,
				format = function(item)
					local s = item.session
					return {
						{ ("%-8s"):format(agents[s.agent].label), agents[s.agent].hl },
						{ "  " },
						{ ("%-" .. width .. "s"):format(M.ago(s.time)), "Comment" },
						{ "  " },
						{ s.title },
					}
				end,
				preview = "preview",
				confirm = function(picker, item)
					picker:close()
					if item then
						vim.schedule(function()
							M.resume(item.session)
						end)
					end
				end,
			})
		else
			vim.ui.select(sessions, { prompt = "Resume an agent session", format_item = format_item }, function(s)
				if s then
					M.resume(s)
				end
			end)
		end
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("AgentSessions", function()
		M.pick()
	end, { desc = "Resume a saved Claude, Codex or OpenCode session of this folder" })
end

return M
