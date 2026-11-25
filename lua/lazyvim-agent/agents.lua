-- The same <leader>a keys for every agent.
--
-- Claude Code runs in a claudecode.nvim terminal, other agents in sidekick.nvim
-- terminals (or in a plain terminal). This module finds them all and acts on
-- "the current agent": the one whose window you are in, else the one you used
-- last, else the only one running. Showing, hiding, focusing, closing, sending
-- the file / the selection / a prompt, picking a model and accepting or
-- rejecting changes then work the same whichever agent it is.
local M = {}

local api = vim.api

---@class lazyvim_agent.Agent
---@field kind "claude"|"sidekick"|"term"
---@field name string tool name: claude, codex, opencode, ...
---@field buf integer terminal buffer
---@field term? table sidekick terminal object

local last_buf ---@type integer? terminal buffer of the agent used last

local labels = {
	claude = "Claude",
	codex = "Codex",
	opencode = "OpenCode",
	cursor = "Cursor Agent",
	["cursor-agent"] = "Cursor Agent",
	copilot = "Copilot",
	gemini = "Gemini",
	aider = "Aider",
}

function M.label(a)
	return labels[a.name] or (a.name:sub(1, 1):upper() .. a.name:sub(2))
end

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Agent" })
end

local function claude_term()
	if not package.loaded["claudecode"] then
		return
	end
	local ok, t = pcall(require, "claudecode.terminal")
	return ok and t or nil
end

local function claude_buf()
	local t = claude_term()
	local ok, b = pcall(function()
		return t and t.get_active_terminal_bufnr()
	end)
	return ok and b and api.nvim_buf_is_valid(b) and b or nil
end

local function sidekick_terms()
	local ok, T = pcall(function()
		return package.loaded["sidekick.cli.terminal"] and require("sidekick.cli.terminal").terminals
	end)
	return ok and T or {}
end

--- Every agent that has a terminal, running or hidden.
---@return lazyvim_agent.Agent[]
function M.list()
	local ret, seen = {}, {}
	local cb = claude_buf()
	if cb then
		ret[#ret + 1] = { kind = "claude", name = "claude", buf = cb }
		seen[cb] = true
	end
	for _, t in pairs(sidekick_terms()) do
		if t.buf and api.nvim_buf_is_valid(t.buf) and not seen[t.buf] then
			ret[#ret + 1] = { kind = "sidekick", name = t.tool and t.tool.name or "agent", buf = t.buf, term = t }
			seen[t.buf] = true
		end
	end
	local ok, follow = pcall(require, "lazyvim-agent.follow")
	for _, b in ipairs(api.nvim_list_bufs()) do
		if not seen[b] and vim.bo[b].buftype == "terminal" and api.nvim_buf_is_loaded(b) then
			local name = ok and follow.agent_name and follow.agent_name(b)
			if name then
				ret[#ret + 1] = { kind = "term", name = name, buf = b }
			end
		end
	end
	return ret
end

---@param buf integer
function M.is_agent(buf)
	for _, a in ipairs(M.list()) do
		if a.buf == buf then
			return a
		end
	end
end

--- Windows of the current tab that show the agent.
local function wins(a)
	local r = {}
	for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_buf(w) == a.buf then
			r[#r + 1] = w
		end
	end
	return r
end

function M.visible(a)
	return #wins(a) > 0
end

--- The agent you are in, else the one used last, else a visible one, else the only one.
---@return lazyvim_agent.Agent?, lazyvim_agent.Agent[]
function M.current()
	local list = M.list()
	local cur = api.nvim_get_current_buf()
	for _, a in ipairs(list) do
		if a.buf == cur then
			return a, list
		end
	end
	for _, a in ipairs(list) do
		if a.buf == last_buf then
			return a, list
		end
	end
	for _, a in ipairs(list) do
		if M.visible(a) then
			return a, list
		end
	end
	return list[1], list
end

local function none()
	notify("No agent is running · <leader>ac starts Claude, <leader>ao another agent")
end

-- ── window actions ────────────────────────────────────────────────────────

local function focus_win(a)
	local w = wins(a)[1]
	if w then
		api.nvim_set_current_win(w)
		vim.cmd("startinsert")
		last_buf = a.buf
	end
end

---@param a lazyvim_agent.Agent
---@param focus? boolean
function M.show(a, focus)
	if a.kind == "claude" then
		if not M.visible(a) then
			pcall(claude_term().ensure_visible)
		end
	elseif a.kind == "sidekick" then
		a.term:show()
	elseif not M.visible(a) then
		local cur = api.nvim_get_current_win()
		vim.cmd("botright vsplit")
		api.nvim_win_set_buf(0, a.buf)
		api.nvim_win_set_width(0, math.floor(vim.o.columns * 0.4))
		if not focus then
			api.nvim_set_current_win(cur)
		end
	end
	if focus then
		focus_win(a)
	end
end

---@param a lazyvim_agent.Agent
function M.hide(a)
	if a.kind == "sidekick" then
		return a.term:hide()
	end
	for _, w in ipairs(wins(a)) do
		if #api.nvim_tabpage_list_wins(0) > 1 then
			api.nvim_win_hide(w)
		end
	end
end

--- Stop the agent and close its window.
---@param a lazyvim_agent.Agent
function M.close(a)
	if a.kind == "claude" then
		claude_term().close()
	elseif a.kind == "sidekick" then
		a.term:close()
	else
		local job = vim.b[a.buf].terminal_job_id
		if job then
			pcall(vim.fn.jobstop, job)
		end
		for _, w in ipairs(vim.fn.win_findbuf(a.buf)) do
			if #api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(w)) > 1 then
				api.nvim_win_close(w, true)
			else
				api.nvim_win_set_buf(w, api.nvim_create_buf(true, false))
			end
		end
		pcall(api.nvim_buf_delete, a.buf, { force = true })
	end
	if last_buf == a.buf then
		last_buf = nil
	end
end

--- Show or hide the current agent.
function M.toggle()
	local a = M.current()
	if not a then
		return none()
	end
	if M.visible(a) then
		M.hide(a)
	else
		M.show(a, true)
	end
end

function M.focus()
	local a = M.current()
	if not a then
		return none()
	end
	M.show(a, true)
end

--- Hide every agent window; the agents keep running.
function M.hide_all()
	local n = 0
	for _, a in ipairs(M.list()) do
		if M.visible(a) then
			M.hide(a)
			n = n + 1
		end
	end
	if n == 0 then
		notify("No agent window is open")
	end
end

--- Close the agent you are in or used last; ask when that is not clear.
function M.quit()
	local list = M.list()
	if #list == 0 then
		return none()
	end
	local cur = api.nvim_get_current_buf()
	for _, a in ipairs(list) do
		if a.buf == cur then
			return M.close(a)
		end
	end
	if #list == 1 then
		return M.close(list[1])
	end
	local items = vim.list_extend({}, list)
	items[#items + 1] = { all = true }
	vim.ui.select(items, {
		prompt = "Close which agent?",
		format_item = function(a)
			if a.all then
				return "All agents"
			end
			return M.label(a) .. (a.buf == last_buf and "  (last used)" or "")
		end,
	}, function(a)
		if not a then
			return
		end
		if a.all then
			return M.quit_all(true)
		end
		M.close(a)
	end)
end

---@param confirmed? boolean
function M.quit_all(confirmed)
	local list = M.list()
	if #list == 0 then
		return none()
	end
	if not confirmed then
		local names = vim.tbl_map(M.label, list)
		if vim.fn.confirm("Close " .. table.concat(names, ", ") .. "?", "&Close\n&Keep running", 2) ~= 1 then
			return
		end
	end
	for _, a in ipairs(list) do
		M.close(a)
	end
end

-- ── sending ───────────────────────────────────────────────────────────────

local function relpath(path)
	local cwd = vim.fn.getcwd()
	return path:sub(1, #cwd + 1) == cwd .. "/" and path:sub(#cwd + 2) or vim.fn.fnamemodify(path, ":~")
end

local function chansend(a, text, submit)
	local job = vim.b[a.buf].terminal_job_id
	if not job then
		return notify(M.label(a) .. " is not running", vim.log.levels.WARN)
	end
	vim.fn.chansend(job, text .. (submit and "\r" or ""))
end

--- Send the current file to the current agent.
function M.add_file()
	local a = M.current()
	if not a then
		return none()
	end
	local path = api.nvim_buf_get_name(0)
	if path == "" or vim.bo.buftype ~= "" then
		return notify("This buffer is not a file", vim.log.levels.WARN)
	end
	last_buf = a.buf
	if a.kind == "claude" then
		vim.cmd("ClaudeCodeAdd " .. vim.fn.fnameescape(path))
	elseif a.kind == "sidekick" then
		require("sidekick.cli").send({ name = a.name, msg = "{file}" })
	else
		chansend(a, "@" .. relpath(path) .. " ")
		M.show(a)
	end
end

--- Send the visual selection to the current agent.
function M.send_selection()
	local a = M.current()
	if not a then
		return none()
	end
	last_buf = a.buf
	if a.kind == "claude" then
		vim.cmd("ClaudeCodeSend")
	elseif a.kind == "sidekick" then
		require("sidekick.cli").send({ name = a.name, msg = "{selection}" })
	else
		local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
		local lines = vim.fn.getregion(s, e, { type = vim.fn.mode() })
		api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
		chansend(a, table.concat(lines, "\n"))
		M.show(a)
	end
end

--- In a file explorer: send the file under the cursor.
function M.add_tree_file()
	local a = M.current()
	if not a or a.kind == "claude" then
		return vim.cmd("ClaudeCodeTreeAdd")
	end
	local path
	if vim.bo.filetype == "neo-tree" then
		local ok, node = pcall(function()
			return require("neo-tree.sources.manager").get_state_for_window().tree:get_node()
		end)
		path = ok and node and node.path
	elseif vim.bo.filetype == "oil" then
		local ok, oil = pcall(require, "oil")
		local entry = ok and oil.get_cursor_entry()
		path = entry and (oil.get_current_dir() .. entry.name)
	end
	if not path then
		return notify("No file under the cursor", vim.log.levels.WARN)
	end
	last_buf = a.buf
	if a.kind == "sidekick" then
		require("sidekick.cli").send({ name = a.name, msg = "@" .. relpath(path) .. " " })
	else
		chansend(a, "@" .. relpath(path) .. " ")
		M.show(a)
	end
end

--- Pick one of sidekick's prompts (explain, fix, review…) and send it to the current agent.
function M.prompt()
	local a = M.current()
	require("sidekick.cli").prompt({
		cb = function(msg, text)
			if not msg then
				return
			end
			if not a or a.kind == "sidekick" then
				return require("sidekick.cli").send({ name = a and a.name or nil, text = text })
			end
			last_buf = a.buf
			if a.kind == "claude" then
				claude_term().send_to_terminal(msg, { submit = false, focus = true })
			else
				chansend(a, msg)
				M.show(a, true)
			end
		end,
	})
end

-- ── agent features ────────────────────────────────────────────────────────

local model_commands = { codex = "/model", opencode = "/models", gemini = "/model", copilot = "/model" }

--- Change the model of the current agent.
function M.model()
	local a = M.current()
	if not a or a.kind == "claude" then
		return vim.cmd("ClaudeCodeSelectModel")
	end
	local cmd = model_commands[a.name]
	if not cmd then
		M.show(a, true)
		return notify(M.label(a) .. " picks its model inside its own window")
	end
	chansend(a, cmd, true)
	M.show(a, true)
end

local function in_claude_diff()
	return vim.b.claudecode_diff_tab_name ~= nil or vim.b.claudecode_inline_diff ~= nil
end

--- Accept: Claude's proposed edit when in its diff, else the agent change under the cursor.
function M.accept()
	if in_claude_diff() then
		return vim.cmd("ClaudeCodeDiffAccept")
	end
	require("lazyvim-agent.follow").keep("hunk")
end

--- Reject: Claude's proposed edit when in its diff, else undo the agent change under the cursor.
function M.reject()
	if in_claude_diff() then
		return vim.cmd("ClaudeCodeDiffDeny")
	end
	require("lazyvim-agent.follow").undo("hunk")
end

--- Continue the newest saved session in this folder, whichever agent it belongs to.
function M.continue()
	local S = require("lazyvim-agent.sessions")
	S.collect(vim.fn.getcwd(), function(list)
		if #list == 0 then
			return notify("No saved Claude, Codex or OpenCode session in this folder")
		end
		S.resume(list[1])
	end)
end

function M.setup()
	api.nvim_create_autocmd({ "BufEnter", "TermOpen" }, {
		group = api.nvim_create_augroup("lazyvim_agent_agents", { clear = true }),
		callback = function(ev)
			if vim.bo[ev.buf].buftype == "terminal" and M.is_agent(ev.buf) then
				last_buf = ev.buf
			end
		end,
	})
end

return M
