-- Snacks explorer integration: while review mode is on with a NON-default
-- baseline, the explorer's git-status column shows status vs the review
-- baseline instead of working-tree status.
--
-- HOW IT WORKS (and where to look when it breaks):
-- snacks splits explorer git status into two halves:
--   snacks.explorer.git.update(cwd)            -- runs `git status --porcelain`
--   snacks.explorer.git._update(cwd, results)  -- writes results into the file
--                                                 tree and re-renders
-- We temporarily replace `update` with a version that feeds `_update` a
-- baseline diff instead. `_update` is an internal snacks API: if snacks.nvim
-- reorganizes these functions, preflight() below fails closed and review
-- falls back to native explorer behavior with a warning. Diagnose with
-- :checkhealth neo-review — it reports exactly which seam went missing.
local M = {
  active = false,
  last_error = nil, ---@type string? shown by :checkhealth neo-review
}

local UPDATE_TTL_MS = 4000 -- our replacement bypasses snacks' cache; rate-limit ourselves
local last_run = 0
local original_update = nil

---Verify every snacks internal we depend on. Returns ok, reason.
---@return boolean, string?
function M.preflight()
  local ok, gitmod = pcall(require, "snacks.explorer.git")
  if not ok then
    return false, "require('snacks.explorer.git') failed — snacks.nvim missing or its explorer was restructured"
  end
  for _, fn in ipairs({ "update", "_update", "refresh" }) do
    if type(gitmod[fn]) ~= "function" then
      return false, ("snacks.explorer.git.%s() no longer exists — snacks.nvim internals changed"):format(fn)
    end
  end
  if not (_G.Snacks and Snacks.git and type(Snacks.git.get_root) == "function") then
    return false, "Snacks.git.get_root() no longer exists — snacks.nvim internals changed"
  end
  return true
end

local function fail(reason)
  M.last_error = reason
  M.deactivate()
  vim.notify(
    "neo-review.nvim: snacks explorer integration disabled — "
      .. reason
      .. "\nSee :checkhealth neo-review; the patch lives in lua/neo-review/integrations/snacks_explorer.lua",
    vim.log.levels.WARN
  )
end

---Re-run any open explorer pickers so the status column redraws now.
local function refresh_explorers()
  for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
    p:find()
  end
end

---Replacement for snacks.explorer.git.update while active.
local function baseline_update(cwd, opts)
  opts = opts or {}
  local now = vim.uv.now()
  if not opts.force and now - last_run < UPDATE_TTL_MS then
    return
  end
  last_run = now

  local ok, err = pcall(function()
    local gitmod = require("snacks.explorer.git")
    local root = Snacks.git.get_root(cwd) or require("neo-review.session").root
    local results = {}
    for rel, code in pairs(M.review_statuses(root)) do
      results[#results + 1] = { status = code, file = root .. "/" .. rel }
    end
    if gitmod._update(cwd, results) and opts.on_update then
      vim.schedule(opts.on_update)
    end
  end)
  if not ok then
    fail("replacement update crashed: " .. tostring(err))
  end
end

---Porcelain-style codes for the explorer, per changed file vs the baseline.
---The letter goes in the UNSTAGED (second) column: snacks paints all
---staged-column codes with one generic "staged" color, but unstaged codes
---get per-kind colors (added green, deleted red, modified blue). Files whose
---hunks are ALL marked reviewed get "!!" — snacks renders that
---ignored-style, i.e. with a dimmed filename: done files visibly fade.
---@return table<string, string> relpath -> two-char code
function M.review_statuses(root)
  local baseline = require("neo-review.baseline")
  local review = require("neo-review")
  local statuses = require("neo-review.git").file_statuses(root, baseline.rev())
  local out = {}
  for rel, code in pairs(statuses) do
    local info = review.file_review_info(rel)
    if info.total > 0 and info.reviewed == info.total then
      out[rel] = "!!"
    else
      out[rel] = " " .. code
    end
  end
  return out
end

---Force a status repaint (reviewed-state changed). No-op unless active.
function M.refresh_statuses()
  if not M.active then
    return
  end
  last_run = 0
  pcall(baseline_update, vim.uv.cwd(), { force = true, on_update = refresh_explorers })
end

---Patch snacks. Idempotent; fails closed via preflight.
function M.activate()
  if M.active then
    return
  end
  local ok, reason = M.preflight()
  if not ok then
    M.last_error = reason
    vim.notify(
      "neo-review.nvim: snacks explorer integration unavailable — " .. reason .. " (see :checkhealth neo-review)",
      vim.log.levels.WARN
    )
    return
  end
  local gitmod = require("snacks.explorer.git")
  original_update = gitmod.update
  gitmod.update = baseline_update
  M.active = true
  M.last_error = nil
  last_run = 0
  baseline_update(vim.uv.cwd(), { force = true, on_update = refresh_explorers })
end

---Restore snacks' own update and re-render with native working-tree status.
function M.deactivate()
  if not M.active then
    return
  end
  local ok, gitmod = pcall(require, "snacks.explorer.git")
  if ok and original_update then
    gitmod.update = original_update
    gitmod.refresh(require("neo-review.session").root or vim.uv.cwd())
    pcall(gitmod.update, vim.uv.cwd(), { force = true, on_update = refresh_explorers })
  end
  original_update = nil
  M.active = false
end

---------------------------------------------------------------------------
-- Changed-files-only filter: hide everything in the explorer except files
-- changed vs the review baseline (and their ancestor dirs, so the tree can
-- reach them). Built on the explorer's documented include/exclude globs:
-- `include` takes precedence over `exclude`, so exclude-everything ("**")
-- plus include-the-changeset shows exactly the changed subtree.
---------------------------------------------------------------------------

M.changed_only = false
local saved_filters = {} ---@type table<any, {include: any, exclude: any}>

local function build_include(root)
  local files = require("neo-review.baseline").changed_files(root)
  local inc, seen = {}, {}
  for _, rel in ipairs(files) do
    inc[#inc + 1] = root .. "/" .. rel
    local dir = vim.fs.dirname(root .. "/" .. rel)
    while dir and #dir >= #root and not seen[dir] do
      seen[dir] = true
      inc[#inc + 1] = dir
      if dir == root then
        break
      end
      dir = vim.fs.dirname(dir)
    end
  end
  return inc
end

---Apply/remove the filter on currently-open explorer pickers.
local function apply_changed_only()
  local session = require("neo-review.session")
  for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
    if M.changed_only then
      saved_filters[p] = saved_filters[p] or { include = p.opts.include, exclude = p.opts.exclude }
      p.opts.include = build_include(session.root)
      p.opts.exclude = { "**" }
    elseif saved_filters[p] then
      p.opts.include = saved_filters[p].include
      p.opts.exclude = saved_filters[p].exclude
      saved_filters[p] = nil
    end
    p:find()
  end
end

---Toggle the changed-files-only explorer view.
function M.toggle_changed_only()
  local session = require("neo-review.session")
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  if not pcall(require, "snacks") then
    vim.notify("neo-review: snacks.nvim not available", vim.log.levels.WARN)
    return
  end
  if #Snacks.picker.get({ source = "explorer" }) == 0 then
    vim.notify("neo-review: no snacks explorer open", vim.log.levels.INFO)
    return
  end
  M.changed_only = not M.changed_only
  local ok, err = pcall(apply_changed_only)
  if not ok then
    M.changed_only = false
    fail("changed-only filter crashed: " .. tostring(err))
    return
  end
  vim.notify("neo-review: explorer showing " .. (M.changed_only and "changed files only" or "all files"))
end

---Expand the explorer tree so every changed-vs-baseline file is revealed
---(snacks has close-all on Z but no expand; blanket expand-all would be
---noisy on big repos, and "show me the changeset" is the actual need).
function M.expand_changed()
  local session = require("neo-review.session")
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  if not pcall(require, "snacks") then
    return
  end
  local pickers = Snacks.picker.get({ source = "explorer" })
  if #pickers == 0 then
    vim.notify("neo-review: no snacks explorer open", vim.log.levels.INFO)
    return
  end
  local ok, err = pcall(function()
    local Tree = require("snacks.explorer.tree")
    for _, rel in ipairs(require("neo-review.baseline").changed_files(session.root)) do
      Tree:show(session.root .. "/" .. rel)
    end
    for _, p in ipairs(pickers) do
      p:find()
    end
  end)
  if not ok then
    fail("expand-changed crashed: " .. tostring(err))
  end
end

---Recompute the filter (baseline switched, changeset moved). No-op when off.
function M.refresh_changed_only()
  if M.changed_only and pcall(require, "snacks") then
    pcall(apply_changed_only)
  end
end

---Called by review on enable/disable/baseline switch: active exactly when
---review mode is on and the integration is enabled (any baseline — the
---reviewed-file indicator needs it on the default working-tree baseline
---too; the trade is that staged/unstaged distinction is hidden while
---reviewing).
function M.sync()
  local session = require("neo-review.session")
  local config = require("neo-review.config")
  local want = session.enabled and config.options.integrations.snacks_explorer and pcall(require, "snacks")
  if want then
    M.activate()
  else
    M.deactivate()
  end
  if not session.enabled and M.changed_only then
    M.changed_only = false
    pcall(apply_changed_only)
  end
  M.refresh_changed_only()
  M.ensure_cursor_hl()
  M.ensure_review_key()
end

---------------------------------------------------------------------------
-- Explorer review key: while review mode is on, keymaps.explorer_review is
-- claimed buffer-locally on explorer list buffers — it toggles reviewed for
-- the file OR WHOLE FOLDER under the cursor (mark_tree_reviewed). Released
-- when review mode turns off. Cheap and idempotent — called from sync()
-- and BufEnter, like ensure_cursor_hl.
---------------------------------------------------------------------------

function M.ensure_review_key()
  local km = require("neo-review.config").options.keymaps
  local key = km and km.explorer_review
  if not key or not (_G.Snacks and Snacks.picker) then
    return
  end
  local enabled = require("neo-review.session").enabled
  pcall(function()
    for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
      local buf = p.list and p.list.win and p.list.win.buf
      if buf and vim.api.nvim_buf_is_valid(buf) then
        if enabled then
          vim.keymap.set("n", key, function()
            local item = p:current()
            if item and item.file then
              require("neo-review").mark_tree_reviewed(item.file)
            end
          end, { buffer = buf, silent = true, desc = "neo-review: toggle reviewed for this file/folder" })
        else
          pcall(vim.keymap.del, "n", key, { buffer = buf })
        end
      end
    end
  end)
end

---------------------------------------------------------------------------
-- Current-row visibility: the unfocused explorer's cursorline is the plain
-- CursorLine group (snacks' follow keeps the cursor on the file you're
-- editing, but the row is nearly invisible). A WINDOW-SCOPED highlight
-- namespace on the list window overrides CursorLine there only — a
-- mechanism snacks never touches, so no clobber-fighting with its
-- winhighlight updates.
---------------------------------------------------------------------------

local cursor_ns = vim.api.nvim_create_namespace("neo-review.explorer.cursor")
vim.api.nvim_set_hl(cursor_ns, "CursorLine", { link = "NeoReviewExplorerCursor" })
vim.api.nvim_set_hl(cursor_ns, "SnacksPickerListCursorLine", { link = "NeoReviewExplorerCursor" })

---Apply (review on) or remove (review off) the namespace on explorer list
---windows. Cheap and idempotent — called from sync() and BufEnter.
function M.ensure_cursor_hl()
  if not (_G.Snacks and Snacks.picker) then
    return
  end
  local enabled = require("neo-review.session").enabled
  local ok = pcall(function()
    for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
      local win = p.list and p.list.win and p.list.win.win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_hl_ns(win, enabled and cursor_ns or 0)
      end
    end
  end)
  local _ = ok
end

---------------------------------------------------------------------------
-- Compound review-explorer toggle (<leader>re / :NeoReviewExplorer): from cold,
-- enable review mode, pre-expand the tree to every changed file, and open
-- the explorer already filtered to the changeset; when open, close it.
---------------------------------------------------------------------------

function M.review_explorer()
  local review = require("neo-review")
  local session = require("neo-review.session")
  if not session.enabled then
    review.enable()
    if not session.enabled then
      return
    end
  end
  if not pcall(require, "snacks") or not Snacks.picker then
    vim.notify("neo-review: snacks.nvim not available", vim.log.levels.WARN)
    return
  end
  local open = Snacks.picker.get({ source = "explorer" })[1]
  if open then
    open:close()
    return
  end
  -- Pre-expand so every changed file is revealed on first paint.
  pcall(function()
    local Tree = require("snacks.explorer.tree")
    for _, rel in ipairs(session.files) do
      Tree:show(session.root .. "/" .. rel)
    end
  end)
  M.changed_only = true
  Snacks.picker.explorer({
    cwd = session.root,
    include = build_include(session.root),
    exclude = { "**" },
  })
  vim.defer_fn(function()
    local p = Snacks.picker.get({ source = "explorer" })[1]
    if p then
      -- The picker's "original" filters are none: toggling changed-only off
      -- later must clear ours, not re-save them as the baseline.
      saved_filters[p] = {}
    end
    M.ensure_cursor_hl()
    M.ensure_review_key()
  end, 120)
end

return M
