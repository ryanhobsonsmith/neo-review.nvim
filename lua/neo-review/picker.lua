-- Pickers. When snacks.nvim is available (LazyVim), use a native snacks
-- picker: color-coded status symbols, fuzzy matching, and file preview for
-- free. Otherwise fall back to vim.ui.select with plain-text symbols.
local baseline = require("neo-review.baseline")
local session = require("neo-review.session")

local M = {}

-- One symbol language everywhere: + added · ~ changed · - removed.
local SYMBOL = {
  -- file statuses
  A = { "+", "NeoReviewSignAdd" },
  M = { "~", "NeoReviewSignChange" },
  D = { "-", "NeoReviewSignDelete" },
  R = { "~", "NeoReviewSignChange" },
  -- hunk kinds
  add = { "+", "NeoReviewSignAdd" },
  change = { "~", "NeoReviewSignChange" },
  delete = { "-", "NeoReviewSignDelete" },
}

local function symbol(key)
  return SYMBOL[key] or { " ", "Normal" }
end

local function has_snacks()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks.picker ~= nil
end

local function no_changes()
  vim.notify("neo-review: no changes vs baseline", vim.log.levels.INFO)
end

---------------------------------------------------------------- files

local function file_items()
  local review = require("neo-review")
  local items = {}
  for _, rel in ipairs(session.files) do
    local info = review.file_review_info(rel)
    items[#items + 1] = {
      rel = rel,
      status = session.statuses[rel] or "M",
      nhunks = info.total,
      nreviewed = info.reviewed,
      done = info.total > 0 and info.reviewed == info.total,
    }
  end
  -- Outstanding files first; reviewed sink to the bottom (alpha within each).
  table.sort(items, function(a, b)
    if a.done ~= b.done then
      return not a.done
    end
    return a.rel < b.rel
  end)
  return items
end

local function file_progress_label(it)
  if it.done then
    return "✓ reviewed"
  end
  if it.nreviewed > 0 then
    return string.format("%d/%d reviewed", it.nreviewed, it.nhunks)
  end
  return string.format("%d hunk%s", it.nhunks, it.nhunks == 1 and "" or "s")
end

function M.files()
  if #session.files == 0 then
    return no_changes()
  end
  local items = file_items()
  local title = "Review files (vs " .. baseline.label() .. ")"

  if has_snacks() then
    Snacks.picker.pick({
      title = title,
      items = vim.tbl_map(function(it)
        return {
          text = it.rel, -- fuzzy-match target
          file = session.root .. "/" .. it.rel,
          rel = it.rel,
          review_status = it.status,
          nhunks = it.nhunks,
          nreviewed = it.nreviewed,
          done = it.done,
        }
      end, items), -- insertion order = outstanding-first (idx sort applies with empty query)
      format = function(item)
        local sym = symbol(item.review_status)
        local it = { done = item.done, nreviewed = item.nreviewed, nhunks = item.nhunks }
        return {
          { item.done and "✓ " or (sym[1] .. " "), item.done and "NeoReviewSignResolved" or sym[2] },
          { item.rel, item.done and "NeoReviewSignResolved" or "SnacksPickerFile" },
          { "  " .. file_progress_label(it), "SnacksPickerComment" },
        }
      end,
    })
    return
  end

  vim.ui.select(
    vim.tbl_map(function(it)
      return string.format("%s %s  (%s)", it.done and "✓" or symbol(it.status)[1], it.rel, file_progress_label(it))
    end, items),
    { prompt = title },
    function(_, i)
      if i then
        vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. items[i].rel))
      end
    end
  )
end

---------------------------------------------------------------- hunks

local function hunk_items()
  local review = require("neo-review")
  local entries = {}
  for _, rel in ipairs(session.files) do
    local hunks, lines = review.file_hunks(rel)
    for _, h in ipairs(hunks) do
      local lnum = math.max(h.buf_start, 1)
      local text = h.kind == "delete" and (h.base_lines[1] or "") or (lines[lnum] or "")
      entries[#entries + 1] = {
        rel = rel,
        lnum = lnum,
        kind = h.kind,
        line = vim.trim(text),
        reviewed = review.hunk_reviewed(rel, h, lines),
      }
    end
  end
  return entries
end

---@param show_all boolean? include reviewed hunks (dimmed, sorted last)
function M.hunks(show_all)
  local all = hunk_items()
  local entries, hidden = {}, 0
  for _, e in ipairs(all) do
    if e.reviewed and not show_all then
      hidden = hidden + 1
    else
      entries[#entries + 1] = e
    end
  end
  if show_all then
    table.sort(entries, function(a, b)
      if a.reviewed ~= b.reviewed then
        return not a.reviewed
      end
      return false
    end)
  end
  if #entries == 0 then
    if hidden > 0 then
      vim.notify(string.format("neo-review: all %d hunks reviewed 🎉 (:NeoReviewHunks! shows them)", hidden), vim.log.levels.INFO)
      return
    end
    return no_changes()
  end
  local title = "Review hunks (vs " .. baseline.label() .. ")"
  if hidden > 0 then
    title = title .. string.format(" · %d reviewed hidden", hidden)
  elseif show_all then
    title = title .. " · incl. reviewed"
  end

  if has_snacks() then
    Snacks.picker.pick({
      title = title,
      items = vim.tbl_map(function(e)
        return {
          text = e.rel .. " " .. e.line, -- fuzzy-match target
          file = session.root .. "/" .. e.rel,
          pos = { e.lnum, 0 },
          rel = e.rel,
          lnum = e.lnum,
          kind = e.kind,
          line = e.line,
          reviewed = e.reviewed,
        }
      end, entries),
      format = function(item)
        local sym = symbol(item.kind)
        if item.reviewed then
          return {
            { "✓ ", "NeoReviewSignResolved" },
            { item.rel, "NeoReviewSignResolved" },
            { ":" .. item.lnum .. " ", "NeoReviewSignResolved" },
            { item.line, "NeoReviewSignResolved" },
          }
        end
        return {
          { sym[1] .. " ", sym[2] },
          { item.rel, "SnacksPickerFile" },
          { ":" .. item.lnum .. " ", "SnacksPickerRow" },
          { item.line, "SnacksPickerComment" },
        }
      end,
      actions = {
        review_toggle_all = function(picker)
          picker:close()
          vim.schedule(function()
            M.hunks(not show_all)
          end)
        end,
      },
      win = { input = { keys = { ["<a-r>"] = { "review_toggle_all", mode = { "i", "n" }, desc = "toggle reviewed hunks" } } } },
    })
    return
  end

  vim.ui.select(
    vim.tbl_map(function(e)
      return string.format("%s %s:%d  %s", e.reviewed and "✓" or symbol(e.kind)[1], e.rel, e.lnum, e.line)
    end, entries),
    { prompt = title },
    function(_, i)
      if i then
        local e = entries[i]
        vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. e.rel))
        vim.api.nvim_win_set_cursor(0, { math.min(e.lnum, vim.api.nvim_buf_line_count(0)), 0 })
        vim.cmd("normal! zz")
      end
    end
  )
end

---------------------------------------------------------------- threads

local THREAD_SYMBOL = {
  open = { "●", "NeoReviewSignNote" },
  resolved = { "✓", "NeoReviewSignAdd" },
  stale = { "!", "NeoReviewSignDelete" },
}

function M.threads()
  local threads = require("neo-review.threads")
  threads.reload()
  local items = {}
  for _, t in ipairs(threads.threads) do
    local state = t.lnum and t.status or "stale"
    items[#items + 1] = {
      thread = t,
      state = state,
      lnum = t.lnum or t.anchor.line,
      summary = threads.summary(t),
    }
  end
  if #items == 0 then
    vim.notify("neo-review: no comment threads", vim.log.levels.INFO)
    return
  end
  local title = "Review threads"

  local function jump_and_open(it)
    vim.cmd.edit(vim.fn.fnameescape(session.root .. "/" .. it.thread.file))
    vim.api.nvim_win_set_cursor(0, { math.min(it.lnum, vim.api.nvim_buf_line_count(0)), 0 })
    vim.cmd("normal! zz")
    require("neo-review.threads.ui").open(it.thread)
  end

  if has_snacks() then
    Snacks.picker.pick({
      title = title,
      items = vim.tbl_map(function(it)
        return {
          text = table.concat({ it.thread.kind, it.thread.file, it.summary }, " "),
          file = session.root .. "/" .. it.thread.file,
          pos = { it.lnum, 0 },
          item = it,
        }
      end, items),
      format = function(entry)
        local it = entry.item
        local sym = THREAD_SYMBOL[it.state]
        return {
          { sym[1] .. " ", sym[2] },
          { string.format("%-10s", it.thread.kind), "SnacksPickerSpecial" },
          { it.thread.file, "SnacksPickerFile" },
          { ":" .. it.lnum .. " ", "SnacksPickerRow" },
          { it.summary, "SnacksPickerComment" },
        }
      end,
      confirm = function(picker, entry)
        picker:close()
        if entry then
          vim.schedule(function()
            jump_and_open(entry.item)
          end)
        end
      end,
    })
    return
  end

  vim.ui.select(
    vim.tbl_map(function(it)
      return string.format("%s %-10s %s:%d  %s", THREAD_SYMBOL[it.state][1], it.thread.kind, it.thread.file, it.lnum, it.summary)
    end, items),
    { prompt = title },
    function(_, i)
      if i then
        jump_and_open(items[i])
      end
    end
  )
end

return M
