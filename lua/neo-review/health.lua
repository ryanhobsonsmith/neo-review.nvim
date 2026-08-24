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

  health.start("agent session (wrapped claude)")
  local agent_cmd = config.options.agent.cmd or "claude"
  if vim.fn.executable(agent_cmd) == 1 then
    local ver = vim.fn.system(agent_cmd .. " --version 2>/dev/null")
    health.ok(agent_cmd .. " found: " .. vim.trim(ver))
    health.info(
      "transport: long-lived `-p --input-format stream-json` + stdio control channel. "
        .. "This wire protocol is UNOFFICIAL (verified against claude 2.1.234); if a CLI "
        .. "update breaks it, look at lua/neo-review/agent/claude.lua (protocol notes in header)"
    )
  else
    health.warn(agent_cmd .. " not found in PATH — :NeoReviewAgentStart will fail")
  end
  local agent = require("neo-review.agent")
  local ast = agent.status()
  if ast.state ~= "stopped" then
    health.ok(
      ("session %s — state: %s, %d queued turn(s), %d pending permission(s), mode: %s"):format(
        (ast.session_id or "?"):sub(1, 8),
        ast.state,
        ast.queued,
        agent.pending_count(),
        agent.mode()
      )
    )
  else
    health.info("no session running (:NeoReviewAgentStart)")
  end
  local pname, _, raw_profile = agent.profile()
  if raw_profile and not pname then
    health.warn("persisted profile '" .. raw_profile .. "' is not defined in config (agent.profiles) — falling back to config defaults")
  end
  health.info(("profile: %s · model: %s · mode: %s"):format(pname or "none", agent.model() or "CLI default", agent.mode()))
  health.info('statusline component: require("neo-review").statusline() — redraw on User NeoReviewAgentStateChanged')
  if require("neo-review.agent").last_stderr then
    health.warn("last stderr: " .. vim.trim(require("neo-review.agent").last_stderr))
  end

  health.start("external-session skill")
  local skill_state, skill_detail = require("neo-review.skill").status()
  if skill_state == "installed" then
    health.ok("review-comments skill installed: " .. skill_detail)
  elseif skill_state == "conflict" then
    health.warn(skill_detail)
  else
    health.info("not installed (" .. skill_state .. ") — :NeoReviewSkillInstall lets external Claude Code sessions act on review comments")
  end

  health.start("agent sandbox (Docker Sandboxes / sbx microVMs)")
  local sandbox = require("neo-review.agent.sandbox")
  local sok, sreason = sandbox.preflight()
  if sok then
    health.ok("sbx ready")
  elseif config.options.agent.sandbox.enabled then
    health.error("sandbox enabled but unavailable — the agent will REFUSE to start: " .. sreason)
  else
    health.warn("sandbox disabled — agent runs directly on the host (" .. (sreason or "") .. ")")
  end
  for _, l in ipairs(sandbox.status_lines()) do
    health.info(l)
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
