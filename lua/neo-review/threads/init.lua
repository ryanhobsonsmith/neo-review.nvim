-- Thread controller: loads threads from disk, resolves anchors against
-- current content, renders in-buffer markers, and polls for changes made by
-- agents (or other tools) editing .review/threads/ directly.
local anchor = require("neo-review.threads.anchor")
local session = require("neo-review.session")
local store = require("neo-review.threads.store")

local M = {}

M.ns = vim.api.nvim_create_namespace("neo-review.nvim.threads")
M.threads = {} ---@type review.Thread[]
local poll_timer = nil
local fingerprint = ""

---Author identity for messages written from this Neovim.
function M.author()
  local configured = require("neo-review.config").options.comments.author
  if configured and configured ~= "" then
    return configured
  end
  local name = require("neo-review.git")._git({ "config", "user.name" }, session.root)
  return (name and name ~= "") and name or "user"
end

---Current file lines, from the open buffer if any, else disk.
local function file_lines(relpath)
  for buf, cache in pairs(session.bufs) do
    if cache.relpath == relpath and vim.api.nvim_buf_is_valid(buf) then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, session.root .. "/" .. relpath)
  return ok and lines or {}
end

---Displayed series position: rank within the series by (pos, created, id),
---counted over EVERY member regardless of status or anchoring, so numbering
---is stable (resolving stop 2 keeps stop 4 labeled 4/N).
local function annotate_series(list)
  local groups = {}
  for _, t in ipairs(list) do
    if t.series then
      groups[t.series.id] = groups[t.series.id] or {}
      table.insert(groups[t.series.id], t)
    end
  end
  for _, g in pairs(groups) do
    table.sort(g, function(a, b)
      if a.series.pos ~= b.series.pos then
        return a.series.pos < b.series.pos
      end
      if a.created ~= b.created then
        return a.created < b.created
      end
      return a.id < b.id
    end)
    for i, t in ipairs(g) do
      t.series.rank = i
      t.series.total = #g
    end
  end
end

---Reload all threads and re-resolve anchors. Cheap enough to call freely.
function M.reload()
  if not session.root then
    return
  end
  M.threads = store.list(session.root)
  local lines_cache = {}
  for _, t in ipairs(M.threads) do
    lines_cache[t.file] = lines_cache[t.file] or file_lines(t.file)
    t.lnum = anchor.resolve(t.anchor, lines_cache[t.file]) -- nil = stale
  end
  annotate_series(M.threads)
end

---All walkthrough stops as one stream (the ]r/[r order): series ordered by
---their earliest thread's `created` (series id tiebreak) and chained, each
---in rank order. Includes resolved AND stale stops so indices are stable;
---navigation steps over stale ones.
---@return review.Thread[]
function M.stop_sequence()
  local groups, first = {}, {}
  for _, t in ipairs(M.threads) do
    if t.series then
      local id = t.series.id
      groups[id] = groups[id] or {}
      table.insert(groups[id], t)
      if not first[id] or t.created < first[id] then
        first[id] = t.created
      end
    end
  end
  local ids = vim.tbl_keys(groups)
  table.sort(ids, function(a, b)
    if first[a] ~= first[b] then
      return first[a] < first[b]
    end
    return a < b
  end)
  local out = {}
  for _, id in ipairs(ids) do
    table.sort(groups[id], function(a, b)
      return a.series.rank < b.series.rank
    end)
    vim.list_extend(out, groups[id])
  end
  return out
end

---Open, anchored threads in positional order (file asc, line asc) — the
---]c/[c stream.
---@return review.Thread[]
function M.comment_sequence()
  local out = {}
  for _, t in ipairs(M.threads) do
    if t.status == "open" and t.lnum then
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  return out
end

---"2/9" for a series thread, nil otherwise.
---@return string?
function M.position(t)
  if t.series and t.series.rank then
    return string.format("%d/%d", t.series.rank, t.series.total)
  end
  return nil
end

---Threads anchored in a buffer, sorted by resolved line. Open threads only
---by default (nav and summaries); pass include_resolved for lookups that
---should see everything.
---@return review.Thread[]
function M.for_buf(buf, include_resolved)
  local cache = session.bufs[buf]
  if not cache then
    return {}
  end
  local out = {}
  for _, t in ipairs(M.threads) do
    if t.file == cache.relpath and t.lnum and (include_resolved or t.status == "open") then
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    return a.lnum < b.lnum
  end)
  return out
end

---One-line summary of a thread (first message's first line).
function M.summary(t)
  local first = t.messages[1]
  local text = first and first.body[1] or ""
  if #text > 60 then
    text = text:sub(1, 57) .. "…"
  end
  return text
end

---Render gutter marker + one-line virtual summary for a buffer's threads.
function M.render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local active = require("neo-review.threads.ui").active_ids()
  for _, t in ipairs(M.for_buf(buf, true)) do
    local row = math.min(t.lnum, line_count) - 1
    local is_active = active[t.id] == true
    if t.status == "open" then
      local n = #t.messages
      local pos = M.position(t)
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        sign_text = "●",
        sign_hl_group = is_active and "NeoReviewSignNoteActive" or "NeoReviewSignNote",
        priority = 11,
      })
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        virt_text = {
          {
            string.format(" ● %s%s · %d msg%s · %s", pos and (pos .. " · ") or "", t.kind, n, n == 1 and "" or "s", M.summary(t)),
            is_active and "NeoReviewNoteVirtActive" or "NeoReviewNoteVirt",
          },
        },
        virt_text_pos = "eol",
      })
    else
      -- Resolved: a quiet ✓ sign, no summary — discoverable (<leader>rc on
      -- the line reopens the conversation) without shouting.
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        sign_text = "✓",
        sign_hl_group = is_active and "NeoReviewSignNoteActive" or "NeoReviewSignResolved",
        priority = 10,
      })
      -- ]r lands on resolved walkthrough stops too: say which stop this is.
      local pos = M.position(t)
      if pos then
        vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
          virt_text = { { " ✓ " .. pos, "NeoReviewSignResolved" } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

function M.render_all()
  for buf in pairs(session.bufs) do
    M.render(buf)
  end
end

---Re-resolve this buffer's anchors against its current lines and redraw
---(called from the debounced edit refresh — no disk IO).
function M.refresh_buf(buf)
  local cache = session.bufs[buf]
  if not cache then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, t in ipairs(M.threads) do
    if t.file == cache.relpath then
      t.lnum = anchor.resolve(t.anchor, lines)
    end
  end
  M.render(buf)
end

---The thread on a line in a buffer. Open threads win over resolved ones on
---the same line — resolved threads are still findable so <leader>rc on a ✓
---line reopens the conversation instead of starting a duplicate.
---@return review.Thread?
function M.at_line(buf, lnum)
  local resolved
  for _, t in ipairs(M.for_buf(buf, true)) do
    if t.lnum == lnum then
      if t.status == "open" then
        return t
      end
      resolved = resolved or t
    end
  end
  return resolved
end

---Cheap change detection for the poll loop: name + size + mtime of every
---thread file. mtime (to the nanosecond) catches in-place edits that keep
---the byte size, e.g. an agent fixing a word or renumbering a stop.
local function compute_fingerprint()
  local dir = session.root .. "/.review/threads"
  if vim.fn.isdirectory(dir) == 0 then
    return ""
  end
  local parts = {}
  for _, f in ipairs(vim.fn.globpath(dir, "*/*", false, true)) do
    local st = vim.uv.fs_stat(f)
    if st then
      parts[#parts + 1] = string.format("%s:%d:%d.%09d", f, st.size, st.mtime.sec, st.mtime.nsec or 0)
    end
  end
  table.sort(parts)
  return table.concat(parts, "|")
end
M._fingerprint = compute_fingerprint -- tests

---Reload + re-render (call after any local write; the poll loop calls it
---when agents write .review/threads/ from outside).
---@param opts { notify: boolean }? notify=true announces externally-arrived
---threads/messages (used by the poll; local writes stay silent)
function M.sync(opts)
  local before
  if opts and opts.notify and require("neo-review.config").options.comments.notify_new then
    before = {}
    for _, t in ipairs(M.threads) do
      before[t.id] = #t.messages
    end
  end
  M.reload()
  if before then
    local new_threads, new_msgs, new_stops = 0, 0, 0
    for _, t in ipairs(M.threads) do
      if before[t.id] == nil then
        new_threads = new_threads + 1
        new_stops = new_stops + (t.series and 1 or 0)
      elseif #t.messages > before[t.id] then
        new_msgs = new_msgs + (#t.messages - before[t.id])
      end
    end
    if new_threads + new_msgs > 0 then
      local parts = {}
      if new_threads > 0 then
        parts[#parts + 1] = new_threads .. " new comment thread" .. (new_threads == 1 and "" or "s")
      end
      if new_msgs > 0 then
        parts[#parts + 1] = new_msgs .. " new repl" .. (new_msgs == 1 and "y" or "ies")
      end
      local km = require("neo-review.config").options.keymaps or {}
      local hint = new_stops > 0 and km.next_stop and (km.next_stop .. " to walk through")
        or (km.next_comment and (km.next_comment .. " to jump"))
      local hints = {}
      if hint then
        hints[#hints + 1] = hint
      end
      if km.threads then
        hints[#hints + 1] = km.threads .. " to list"
      end
      vim.notify("neo-review: " .. table.concat(parts, ", ") .. (#hints > 0 and ("  (" .. table.concat(hints, ", ") .. ")") or ""))
    end
  end
  M.render_all()
  require("neo-review.threads.ui").repaint_all()
end

function M.start_polling()
  M.stop_polling()
  fingerprint = compute_fingerprint()
  poll_timer = vim.uv.new_timer()
  poll_timer:start(
    3000,
    3000,
    vim.schedule_wrap(function()
      if not session.enabled then
        return
      end
      local fp = compute_fingerprint()
      if fp ~= fingerprint then
        fingerprint = fp
        M.sync({ notify = true })
      end
    end)
  )
end

function M.stop_polling()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
