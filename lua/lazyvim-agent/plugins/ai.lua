-- Agent development, Cursor-style: an AI agent in a side panel of the project.
--
-- Claude Code (coder/claudecode.nvim) is the main agent. It runs in a right
-- split, sees the open file and the selection, and when it asks before an
-- edit, shows the edit inline in the file (removed lines red, new lines
-- green): accept with <leader>aa (or :w), reject with <leader>ad.
--
-- Edits that apply without asking (auto mode, or any other agent) are shown
-- live by lazyvim-agent.follow: the edited file opens in the editor window,
-- the changes are marked inline, and each one can be kept or undone.
--
-- Most <leader>a keys act on the current agent, whichever it is, so closing,
-- hiding, sending code or a prompt works the same for Claude and the others
-- (lua/lazyvim-agent/agents.lua).
--
-- <leader>ar lists the saved sessions of Claude, Codex and OpenCode for the
-- current folder and resumes the one you pick (lua/lazyvim-agent/sessions.lua).
--
-- Any other agent CLI you have installed (Codex, OpenCode, Cursor Agent,
-- Copilot, Gemini, Aider, ...) runs through folke/sidekick.nvim. Its Copilot
-- "next edit suggestions" are off: they need a Copilot subscription and LSP.
--
-- The Claude keys match LazyVim's `ai.claudecode` extra, so enabling that
-- extra as well does no harm; the sidekick keys avoid every one of them.
return {
	{
		"coder/claudecode.nvim",
		dependencies = { "folke/snacks.nvim" },
		-- load on the commands too, so :ClaudeCode works before any <leader>a key
		cmd = {
			"ClaudeCode",
			"ClaudeCodeFocus",
			"ClaudeCodeOpen",
			"ClaudeCodeClose",
			"ClaudeCodeAdd",
			"ClaudeCodeSend",
			"ClaudeCodeTreeAdd",
			"ClaudeCodeSelectModel",
			"ClaudeCodeStatus",
			"ClaudeCodeStart",
			"ClaudeCodeDiffAccept",
			"ClaudeCodeDiffDeny",
		},
		-- your own opts for this plugin win, whatever order the specs load in
		opts = function(_, opts)
			return vim.tbl_deep_extend("keep", opts or {}, {
				-- after <leader>as / <leader>ab, jump into Claude to type the request
				focus_after_send = true,
				terminal = {
					provider = "snacks",
					split_side = "right",
					split_width_percentage = 0.40,
				},
				diff_opts = {
					layout = "unified", -- one buffer, removed and added lines inline, like Cursor
					open_in_new_tab = false,
				},
			})
		end,
		keys = {
			{ "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
			{ "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude: toggle" },
			-- The keys below act on the current agent, whichever it is: the one
			-- whose window you are in, else the one you used last
			-- (lua/lazyvim-agent/agents.lua). They live in this spec so they also
			-- replace the same keys of LazyVim's ai.claudecode extra.
			-- stylua: ignore start
			{ "<leader>af", function() require("lazyvim-agent.agents").focus() end, desc = "Agent: focus" },
			{ "<leader>aq", function() require("lazyvim-agent.agents").quit() end, desc = "Agent: close (stop) it" },
			{ "<leader>ab", function() require("lazyvim-agent.agents").add_file() end, desc = "Agent: add current file" },
			{ "<leader>as", function() require("lazyvim-agent.agents").send_selection() end, mode = "x", desc = "Agent: send selection" },
			{
				"<leader>as",
				function() require("lazyvim-agent.agents").add_tree_file() end,
				desc = "Agent: add file",
				ft = { "NvimTree", "neo-tree", "oil", "minifiles", "snacks_picker_list" },
			},
			{ "<leader>am", function() require("lazyvim-agent.agents").model() end, desc = "Agent: change model" },
			{ "<leader>ar", function() require("lazyvim-agent.sessions").pick() end, desc = "Resume a session (Claude, Codex, OpenCode)" },
			{ "<leader>aC", function() require("lazyvim-agent.agents").continue() end, desc = "Continue the latest session here" },
			-- in Claude's proposed edit: accept / reject it; elsewhere: keep / undo the agent change under the cursor
			{ "<leader>aa", function() require("lazyvim-agent.agents").accept() end, desc = "Accept (Claude diff or agent change)" },
			{ "<leader>ad", function() require("lazyvim-agent.agents").reject() end, desc = "Reject (Claude diff or agent change)" },
			-- stylua: ignore end
		},
	},

	{
		"folke/sidekick.nvim",
		cmd = "Sidekick",
		opts = function(_, opts)
			return vim.tbl_deep_extend("keep", opts or {}, {
				nes = { enabled = false },
				copilot = { status = { enabled = false } },
				cli = {
					-- lazyvim-agent.follow reloads changed files itself and needs to see
					-- them before anything else reloads them
					watch = false,
					win = {
						layout = "right",
						split = { width = math.floor(vim.o.columns * 0.40) },
					},
				},
			})
		end,
		-- stylua: ignore
		keys = {
			{ "<leader>ao", function() require("sidekick.cli").select({ filter = { installed = true } }) end, desc = "Agent: pick (Codex, OpenCode, Cursor…)" },
			{ "<leader>aO", function() require("lazyvim-agent.agents").toggle() end, desc = "Agent: show / hide window" },
			{ "<leader>ap", function() require("lazyvim-agent.agents").prompt() end, mode = { "n", "x" }, desc = "Agent: prompt (explain, fix, review…)" },
			{ "<leader>av", function() require("lazyvim-agent.agents").send_selection() end, mode = "x", desc = "Agent: send selection" },
			{ "<leader>aF", function() require("lazyvim-agent.agents").add_file() end, desc = "Agent: add current file" },
		},
	},

	-- Live view of agent edits: lua/lazyvim-agent/follow.lua in this repo.
	-- This spec has no URL: it adds to the spec you import this repo with.
	{
		"lazyvim-agent",
		event = "VeryLazy",
		opts = {},
		config = function(_, opts)
			require("lazyvim-agent.follow").setup(opts)
			require("lazyvim-agent.sessions").setup()
			require("lazyvim-agent.agents").setup()
		end,
		-- stylua: ignore
		keys = {
			{ "<leader>ah", function() require("lazyvim-agent.agents").hide_all() end, desc = "Agent: hide all windows (keep running)" },
			{ "<leader>aQ", function() require("lazyvim-agent.agents").quit_all() end, desc = "Agent: close all agents" },
			{ "]x", function() require("lazyvim-agent.follow").jump(1) end, desc = "Next agent change" },
			{ "[x", function() require("lazyvim-agent.follow").jump(-1) end, desc = "Prev agent change" },
			{ "<leader>ay", function() require("lazyvim-agent.follow").keep("hunk") end, desc = "Agent change: keep" },
			{ "<leader>an", function() require("lazyvim-agent.follow").undo("hunk") end, desc = "Agent change: undo" },
			{ "<leader>aY", function() require("lazyvim-agent.follow").keep("file") end, desc = "Agent changes: keep file" },
			{ "<leader>aN", function() require("lazyvim-agent.follow").undo("file") end, desc = "Agent changes: undo file" },
			{ "<leader>aA", function() require("lazyvim-agent.follow").keep("all") end, desc = "Agent changes: keep all" },
			{ "<leader>al", function() require("lazyvim-agent.follow").list() end, desc = "Agent changes: list" },
			{ "<leader>aw", function() require("lazyvim-agent.follow").toggle_follow() end, desc = "Agent: follow edits on/off" },
			{ "<leader>aW", function() require("lazyvim-agent.follow").toggle_watch() end, desc = "Agent: watch project (agent outside nvim)" },
		},
	},
}
