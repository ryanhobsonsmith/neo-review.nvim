-- Live, read-only activity log for the wrapped agent session: the
-- controller appends one-line summaries of everything on the wire (turns,
-- assistant text, tool calls, permissions, results, stderr) into a scratch
-- buffer. :NeoReviewAgentLog toggles a split on it; windows parked at the
-- bottom follow new output (tail -f style), scrolled-up windows stay put.
local M = {}

local MAX_LINES = 2000

M.buf = nil ---@type integer?

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "review://agent-log")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "neo-review-agent-log"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  M.buf = buf
  return buf
end

---Append lines (each prefixed with a timestamp on the first line of the
---batch). Trims the buffer to MAX_LINES and tails windows that were at the
---bottom.
---@param lines string|string[]
function M.append(lines)
  if type(lines) == "string" then
    lines = { lines }
  end
  if #lines == 0 then
    return
  end
  local buf = ensure_buf()
  local stamped = { os.date("%H:%M:%S ") .. lines[1] }
  for i = 2, #lines do
    stamped[#stamped + 1] = "         " .. lines[i]
  end

  -- Remember which windows are parked at the bottom BEFORE appending.
  local last = vim.api.nvim_buf_line_count(buf)
  local tailing = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf and vim.api.nvim_win_get_cursor(win)[1] >= last then
      tailing[#tailing + 1] = win
    end
  end

  vim.bo[buf].modifiable = true
  -- The very first append replaces the initial empty line.
  if last == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, stamped)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, stamped)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count > MAX_LINES then
    vim.api.nvim_buf_set_lines(buf, 0, count - MAX_LINES, false, {})
    count = MAX_LINES
  end
  vim.bo[buf].modifiable = false

  for _, win in ipairs(tailing) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { count, 0 })
    end
  end
end

---All log lines (tests, and programmatic peeking).
function M.lines()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
end

---Toggle a read-only split tailing the log.
function M.toggle()
  local buf = ensure_buf()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_close(win, true)
      return
    end
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_height(0, math.max(10, math.floor(vim.o.lines / 4)))
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.winfixheight = true
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
end

return M
