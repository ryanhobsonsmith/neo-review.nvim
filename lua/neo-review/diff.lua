local M = {}

-- vim.diff was renamed to vim.text.diff in 0.12.
local difffn = (vim.text and vim.text.diff) or vim.diff

---@class review.Hunk
---@field kind "add"|"change"|"delete"
---@field buf_start integer   1-based first buffer line (for delete: line *after* which text was removed; 0 = top of file)
---@field buf_count integer
---@field base_start integer
---@field base_count integer
---@field base_lines string[] the removed/replaced baseline lines

---Diff baseline text against buffer lines.
---@param base_text string full baseline file content ("" for a new file)
---@param buf_lines string[]
---@return review.Hunk[]
function M.hunks(base_text, buf_lines)
  local buf_text = table.concat(buf_lines, "\n") .. "\n"

  if base_text == "" then
    if buf_text == "\n" then
      return {}
    end
    return {
      {
        kind = "add",
        buf_start = 1,
        buf_count = #buf_lines,
        base_start = 0,
        base_count = 0,
        base_lines = {},
      },
    }
  end
  if base_text:sub(-1) ~= "\n" then
    base_text = base_text .. "\n"
  end

  local indices = difffn(base_text, buf_text, {
    result_type = "indices",
    linematch = true,
    algorithm = "histogram",
  })

  local base_lines = vim.split(base_text, "\n")
  table.remove(base_lines) -- trailing "" from the final newline

  local hunks = {}
  for _, idx in ipairs(indices) do
    local start_a, count_a, start_b, count_b = idx[1], idx[2], idx[3], idx[4]
    local kind
    if count_a == 0 then
      kind = "add"
    elseif count_b == 0 then
      kind = "delete"
    else
      kind = "change"
    end
    local removed = {}
    for i = start_a, start_a + count_a - 1 do
      removed[#removed + 1] = base_lines[i]
    end
    hunks[#hunks + 1] = {
      kind = kind,
      buf_start = start_b,
      buf_count = count_b,
      base_start = start_a,
      base_count = count_a,
      base_lines = removed,
    }
  end
  return hunks
end

---Split a line into runs of word chars / punctuation / whitespace, keeping
---byte offsets (0-based start, end-exclusive stop).
---@param line string
---@return { text: string, start: integer, stop: integer }[]
local function tokenize(line)
  local tokens = {}
  local pos = 1
  while pos <= #line do
    local s, e = line:find("^%s+", pos)
    if not s then
      s, e = line:find("^[%w_]+", pos)
    end
    if not s then
      s, e = line:find("^[^%w_%s]+", pos)
    end
    tokens[#tokens + 1] = { text = line:sub(s, e), start = s - 1, stop = e }
    pos = e + 1
  end
  return tokens
end

---Intra-line diff of a paired old/new line: changed spans as byte-column
---ranges ({start, stop}, 0-based end-exclusive) for each side. Returns nil
---when word highlights would be noise rather than signal: identical lines,
---very long lines, or a pair so different that the spans would cover
---(nearly) both whole lines — the whole-line tint already says that.
---@param old_line string
---@param new_line string
---@return { [1]: integer, [2]: integer }[]? old_spans
---@return { [1]: integer, [2]: integer }[]? new_spans
function M.word_diff(old_line, new_line)
  if old_line == new_line or #old_line > 1000 or #new_line > 1000 then
    return nil
  end
  local old_tokens = tokenize(old_line)
  local new_tokens = tokenize(new_line)
  if #old_tokens == 0 or #new_tokens == 0 then
    return nil
  end

  local function stream(tokens)
    local texts = {}
    for i, t in ipairs(tokens) do
      texts[i] = t.text
    end
    return table.concat(texts, "\n") .. "\n"
  end
  local indices = difffn(stream(old_tokens), stream(new_tokens), { result_type = "indices" })

  local old_spans, new_spans = {}, {}
  local old_changed, new_changed = 0, 0
  for _, idx in ipairs(indices) do
    local start_a, count_a, start_b, count_b = idx[1], idx[2], idx[3], idx[4]
    if count_a > 0 then
      local span = { old_tokens[start_a].start, old_tokens[start_a + count_a - 1].stop }
      old_spans[#old_spans + 1] = span
      old_changed = old_changed + span[2] - span[1]
    end
    if count_b > 0 then
      local span = { new_tokens[start_b].start, new_tokens[start_b + count_b - 1].stop }
      new_spans[#new_spans + 1] = span
      new_changed = new_changed + span[2] - span[1]
    end
  end
  if #old_spans == 0 and #new_spans == 0 then
    return nil
  end
  if old_changed > 0.7 * #old_line and new_changed > 0.7 * #new_line then
    return nil
  end
  return old_spans, new_spans
end

---Stable identity for a hunk, independent of line numbers, so reviewed-state
---survives edits elsewhere in the file (and correctly resets when the hunk's
---own content changes).
---@param relpath string
---@param hunk review.Hunk
---@param buf_lines string[]
---@return string
function M.hash(relpath, hunk, buf_lines)
  local new = {}
  for i = hunk.buf_start, hunk.buf_start + hunk.buf_count - 1 do
    new[#new + 1] = buf_lines[i]
  end
  local payload = table.concat({
    relpath,
    hunk.kind,
    table.concat(hunk.base_lines, "\n"),
    table.concat(new, "\n"),
  }, "\0")
  return vim.fn.sha256(payload)
end

return M
