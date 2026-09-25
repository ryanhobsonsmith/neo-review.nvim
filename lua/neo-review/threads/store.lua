-- Thread storage: .review/threads/<id>/ in the repo.
--
-- One file per message / status event, each with a collision-proof name:
-- the editor and an agent writing the same thread seconds apart (or two
-- branches) add DIFFERENT files, so they never overwrite each other. Thread
-- state (messages, resolved/open) is materialized by reading the directory.
--
-- Files are EDITABLE in place: agents correct their own stops and messages
-- (wrong claim, bad anchor, renumbered series). Edits are rare and
-- single-author, so the occasional git conflict is an acceptable price.
-- The poll fingerprint includes mtimes so in-place edits re-render.
--
--   thread.json                       anchor + kind + creator
--                                     (+ optional series membership)
--   msg-<ts>-<rand>-<author>.json     one message
--   status-<ts>-<rand>-<author>.json  status event; latest ts wins
local M = {}

-- Microsecond precision: messages written in the same second (a fast agent,
-- or create+reply in one action) must still sort deterministically by ts.
local function now_parts()
  local sec, usec = vim.uv.gettimeofday()
  return sec, usec
end

local function iso_now()
  local sec, usec = now_parts()
  return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%06dZ", usec)
end

local function compact_now()
  local sec, usec = now_parts()
  return os.date("!%Y%m%dT%H%M%S", sec) .. string.format("%06d", usec)
end

local function rand4()
  return string.format("%04x", math.random(0, 0xffff))
end

local function slug(name)
  return (name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):sub(1, 24))
end

local function threads_dir(root)
  return root .. "/.review/threads"
end

local function write_json(path, tbl)
  local blob = vim.json.encode(tbl)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(blob, "\n"), path)
end

local function read_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and decoded or nil
end

---Comparable epoch-ish value for an ISO ts (consistent local interpretation;
---only ever compared against values from the same function).
local function ts_epochish(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
end

local FUTURE_SKEW = 300 -- seconds

---Agents sometimes INVENT timestamps instead of reading the clock (they
---don't know the time), which mis-sorts conversations and can make a bogus
---status event win. Defense: if a record's ts is further in the future than
---the file's own mtime allows, correct it (in memory only — files are never
---rewritten) to the mtime, which is the true local write time.
---@param rec table with a .ts field
---@param path string
local function clamp_future_ts(rec, path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not rec.ts then
    return rec
  end
  local claimed = ts_epochish(rec.ts)
  local mtime_t = os.date("!*t", stat.mtime.sec)
  mtime_t.isdst = false
  local written = os.time(mtime_t)
  if claimed and written and claimed > written + FUTURE_SKEW then
    -- Microsecond precision so corrected values sort consistently against
    -- our own fractional timestamps within the same second.
    rec.ts = os.date("!%Y-%m-%dT%H:%M:%S", stat.mtime.sec) .. string.format(".%06dZ", math.floor((stat.mtime.nsec or 0) / 1000))
    rec.ts_corrected = true
  end
  return rec
end

---@class review.ThreadMessage
---@field author string
---@field role "human"|"agent"
---@field ts string ISO 8601
---@field body string[]

---Walkthrough membership. `pos` only sorts stops
---within a series (fractional values slot a late stop between two others);
---`rank`/`total` are the displayed position, filled in by threads.reload().
---@class review.ThreadSeries
---@field id string
---@field pos number
---@field rank integer?
---@field total integer?

---@class review.Thread
---@field id string
---@field dir string
---@field file string repo-relative
---@field kind string question|issue|suggestion|nitpick|note|praise|worker
---@field created string
---@field anchor { line: integer, snippet: string[], context_before: string[], context_after: string[], symbol: string? }
---@field messages review.ThreadMessage[]
---@field status "open"|"resolved"
---@field series review.ThreadSeries?

---Create a new thread with its first message. Returns the thread id.
---@param root string
---@param opts { file: string, kind: string, anchor: table, author: string, role: string, body: string[], series: { id: string, pos: number }? }
---@return string
function M.create(root, opts)
  require("neo-review.repo").ensure(root)
  local id = string.format("%x%s", os.time() % 0xffffff, rand4())
  local dir = threads_dir(root) .. "/" .. id
  write_json(dir .. "/thread.json", {
    version = 1,
    id = id,
    file = opts.file,
    kind = opts.kind,
    created = iso_now(),
    anchor = opts.anchor,
    series = opts.series and { id = opts.series.id, pos = opts.series.pos } or nil,
  })
  M.reply(root, id, opts)
  return id
end

---Append a message to a thread.
---@param opts { author: string, role: string, body: string[] }
function M.reply(root, id, opts)
  local name = string.format("msg-%s-%s-%s.json", compact_now(), rand4(), slug(opts.author))
  write_json(threads_dir(root) .. "/" .. id .. "/" .. name, {
    author = opts.author,
    role = opts.role,
    ts = iso_now(),
    body = opts.body,
  })
end

---Record a status event ("resolved" or "open").
function M.set_status(root, id, status, author)
  local name = string.format("status-%s-%s-%s.json", compact_now(), rand4(), slug(author))
  write_json(threads_dir(root) .. "/" .. id .. "/" .. name, {
    status = status,
    author = author,
    ts = iso_now(),
  })
end

---A thread.json `series` value, or nil when absent/malformed (a malformed
---field makes the thread standalone rather than dropping it).
---@return review.ThreadSeries?
local function valid_series(s)
  if type(s) == "table" and type(s.id) == "string" and s.id ~= "" and type(s.pos) == "number" then
    return { id = s.id, pos = s.pos }
  end
  return nil
end

---Load one thread directory into a materialized thread. nil if malformed.
---@return review.Thread?
function M.load(root, id)
  local dir = threads_dir(root) .. "/" .. id
  local meta = read_json(dir .. "/thread.json")
  if not meta or not meta.file or not meta.anchor then
    return nil
  end
  local messages, status_events = {}, {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" then
      if name:match("^msg%-") then
        local msg = read_json(dir .. "/" .. name)
        if msg and msg.body then
          msg._file = name
          messages[#messages + 1] = clamp_future_ts(msg, dir .. "/" .. name)
        end
      elseif name:match("^status%-") then
        local ev = read_json(dir .. "/" .. name)
        if ev and ev.status then
          status_events[#status_events + 1] = clamp_future_ts(ev, dir .. "/" .. name)
        end
      end
    end
  end
  -- Render order / status: timestamp, filename as tiebreak (both sortable).
  table.sort(messages, function(a, b)
    if a.ts ~= b.ts then
      return a.ts < b.ts
    end
    return a._file < b._file
  end)
  table.sort(status_events, function(a, b)
    return a.ts < b.ts
  end)
  local last = status_events[#status_events]
  return {
    id = meta.id or id,
    dir = dir,
    file = meta.file,
    kind = meta.kind or "note",
    created = meta.created or "",
    anchor = meta.anchor,
    messages = messages,
    status = last and last.status or "open",
    series = valid_series(meta.series),
  }
end

---Delete a thread directory (editor cleanup; agents only on the user's
---request, per SKILL.md). Can raise ordinary git delete/modify conflicts if
---another branch touched the thread — acceptable for an explicit op.
function M.delete(root, id)
  vim.fn.delete(threads_dir(root) .. "/" .. id, "rf")
end

---All threads in the repo, newest first.
---@return review.Thread[]
function M.list(root)
  local dir = threads_dir(root)
  local threads = {}
  if vim.fn.isdirectory(dir) == 1 then
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" then
        local t = M.load(root, name)
        if t then
          threads[#threads + 1] = t
        end
      end
    end
  end
  table.sort(threads, function(a, b)
    return a.created > b.created
  end)
  return threads
end

return M
