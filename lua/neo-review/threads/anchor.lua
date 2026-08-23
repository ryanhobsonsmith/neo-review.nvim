-- Anchoring: pin a thread to a line in a way that survives edits.
--
-- At creation we store redundant anchors: line number, the line text
-- ("snippet", possibly several lines), surrounding context, and the
-- enclosing Treesitter symbol. At render time we re-resolve against the
-- CURRENT file content — stored line numbers are a hint, never trusted.
-- Resolution order: exact snippet match nearest the stored line → context
-- match → symbol search → stale (listed, but no in-buffer marker).
local M = {}

local CONTEXT = 2

---Build an anchor for a (1-based) line in a buffer.
---@param buf integer
---@param lnum integer
---@param count integer? how many lines the comment covers (default 1)
function M.capture(buf, lnum, count)
  count = count or 1
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local anchor = {
    line = lnum,
    snippet = vim.list_slice(lines, lnum, lnum + count - 1),
    context_before = vim.list_slice(lines, math.max(1, lnum - CONTEXT), lnum - 1),
    context_after = vim.list_slice(lines, lnum + count, math.min(#lines, lnum + count - 1 + CONTEXT)),
  }
  -- Enclosing function/class name via Treesitter, best effort.
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { lnum - 1, 0 } })
  while ok and node do
    local type_ = node:type()
    if type_:match("function") or type_:match("method") or type_:match("class") then
      for child in node:iter_children() do
        if child:type():match("identifier") or child:type():match("name") then
          local name_ok, text = pcall(vim.treesitter.get_node_text, child, buf)
          if name_ok and text ~= "" then
            anchor.symbol = text:match("[^\n]*")
          end
          break
        end
      end
      if anchor.symbol then
        break
      end
    end
    node = node:parent()
  end
  return anchor
end

local function lines_match(lines, at, wanted)
  for i, w in ipairs(wanted) do
    if lines[at + i - 1] ~= w then
      return false
    end
  end
  return true
end

---Resolve an anchor against current file lines.
---@param anchor table
---@param lines string[]
---@return integer? lnum (nil = stale)
function M.resolve(anchor, lines)
  local snippet = anchor.snippet or {}
  if #snippet == 0 then
    return anchor.line <= #lines and anchor.line or nil
  end

  -- Pass 1: exact snippet match, nearest to the stored line first.
  local best
  for lnum = 1, #lines - #snippet + 1 do
    if lines_match(lines, lnum, snippet) then
      local dist = math.abs(lnum - anchor.line)
      if not best or dist < best.dist then
        best = { lnum = lnum, dist = dist }
      end
    end
  end
  if best then
    return best.lnum
  end

  -- Pass 2: first snippet line + either context neighbor (tolerates edits to
  -- the other snippet lines).
  local first = snippet[1]
  local before = anchor.context_before and anchor.context_before[#anchor.context_before]
  local after = anchor.context_after and anchor.context_after[1]
  for lnum = 1, #lines do
    if lines[lnum] == first then
      if (before and lines[lnum - 1] == before) or (after and lines[lnum + #snippet] == after) then
        return lnum
      end
    end
  end

  -- Pass 3: the enclosing symbol's definition line, as a coarse "somewhere in
  -- this function" fallback.
  if anchor.symbol then
    for lnum, l in ipairs(lines) do
      if l:find(anchor.symbol, 1, true) and (l:match("function") or l:match("def ") or l:match("class ")) then
        return lnum
      end
    end
  end

  return nil -- stale
end

return M
