local baseline = require("neo-review.baseline")
local config = require("neo-review.config")
local diff = require("neo-review.diff")
local git = require("neo-review.git")
local render = require("neo-review.render")
local session = require("neo-review.session")
local state = require("neo-review.state")

local M = {}

local augroup = vim.api.nvim_create_augroup("neo-review.nvim", { clear = false })
local timers = {} ---@type table<integer, uv.uv_timer_t>

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Per-refresh-cycle memo of per-file review info: computing it runs a git
-- show + diff per file, and the winbar/explorer/pickers all want it.
local review_info_cache = {}

local function invalidate_review_info(rel)
  if rel then
    review_info_cache[rel] = nil
  else
    review_info_cache = {}
  end
end

local function refresh_files()
  session.files = baseline.changed_files(session.root)
  session.statuses = git.file_statuses(session.root, baseline.rev())
  invalidate_review_info()
end

---Reviewed-state summary for a changed file (memoized per refresh cycle).
---Content-hashed, so an edit to any reviewed hunk automatically returns it
---(and the file) to outstanding.
---@return { total: integer, reviewed: integer, hashes: string[] }
function M.file_review_info(rel)
  local cached = review_info_cache[rel]
  if cached then
    return cached
  end
  local hunks, lines = M.file_hunks(rel)
  local hashes, reviewed_n = {}, 0
  for _, h in ipairs(hunks) do
    local hash = diff.hash(rel, h, lines)
    hashes[#hashes + 1] = hash
    if state.is_reviewed(session.reviewed, baseline.key(), hash) then
      reviewed_n = reviewed_n + 1
    end
  end
  local info = { total = #hunks, reviewed = reviewed_n, hashes = hashes }
  review_info_cache[rel] = info
  return info
end

---Is this hunk (in this file, with these buffer lines) marked reviewed?
function M.hunk_reviewed(rel, hunk, lines)
  return state.is_reviewed(session.reviewed, baseline.key(), diff.hash(rel, hunk, lines))
end

---Files fully reviewed / total changed files.
---@return integer, integer
function M.progress()
  local done = 0
  for _, rel in ipairs(session.files) do
    local info = M.file_review_info(rel)
    if info.total > 0 and info.reviewed == info.total then
      done = done + 1
    end
  end
  return done, #session.files
end

local function after_reviewed_change(rel)
  invalidate_review_info(rel)
  for b, c in pairs(session.bufs) do
    if not rel or c.relpath == rel then
      M.refresh(b)
    end
  end
  require("neo-review.integrations.snacks_explorer").refresh_statuses()
end

-- Review mode claims hunk-nav keys buffer-locally on attached buffers:
-- gitsigns (e.g. in LazyVim) binds ]h/[h buffer-locally, which would shadow
-- our global maps and keep navigating working-tree hunks regardless of the
-- review baseline. Released again in disable(), which puts back whatever
-- buffer-local map we displaced (LazyVim's ]c = next class, a filetype
-- plugin's ]], gitsigns' ]h …) instead of leaving the key dead.
local displaced = {} ---@type table<integer, table<string, table>>

local function claim_buffer_keymaps(buf)
  local km = config.options.keymaps
  if not km then
    return
  end
  local nav = require("neo-review.nav")
  local set = function(lhs, fn, desc)
    if lhs then
      local prev = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true)
      end)
      -- Only buffer-local maps that aren't ours (re-claims are frequent:
      -- BufEnter, GitSignsUpdate); the latest foreign one wins.
      if prev.buffer == 1 and not (prev.desc or ""):find("^Review:") then
        displaced[buf] = displaced[buf] or {}
        displaced[buf][lhs] = prev
      end
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, silent = true })
    end
  end
  set(km.next_hunk, function()
    nav.hunk(1)
  end, "Review: next hunk (review mode)")
  set(km.prev_hunk, function()
    nav.hunk(-1)
  end, "Review: prev hunk (review mode)")
  set(km.mark_reviewed, M.mark_reviewed, "Review: mark hunk reviewed")
  set(km.review_file, function()
    M.mark_file_reviewed()
  end, "Review: mark whole file reviewed")
  set(km.next_file, function()
    nav.file(1)
  end, "Review: next changed file (review mode)")
  set(km.prev_file, function()
    nav.file(-1)
  end, "Review: prev changed file (review mode)")
  set(km.show_deleted, function()
    require("neo-review.peek").show_deleted(buf)
  end, "Review: view full deleted lines of hunk")
  set(km.comment, M.comment, "Review: comment (open or new thread)")
  set(km.resolve, M.resolve, "Review: toggle thread resolved")
  set(km.next_comment, function()
    nav.comment(1)
  end, "Review: next comment (review mode)")
  set(km.prev_comment, function()
    nav.comment(-1)
  end, "Review: prev comment (review mode)")
  set(km.next_stop, function()
    nav.stop(1)
  end, "Review: next walkthrough stop (review mode)")
  set(km.prev_stop, function()
    nav.stop(-1)
  end, "Review: prev walkthrough stop (review mode)")
end

local function release_buffer_keymaps(buf)
  local km = config.options.keymaps
  if not km or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, lhs in ipairs({
    km.next_hunk,
    km.prev_hunk,
    km.next_file,
    km.prev_file,
    km.mark_reviewed,
    km.review_file,
    km.show_deleted,
    km.comment,
    km.resolve,
    km.next_comment,
    km.prev_comment,
    km.next_stop,
    km.prev_stop,
  }) do
    if lhs then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  for _, prev in pairs(displaced[buf] or {}) do
    vim.api.nvim_buf_call(buf, function()
      pcall(vim.fn.mapset, "n", false, prev)
    end)
  end
  displaced[buf] = nil
end

local function reviewed_fn(relpath, lines)
  return function(hunk)
    return state.is_reviewed(session.reviewed, baseline.key(), diff.hash(relpath, hunk, lines))
  end
end

---Re-diff a buffer against its cached baseline text and redraw.
function M.refresh(buf)
  local cache = session.bufs[buf]
  if not cache or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = buf_lines(buf)
  cache.hunks = diff.hunks(cache.base_text, lines)
  invalidate_review_info(cache.relpath)
  render.apply(buf, cache.hunks, {
    overlay = config.options.overlay,
    reviewed = reviewed_fn(cache.relpath, lines),
  })
  require("neo-review.threads").refresh_buf(buf)
end

local function debounced_refresh(buf)
  local timer = timers[buf]
  if not timer then
    timer = vim.uv.new_timer()
    timers[buf] = timer
  end
  timer:stop()
  timer:start(
    config.options.update_debounce,
    0,
    vim.schedule_wrap(function()
      M.refresh(buf)
    end)
  )
end

---Attach review rendering to a buffer (no-op unless review mode is enabled
---and the buffer is a file inside the session root).
function M.attach(buf)
  if not session.enabled or session.bufs[buf] then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return
  end
  -- realpath both sides so symlinked paths (e.g. /var -> /private/var on
  -- macOS) still match the git root.
  local norm = vim.uv.fs_realpath(vim.fs.normalize(name))
  if not norm or norm:sub(1, #session.root + 1) ~= session.root .. "/" then
    return
  end

  local relpath = git.rel(session.root, norm)
  if relpath:sub(1, 8) == ".review/" then
    return
  end
  session.bufs[buf] = {
    relpath = relpath,
    base_text = baseline.file_text(session.root, relpath),
    hunks = {},
  }
  claim_buffer_keymaps(buf)
  M.refresh(buf)

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not session.bufs[buf] then
        return true -- detach
      end
      debounced_refresh(buf)
    end,
    on_detach = function()
      session.bufs[buf] = nil
      if timers[buf] then
        timers[buf]:stop()
        timers[buf]:close()
        timers[buf] = nil
      end
      -- A reload (:e, or :checktime picking up an external edit — e.g. an
      -- agent changing the file while it's open) also detaches buf_attach
      -- callbacks. The BufReadPost autocmd can't recover: it fires while
      -- the stale session entry still exists, so attach() no-ops, and THEN
      -- this detach clears it. Re-attach once the reload settles; for
      -- genuinely gone buffers (:bdelete/:bwipeout) the guards make this
      -- a no-op.
      vim.schedule(function()
        if session.enabled and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
          M.attach(buf)
        end
      end)
    end,
  })
end

local function update_winbar()
  if not config.options.winbar then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local cache = session.bufs[buf]
  if not cache then
    if (vim.wo.winbar or ""):find("^review ▸") then
      vim.wo.winbar = ""
    end
    return
  end
  local fidx = session.file_index(cache.relpath)
  local _, hidx = require("neo-review.nav").hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  local agent = require("neo-review.agent").status_text()
  local done, total = M.progress()
  vim.wo.winbar = string.format(
    "review ▸ %s · %s · file %s/%d · hunk %s/%d · ✓%d/%d%s",
    baseline.label(),
    cache.relpath,
    fidx and tostring(fidx) or "–",
    #session.files,
    hidx and tostring(hidx) or "–",
    #cache.hunks,
    done,
    total,
    agent ~= "" and (" · " .. agent) or ""
  )
end

function M.enable()
  if session.enabled then
    return
  end
  local origin = vim.api.nvim_buf_get_name(0)
  local root = git.root(origin ~= "" and origin or (vim.uv.cwd() .. "/."))
  if not root then
    vim.notify("neo-review: not inside a git repository", vim.log.levels.WARN)
    return
  end
  session.enabled = true
  session.root = vim.uv.fs_realpath(vim.fs.normalize(root)) or vim.fs.normalize(root)
  require("neo-review.repo").ensure(session.root)
  session.reviewed = state.load(session.root)
  refresh_files()

  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = augroup,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      -- The changed-file list can grow when a new file is saved.
      if session.bufs[ev.buf] then
        refresh_files()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = augroup,
    callback = update_winbar,
  })
  -- The "auto" deleted-lines cap depends on window height (render.max_deleted).
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = augroup,
    callback = function()
      for buf in pairs(session.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          debounced_refresh(buf)
        end
      end
    end,
  })
  -- Re-claim nav keys after gitsigns attaches: gitsigns attaches
  -- asynchronously (LazyVim binds its ]h/[h in on_attach), so its
  -- buffer-local maps can land *after* ours did at attach time. It fires
  -- User GitSignsUpdate right after attaching/updating; the event carries no
  -- buffer, so re-claim every attached buffer (idempotent and cheap).
  -- BufEnter below is the belt-and-suspenders for other async mappers.
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "GitSignsUpdate",
    callback = function()
      for buf in pairs(session.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          claim_buffer_keymaps(buf)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function(ev)
      if session.bufs[ev.buf] then
        claim_buffer_keymaps(ev.buf)
      end
      -- Keep the explorer's current-row highlight and review key applied
      -- (explorer windows can be (re)opened at any time; idempotent + cheap).
      require("neo-review.integrations.snacks_explorer").ensure_cursor_hl()
      require("neo-review.integrations.snacks_explorer").ensure_review_key()
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
  update_winbar()
  require("neo-review.integrations.snacks_explorer").sync()
  local threads = require("neo-review.threads")
  threads.sync()
  threads.start_polling()
  vim.notify(
    string.format("neo-review: on (vs %s, %d changed file%s)", baseline.label(), #session.files, #session.files == 1 and "" or "s")
  )
end

function M.disable()
  if not session.enabled then
    return
  end
  vim.api.nvim_clear_autocmds({ group = augroup })
  local threads = require("neo-review.threads")
  threads.stop_polling()
  for buf in pairs(session.bufs) do
    render.clear(buf)
    threads.clear(buf)
    release_buffer_keymaps(buf)
  end
  require("neo-review.integrations.snacks_explorer").deactivate()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if (vim.wo[win].winbar or ""):find("^review ▸") then
      vim.wo[win].winbar = ""
    end
  end
  session.reset()
  -- After reset so the integration sees enabled=false and also clears the
  -- changed-only explorer filter.
  require("neo-review.integrations.snacks_explorer").sync()
  vim.notify("neo-review: off")
end

function M.toggle()
  if session.enabled then
    M.disable()
  else
    M.enable()
  end
end

---:NeoReviewBaseline [rev] — switch baselines live.
function M.set_baseline(arg)
  if not session.enabled then
    M.enable()
    if not session.enabled then
      return
    end
  end
  local ok, err = baseline.set(session.root, arg)
  if not ok then
    vim.notify("neo-review: " .. err, vim.log.levels.ERROR)
    return
  end
  refresh_files()
  for buf, cache in pairs(session.bufs) do
    cache.base_text = baseline.file_text(session.root, cache.relpath)
    M.refresh(buf)
  end
  update_winbar()
  require("neo-review.integrations.snacks_explorer").sync()
  vim.notify(string.format("neo-review: baseline = %s (%d changed files)", baseline.label(), #session.files))
end

---Toggle reviewed-state for the hunk under the cursor.
function M.mark_reviewed()
  local buf = vim.api.nvim_get_current_buf()
  local cache = session.bufs[buf]
  if not cache then
    return
  end
  local hunk = require("neo-review.nav").hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not hunk then
    vim.notify("neo-review: no hunk under cursor", vim.log.levels.INFO)
    return
  end
  local hash = diff.hash(cache.relpath, hunk, buf_lines(buf))
  local now = state.toggle(session.root, session.reviewed, baseline.key(), hash)
  after_reviewed_change(cache.relpath)
  vim.notify("neo-review: hunk marked " .. (now and "reviewed" or "unreviewed"))
end

---Toggle reviewed for a whole FILE (all current hunks; content-hashed, so
---later edits to any hunk return it to outstanding). rel defaults to the
---current buffer's file. Marks then auto-advances to the next unreviewed
---file (config review.advance_after_file).
---@param rel string?
function M.mark_file_reviewed(rel)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  if not rel or rel == "" then
    local cache = session.bufs[vim.api.nvim_get_current_buf()]
    rel = cache and cache.relpath
  end
  if not rel then
    vim.notify("neo-review: no changed file here", vim.log.levels.INFO)
    return
  end
  local info = M.file_review_info(rel)
  if info.total == 0 then
    vim.notify("neo-review: " .. rel .. " has no hunks vs the baseline", vim.log.levels.INFO)
    return
  end
  local marking = info.reviewed < info.total
  state.set_many(session.root, session.reviewed, baseline.key(), info.hashes, marking)
  after_reviewed_change(rel)
  update_winbar()
  vim.notify(
    string.format("neo-review: %s marked %s (%d hunk%s)", rel, marking and "reviewed" or "unreviewed", info.total, info.total == 1 and "" or "s")
  )
  if marking and config.options.review.advance_after_file then
    require("neo-review.nav").file(1)
  end
end

---Toggle reviewed for every changed file at/under PATH (file or folder;
---absolute or repo-relative, "" = whole repo). Marks when anything under it
---is outstanding, unmarks when everything is already reviewed — same toggle
---semantics as mark_file_reviewed, one level up.
function M.mark_tree_reviewed(path)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local rel = path or ""
  if rel:sub(1, 1) == "/" then
    local norm = vim.uv.fs_realpath(vim.fs.normalize(rel)) or vim.fs.normalize(rel)
    if norm == session.root then
      rel = ""
    elseif norm:sub(1, #session.root + 1) == session.root .. "/" then
      rel = norm:sub(#session.root + 2)
    else
      vim.notify("neo-review: " .. path .. " is outside the repo", vim.log.levels.INFO)
      return
    end
  end
  local hashes, outstanding, matched = {}, 0, 0
  for _, f in ipairs(session.files) do
    if rel == "" or f == rel or f:sub(1, #rel + 1) == rel .. "/" then
      local info = M.file_review_info(f)
      matched = matched + 1
      outstanding = outstanding + (info.total - info.reviewed)
      vim.list_extend(hashes, info.hashes)
    end
  end
  if matched == 0 then
    vim.notify("neo-review: no changed files under " .. (rel == "" and "the repo root" or rel), vim.log.levels.INFO)
    return
  end
  local marking = outstanding > 0
  state.set_many(session.root, session.reviewed, baseline.key(), hashes, marking)
  after_reviewed_change(nil)
  update_winbar()
  vim.notify(
    string.format(
      "neo-review: %s marked %s (%d file%s)",
      rel == "" and "everything" or rel,
      marking and "reviewed" or "unreviewed",
      matched,
      matched == 1 and "" or "s"
    )
  )
end

---Mark EVERY hunk in the changeset reviewed (opposite of clear_reviewed).
---Content-hashed like the rest: later edits return those hunks to
---outstanding on their own.
function M.review_all()
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local hashes, outstanding = {}, 0
  for _, rel in ipairs(session.files) do
    local info = M.file_review_info(rel)
    outstanding = outstanding + (info.total - info.reviewed)
    vim.list_extend(hashes, info.hashes)
  end
  if outstanding == 0 then
    vim.notify("neo-review: nothing outstanding — everything is already reviewed")
    return
  end
  if vim.fn.confirm(string.format("Mark ALL %d outstanding hunk%s reviewed?", outstanding, outstanding == 1 and "" or "s"), "&Yes\n&No", 2) ~= 1 then
    return
  end
  state.set_many(session.root, session.reviewed, baseline.key(), hashes, true)
  after_reviewed_change(nil)
  update_winbar()
  vim.notify(string.format("neo-review: all %d file%s marked reviewed", #session.files, #session.files == 1 and "" or "s"))
end

---Reset every reviewed checkmark for the current baseline.
function M.clear_reviewed()
  if not session.enabled then
    return
  end
  local done, total = M.progress()
  if vim.fn.confirm(string.format("Reset reviewed-state? (%d/%d files currently reviewed)", done, total), "&Yes\n&No", 2) ~= 1 then
    return
  end
  state.clear_key(session.root, session.reviewed, baseline.key())
  after_reviewed_change(nil)
  update_winbar()
  vim.notify("neo-review: reviewed-state reset")
end

---<leader>rc / :NeoReviewComment [kind]: open the thread at the cursor if one
---exists, otherwise start a new one.
---@param kind string?
function M.comment(kind)
  if not session.enabled then
    vim.notify("neo-review: review mode is off (:NeoReviewToggle)", vim.log.levels.INFO)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local threads = require("neo-review.threads")
  local ui = require("neo-review.threads.ui")
  local existing = threads.at_line(buf, vim.api.nvim_win_get_cursor(0)[1])
  if existing and not (kind and kind ~= "") then
    ui.open(existing)
  else
    ui.new(buf, kind and kind ~= "" and kind or nil)
  end
end

---Toggle resolved for the thread in the current thread buffer, or the thread
---on the current code line.
function M.resolve()
  local buf = vim.api.nvim_get_current_buf()
  local ui = require("neo-review.threads.ui")
  local id = ui.buf_thread_id(buf)
  if not id then
    local t = require("neo-review.threads").at_line(buf, vim.api.nvim_win_get_cursor(0)[1])
    id = t and t.id
  end
  if not id then
    vim.notify("neo-review: no thread here", vim.log.levels.INFO)
    return
  end
  ui.toggle_resolve_id(id)
end

---Delete the thread in the current thread buffer / on the current line.
function M.delete_thread()
  local buf = vim.api.nvim_get_current_buf()
  local ui = require("neo-review.threads.ui")
  local id = ui.buf_thread_id(buf)
  if not id then
    local t = require("neo-review.threads").at_line(buf, vim.api.nvim_win_get_cursor(0)[1])
    id = t and t.id
  end
  if not id then
    vim.notify("neo-review: no thread here", vim.log.levels.INFO)
    return
  end
  ui.delete(id)
end

---Delete every resolved thread (cleanup).
function M.clean_resolved()
  local threads = require("neo-review.threads")
  local store = require("neo-review.threads.store")
  threads.reload()
  local resolved = vim.tbl_filter(function(t)
    return t.status == "resolved"
  end, threads.threads)
  if #resolved == 0 then
    vim.notify("neo-review: no resolved threads", vim.log.levels.INFO)
    return
  end
  local prompt = string.format("Delete %d resolved thread%s?", #resolved, #resolved == 1 and "" or "s")
  if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
    return
  end
  for _, t in ipairs(resolved) do
    store.delete(session.root, t.id)
  end
  threads.sync()
  vim.notify(string.format("neo-review: deleted %d resolved thread%s", #resolved, #resolved == 1 and "" or "s"))
end

---Hunks for any changed file, loaded buffer or not (used by qf/pickers).
---@return review.Hunk[], string[]
function M.file_hunks(relpath)
  for _, cache in pairs(session.bufs) do
    if cache.relpath == relpath then
      for buf, c in pairs(session.bufs) do
        if c == cache and vim.api.nvim_buf_is_valid(buf) then
          return cache.hunks, buf_lines(buf)
        end
      end
    end
  end
  local abs = session.root .. "/" .. relpath
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then
    lines = {}
  end
  return diff.hunks(baseline.file_text(session.root, relpath), lines), lines
end

---Statusline component: "agent" while the agent terminal's claude is
---running, else "". User NeoReviewAgentStateChanged (data: running) fires on
---start/exit — native-statusline users can redrawstatus on it.
function M.statusline()
  return require("neo-review.agent").status_text()
end

---Compact icon for a native 'statusline' ("%#NeoReviewAgent#●%*" while the
---agent terminal is running, else "").
function M.statusline_icon()
  local icon, hl = require("neo-review.agent").status_icon()
  if not icon then
    return ""
  end
  return "%#" .. hl .. "#" .. icon .. "%*"
end

---Ready-made lualine component for the same icon (drop into any section):
---  table.insert(opts.sections.lualine_x, 1, require("neo-review").lualine())
function M.lualine()
  return {
    function()
      return (require("neo-review.agent").status_icon()) or ""
    end,
    cond = function()
      return require("neo-review.agent").status().running
    end,
    color = function()
      local _, hl = require("neo-review.agent").status_icon()
      return hl
    end,
  }
end

function M.setup(opts)
  M._did_setup = true
  config.setup(opts)
  render.define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = render.define_highlights,
  })

  if config.options.skill.auto_install then
    vim.schedule(function()
      require("neo-review.skill").auto_install()
    end)
  end

  local km = config.options.keymaps
  if km then
    local nav = require("neo-review.nav")
    local picker = require("neo-review.picker")
    local map = function(lhs, fn, desc)
      if lhs then
        vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
      end
    end
    map(km.toggle, M.toggle, "Review: toggle")
    map(km.next_hunk, function()
      nav.hunk(1)
    end, "Review: next hunk")
    map(km.prev_hunk, function()
      nav.hunk(-1)
    end, "Review: prev hunk")
    map(km.mark_reviewed, M.mark_reviewed, "Review: mark hunk reviewed")
    map(km.review_file, M.mark_file_reviewed, "Review: mark whole file reviewed")
    map(km.next_file, function()
      nav.file(1)
    end, "Review: next changed file")
    map(km.prev_file, function()
      nav.file(-1)
    end, "Review: prev changed file")
    map(km.files, picker.files, "Review: changed files")
    map(km.hunks, picker.hunks, "Review: hunks")
    map(km.comment, M.comment, "Review: comment (open or new thread)")
    map(km.resolve, M.resolve, "Review: toggle thread resolved")
    map(km.threads, picker.threads, "Review: comment threads")
    map(km.explorer, function()
      require("neo-review.integrations.snacks_explorer").review_explorer()
    end, "Review: explorer (filtered + expanded to changeset)")
    map(km.explorer_filter, function()
      require("neo-review.integrations.snacks_explorer").toggle_changed_only()
    end, "Review: explorer changed-files-only")
    map(km.explorer_expand, function()
      require("neo-review.integrations.snacks_explorer").expand_changed()
    end, "Review: explorer reveal changed files")
    map(km.agent_open, function()
      require("neo-review.agent").toggle()
    end, "Review: open/toggle agent terminal")
    map(km.agent_ping, function()
      require("neo-review.agent").ping()
    end, "Review: ping agent about open threads")
    map(km.next_comment, function()
      nav.comment(1)
    end, "Review: next comment")
    map(km.prev_comment, function()
      nav.comment(-1)
    end, "Review: prev comment")
    map(km.next_stop, function()
      nav.stop(1)
    end, "Review: next walkthrough stop")
    map(km.prev_stop, function()
      nav.stop(-1)
    end, "Review: prev walkthrough stop")
  end
end

return M
