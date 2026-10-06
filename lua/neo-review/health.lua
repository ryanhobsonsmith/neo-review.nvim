-- :checkhealth neo-review
local M = {}

function M.check()
  local health = vim.health
  local session = require("neo-review.session")
  local baseline = require("neo-review.baseline")
  local config = require("neo-review.config")

  health.start("neo-review.nvim")

  if vim.fn.executable("git") == 1 then
    health.ok("git executable found")
  else
    health.error("git not found in PATH — nothing works without it")
  end

  if session.enabled then
    health.ok(
      ("review mode ON — baseline: %s, %d changed file(s), %d attached buffer(s)"):format(
        baseline.label(),
        #session.files,
        vim.tbl_count(session.bufs)
      )
    )
  else
    health.info("review mode off (:NeoReviewToggle)")
  end

  health.start("agent terminal")
  local agent_cmd = config.options.agent.cmd
  local exe = vim.split(agent_cmd, "%s+", { trimempty = true })[1] or ""
  if vim.fn.executable(exe) == 1 then
    health.ok(exe .. " found: " .. vim.trim(vim.fn.system({ exe, "--version" })))
  else
    health.warn(exe .. " not found in PATH — :NeoReviewAgentOpen will fail (agent.cmd = " .. agent_cmd .. ")")
  end
  if require("neo-review.agent").status().running then
    health.ok("terminal running")
  else
    health.info("terminal not running (:NeoReviewAgentOpen)")
  end

  health.start("external-session skills")
  local skill = require("neo-review.skill")
  for _, name in ipairs(skill.NAMES) do
    local state, detail = skill.status_of(name)
    if state == "installed" then
      health.ok(name .. " installed: " .. detail)
    elseif state == "conflict" then
      health.warn(detail)
    else
      health.info(name .. " not installed (" .. state .. ": " .. detail .. ") — :NeoReviewSkillInstall links it for external Claude Code sessions")
    end
  end

  health.start("snacks explorer integration")
  local integ = require("neo-review.integrations.snacks_explorer")
  if not config.options.integrations.snacks_explorer then
    health.info("disabled by config (integrations.snacks_explorer = false)")
    return
  end
  if not pcall(require, "snacks") then
    health.info("snacks.nvim not installed — integration inert, native pickers fall back to vim.ui.select")
    return
  end
  local ok, reason = integ.preflight()
  if ok then
    health.ok("snacks internals present (explorer.git update/_update/refresh)")
  else
    health.error(
      "snacks internals changed: " .. reason,
      { "Fix or disable in lua/neo-review/integrations/snacks_explorer.lua (see the header comment for the design)" }
    )
  end
  if integ.active then
    health.ok("ACTIVE — explorer currently shows status vs baseline: " .. baseline.label())
  else
    health.info("inactive (activates when review mode is on with a non-default baseline)")
  end
  if integ.last_error then
    health.warn("last error: " .. integ.last_error)
  end
end

return M
