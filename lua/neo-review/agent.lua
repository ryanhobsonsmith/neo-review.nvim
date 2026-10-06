-- The agent terminal: one plain interactive `claude` running in a :terminal
-- buffer per Neovim instance. The editor only opens/hides it and types into
-- it (ping); you watch the terminal itself to see what the agent is doing.
local config = require("neo-review.config")

local M = {}

local state = { buf = nil, job = nil }

local function running()
  return state.job ~= nil and vim.fn.jobwait({ state.job }, 0)[1] == -1
end

local function announce()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NeoReviewAgentStateChanged",
    data = { running = running() },
  })
end

local function find_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      return win
    end
  end
end

local function spawn()
  vim.cmd("botright vsplit")
  vim.cmd("terminal " .. config.options.agent.cmd)
  local buf = vim.api.nvim_get_current_buf()
  state.buf, state.job = buf, vim.b[buf].terminal_job_id
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once = true,
    callback = function()
      if state.buf == buf then
        state.buf, state.job = nil, nil
        announce()
      end
    end,
  })
  announce()
end

---Make the agent terminal visible (spawning `claude` if none is running) and
---focus it.
---@return boolean spawned true when a new process was started
function M.open()
  local spawned = false
  if not (running() and vim.api.nvim_buf_is_valid(state.buf)) then
    spawn()
    spawned = true
  else
    local win = find_win()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright vsplit")
      vim.api.nvim_win_set_buf(0, state.buf)
    end
  end
  vim.cmd("startinsert")
  return spawned
end

---Hide the terminal when it's the current window (the process keeps
---running), otherwise open/focus it.
function M.toggle()
  if state.buf and vim.api.nvim_get_current_buf() == state.buf and running() then
    vim.cmd("stopinsert")
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      vim.api.nvim_win_close(0, false)
    else
      vim.cmd("enew")
    end
    return
  end
  M.open()
end

local function send(text)
  vim.api.nvim_chan_send(state.job, text)
  vim.api.nvim_chan_send(state.job, "\r")
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

---Open the terminal (starting `claude` if needed) and type a prompt about the
---open comment threads into it.
function M.ping()
  local prompt = ping_prompt()
  local spawned = M.open()
  local delay = spawned and config.options.agent.ready_delay_ms or 0
  if delay > 0 then
    vim.defer_fn(function()
      if running() then
        send(prompt)
      end
    end, delay)
  else
    send(prompt)
  end
  vim.notify("neo-review agent: pinged about open threads")
end

function M.stop()
  if running() then
    vim.fn.jobstop(state.job)
  end
end

---@return { running: boolean, buf: integer? }
function M.status()
  return { running = running(), buf = state.buf }
end

---"agent" while the terminal's process is running, else "".
function M.status_text()
  return running() and "agent" or ""
end

local function ensure_icon_hl()
  vim.api.nvim_set_hl(0, "NeoReviewAgent", { link = "DiagnosticOk", default = true })
end
ensure_icon_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("neo-review.agent.hl", { clear = true }),
  callback = ensure_icon_hl,
})

---@return string? icon, string? hlgroup
function M.status_icon()
  if running() then
    return "●", "NeoReviewAgent"
  end
  return nil, nil
end

return M
