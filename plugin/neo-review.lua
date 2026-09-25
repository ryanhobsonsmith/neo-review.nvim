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

vim.api.nvim_create_user_command("NeoReviewAgentStart", function(cmd)
  review()
  require("neo-review.agent").start({ resume = cmd.args == "--resume" })
end, {
  nargs = "?",
  complete = function()
    return { "--resume" }
  end,
  desc = "Start the wrapped agent session (--resume continues the last one)",
})

vim.api.nvim_create_user_command("NeoReviewAgentStop", function()
  require("neo-review.agent").stop()
end, { desc = "Stop the wrapped agent session" })

vim.api.nvim_create_user_command("NeoReviewAgentPing", function()
  review()
  require("neo-review.agent").ping()
end, { desc = "Alert the wrapped agent about open comment threads" })

vim.api.nvim_create_user_command("NeoReviewAgentInterrupt", function()
  require("neo-review.agent").interrupt()
end, { desc = "Interrupt the agent's in-flight turn" })

vim.api.nvim_create_user_command("NeoReviewAgentFork", function()
  review()
  require("neo-review.agent").fork()
end, { desc = "Open the real Claude Code TUI on a fork of the wrapped session" })

vim.api.nvim_create_user_command("NeoReviewAgentMode", function(cmd)
  review()
  local agent = require("neo-review.agent")
  if cmd.args ~= "" then
    agent.set_mode(cmd.args)
  else
    agent.pick_mode()
  end
end, {
  nargs = "?",
  complete = function()
    return vim.tbl_map(function(m)
      return m.mode
    end, require("neo-review.agent").MODES)
  end,
  desc = "Show/set the agent permission mode (claude-style; persisted per repo)",
})

vim.api.nvim_create_user_command("NeoReviewAgentProfile", function(cmd)
  review()
  local agent = require("neo-review.agent")
  if cmd.args ~= "" then
    agent.set_profile(cmd.args)
  else
    agent.pick_profile()
  end
end, {
  nargs = "?",
  complete = function()
    -- config.options defaults to a copy of the defaults pre-setup()
    local names = vim.tbl_keys(require("neo-review.config").options.agent.profiles or {})
    table.sort(names)
    names[#names + 1] = "none"
    return names
  end,
  desc = "Show/set the agent profile (model + permission mode preset; persisted per repo)",
})

vim.api.nvim_create_user_command("NeoReviewAgentModel", function(cmd)
  review()
  require("neo-review.agent").set_model(cmd.args ~= "" and cmd.args or nil)
end, {
  nargs = "?",
  complete = function()
    return { "sonnet", "opus", "haiku", "default" }
  end,
  desc = "Set the agent model for this repo (no arg / 'default' clears the override)",
})

vim.api.nvim_create_user_command("NeoReviewAgentPermission", function()
  require("neo-review.agent").review_permission()
end, { desc = "Review the pending agent permission request" })

vim.api.nvim_create_user_command("NeoReviewAgentStatus", function()
  require("neo-review.agent").show_status()
end, { desc = "Show wrapped agent session status" })

vim.api.nvim_create_user_command("NeoReviewAgentLog", function()
  require("neo-review.agent.log").toggle()
end, { desc = "Toggle a live read-only view of the agent's activity (turns, tool calls, permissions, stderr)" })

vim.api.nvim_create_user_command("NeoReviewSkillInstall", function()
  require("neo-review.skill").install()
end, { desc = "Symlink the neo-review and guided-review skills into ~/.claude/skills for external Claude Code sessions" })

vim.api.nvim_create_user_command("NeoReviewAgentSandbox", function(cmd)
  review()
  require("neo-review.agent").sandbox_cmd(cmd.args)
end, {
  nargs = "?",
  complete = function()
    return { "on", "off" }
  end,
  desc = "Agent sandbox (sbx microVM): status / on / off (per repo)",
})
