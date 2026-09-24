local session = require("neo-review.session")

local M = {}

---The hunk covering (or preceding) the cursor. Returns hunk, index.
---@return review.Hunk?, integer?
function M.hunk_at(buf, lnum)
  local cache = session.bufs[buf]
  if not cache then
    return nil, nil
  end
  for i, h in ipairs(cache.hunks) do
    local first = math.max(h.buf_start, 1)
    local last = h.kind == "delete" and first or (h.buf_start + h.buf_count - 1)
    if lnum >= first and lnum <= last then
      return h, i
    end
  end
  return nil, nil
end

local function jump_to(buf, hunk)
  vim.api.nvim_win_set_cursor(0, { math.max(hunk.buf_start, 1), 0 })
  vim.cmd("normal! zz")
  -- Deleted baseline lines render as a virt_lines block next to the anchor
  -- (above it for change hunks, below for delete hunks). zz centers on the
  -- real line only; re-position if the capped block wouldn't fit on screen.
  if #hunk.base_lines > 0 then
    local virt = math.min(#hunk.base_lines, require("neo-review.render").max_deleted(buf)) + 1
    if hunk.kind == "change" and vim.fn.winline() <= virt then
      vim.cmd("normal! zb")
    elseif hunk.kind == "delete" and vim.api.nvim_win_get_height(0) - vim.fn.winline() < virt then
      vim.cmd("normal! zt")
    end
  end
end

local function skip_reviewed()
  return require("neo-review.config").options.review.skip_reviewed
end

---Hunks of a buffer that are still outstanding (all of them when the
---skip_reviewed flag is off).
local function candidate_hunks(buf)
  local cache = session.bufs[buf]
  if not cache then
    return {}
  end
  if not skip_reviewed() then
    return cache.hunks
  end
  local review = require("neo-review")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.tbl_filter(function(h)
    return not review.hunk_reviewed(cache.relpath, h, lines)
  end, cache.hunks)
end

---Does a file still have anything to review (or any hunks, when the skip
---flag is off)?
local function file_has_candidates(rel)
  local info = require("neo-review").file_review_info(rel)
  if info.total == 0 then
    return false
  end
  return not skip_reviewed() or info.reviewed < info.total
end

---Open the first/last candidate hunk of a changed file (loading the buffer
---attaches it).
local function open_file_hunk(relpath, which)
  vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. relpath))
  local buf = vim.api.nvim_get_current_buf()
  -- Attach happens via autocmd on BufReadPost; make sure the cache exists.
  require("neo-review").attach(buf)
  local hunks = candidate_hunks(buf)
  if #hunks == 0 then
    hunks = session.bufs[buf] and session.bufs[buf].hunks or {}
  end
  if #hunks > 0 then
    jump_to(buf, which == "first" and hunks[1] or hunks[#hunks])
  end
end

---Next/prev hunk within the buffer; at the edge, wrap to the next/prev changed
---file (Hunk-style single-stream review).
---@param dir 1|-1
function M.hunk(dir)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cache = session.bufs[buf]
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  if cache then
    local hunks = candidate_hunks(buf)
    local candidate
    if dir == 1 then
      for _, h in ipairs(hunks) do
        if math.max(h.buf_start, 1) > lnum then
          candidate = h
          break
        end
      end
    else
      for i = #hunks, 1, -1 do
        local h = hunks[i]
        local first = math.max(h.buf_start, 1)
        local last = h.kind == "delete" and first or (h.buf_start + h.buf_count - 1)
        if last < lnum then
          candidate = h
          break
        end
      end
    end
    if candidate then
      jump_to(buf, candidate)
      return
    end
  end

  -- Cross-file wrap, skipping fully-reviewed files when skip_reviewed is on.
  local target = M.next_file_with_candidates(cache and cache.relpath, dir)
  if not target then
    vim.notify(
      skip_reviewed() and "neo-review: nothing left to review 🎉 (:NeoReviewHunks! shows reviewed)" or "neo-review: no changes vs baseline",
      vim.log.levels.INFO
    )
    return
  end
  open_file_hunk(target, dir == 1 and "first" or "last")
end

---Next/prev changed file that still has candidate hunks, starting after
---`rel` (nil = from the edges). Wraps; nil when none qualify.
---@return string?
function M.next_file_with_candidates(rel, dir)
  local files = session.files
  if #files == 0 then
    return nil
  end
  local idx = rel and session.file_index(rel)
  local start = idx or (dir == 1 and 0 or #files + 1)
  for step = 1, #files do
    local i = ((start - 1 + dir * step) % #files) + 1
    if file_has_candidates(files[i]) then
      return files[i]
    end
  end
  return nil
end

---]H/[H: jump to the next/prev changed file's first outstanding hunk.
---@param dir 1|-1
function M.file(dir)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local cache = session.bufs[vim.api.nvim_get_current_buf()]
  local target = M.next_file_with_candidates(cache and cache.relpath, dir)
  if not target then
    vim.notify("neo-review: nothing left to review 🎉 (:NeoReviewHunks! shows reviewed)", vim.log.levels.INFO)
    return
  end
  open_file_hunk(target, "first")
end

---------------------------------------------------------------- comments

---Thread id shown in the current window's thread buffer (nil elsewhere, and
---for a not-yet-created thread).
local function pane_thread_id()
  return require("neo-review.threads.ui").buf_thread_id(vim.api.nvim_get_current_buf())
end

local function in_pane()
  return vim.bo[vim.api.nvim_get_current_buf()].filetype == "reviewthread"
end

---A normal window to show code in: the current one if it's a plain file
---window, else one already showing `file`, else the largest plain window.
---Never the thread pane or sidebars (explorer, quickfix, terminals).
local function code_win(file)
  local function plain(win)
    local b = vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_win_get_config(win).relative == "" and vim.bo[b].buftype == ""
  end
  local cur = vim.api.nvim_get_current_win()
  if plain(cur) then
    return cur
  end
  local best, best_area
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if plain(win) then
      local cache = session.bufs[vim.api.nvim_win_get_buf(win)]
      if cache and cache.relpath == file then
        return win
      end
      local area = vim.api.nvim_win_get_width(win) * vim.api.nvim_win_get_height(win)
      if not best_area or area > best_area then
        best, best_area = win, area
      end
    end
  end
  if best then
    return best
  end
  vim.cmd("leftabove vsplit")
  return vim.api.nvim_get_current_win()
end

---Show `t` in a code window, retarget an open thread pane at it, and leave
---focus where the key was pressed (pane stays focused when used from it).
local function goto_thread(t)
  local from_win = vim.api.nvim_get_current_win()
  local from_pane = in_pane()
  local win = code_win(t.file)
  vim.api.nvim_set_current_win(win)
  local cache = session.bufs[vim.api.nvim_get_current_buf()]
  if not cache or cache.relpath ~= t.file then
    vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. t.file))
    require("neo-review").attach(vim.api.nvim_get_current_buf())
  end
  local line_count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(t.lnum, line_count), 0 })
  vim.cmd("normal! zz")
  require("neo-review.threads.ui").show_in_panel(t, { notify = from_pane })
  if from_pane and vim.api.nvim_win_is_valid(from_win) then
    vim.api.nvim_set_current_win(from_win)
  end
end

local function review_on()
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return false
  end
  return true
end

---]c/[c: next/prev OPEN thread in positional order (file, then line),
---wrapping across files. Works from the thread pane too (relative to the
---thread it shows) and retargets an open pane.
---@param dir 1|-1
function M.comment(dir)
  if not review_on() then
    return
  end
  local threads = require("neo-review.threads")
  local seq = threads.comment_sequence()
  if #seq == 0 then
    vim.notify("neo-review: no open comment threads", vim.log.levels.INFO)
    return
  end
  -- Reference position: the pane's thread, or the cursor in an attached buffer.
  local ref_file, ref_lnum
  if in_pane() then
    local id = pane_thread_id()
    for _, t in ipairs(threads.threads) do
      if t.id == id and t.lnum then
        ref_file, ref_lnum = t.file, t.lnum
      end
    end
  else
    local cache = session.bufs[vim.api.nvim_get_current_buf()]
    if cache then
      ref_file, ref_lnum = cache.relpath, vim.api.nvim_win_get_cursor(0)[1]
    end
  end
  local function before(af, al, bf, bl)
    return af < bf or (af == bf and al < bl)
  end
  local target
  if ref_file then
    if dir == 1 then
      for _, t in ipairs(seq) do
        if before(ref_file, ref_lnum, t.file, t.lnum) then
          target = t
          break
        end
      end
    else
      for i = #seq, 1, -1 do
        if before(seq[i].file, seq[i].lnum, ref_file, ref_lnum) then
          target = seq[i]
          break
        end
      end
    end
  end
  goto_thread(target or (dir == 1 and seq[1] or seq[#seq]))
end

-- Last walkthrough stop visited/opened: lets ]r continue from stop N after
-- the cursor has wandered off it to read code.
local last_stop = nil ---@type string?

---Record the current walkthrough stop (ui.open calls this for series threads).
function M.remember_stop(id)
  last_stop = id
end

---]r/[r: next/prev walkthrough stop in series order. Resolved stops are
---NOT skipped (a reader resolving stops as they go can still step back);
---stale (unanchored) stops are stepped over.
---@param dir 1|-1
function M.stop(dir)
  if not review_on() then
    return
  end
  local threads = require("neo-review.threads")
  local seq = threads.stop_sequence()
  if #seq == 0 then
    vim.notify("neo-review: no walkthrough stops", vim.log.levels.INFO)
    return
  end
  local index = {}
  for i, t in ipairs(seq) do
    index[t.id] = i
  end
  -- Current stop: the pane's thread, else a stop on the cursor line, else
  -- the last one visited.
  local cur
  if in_pane() then
    cur = index[pane_thread_id() or ""]
  else
    local cache = session.bufs[vim.api.nvim_get_current_buf()]
    if cache then
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      for i, t in ipairs(seq) do
        if t.file == cache.relpath and t.lnum == lnum then
          cur = i
          break
        end
      end
    end
  end
  cur = cur or (last_stop and index[last_stop])
  local target
  for step = 1, #seq do
    local i
    if cur then
      i = ((cur - 1 + dir * step) % #seq) + 1
    else
      i = dir == 1 and step or (#seq - step + 1)
    end
    if seq[i].lnum then
      target = seq[i]
      break
    end
  end
  if not target then
    vim.notify("neo-review: every walkthrough stop is stale (its code moved or changed)", vim.log.levels.INFO)
    return
  end
  last_stop = target.id
  goto_thread(target)
end

---Load every hunk across the changeset into the quickfix list.
function M.qflist()
  local review = require("neo-review")
  local items = {}
  local hidden = 0
  for _, rel in ipairs(session.files) do
    local hunks, lines = review.file_hunks(rel)
    for i, h in ipairs(hunks) do
      if skip_reviewed() and review.hunk_reviewed(rel, h, lines) then
        hidden = hidden + 1
        goto continue
      end
      local lnum = math.max(h.buf_start, 1)
      local text
      if h.kind == "delete" then
        text = string.format("(deleted %d line%s) %s", #h.base_lines, #h.base_lines == 1 and "" or "s", h.base_lines[1] or "")
      else
        text = lines[lnum] or ""
      end
      items[#items + 1] = {
        filename = session.root .. "/" .. rel,
        lnum = lnum,
        text = string.format("[%s %d/%d] %s", h.kind, i, #hunks, vim.trim(text)),
      }
      ::continue::
    end
  end
  local title = "Review hunks" .. (hidden > 0 and string.format(" (%d reviewed hidden)", hidden) or "")
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if #items > 0 then
    vim.cmd("copen")
  elseif hidden > 0 then
    vim.notify(string.format("neo-review: all %d hunks reviewed 🎉", hidden), vim.log.levels.INFO)
  else
    vim.notify("neo-review: no changes vs baseline", vim.log.levels.INFO)
  end
end

return M
