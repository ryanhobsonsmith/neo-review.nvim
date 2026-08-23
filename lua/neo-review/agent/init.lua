-- Agent controller: owns the wrapped session for this Neovim instance and
-- drives the comment-thread loop on top of the transport. Thread-driven by
-- design (decision ⑨): there is no free-form chat surface — pings are
-- generated turns, and the agent talks back through .review/threads/ files
-- which the existing poll renders.
--
-- PERMISSIONS (design A + D): a permission request NEVER opens UI on
-- arrival. It lands in a pending inbox — winbar shows ⏸N, a passive notify
-- fires, and the agent simply waits. <leader>rp opens the request
-- deliberately in a float where only explicit keys answer (y/Y/n); closing
-- the float leaves it pending. Cancel can never deny. Prompt volume is kept
-- low structurally: curated auto-allowed read-only tools + a CLI-style
-- permission mode (:NeoReviewAgentMode, persisted per repo).
local session = require("neo-review.session")

local M = {}

local transport = require("neo-review.agent.claude")
local allowed_tools = {} ---@type table<string, true> session-scoped auto-allows
local pending = {} ---@type table[] permission inbox, FIFO

-- Matches `claude --permission-mode` choices as of 2.1.234, plus "default"
-- (= no flag, the CLI's settings-driven behavior).
M.MODES = {
  { mode = "default", desc = "CLI default: settings/allowlist-driven prompting" },
  { mode = "auto", desc = "classifier auto-approves safe actions; flagged ones land in the inbox" },
  { mode = "acceptEdits", desc = "file edits in the repo auto-approved; Bash etc. still prompt" },
  { mode = "plan", desc = "read-only: agent may plan but not modify anything" },
  { mode = "manual", desc = "prompt for every tool use" },
  { mode = "dontAsk", desc = "never prompts: anything not pre-approved is denied" },
  { mode = "bypassPermissions", desc = "NO prompts at all — only sane inside a sandbox" },
}

local function agent_config()
  return require("neo-review.config").options.agent
end

---------------------------------------------------------------- per-repo agent state

local function agent_state_path()
  return session.root .. "/.review/local/agent.json"
end

local function load_agent_state()
  if not session.root or vim.fn.filereadable(agent_state_path()) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(agent_state_path()), "\n"))
  return ok and decoded or {}
end

local function save_agent_state(patch)
  require("neo-review.repo").ensure(session.root)
  local st = load_agent_state()
  for k, v in pairs(patch) do
    st[k] = v
  end
  vim.fn.writefile({ vim.json.encode(st) }, agent_state_path())
end

---Is the sandbox active for this repo (per-repo override, else config)?
function M.sandboxed()
  return require("neo-review.agent.sandbox").enabled(load_agent_state())
end

---The active permission mode: per-repo saved choice wins; otherwise
---sandboxed sessions default to "auto" (the container is the safety
---boundary) and direct sessions to the configured default.
function M.mode()
  local saved = load_agent_state().permission_mode
  if saved then
    return saved
  end
  if M.sandboxed() then
    return "auto"
  end
  return agent_config().permission_mode or "default"
end

---------------------------------------------------------------- permission inbox (A)

local function auto_allowed(tool_name)
  return allowed_tools[tool_name] or vim.tbl_contains(agent_config().auto_allow_tools or {}, tool_name)
end

local function on_permission(req)
  if auto_allowed(req.tool_name) then
    transport.respond_permission(req.request_id, true, req.input)
    return
  end
  pending[#pending + 1] = req
  vim.notify(
    string.format("neo-review agent: waiting on approval — %s (%d pending, <leader>rp to review)", req.display_name, #pending),
    vim.log.levels.WARN
  )
  vim.cmd("redrawstatus")
end

---Answer the FIRST pending request. scope: "once" | "session" | "deny".
---Used by the float's keymaps and by tests.
function M.respond_pending(scope)
  local req = table.remove(pending, 1)
  if not req then
    return false
  end
  if scope == "deny" then
    transport.respond_permission(req.request_id, false, nil, "denied by user in Neovim")
  else
    if scope == "session" then
      allowed_tools[req.tool_name] = true
    end
    transport.respond_permission(req.request_id, true, req.input)
  end
  vim.cmd("redrawstatus")
  return true
end

function M.pending_count()
  return #pending
end

---Render one permission request's details as float lines.
local function request_lines(req)
  local lines = {
    "Permission request: " .. req.display_name,
    string.rep("─", 50),
  }
  local input = req.input or {}
  if req.tool_name == "Bash" and input.command then
    lines[#lines + 1] = "$ " .. input.command
    if input.description then
      lines[#lines + 1] = "(" .. input.description .. ")"
    end
  elseif (req.tool_name == "Write" or req.tool_name == "Edit") and input.file_path then
    lines[#lines + 1] = "file: " .. input.file_path
    local body = input.content or input.new_string
    if body then
      lines[#lines + 1] = string.rep("─", 50)
      for _, l in ipairs(vim.split(body, "\n")) do
        lines[#lines + 1] = "  " .. l
        if #lines > 40 then
          lines[#lines + 1] = "  … (truncated)"
          break
        end
      end
    end
  else
    for _, l in ipairs(vim.split(vim.inspect(input), "\n")) do
      lines[#lines + 1] = l
      if #lines > 40 then
        lines[#lines + 1] = "… (truncated)"
        break
      end
    end
  end
  lines[#lines + 1] = string.rep("─", 50)
  lines[#lines + 1] = "[y] allow once   [Y] allow " .. req.tool_name .. " for session   [n] deny"
  lines[#lines + 1] = "[q/Esc] close (stays pending" .. (#pending > 1 and (", " .. #pending .. " total") or "") .. ")"
  return lines
end

---<leader>rp: deliberately review the next pending permission request.
function M.review_permission()
  local req = pending[1]
  if not req then
    vim.notify("neo-review agent: no pending permission requests", vim.log.levels.INFO)
    return
  end
  local lines = request_lines(req)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 3),
    col = math.floor((vim.o.columns - math.min(width + 2, 100)) / 2),
    width = math.min(width + 2, 100),
    height = math.min(#lines, 40),
    style = "minimal",
    border = "rounded",
    title = " agent approval ",
  })
  local function answer(scope)
    vim.api.nvim_win_close(win, true)
    M.respond_pending(scope)
    if #pending > 0 then
      vim.schedule(M.review_permission) -- walk the queue
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "y", function()
    answer("once")
  end, opts)
  vim.keymap.set("n", "Y", function()
    answer("session")
  end, opts)
  vim.keymap.set("n", "n", function()
    answer("deny")
  end, opts)
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      vim.api.nvim_win_close(win, true)
    end, opts)
  end
end

---------------------------------------------------------------- lifecycle

local function on_result(ev)
  save_agent_state({ last_session_id = transport.status().session_id })
  -- The agent may have edited files and/or written thread replies.
  require("neo-review.threads").sync({ notify = true })
  vim.cmd("silent! checktime")
  local cost = ev.total_cost_usd and string.format(" · $%.2f", ev.total_cost_usd) or ""
  local denials = ev.permission_denials and #ev.permission_denials or 0
  vim.notify(
    string.format(
      "neo-review agent: turn done%s%s",
      cost,
      denials > 0 and (" · " .. denials .. " permission denial" .. (denials == 1 and "" or "s")) or ""
    )
  )
end

---@param opts { resume: boolean?, resume_id: string? }?
function M.start(opts)
  opts = opts or {}
  if not session.enabled then
    require("neo-review").enable()
    if not session.enabled then
      return
    end
  end
  local cfg = agent_config()
  local resume_id = opts.resume_id or (opts.resume and load_agent_state().last_session_id or nil)
  if opts.resume and not resume_id then
    vim.notify("neo-review agent: no previous session to resume", vim.log.levels.WARN)
  end
  -- Sandbox: preferred when enabled, with graceful fallback to direct
  -- execution so a missing docker/image never blocks work.
  -- Sandbox (sbx microVMs) is required when enabled — no silent fallback to
  -- an unsandboxed run; direct execution is the explicit
  -- :NeoReviewAgentSandbox off choice.
  local sandbox = require("neo-review.agent.sandbox")
  local argv_prefix, sandboxed
  if M.sandboxed() then
    local sok, reason = sandbox.preflight()
    if not sok then
      vim.notify("neo-review agent: sandbox required but unavailable — " .. reason, vim.log.levels.ERROR)
      return
    end
    local eok, err = sandbox.ensure_sandbox()
    if not eok then
      vim.notify("neo-review agent: " .. err, vim.log.levels.ERROR)
      return
    end
    argv_prefix = sandbox.argv_prefix()
    sandboxed = true
  end
  M.session_sandboxed = sandboxed or false

  local mode = M.mode()
  if not sandboxed and mode == "bypassPermissions" and not opts.force then
    vim.notify("neo-review agent: refusing bypassPermissions OUTSIDE the sandbox — switch modes or enable the sandbox", vim.log.levels.ERROR)
    return
  end
  pending = {}
  local ok, err = transport.start({
    cwd = session.root,
    cmd = cfg.cmd,
    argv_prefix = argv_prefix,
    model = cfg.model,
    permission_mode = mode ~= "default" and mode or nil,
    resume = resume_id,
    handlers = {
      permission = on_permission,
      result = on_result,
      init = function(ev)
        vim.notify(
          string.format(
            "neo-review agent: session ready (%s, %s, mode: %s%s)",
            ev.model or "?",
            (ev.session_id or ""):sub(1, 8),
            mode,
            sandboxed and ", sandboxed" or ", DIRECT"
          )
        )
        save_agent_state({ last_session_id = ev.session_id })
      end,
      state = function()
        vim.cmd("redrawstatus")
      end,
      exit = function(code)
        pending = {}
        -- 143 = 128+SIGTERM, i.e. our own stop(); not an error.
        if code ~= 0 and code ~= 15 and code ~= 143 then
          vim.notify("neo-review agent: process exited with code " .. code .. " (see :checkhealth neo-review)", vim.log.levels.WARN)
        else
          vim.notify("neo-review agent: stopped")
        end
      end,
      stderr = function(data)
        M.last_stderr = data
      end,
    },
  })
  if not ok then
    vim.notify("neo-review agent: " .. err, vim.log.levels.ERROR)
  end
end

function M.stop()
  transport.stop()
end

function M.interrupt()
  transport.interrupt()
end

function M.status()
  return transport.status()
end

---------------------------------------------------------------- mode switching (D)

---Set the permission mode (persisted per repo). If a session is running it
---is restarted with --resume onto the same conversation — mid-process mode
---switching isn't part of the verified wire protocol, and resume is.
function M.set_mode(mode)
  local valid = false
  for _, m in ipairs(M.MODES) do
    valid = valid or m.mode == mode
  end
  if not valid then
    vim.notify("neo-review agent: unknown mode " .. tostring(mode), vim.log.levels.ERROR)
    return
  end
  if mode == "bypassPermissions" then
    vim.notify("neo-review agent: bypassPermissions — every tool call auto-approved. Intended for sandboxed runs only.", vim.log.levels.WARN)
  end
  save_agent_state({ permission_mode = mode })
  local st = transport.status()
  if st.state ~= "stopped" then
    local sid = st.session_id
    transport.stop()
    vim.defer_fn(function()
      M.start({ resume_id = sid })
    end, 400)
    vim.notify("neo-review agent: mode → " .. mode .. " (restarting session in place)")
  else
    vim.notify("neo-review agent: mode → " .. mode)
  end
end

---:NeoReviewAgentMode with no args: claude-style mode picker showing current.
function M.pick_mode()
  local current = M.mode()
  local items = {}
  for _, m in ipairs(M.MODES) do
    items[#items + 1] = string.format("%s %-18s %s", m.mode == current and "●" or " ", m.mode, m.desc)
  end
  vim.ui.select(items, { prompt = "Agent permission mode (current: " .. current .. ")" }, function(_, i)
    if i then
      M.set_mode(M.MODES[i].mode)
    end
  end)
end

---------------------------------------------------------------- status

---Short status string for winbar/statusline, e.g. "agent:working ⏸1 [auto⛨]".
function M.status_text()
  local st = transport.status()
  if st.state == "stopped" then
    return ""
  end
  local s = "agent:" .. st.state
  if #pending > 0 then
    s = s .. " ⏸" .. #pending
  end
  if st.queued > 0 then
    s = s .. " +" .. st.queued
  end
  local mode = M.mode()
  local badge = M.session_sandboxed and "⛨" or ""
  if mode ~= "default" or badge ~= "" then
    s = s .. " [" .. mode .. badge .. "]"
  end
  return s
end

---:NeoReviewAgentSandbox [on|off|build|login] — no arg shows status.
function M.sandbox_cmd(arg)
  local sandbox = require("neo-review.agent.sandbox")
  if arg == "on" or arg == "off" then
    save_agent_state({ sandbox = arg == "on" })
    if arg == "off" then
      vim.notify(
        "neo-review agent: sandbox OFF for this repo — the agent will run directly on your machine (permission prompts are the only guardrail)",
        vim.log.levels.WARN
      )
    else
      vim.notify("neo-review agent: sandbox on for this repo (takes effect on next :NeoReviewAgentStart)")
    end
  else
    local lines = sandbox.status_lines()
    table.insert(lines, 1, "sandbox:   " .. (M.sandboxed() and "ON" or "off") .. (M.session_sandboxed and " (current session sandboxed)" or ""))
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "neo-review agent sandbox" })
  end
end

---:NeoReviewAgentStatus — the full picture.
function M.show_status()
  local st = transport.status()
  local lines = {
    "state:    " .. st.state,
    "sandbox:  " .. (M.sandboxed() and "on" or "off") .. (st.state ~= "stopped" and (M.session_sandboxed and " (active)" or " (session is DIRECT)") or ""),
    "mode:     " .. M.mode(),
    "session:  " .. (st.session_id or "—"),
    "queued:   " .. st.queued .. " turn(s)",
    "pending:  " .. #pending .. " permission request(s)" .. (#pending > 0 and "  (<leader>rp to review)" or ""),
  }
  for i, req in ipairs(pending) do
    lines[#lines + 1] = string.format("  %d. %s %s", i, req.display_name, req.description or "")
  end
  local auto = vim.deepcopy(agent_config().auto_allow_tools or {})
  for tool in pairs(allowed_tools) do
    auto[#auto + 1] = tool .. " (session)"
  end
  lines[#lines + 1] = "auto-allow: " .. (#auto > 0 and table.concat(auto, ", ") or "—")
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "neo-review agent" })
end

---------------------------------------------------------------- the ping

---Build the ping prompt: open threads (unresolved), pointing the agent at
---the SKILL.md contract.
local function ping_prompt()
  local threads = require("neo-review.threads")
  threads.reload()
  local open = {}
  for _, t in ipairs(threads.threads) do
    if t.status == "open" then
      open[#open + 1] = string.format("- %s (%s) %s:%d — %s", t.id, t.kind, t.file, t.lnum or t.anchor.line, threads.summary(t))
    end
  end
  local head = "Review comments need your attention. Read .review/SKILL.md for the thread format and etiquette, then address these open threads:\n"
  if #open == 0 then
    head = "Check .review/threads/ for review comments (read .review/SKILL.md for the format). Address anything open.\n"
  end
  return head
    .. table.concat(open, "\n")
    .. "\nFor each: reply in the thread; if you make a code change for it, describe it in your reply and add a resolved status event. Do not delete any thread files."
end

---<leader>ra: alert the wrapped session about open comment threads.
function M.ping()
  if transport.status().state == "stopped" then
    M.start()
  end
  local ok, err = transport.send(ping_prompt())
  if not ok then
    vim.notify("neo-review agent: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify("neo-review agent: pinged about open threads")
end

---------------------------------------------------------------- escape hatch

---Open the real Claude Code TUI on a FORK of the wrapped session in a
---terminal split (new session id — safe to run alongside the wrapper).
function M.fork()
  local st = transport.status()
  local sid = st.session_id or load_agent_state().last_session_id
  if not sid then
    vim.notify("neo-review agent: no session to fork", vim.log.levels.WARN)
    return
  end
  local sandbox = require("neo-review.agent.sandbox")
  local cmd
  if M.session_sandboxed and sandbox.sandbox_exists() then
    -- Session (and its transcript) live in the sbx sandbox — fork in there.
    cmd = "sbx exec -it " .. sandbox.sandbox_name() .. " claude --resume " .. vim.fn.shellescape(sid) .. " --fork-session"
  else
    cmd = (agent_config().cmd or "claude") .. " --resume " .. vim.fn.shellescape(sid) .. " --fork-session"
  end
  vim.cmd("botright vsplit")
  vim.cmd("terminal " .. cmd)
  vim.cmd("startinsert")
end

return M
