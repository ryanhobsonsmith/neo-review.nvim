local session = require("neo-review.session")

local M = {}

-- One reusable peek window/buffer per session (no stacking splits).
local state = { win = nil, buf = nil }

local function valid_win()
  return state.win and vim.api.nvim_win_is_valid(state.win) and state.win or nil
end

---Show the full deleted baseline content of the hunk at the cursor in a
---read-only scratch split. The inline overlay caps deleted lines below the
---window height (see render.max_deleted); this is the escape hatch for the
---rest. Also usable for whole-file deletions later (TODO.md).
---@param buf integer? source buffer (default: current)
function M.show_deleted(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cache = session.bufs[buf]
  if not cache then
    vim.notify("neo-review: buffer not attached to review mode", vim.log.levels.INFO)
    return
  end
  local hunk = require("neo-review.nav").hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not hunk or #hunk.base_lines == 0 then
    vim.notify("neo-review: no deleted lines in the hunk under cursor", vim.log.levels.INFO)
    return
  end

  local win = valid_win()
  if not win then
    vim.cmd("botright " .. math.floor(vim.o.lines / 2) .. "split")
    win = vim.api.nvim_get_current_win()
    state.win = win
  end

  local sbuf = state.buf
  if not (sbuf and vim.api.nvim_buf_is_valid(sbuf)) then
    sbuf = vim.api.nvim_create_buf(false, true)
    state.buf = sbuf
    vim.bo[sbuf].buftype = "nofile"
    vim.bo[sbuf].bufhidden = "wipe"
    vim.bo[sbuf].swapfile = false
    vim.keymap.set("n", "q", function()
      local w = valid_win()
      if w then
        vim.api.nvim_win_close(w, true)
      end
    end, { buffer = sbuf, silent = true, desc = "Review: close deleted-lines view" })
  end

  vim.bo[sbuf].modifiable = true
  vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, hunk.base_lines)
  vim.bo[sbuf].modifiable = false
  vim.bo[sbuf].filetype = vim.bo[buf].filetype
  pcall(vim.api.nvim_buf_set_name, sbuf, string.format("review://deleted/%s#%d", cache.relpath, math.max(hunk.buf_start, 1)))

  vim.api.nvim_win_set_buf(win, sbuf)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

return M
