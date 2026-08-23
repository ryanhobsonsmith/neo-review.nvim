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

---Next/prev open comment thread; wraps across files with threads.
---@param dir 1|-1
function M.comment(dir)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local threads = require("neo-review.threads")
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local here = threads.for_buf(buf)
  local candidate
  if dir == 1 then
    for _, t in ipairs(here) do
      if t.lnum > lnum then
        candidate = t
        break
      end
    end
  else
    for i = #here, 1, -1 do
      if here[i].lnum < lnum then
        candidate = here[i]
        break
      end
    end
  end
  if candidate then
    vim.api.nvim_win_set_cursor(0, { candidate.lnum, 0 })
    vim.cmd("normal! zz")
    return
  end

  -- Cross-file wrap over files that have open, anchored threads.
  local files, seen = {}, {}
  for _, t in ipairs(threads.threads) do
    if t.status == "open" and t.lnum and not seen[t.file] then
      seen[t.file] = true
      files[#files + 1] = t.file
    end
  end
  table.sort(files)
  if #files == 0 then
    vim.notify("neo-review: no open comment threads", vim.log.levels.INFO)
    return
  end
  local cache = session.bufs[buf]
  local rel = cache and cache.relpath
  local idx
  for i, f in ipairs(files) do
    if f == rel then
      idx = i
    end
  end
  local next_idx = idx and (((idx - 1 + dir) % #files) + 1) or (dir == 1 and 1 or #files)
  vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. files[next_idx]))
  local nbuf = vim.api.nvim_get_current_buf()
  require("neo-review").attach(nbuf)
  local list = threads.for_buf(nbuf)
  local target = dir == 1 and list[1] or list[#list]
  if target then
    vim.api.nvim_win_set_cursor(0, { math.min(target.lnum, vim.api.nvim_buf_line_count(nbuf)), 0 })
    vim.cmd("normal! zz")
  end
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
