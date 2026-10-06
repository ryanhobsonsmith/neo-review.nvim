-- The agent terminal: one plain interactive `claude` running in a hidden,
-- unlisted terminal buffer per Neovim instance. The editor shows/hides it in
-- a float and types into it (ping); you watch the terminal itself to see what
-- the agent is doing.
local config = require("neo-review.config")

local M = {}

-- activity (from claude's hooks): "starting" | "idle" | "working" | "waiting";
-- nil when hooks are off.
local state = { buf = nil, job = nil, win = nil, activity = nil }

local function running()
  return state.job ~= nil and vim.fn.jobwait({ state.job }, 0)[1] == -1
end

local function announce()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoReviewAgentStateChanged",
    data = { running = running(), activity = state.activity },
  })
  vim.cmd("redrawstatus!")
end

-- Typed text and its Enter must arrive separately: in one burst the TUI
-- treats the Enter as part of a paste and never submits.
local SUBMIT_DELAY_MS = 200

local function toggle_key()
  local km = config.options.keymaps
  return km and km.agent_open or nil
end

local function float_config()
  local width = math.floor(vim.o.columns * 0.85)
  local height = math.floor((vim.o.lines - vim.o.cmdheight) * 0.85)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " claude ",
    title_pos = "center",
  }
end

local function visible()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local HOOK_EVENTS = {
  { "SessionStart", nil, "start" },
  { "UserPromptSubmit", nil, "prompt" },
  { "PostToolUse", "*", "tool" },
  { "Stop", nil, "stop" },
  { "Notification", "permission_prompt", "permission" },
  { "Notification", "idle_prompt", "idle" },
}

---Settings file for `claude --settings`: hooks that report claude's activity
---back to this Neovim over $NVIM (set in every :terminal job's env).
---@return string path
local function write_hook_settings()
  local hooks = {}
  for _, h in ipairs(HOOK_EVENTS) do
    local event, matcher, name = h[1], h[2], h[3]
    local command = string.format(
      [=[[ -n "$NVIM" ] && %s --server "$NVIM" --remote-expr "v:lua.require'neo-review.agent'._hook('%s')" >/dev/null 2>&1; true]=],
      vim.fn.shellescape(vim.v.progpath),
      name
    )
    hooks[event] = hooks[event] or {}
    table.insert(hooks[event], {
      matcher = matcher,
      hooks = { { type = "command", command = command, timeout = 5 } },
    })
  end
  local path = vim.fn.tempname() .. "-claude-settings.json"
  vim.fn.writefile({ vim.json.encode({ hooks = hooks }) }, path)
  return path
end

---Start `claude` in a hidden, unlisted terminal buffer (no window).
local function spawn()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = "hide"
  local cmd = config.options.agent.cmd
  state.activity = nil
  if config.options.agent.hooks then
    cmd = cmd .. " --settings " .. vim.fn.shellescape(write_hook_settings())
    state.activity = "starting"
  end
  -- Nvim's terminal renders 24-bit color but doesn't advertise it.
  local opts = { env = { COLORTERM = "truecolor" } }
  local job
  vim.api.nvim_buf_call(buf, function()
    if vim.fn.has("nvim-0.11") == 1 then
      job = vim.fn.jobstart(cmd, vim.tbl_extend("force", opts, { term = true }))
    else
      job = vim.fn.termopen(cmd, opts)
    end
  end)
  vim.bo[buf].buflisted = false
  state.buf, state.job = buf, job

  local key = toggle_key()
  if key then
    vim.keymap.set("t", key, M.toggle, { buffer = buf, desc = "Review: hide agent terminal" })
  end
  vim.keymap.set("n", "q", M.hide, { buffer = buf, desc = "Review: hide agent terminal" })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_win() == state.win then
        vim.schedule(M.hide)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf == buf then
        state.buf, state.job, state.win, state.activity = nil, nil, nil, nil
        announce()
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end)
    end,
  })
  announce()
end

---Make sure the hidden terminal is running.
---@return boolean spawned true when a new process was started
local function ensure()
  if running() and vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end
  spawn()
  return true
end

---Show the agent terminal in a float (starting `claude` if needed) and focus it.
function M.show()
  ensure()
  if visible() then
    vim.api.nvim_set_current_win(state.win)
  else
    state.win = vim.api.nvim_open_win(state.buf, true, float_config())
  end
  vim.cmd("startinsert")
end

---Hide the float; the process keeps running.
function M.hide()
  if visible() then
    local win = state.win
    state.win = nil
    vim.api.nvim_win_close(win, false)
  end
end

---Hide the float when it's focused, otherwise show/focus it.
function M.toggle()
  if visible() and vim.api.nvim_get_current_win() == state.win then
    M.hide()
  else
    M.show()
  end
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("neo-review.agent.resize", { clear = true }),
  callback = function()
    if visible() then
      vim.api.nvim_win_set_config(state.win, float_config())
    end
  end,
})

local function send(text)
  local job = state.job
  vim.api.nvim_chan_send(job, text)
  vim.defer_fn(function()
    if state.job == job and running() then
      vim.api.nvim_chan_send(job, "\r")
    end
  end, SUBMIT_DELAY_MS)
end

---One line on purpose: a newline typed into the TUI would submit early.
local function ping_prompt()
  local threads = require("neo-review.threads")
  threads.reload()
  local open = {}
  for _, t in ipairs(threads.threads) do
    if t.status == "open" then
      open[#open + 1] = string.format("%s (%s) %s:%d — %s", t.id, t.kind, t.file, t.lnum or t.anchor.line, threads.summary(t))
    end
  end
  local head
  if #open == 0 then
    head = "Check .review/threads/ for review comments (read .review/SKILL.md for the format). Address anything open."
  else
    head = "Review comments need your attention. Read .review/SKILL.md for the thread format and etiquette, then address these open threads: "
      .. table.concat(open, "; ")
      .. "."
  end
  local prompt = head
    .. " For each: reply in the thread; if you make a code change for it, describe it in your reply and add a resolved status event. Do not delete any thread files."
  return (prompt:gsub("[\r\n]+", " "))
end

---claude is waiting on a selection dialog (folder trust, etc.): typed text
---would answer it instead of becoming a prompt.
local function awaiting_dialog()
  for _, l in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    if l:find("Enter to confirm", 1, true) then
      return true
    end
  end
  return false
end

local function deliver(prompt)
  if not running() then
    return
  end
  if awaiting_dialog() then
    vim.notify("neo-review agent: claude is waiting on a prompt — answer it, then ping again", vim.log.levels.WARN)
    M.show()
    return
  end
  send(prompt)
end

---Type a prompt about the open comment threads into the agent terminal,
---starting `claude` in the background if needed. Doesn't show the terminal.
function M.ping()
  local prompt = ping_prompt()
  local spawned = ensure()
  local delay = spawned and config.options.agent.ready_delay_ms or 0
  if delay > 0 then
    vim.defer_fn(function()
      deliver(prompt)
    end, delay)
  else
    deliver(prompt)
  end
  local key = toggle_key()
  vim.notify("neo-review agent: pinged about open threads" .. (key and (" (" .. key .. " to watch)") or ""))
end

function M.stop()
  if running() then
    vim.fn.jobstop(state.job)
  end
end

---@return { running: boolean, visible: boolean, activity: string?, buf: integer? }
function M.status()
  return { running = running(), visible = visible(), activity = state.activity, buf = state.buf }
end

local function watching()
  return visible() and vim.api.nvim_get_current_win() == state.win
end

local function alert(msg, level)
  local key = toggle_key()
  vim.notify("neo-review agent: " .. msg .. (key and (" (" .. key .. " to view)") or ""), level)
end

---Called by claude's hooks (see write_hook_settings) over RPC.
---@param event "start"|"prompt"|"tool"|"stop"|"permission"|"idle"
function M._hook(event)
  if not running() then
    return 0
  end
  local prev = state.activity
  local next_activity = ({
    start = "idle",
    prompt = "working",
    tool = "working",
    stop = "idle",
    permission = "waiting",
    idle = "idle",
  })[event]
  if not next_activity then
    return 0
  end
  state.activity = next_activity
  if not watching() then
    if event == "permission" then
      alert("claude is waiting for your permission", vim.log.levels.WARN)
    elseif event == "stop" and (prev == "working" or prev == "waiting") then
      alert("claude finished", vim.log.levels.INFO)
    end
  end
  if prev ~= next_activity then
    announce()
  end
  return 0
end

---"agent:<activity>" while claude is running (just "agent" with hooks off),
---else "".
function M.status_text()
  if not running() then
    return ""
  end
  return state.activity and ("agent:" .. state.activity) or "agent"
end

local ICON_HL = {
  NeoReviewAgentIdle = "DiagnosticOk",
  NeoReviewAgentWorking = "DiagnosticWarn",
  NeoReviewAgentWaiting = "DiagnosticError",
  NeoReviewAgentStarting = "Comment",
}

local function ensure_icon_hl()
  for group, link in pairs(ICON_HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end
ensure_icon_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("neo-review.agent.hl", { clear = true }),
  callback = ensure_icon_hl,
})

---Colored icon: ⏸ red = waiting for permission, ● orange = working,
---● green = idle, ○ dim = starting. nil when not running.
---@return string? icon, string? hlgroup
function M.status_icon()
  if not running() then
    return nil, nil
  end
  local a = state.activity
  if a == "waiting" then
    return "⏸", "NeoReviewAgentWaiting"
  elseif a == "working" then
    return "●", "NeoReviewAgentWorking"
  elseif a == "starting" then
    return "○", "NeoReviewAgentStarting"
  end
  return "●", "NeoReviewAgentIdle"
end

return M
