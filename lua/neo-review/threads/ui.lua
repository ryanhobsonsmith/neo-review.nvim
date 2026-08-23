-- Thread buffers (octo-style): the conversation opens as a REAL buffer in a
-- vertical split. Reply by typing below the reply separator and :w to send.
-- The same buffer handles a not-yet-created thread ("new mode"): first :w
-- creates the thread with your text as the opening message.
local session = require("neo-review.session")
local store = require("neo-review.threads.store")
local threads = require("neo-review.threads")

local M = {}

local REPLY_SEP = "── reply (:w to send) " .. string.rep("─", 40)

M.ns = vim.api.nvim_create_namespace("neo-review.nvim.threadbuf")

---@class review.ThreadBufState
---@field id string?           existing thread id (nil in new mode)
---@field new { file: string, anchor: table, kind: string }?

local states = {} ---@type table<integer, review.ThreadBufState>

---"2026-08-14T21:37:08.020169Z" -> "Aug 14 14:37" in local time.
local function fmt_ts(iso)
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return iso
  end
  -- isdst=false on BOTH os.time calls: mixing auto-detected and forced DST
  -- flags skews the result by an hour half the year.
  local utc = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  local utc_now = os.date("!*t")
  utc_now.isdst = false
  local offset = os.difftime(os.time(), os.time(utc_now))
  return os.date("%b %d %H:%M", utc + offset)
end

---Build display lines plus highlight marks: { {row0, col0, end_col|-1, hl}, ... }
local function render_lines(t)
  local lines, marks = {}, {}
  local status = t.status:upper()
  local head_sym = t.status == "open" and "●" or "✓"
  local status_hl = t.status == "open" and "NeoReviewThreadOpen" or "NeoReviewThreadResolved"
  local head = string.format("%s %s:%d · %s · ", head_sym, t.file, t.lnum or (t.anchor and t.anchor.line) or 0, t.kind)
  lines[1] = head .. status
  marks[#marks + 1] = { 0, 0, #head, "NeoReviewThreadHeader" }
  marks[#marks + 1] = { 0, #head, -1, status_hl }
  lines[2] = string.rep("─", 60)
  marks[#marks + 1] = { 1, 0, -1, "NeoReviewThreadDim" }

  for _, m in ipairs(t.messages) do
    local author_hl = m.role == "agent" and "NeoReviewThreadAgent" or "NeoReviewThreadAuthor"
    local name = "● " .. m.author .. (m.role == "agent" and " (agent)" or "")
    local meta = " · " .. fmt_ts(m.ts)
    lines[#lines + 1] = name .. meta
    marks[#marks + 1] = { #lines - 1, 0, #name, author_hl }
    marks[#marks + 1] = { #lines - 1, #name, -1, "NeoReviewThreadDim" }
    for _, l in ipairs(m.body) do
      lines[#lines + 1] = "  " .. l
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = REPLY_SEP
  marks[#marks + 1] = { #lines - 1, 0, -1, "NeoReviewThreadDim" }
  lines[#lines + 1] = ""
  return lines, marks
end

local function render_new_lines(spec)
  local lines = {
    string.format("● %s:%d · %s · NEW", spec.file, spec.anchor.line, spec.kind),
    string.rep("─", 60),
    "(write your comment below, :w to create)",
    REPLY_SEP,
    "",
  }
  return lines, {
    { 0, 0, -1, "NeoReviewThreadHeader" },
    { 1, 0, -1, "NeoReviewThreadDim" },
    { 2, 0, -1, "NeoReviewThreadDim" },
    { 3, 0, -1, "NeoReviewThreadDim" },
  }
end

---Text the user typed after the reply separator.
local function reply_body(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sep
  for i, l in ipairs(lines) do
    if l == REPLY_SEP then
      sep = i
    end
  end
  if not sep then
    return {}
  end
  local body = vim.list_slice(lines, sep + 1, #lines)
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  while #body > 0 and vim.trim(body[1]) == "" do
    table.remove(body, 1)
  end
  return body
end

local function repaint(buf)
  local st = states[buf]
  local lines, marks
  if st.id then
    local t = store.load(session.root, st.id)
    if not t then
      return
    end
    t.lnum = t.anchor.line
    for _, loaded in ipairs(threads.threads) do
      if loaded.id == st.id then
        t.lnum = loaded.lnum or t.lnum
      end
    end
    lines, marks = render_lines(t)
  else
    lines, marks = render_new_lines(st.new)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, m[1], m[2], {
      end_row = m[3] == -1 and m[1] + 1 or m[1],
      end_col = m[3] == -1 and 0 or m[3],
      hl_group = m[4],
      hl_eol = m[3] == -1,
    })
  end
  vim.bo[buf].modified = false
  -- Cursor to the reply line, ready to type — but only in the focused
  -- window; background repaints (poll sync) must not yank the cursor around.
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 and win == vim.api.nvim_get_current_win() then
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
  end
end

---Repaint every open thread buffer from disk (called after sync picks up
---changes, e.g. an agent reply). Buffers with an unsent draft are left
---alone — never clobber typed text.
function M.repaint_all()
  for buf, st in pairs(states) do
    if st.id and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
      repaint(buf)
    end
  end
end

local function on_write(buf)
  local st = states[buf]
  local body = reply_body(buf)
  if #body == 0 then
    vim.notify("neo-review: nothing to send (type below the reply line)", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end
  local author = threads.author()
  if st.id then
    store.reply(session.root, st.id, { author = author, role = "human", body = body })
    -- A reply to a resolved thread reopens it: without notifications, a
    -- comment left under "resolved" would be invisible to everyone.
    local t = store.load(session.root, st.id)
    if t and t.status == "resolved" then
      store.set_status(session.root, st.id, "open", author)
      vim.notify("neo-review: thread reopened by reply")
    end
  else
    st.id = store.create(session.root, {
      file = st.new.file,
      kind = st.new.kind,
      anchor = st.new.anchor,
      author = author,
      role = "human",
      body = body,
    })
    st.new = nil
    vim.api.nvim_buf_set_name(buf, "neo-review-thread://" .. st.id)
  end
  threads.sync()
  repaint(buf)
  vim.notify("neo-review: comment sent")
end

local function make_buf(name)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "reviewthread"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      on_write(buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      states[buf] = nil
      -- The active-thread indicator in code buffers must revert.
      vim.schedule(function()
        require("neo-review.threads").render_all()
      end)
    end,
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, desc = "Close thread" })
  local resolve_key = (require("neo-review.config").options.keymaps or {}).resolve
  if resolve_key then
    vim.keymap.set("n", resolve_key, function()
      M.toggle_resolve(buf)
    end, { buffer = buf, silent = true, desc = "Review: toggle resolved" })
  end
  return buf
end

---The window currently acting as the thread panel (any window showing a
---thread buffer), plus that buffer.
local function panel_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if states[b] then
      return win, b
    end
  end
end

---Show a thread buffer in the single thread panel, reusing the existing one
---(drawer model). Exception: a panel holding an unsent draft is left alone —
---the new thread opens in its own split rather than destroying typed text.
local function open_split(buf)
  local win, cur = panel_win()
  if win and cur ~= buf and vim.bo[cur].modified then
    vim.notify("neo-review: unsent draft in thread panel — opening a separate split", vim.log.levels.INFO)
    win = nil
  end
  if win then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, buf)
    return
  end
  vim.cmd("botright vsplit")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_width(0, math.max(50, math.floor(vim.o.columns * 0.35)))
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.winfixwidth = true
  -- Prose, not code: wrap long comment lines at word boundaries instead of
  -- letting them scroll off horizontally.
  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.wo.breakindent = true
end

---Open an existing thread in a split. If it's already open, reuse it:
---focus its window (or show the existing buffer in a new split) and repaint.
function M.open(thread)
  for buf, st in pairs(states) do
    if st.id == thread.id and vim.api.nvim_buf_is_valid(buf) then
      local win = vim.fn.bufwinid(buf)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
      else
        open_split(buf)
      end
      if not vim.bo[buf].modified then
        repaint(buf)
      end
      threads.render_all()
      return
    end
  end
  local buf = make_buf("neo-review-thread://" .. thread.id)
  states[buf] = { id = thread.id }
  open_split(buf)
  repaint(buf)
  threads.render_all()
end

---Open a new-thread buffer anchored at the cursor in `srcbuf`.
function M.new(srcbuf, kind)
  local cache = session.bufs[srcbuf]
  if not cache then
    vim.notify("neo-review: buffer not attached (is review mode on?)", vim.log.levels.WARN)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local a = require("neo-review.threads.anchor").capture(srcbuf, lnum)
  local buf = make_buf("neo-review-thread://new-" .. tostring(srcbuf) .. "-" .. tostring(lnum))
  states[buf] = { new = { file = cache.relpath, anchor = a, kind = kind or "note" } }
  open_split(buf)
  repaint(buf)
  vim.cmd("startinsert")
end

---Resolve/reopen from a thread buffer.
function M.toggle_resolve(buf)
  local st = states[buf]
  if not st or not st.id then
    return
  end
  M.toggle_resolve_id(st.id)
end

---Resolve/reopen a thread by id (used from code lines too).
function M.toggle_resolve_id(id)
  local t = store.load(session.root, id)
  if not t then
    return
  end
  local next_status = t.status == "open" and "resolved" or "open"
  store.set_status(session.root, id, next_status, threads.author())
  threads.sync()
  vim.notify("neo-review: thread " .. next_status)
end

---The thread id shown in a thread buffer (nil for non-thread buffers).
function M.buf_thread_id(buf)
  local st = states[buf]
  return st and st.id or nil
end

---Set of thread ids currently visible in a window (drives the "this comment
---is open in the panel" indicator in code buffers).
---@return table<string, true>
function M.active_ids()
  local ids = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local st = states[vim.api.nvim_win_get_buf(win)]
    if st and st.id then
      ids[st.id] = true
    end
  end
  return ids
end

---Delete a thread (its whole directory) after confirmation. Closes any open
---thread buffer for it.
function M.delete(id)
  local t = store.load(session.root, id)
  if not t then
    return
  end
  local prompt = string.format("Delete thread %s (%s, %d message%s)?", id, t.kind, #t.messages, #t.messages == 1 and "" or "s")
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end
  store.delete(session.root, id)
  for buf, st in pairs(states) do
    if st.id == id and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  threads.sync()
  vim.notify("neo-review: thread deleted")
end

return M
