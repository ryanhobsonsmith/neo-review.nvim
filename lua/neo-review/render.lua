local config = require("neo-review.config")
local diff = require("neo-review.diff")

local M = {}

M.ns = vim.api.nvim_create_namespace("neo-review.nvim")

---Word-diff span color derived from the corresponding line group: same hue,
---background intensified toward the foreground pole (delta-style), fg left
---unset so syntax highlighting shows through on buffer lines. Falls back to
---`fallback` when the source group has no background to derive from.
local function rgb(color)
  return math.floor(color / 0x10000) % 0x100, math.floor(color / 0x100) % 0x100, color % 0x100
end

---@param source string highlight group to derive the span bg from
---@param accent string group whose fg is the theme's saturated add/delete
---       color (used when amplification alone is imperceptible)
---@param fallback string link target when no bg is available
---@param keep_fg boolean? carry the source fg (for virt_lines chunks, where
---       there is no syntax fg to preserve and Normal fg would clash)
---@return vim.api.keyset.highlight
local function inline_hl(source, accent, fallback, keep_fg)
  local src = vim.api.nvim_get_hl(0, { name = source, link = false })
  if not src or not src.bg then
    return { default = true, link = fallback }
  end
  -- Amplify the tint's distance from the Normal background: doubles the
  -- saturation of the hunk tint in its own hue instead of washing it out
  -- toward white/black (works for both dark and light themes).
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    or (vim.o.background == "dark" and 0x000000 or 0xffffff)
  local sr, sg, sb = rgb(src.bg)
  local nr, ng, nb = rgb(normal)
  local function amp(c, n)
    return math.min(0xff, math.max(0, math.floor(n + (c - n) * 2 + 0.5)))
  end
  local r, g, b = amp(sr, nr), amp(sg, ng), amp(sb, nb)
  -- Contrast floor: when the line tint sits close to Normal, doubling the
  -- distance is still imperceptible — blend toward the theme's saturated
  -- add/delete foreground (Added/Removed) instead.
  if math.max(math.abs(r - sr), math.abs(g - sg), math.abs(b - sb)) < 0x20 then
    local acc = vim.api.nvim_get_hl(0, { name = accent, link = false }).fg
    if acc then
      local ar, ag, ab = rgb(acc)
      local function blend(c, a)
        return math.floor(c + (a - c) * 0.45 + 0.5)
      end
      r, g, b = blend(sr, ar), blend(sg, ag), blend(sb, ab)
    end
  end
  return { default = true, bg = r * 0x10000 + g * 0x100 + b, fg = keep_fg and src.fg or nil }
end

function M.define_highlights()
  local hl = function(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  hl("NeoReviewSignAdd", "Added")
  hl("NeoReviewSignChange", "Changed")
  hl("NeoReviewSignDelete", "Removed")
  hl("NeoReviewSignReviewed", "NonText")
  -- delta-style: the new side of a change hunk is green like an addition
  -- (the red deleted virt_lines above carry the "old side"); there is no
  -- separate change tint.
  hl("NeoReviewAdd", "DiffAdd")
  hl("NeoReviewDeleteVirt", "DiffDelete")
  hl("NeoReviewDeleteMore", "NonText")
  -- Derived from the line groups just defined (post-link resolution), so
  -- overriding NeoReviewAdd/NeoReviewDeleteVirt re-tints the spans too.
  vim.api.nvim_set_hl(0, "NeoReviewAddInline", inline_hl("NeoReviewAdd", "Added", "DiffText"))
  vim.api.nvim_set_hl(0, "NeoReviewDeleteInline", inline_hl("NeoReviewDeleteVirt", "Removed", "DiffText", true))
  hl("NeoReviewSignNote", "DiagnosticSignWarn")
  hl("NeoReviewNoteVirt", "DiagnosticVirtualTextWarn")
  hl("NeoReviewSignNoteActive", "DiagnosticSignInfo")
  hl("NeoReviewNoteVirtActive", "DiagnosticVirtualTextInfo")
  hl("NeoReviewSignResolved", "NonText")
  hl("NeoReviewExplorerCursor", "Visual")
  hl("NeoReviewThreadDim", "Comment")
  hl("NeoReviewThreadAuthor", "Function")
  hl("NeoReviewThreadAgent", "Special")
  hl("NeoReviewThreadOpen", "DiagnosticWarn")
  hl("NeoReviewThreadResolved", "DiagnosticOk")
  vim.api.nvim_set_hl(0, "NeoReviewThreadHeader", { default = true, bold = true })
end

local sign_hl = {
  add = "NeoReviewSignAdd",
  change = "NeoReviewSignChange",
  delete = "NeoReviewSignDelete",
}

---Max deleted baseline lines to render inline for `buf`. A virt_lines block
---taller than the window is unscrollable (the cursor can only sit on real,
---visible lines, so the view snaps past the block's middle) — cap below the
---smallest window currently showing the buffer.
---@param buf integer
---@return integer
function M.max_deleted(buf)
  local opt = config.options.overlay_max_lines
  if type(opt) == "number" then
    return math.max(opt, 1)
  end
  -- "auto"
  local height
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local h = vim.api.nvim_win_get_height(win)
      height = height and math.min(height, h) or h
    end
  end
  height = height or vim.o.lines
  return math.max(height - 2, 8)
end

---One virt_lines row for a deleted baseline line, segmented so word-diff
---spans ({start, stop} byte columns, 0-based end-exclusive) highlight as
---NeoReviewDeleteInline within the NeoReviewDeleteVirt line.
local function deleted_line_chunks(line, spans)
  if not spans or #spans == 0 then
    return { { line, "NeoReviewDeleteVirt" } }
  end
  local chunks = {}
  local pos = 0
  for _, span in ipairs(spans) do
    if span[1] > pos then
      chunks[#chunks + 1] = { line:sub(pos + 1, span[1]), "NeoReviewDeleteVirt" }
    end
    chunks[#chunks + 1] = { line:sub(span[1] + 1, span[2]), "NeoReviewDeleteInline" }
    pos = span[2]
  end
  if pos < #line then
    chunks[#chunks + 1] = { line:sub(pos + 1), "NeoReviewDeleteVirt" }
  end
  return chunks
end

---Deleted baseline lines as virt_lines, truncated to `max` with a "+N more"
---tail when the block would otherwise be taller than the window.
---`word_spans` (optional) maps base_lines index -> span list for that line.
local function deleted_virt(base_lines, max, word_spans)
  local virt = {}
  for i = 1, math.min(#base_lines, max) do
    virt[#virt + 1] = deleted_line_chunks(base_lines[i], word_spans and word_spans[i])
  end
  local hidden = #base_lines - max
  if hidden > 0 then
    local km = config.options.keymaps
    local hint = km and km.show_deleted and (" (" .. km.show_deleted .. " to view all)") or ""
    virt[#virt + 1] = { { string.format("… +%d more deleted lines%s", hidden, hint), "NeoReviewDeleteMore" } }
  end
  return virt
end

---Render hunks into a buffer.
---@param buf integer
---@param hunks review.Hunk[]
---@param opts { overlay: boolean, reviewed: fun(hunk: review.Hunk): boolean }
function M.apply(buf, hunks, opts)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local signs = config.options.signs
  local max_virt = M.max_deleted(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local function clamp_row(lnum) -- 1-based lnum -> valid 0-based row
    return math.min(math.max(lnum, 1), line_count) - 1
  end

  for _, hunk in ipairs(hunks) do
    local done = opts.reviewed(hunk)

    if done then
      vim.api.nvim_buf_set_extmark(buf, M.ns, clamp_row(math.max(hunk.buf_start, 1)), 0, {
        sign_text = signs.reviewed,
        sign_hl_group = "NeoReviewSignReviewed",
        priority = 8,
      })
    elseif hunk.kind == "delete" then
      -- buf_start is the line *after which* text was removed (0 = top).
      local mark_row = clamp_row(math.max(hunk.buf_start, 1))
      vim.api.nvim_buf_set_extmark(buf, M.ns, mark_row, 0, {
        sign_text = signs.delete,
        sign_hl_group = sign_hl.delete,
        priority = 9,
      })
      if opts.overlay then
        vim.api.nvim_buf_set_extmark(buf, M.ns, clamp_row(hunk.buf_start + 1), 0, {
          virt_lines = deleted_virt(hunk.base_lines, max_virt),
          virt_lines_above = hunk.buf_start > 0 or nil,
        })
      end
    else
      for lnum = hunk.buf_start, hunk.buf_start + hunk.buf_count - 1 do
        vim.api.nvim_buf_set_extmark(buf, M.ns, clamp_row(lnum), 0, {
          sign_text = signs[hunk.kind],
          sign_hl_group = sign_hl[hunk.kind],
          priority = 9,
        })
      end
      if opts.overlay then
        -- Line tint as a full-line RANGE highlight, not line_hl_group: as of
        -- nvim 0.12 the line_hl layer paints over range-highlight backgrounds
        -- regardless of priority, which would hide the word-diff spans below.
        vim.api.nvim_buf_set_extmark(buf, M.ns, clamp_row(hunk.buf_start), 0, {
          end_row = hunk.buf_start + hunk.buf_count - 1, -- 0-based, end-exclusive
          end_col = 0,
          hl_group = "NeoReviewAdd",
          hl_eol = true,
          priority = 9,
          strict = false,
        })
      end
      -- Word-level highlights: pair base_lines[i] with buffer line
      -- buf_start+i-1 (linematch makes the pairing meaningful); surplus
      -- lines on either side are pure add/delete and get no spans.
      local word_spans
      if opts.overlay and config.options.word_diff and hunk.kind == "change" then
        word_spans = {}
        local npairs = math.min(#hunk.base_lines, hunk.buf_count)
        local new_lines = vim.api.nvim_buf_get_lines(buf, hunk.buf_start - 1, hunk.buf_start - 1 + npairs, false)
        for i = 1, math.min(npairs, #new_lines) do
          local old_spans, new_spans = diff.word_diff(hunk.base_lines[i], new_lines[i])
          if old_spans then
            word_spans[i] = old_spans
            local row = clamp_row(hunk.buf_start + i - 1)
            for _, span in ipairs(new_spans) do
              local start_col = math.min(span[1], #new_lines[i])
              local end_col = math.min(span[2], #new_lines[i])
              if end_col > start_col then
                vim.api.nvim_buf_set_extmark(buf, M.ns, row, start_col, {
                  end_col = end_col,
                  hl_group = "NeoReviewAddInline",
                  priority = 10,
                })
              end
            end
          end
        end
      end
      if opts.overlay and hunk.kind == "change" and #hunk.base_lines > 0 then
        vim.api.nvim_buf_set_extmark(buf, M.ns, clamp_row(hunk.buf_start), 0, {
          virt_lines = deleted_virt(hunk.base_lines, max_virt, word_spans),
          virt_lines_above = true,
        })
      end
    end
  end
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
