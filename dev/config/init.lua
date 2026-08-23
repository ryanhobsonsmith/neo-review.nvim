-- MINIMAL sandbox config: just this plugin, no other plugins/config. Useful
-- for isolating whether a bug is ours or an interaction with the real config.
-- For the realistic sandbox (a clone of your actual config + this plugin),
-- use ../sandbox.sh instead.
--
--   mkdir -p ~/.config/review-min && ln -s <plugin-checkout>/dev/config/init.lua ~/.config/review-min/init.lua
--   NVIM_APPNAME=review-min nvim

vim.g.mapleader = " "
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.termguicolors = true

-- The plugin repo itself, loaded from the working copy (resolved from this
-- file's real location, so the symlink works from any checkout path).
local this = vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))
local plugin_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this)))
vim.opt.rtp:prepend(plugin_dir)

require("neo-review").setup({})

vim.notify("neo-review.nvim sandbox — :NeoReviewToggle to start", vim.log.levels.INFO)
