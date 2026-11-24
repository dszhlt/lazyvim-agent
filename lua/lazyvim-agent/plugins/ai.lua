-- Agent development, Cursor-style: an AI agent in a side panel of the project.
--
-- Claude Code (coder/claudecode.nvim) is the main agent. It runs in a right
-- split, sees the open file and the selection, and proposes edits as Neovim
-- diffs: accept with <leader>aa (or :w), reject with <leader>ad.
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
					layout = "vertical",
					open_in_new_tab = false,
				},
			})
		end,
		keys = {
			{ "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
			{ "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude: toggle" },
			{ "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude: focus" },
			{ "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Claude: resume a session" },
			{ "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Claude: continue last session" },
			{ "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Claude: select model" },
			{ "<leader>aq", "<cmd>ClaudeCodeClose<cr>", desc = "Claude: close" },
			{ "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Claude: add current buffer" },
			{ "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Claude: send selection" },
			{
				"<leader>as",
				"<cmd>ClaudeCodeTreeAdd<cr>",
				desc = "Claude: add file",
				ft = { "NvimTree", "neo-tree", "oil", "minifiles", "snacks_picker_list" },
			},
			{ "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Claude: accept diff" },
			{ "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Claude: deny diff" },
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
					watch = true, -- reload buffers the agent changed on disk
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
			{ "<leader>aO", function() require("sidekick.cli").toggle() end, desc = "Agent: toggle window" },
			{ "<leader>ap", function() require("sidekick.cli").prompt() end, mode = { "n", "x" }, desc = "Agent: prompt (explain, fix, review…)" },
			{ "<leader>av", function() require("sidekick.cli").send({ msg = "{selection}" }) end, mode = "x", desc = "Agent: send selection" },
			{ "<leader>aF", function() require("sidekick.cli").send({ msg = "{file}" }) end, desc = "Agent: send file" },
		},
	},
}
