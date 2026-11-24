-- Git on top of LazyVim's lazygit (<leader>gg), gitsigns hunks (<leader>gh…)
-- and Snacks pickers (<leader>gs status, <leader>gd diff, <leader>gl log).
--
-- Diffview reviews every uncommitted change in one tab, which is the step
-- after an agent edits the project: look over all files, then stage or
-- revert hunks and commit from lazygit.
return {
	{
		"sindrets/diffview.nvim",
		cmd = {
			"DiffviewOpen",
			"DiffviewClose",
			"DiffviewFileHistory",
			"DiffviewToggleFiles",
			"DiffviewFocusFiles",
			"DiffviewRefresh",
		},
		opts = {
			enhanced_diff_hl = true,
			keymaps = {
				view = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
				file_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
				file_history_panel = { { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close Diffview" } } },
			},
		},
		keys = {
			{
				"<leader>gv",
				function()
					if require("diffview.lib").get_current_view() then
						vim.cmd("DiffviewClose")
					else
						vim.cmd("DiffviewOpen")
					end
				end,
				desc = "Diffview: review changes (toggle)",
			},
			{ "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: file history" },
			{ "<leader>gV", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: repo history" },
			{ "<leader>gF", ":DiffviewFileHistory<cr>", mode = "x", desc = "Diffview: selection history" },
		},
	},

	{
		"lewis6991/gitsigns.nvim",
		optional = true,
		opts = { current_line_blame_opts = { delay = 300 } },
		keys = {
			{ "<leader>gt", "<cmd>Gitsigns toggle_current_line_blame<cr>", desc = "Toggle inline blame" },
		},
	},

	-- highlighting for commit messages, rebase todo lists, .gitignore and friends
	{
		"nvim-treesitter/nvim-treesitter",
		optional = true,
		opts = { ensure_installed = { "git_config", "gitcommit", "git_rebase", "gitignore", "gitattributes" } },
	},
}
