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
local log = require("neo-review.agent.log")
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

-- Cached per repo root: statusline components read this every render, and
-- this module is agent.json's only writer (external edits mid-session are
-- not a supported path).
local state_cache, state_cache_root

local function load_agent_state()
  if state_cache and state_cache_root == session.root then
    return state_cache
  end
  if not session.root then
    return {}
  end
  local st = {}
  if vim.fn.filereadable(agent_state_path()) == 1 then
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(agent_state_path()), "\n"))
    st = ok and decoded or {}
  end
  state_cache, state_cache_root = st, session.root
  return st
end

---A patch value of vim.NIL DELETES the key (plain nil is invisible to
---pairs) — set_profile/set_model use it to clear ad-hoc overrides.
local function save_agent_state(patch)
  require("neo-review.repo").ensure(session.root)
  local st = load_agent_state()
  for k, v in pairs(patch) do
    if v == vim.NIL then
      st[k] = nil
    else
      st[k] = v
    end
  end
  state_cache, state_cache_root = st, session.root
  vim.fn.writefile({ vim.json.encode(st) }, agent_state_path())
end

---Tests only: force the next load_agent_state() to re-read agent.json.
function M._invalidate_state_cache()
  state_cache, state_cache_root = nil, nil
end

---The active profile (persisted per-repo name looked up in config).
---@return string? name (nil when unset or no longer defined in config)
---@return table? profile
---@return string? raw the persisted name even when unknown (health warns)
function M.profile()
  local raw = load_agent_state().profile
  local p = raw and (agent_config().profiles or {})[raw] or nil
  if p then
    return raw, p, raw
  end
  return nil, nil, raw
end

---Is the sandbox active for this repo (per-repo override, else the active
---profile, else config)?
function M.sandboxed()
  local _, prof = M.profile()
  return require("neo-review.agent.sandbox").enabled(load_agent_state(), prof)
end

---The active permission mode. Precedence (last explicit per-repo action
---wins): saved :NeoReviewAgentMode choice → active profile → "auto" for
---sandboxed sessions (the container is the safety boundary) → config.
function M.mode()
  local saved = load_agent_state().permission_mode
  if saved then
    return saved
  end
  local _, prof = M.profile()
  if prof and prof.permission_mode then
    return prof.permission_mode
  end
  if M.sandboxed() then
    return "auto"
  end
  return agent_config().permission_mode or "default"
end

---The model for new sessions, same precedence as M.mode(). nil = the CLI's
---default model.
function M.model()
  local saved = load_agent_state().model
  if saved then
    return saved
  end
  local _, prof = M.profile()
  if prof and prof.model then
    return prof.model
  end
  return agent_config().model
end

---One event for every observable change (state, permission inbox, queue):
---statusline consumers redraw on User NeoReviewAgentStateChanged instead of
---polling.
local function announce()
  local st = transport.status()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoReviewAgentStateChanged",
    data = {
      state = st.state, -- "stopped"|"starting"|"idle"|"working"
      session_id = st.session_id,
      queued = st.queued,
      pending = #pending,
      mode = M.mode(),
      profile = (M.profile()),
      sandboxed = M.session_sandboxed or false,
    },
  })
  vim.cmd("redrawstatus")
end

---------------------------------------------------------------- activity log

local function short(s, n)
  s = (s or ""):gsub("%s+", " ")
  n = n or 90
  return #s > n and (s:sub(1, n - 1) .. "…") or s
end

---One-line summary of a tool_use input.
local function tool_summary(name, input)
  input = input or {}
  if name == "Bash" and input.command then
    return "$ " .. short(input.command)
  end
  if input.file_path then
    return input.file_path
  end
  if input.pattern then
    return short(input.pattern, 60)
  end
  local ok, enc = pcall(vim.json.encode, input)
  return ok and short(enc, 70) or ""
end

---Every wire event lands here (transport's catch-all "event" handler):
---streamed content becomes log lines — this is the "what is it doing right
---now" view for :NeoReviewAgentLog. Lifecycle lines (session ready, turn
---done, permissions, exit) come from their dedicated handlers.
local function log_stream_event(ev)
  if ev.type == "assistant" then
    for _, block in ipairs((ev.message or {}).content or {}) do
      if block.type == "text" and block.text and block.text ~= "" then
        local lines = vim.split(block.text, "\n")
        local cap = 12
        local out = {}
        for i = 1, math.min(#lines, cap) do
          out[#out + 1] = "  " .. lines[i]
        end
        if #lines > cap then
          out[#out + 1] = ("  … (+%d more lines)"):format(#lines - cap)
        end
        log.append(out)
      elseif block.type == "tool_use" then
        log.append("→ " .. (block.name or "?") .. "  " .. tool_summary(block.name, block.input))
      elseif block.type == "thinking" then
        log.append("· thinking…")
      end
    end
  elseif ev.type == "user" then
    -- Tool results echo back on the wire as user messages.
    for _, block in ipairs((ev.message or {}).content or {}) do
      if block.type == "tool_result" then
        local text = block.content
        if type(text) == "table" then
          local first
          for _, c in ipairs(text) do
            if c.type == "text" then
              first = c.text
              break
            end
          end
          text = first
        end
        log.append("· " .. (block.is_error and "ERROR: " or "result: ") .. short(text or "", 80))
      end
    end
  end
end

---------------------------------------------------------------- permission inbox (A)

local function auto_allowed(tool_name)
  return allowed_tools[tool_name] or vim.tbl_contains(agent_config().auto_allow_tools or {}, tool_name)
end

local function on_permission(req)
  if auto_allowed(req.tool_name) then
    log.append("✓ auto-allowed " .. req.display_name)
    transport.respond_permission(req.request_id, true, req.input)
    return
  end
  pending[#pending + 1] = req
  log.append("⏸ permission requested: " .. req.display_name .. "  " .. tool_summary(req.tool_name, req.input))
  vim.notify(
    string.format("neo-review agent: waiting on approval — %s (%d pending, <leader>rp to review)", req.display_name, #pending),
    vim.log.levels.WARN
  )
  announce()
end

---Answer the FIRST pending request. scope: "once" | "session" | "deny".
---Used by the float's keymaps and by tests.
function M.respond_pending(scope)
  local req = table.remove(pending, 1)
  if not req then
    return false
  end
  if scope == "deny" then
    log.append("✗ denied " .. req.display_name)
    transport.respond_permission(req.request_id, false, nil, "denied by user in Neovim")
  else
    if scope == "session" then
      allowed_tools[req.tool_name] = true
    end
    log.append("✓ allowed " .. req.display_name .. (scope == "session" and " (for session)" or " (once)"))
    transport.respond_permission(req.request_id, true, req.input)
  end
  announce()
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
  save_agent_state({ last_session_id = transport.status().session_id, sandboxed = M.session_sandboxed or false })
  -- The agent may have edited files and/or written thread replies.
  require("neo-review.threads").sync({ notify = true })
  vim.cmd("silent! checktime")
  local cost = ev.total_cost_usd and string.format(" · $%.2f", ev.total_cost_usd) or ""
  local denials = ev.permission_denials and #ev.permission_denials or 0
  log.append("■ turn done" .. cost .. (denials > 0 and (" · " .. denials .. " denial(s)") or ""))
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
    model = M.model(),
    permission_mode = mode ~= "default" and mode or nil,
    resume = resume_id,
    handlers = {
      permission = on_permission,
      result = on_result,
      event = log_stream_event,
      init = function(ev)
        log.append(string.format(
          "── session ready: %s · %s · mode %s · %s ──",
          ev.model or "?",
          (ev.session_id or ""):sub(1, 8),
          mode,
          sandboxed and "sandboxed" or "DIRECT"
        ))
        vim.notify(
          string.format(
            "neo-review agent: session ready (%s, %s, mode: %s%s)",
            ev.model or "?",
            (ev.session_id or ""):sub(1, 8),
            mode,
            sandboxed and ", sandboxed" or ", DIRECT"
          )
        )
        -- sandboxed persists alongside the sid: :NeoReviewAgentFork needs
        -- it after an nvim restart to fork on the right side of the boundary.
        save_agent_state({ last_session_id = ev.session_id, sandboxed = M.session_sandboxed or false })
      end,
      state = announce,
      exit = function(code)
        pending = {}
        announce()
        log.append("── process exited (code " .. code .. ") ──")
        -- 143 = 128+SIGTERM, i.e. our own stop(); not an error.
        if code ~= 0 and code ~= 15 and code ~= 143 then
          vim.notify("neo-review agent: process exited with code " .. code .. " (see :checkhealth neo-review)", vim.log.levels.WARN)
        else
          vim.notify("neo-review agent: stopped")
        end
      end,
      stderr = function(data)
        M.last_stderr = data
        for _, l in ipairs(vim.split(vim.trim(data), "\n")) do
          if l ~= "" then
            log.append("stderr: " .. l)
          end
        end
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

local function valid_mode(mode)
  for _, m in ipairs(M.MODES) do
    if m.mode == mode then
      return true
    end
  end
  return false
end

---Restart a running session in place: --resume onto the same conversation —
---mid-process settings switching isn't part of the verified wire protocol,
---and resume is. Exception: when the resolved sandbox side changed, start
---FRESH — transcripts don't cross the sandbox boundary, so --resume would
---not find the conversation on the other side.
---@return boolean was_running
local function restart_in_place()
  local st = transport.status()
  if st.state == "stopped" then
    return false
  end
  local sid = st.session_id
  local was_sandboxed = M.session_sandboxed or false
  transport.stop()
  vim.defer_fn(function()
    if M.sandboxed() ~= was_sandboxed then
      vim.notify("neo-review agent: sandbox boundary changed — starting a fresh session (the transcript can't cross it)", vim.log.levels.WARN)
      M.start()
    else
      M.start({ resume_id = sid })
    end
  end, 400)
  return true
end

---Set the permission mode (persisted per repo; beats the active profile).
function M.set_mode(mode)
  if not valid_mode(mode) then
    vim.notify("neo-review agent: unknown mode " .. tostring(mode), vim.log.levels.ERROR)
    return
  end
  if mode == "bypassPermissions" then
    vim.notify("neo-review agent: bypassPermissions — every tool call auto-approved. Intended for sandboxed runs only.", vim.log.levels.WARN)
  end
  save_agent_state({ permission_mode = mode })
  if restart_in_place() then
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

---------------------------------------------------------------- profiles

---Human summary, e.g. "opus, plan" or "sonnet, auto, sandbox off".
local function profile_summary(p)
  local parts = { p.model or "default model", p.permission_mode or "default mode" }
  if p.sandbox ~= nil then
    parts[#parts + 1] = "sandbox " .. (p.sandbox and "on" or "off")
  end
  return table.concat(parts, ", ")
end

---Activate a named profile (persisted per repo). Clears earlier ad-hoc
---mode/model overrides so the profile governs; a later :NeoReviewAgentMode /
---:NeoReviewAgentModel beats the profile again. "none" clears everything
---back to config defaults.
function M.set_profile(name)
  local profiles = agent_config().profiles or {}
  if name ~= "none" then
    local p = profiles[name]
    if not p then
      vim.notify("neo-review agent: unknown profile " .. tostring(name), vim.log.levels.ERROR)
      return
    end
    if p.permission_mode and not valid_mode(p.permission_mode) then
      vim.notify("neo-review agent: profile " .. name .. " has unknown permission_mode " .. tostring(p.permission_mode), vim.log.levels.ERROR)
      return
    end
  end
  save_agent_state({
    profile = name ~= "none" and name or vim.NIL,
    permission_mode = vim.NIL, -- ad-hoc overrides yield to the profile
    model = vim.NIL,
  })
  if M.mode() == "bypassPermissions" and not M.sandboxed() then
    vim.notify("neo-review agent: this profile resolves to bypassPermissions OUTSIDE the sandbox — start will refuse", vim.log.levels.WARN)
  end
  local label = name == "none" and "profile cleared (config defaults)" or ("profile → " .. name .. " (" .. profile_summary(profiles[name]) .. ")")
  if restart_in_place() then
    label = label .. " (restarting session in place)"
  end
  vim.notify("neo-review agent: " .. label)
end

---:NeoReviewAgentProfile with no args: picker showing current (mirrors
---pick_mode).
function M.pick_profile()
  local profiles = agent_config().profiles or {}
  local names = vim.tbl_keys(profiles)
  table.sort(names) -- pairs order is nondeterministic
  local current = M.profile()
  local items = {}
  for _, n in ipairs(names) do
    items[#items + 1] = string.format("%s %-12s %s", n == current and "●" or " ", n, profile_summary(profiles[n]))
  end
  items[#items + 1] = string.format("%s %-12s clear profile (config defaults)", current == nil and "●" or " ", "none")
  vim.ui.select(items, { prompt = "Agent profile (current: " .. (current or "none") .. ")" }, function(_, i)
    if i then
      M.set_profile(names[i] or "none")
    end
  end)
end

---Ad-hoc model override (persisted per repo; beats the active profile).
---nil or "default" clears it. No validation list — the CLI accepts aliases
---and full model ids; a bad one surfaces as a start/turn error.
function M.set_model(model)
  if model == "default" then
    model = nil
  end
  save_agent_state({ model = model or vim.NIL })
  local label = "model → " .. (M.model() or "CLI default")
  if restart_in_place() then
    label = label .. " (restarting session in place)"
  end
  vim.notify("neo-review agent: " .. label)
end

---------------------------------------------------------------- status

---Short status string for winbar/statusline, e.g. "agent:working ⏸1
---[review:auto⛨]" (profile:mode, ⛨ = sandboxed). "" when stopped.
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
  local pname = M.profile()
  local badge = M.session_sandboxed and "⛨" or ""
  if pname or mode ~= "default" or badge ~= "" then
    s = s .. " [" .. (pname and (pname .. ":") or "") .. mode .. badge .. "]"
  end
  return s
end

-- Color-coded status icon (statusline/lualine). Defaults link to the
-- diagnostic palette; override the NeoReviewAgent* groups to re-tint.
local function ensure_icon_hl()
  for group, link in pairs({
    NeoReviewAgentIdle = "DiagnosticOk",
    NeoReviewAgentWorking = "DiagnosticWarn",
    NeoReviewAgentPending = "DiagnosticError",
    NeoReviewAgentStarting = "Comment",
  }) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end
ensure_icon_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("neo-review.agent.hl", { clear = true }),
  callback = ensure_icon_hl,
})

---Compact color-coded status icon: ⏸N = pending approvals (red), ● working
---(orange) / idle (green), ○ starting (dim). nil when stopped.
---@return string? icon, string? hlgroup
function M.status_icon()
  local st = transport.status()
  if st.state == "stopped" then
    return nil, nil
  end
  if #pending > 0 then
    return "⏸" .. #pending, "NeoReviewAgentPending"
  end
  if st.state == "working" then
    return "●", "NeoReviewAgentWorking"
  end
  if st.state == "starting" then
    return "○", "NeoReviewAgentStarting"
  end
  return "●", "NeoReviewAgentIdle"
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
    "sandbox:  " .. (M.sandboxed() and "on" or "off") .. (st.state ~= "stopped" and (M.session_sandboxed and " (active)" or " (session is DIRECT)") or (load_agent_state().sandboxed and " (last session was sandboxed)" or "")),
    "profile:  " .. (M.profile() or "none"),
    "model:    " .. (M.model() or "CLI default"),
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
  local prompt = ping_prompt()
  local ok, err = transport.send(prompt)
  if not ok then
    vim.notify("neo-review agent: " .. err, vim.log.levels.ERROR)
    return
  end
  log.append("▶ ping: " .. short(vim.split(prompt, "\n")[1]))
  vim.notify("neo-review agent: pinged about open threads")
end

---------------------------------------------------------------- escape hatch

---Build the fork terminal command. The forked sid's sandboxed-ness comes
---from the live session when one is running, else from the flag persisted
---in agent.json — the transcript lives wherever that session ran, and
---"claude --resume" only finds it on that side of the boundary.
---@return string? cmd, string? err
function M.fork_cmd()
  local st = transport.status()
  -- The transport remembers its session_id after stop — only a RUNNING
  -- session counts as live; otherwise the persisted state governs.
  local live = st.state ~= "stopped" and st.session_id or nil
  local sid = live or load_agent_state().last_session_id
  if not sid then
    return nil, "no session to fork"
  end
  local sandboxed
  if live then
    sandboxed = M.session_sandboxed
  else
    sandboxed = load_agent_state().sandboxed
  end
  local sandbox = require("neo-review.agent.sandbox")
  if sandboxed then
    if vim.fn.executable("sbx") == 1 and sandbox.sandbox_exists() then
      -- Session (and its transcript) live in the sbx sandbox — fork in there.
      return "sbx exec -it " .. sandbox.sandbox_name() .. " claude --resume " .. vim.fn.shellescape(sid) .. " --fork-session"
    end
    vim.notify(
      "neo-review agent: that session's transcript lives in the sbx sandbox, which is unavailable — forking on the host will likely not find it",
      vim.log.levels.WARN
    )
  end
  return (agent_config().cmd or "claude") .. " --resume " .. vim.fn.shellescape(sid) .. " --fork-session"
end

---Open the real Claude Code TUI on a FORK of the wrapped session in a
---terminal split (new session id — safe to run alongside the wrapper).
function M.fork()
  local cmd, err = M.fork_cmd()
  if not cmd then
    vim.notify("neo-review agent: " .. err, vim.log.levels.WARN)
    return
  end
  vim.cmd("botright vsplit")
  vim.cmd("terminal " .. cmd)
  vim.cmd("startinsert")
end

return M
