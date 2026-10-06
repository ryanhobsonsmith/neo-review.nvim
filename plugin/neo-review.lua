-- Commands only: nothing attaches to buffers and no module is require()d
-- until a command runs (or the user calls require("neo-review").setup()).
if vim.g.loaded_neo_review_nvim then
  return
end
vim.g.loaded_neo_review_nvim = true

local function review()
  local m = require("neo-review")
  if not m._did_setup then
    m.setup(vim.g.neo_review_nvim or {})
  end
  return m
end

vim.api.nvim_create_user_command("NeoReviewToggle", function()
  review().toggle()
end, { desc = "Toggle review mode" })

vim.api.nvim_create_user_command("NeoReviewBaseline", function(cmd)
  review().set_baseline(cmd.args)
end, {
  nargs = "?",
  complete = function()
    return { "main", "HEAD~1" }
  end,
  desc = "Set review baseline (empty = working tree vs HEAD)",
})

vim.api.nvim_create_user_command("NeoReviewFiles", function()
  review()
  require("neo-review.picker").files()
end, { desc = "Pick a changed file" })

vim.api.nvim_create_user_command("NeoReviewHunks", function(cmd)
  review()
  require("neo-review.picker").hunks(cmd.bang)
end, { bang = true, desc = "Pick a hunk (! includes reviewed hunks)" })

vim.api.nvim_create_user_command("NeoReviewExplorer", function()
  review()
  require("neo-review.integrations.snacks_explorer").review_explorer()
end, { desc = "Toggle the review explorer (review mode on + filtered/expanded to the changeset)" })

vim.api.nvim_create_user_command("NeoReviewMarkFileReviewed", function(cmd)
  review().mark_file_reviewed(cmd.args ~= "" and cmd.args or nil)
end, { nargs = "?", complete = "file", desc = "Toggle reviewed for a whole file (default: current)" })

vim.api.nvim_create_user_command("NeoReviewUnreviewAll", function()
  review().clear_reviewed()
end, { desc = "Reset all reviewed-state for the current baseline (asks for confirmation)" })

vim.api.nvim_create_user_command("NeoReviewReviewAll", function()
  review().review_all()
end, { desc = "Mark every hunk in the changeset reviewed (asks for confirmation)" })

vim.api.nvim_create_user_command("NeoReviewQuickfix", function()
  review()
  require("neo-review.nav").qflist()
end, { desc = "Load all hunks into quickfix" })

vim.api.nvim_create_user_command("NeoReviewMarkReviewed", function()
  review().mark_reviewed()
end, { desc = "Toggle reviewed-state for the hunk under the cursor" })

vim.api.nvim_create_user_command("NeoReviewComment", function(cmd)
  review().comment(cmd.args)
end, {
  nargs = "?",
  complete = function()
    return { "question", "issue", "suggestion", "nitpick", "note", "praise" }
  end,
  desc = "Open the comment thread at the cursor, or start a new one [kind]",
})

vim.api.nvim_create_user_command("NeoReviewThreads", function()
  review()
  require("neo-review.picker").threads()
end, { desc = "Pick a comment thread" })

vim.api.nvim_create_user_command("NeoReviewResolve", function()
  review().resolve()
end, { desc = "Toggle resolved for the thread here (thread buffer or code line)" })

vim.api.nvim_create_user_command("NeoReviewThreadDelete", function()
  review().delete_thread()
end, { desc = "Delete the thread here (asks for confirmation)" })

vim.api.nvim_create_user_command("NeoReviewCleanResolved", function()
  review().clean_resolved()
end, { desc = "Delete all resolved threads (asks for confirmation)" })

vim.api.nvim_create_user_command("NeoReviewExplorerFilter", function()
  review()
  require("neo-review.integrations.snacks_explorer").toggle_changed_only()
end, { desc = "Toggle snacks explorer between all files and changed-only" })

vim.api.nvim_create_user_command("NeoReviewExplorerExpand", function()
  review()
  require("neo-review.integrations.snacks_explorer").expand_changed()
end, { desc = "Expand snacks explorer to reveal all changed files" })

vim.api.nvim_create_user_command("NeoReviewAgentOpen", function()
  review()
  require("neo-review.agent").toggle()
end, { desc = "Show/hide the agent terminal float (interactive claude)" })

vim.api.nvim_create_user_command("NeoReviewAgentPing", function()
  review()
  require("neo-review.agent").ping()
end, { desc = "Type a prompt about open comment threads into the agent terminal" })

vim.api.nvim_create_user_command("NeoReviewAgentStop", function()
  require("neo-review.agent").stop()
end, { desc = "Stop the agent terminal's claude process" })

vim.api.nvim_create_user_command("NeoReviewSkillInstall", function()
  require("neo-review.skill").install()
end, { desc = "Symlink the neo-review and guided-review skills into ~/.claude/skills for external Claude Code sessions" })
