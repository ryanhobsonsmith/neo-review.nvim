-- Headless test runner:  nvim --headless -l tests/run.lua
-- Plain asserts, no framework; exits non-zero on any failure.

-- Absolute plugin root: the source path may be relative (e.g. "@tests/run.lua"
-- when invoked from the repo root), and tests cd around — a relative rtp
-- entry would silently stop resolving modules after the first cd.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.opt.rtp:prepend(root)

local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write("ok   ", name, "\n")
  else
    failed = failed + 1
    io.write("FAIL ", name, "\n     ", tostring(err), "\n")
  end
end

local function eq(want, got, label)
  if not vim.deep_equal(want, got) then
    error(string.format("%s\n  want: %s\n  got:  %s", label or "not equal", vim.inspect(want), vim.inspect(got)), 2)
  end
end

---------------------------------------------------------------- diff.hunks

local diff = require("neo-review.diff")

test("diff: identical -> no hunks", function()
  eq({}, diff.hunks("a\nb\n", { "a", "b" }))
end)

test("diff: pure addition", function()
  local h = diff.hunks("a\nc\n", { "a", "b", "c" })
  eq(1, #h)
  eq("add", h[1].kind)
  eq(2, h[1].buf_start)
  eq(1, h[1].buf_count)
  eq({}, h[1].base_lines)
end)

test("diff: pure deletion", function()
  local h = diff.hunks("a\nb\nc\n", { "a", "c" })
  eq(1, #h)
  eq("delete", h[1].kind)
  eq(1, h[1].buf_start, "delete anchors to the line after which text was removed")
  eq({ "b" }, h[1].base_lines)
end)

test("diff: change", function()
  local h = diff.hunks("a\nold\nc\n", { "a", "new", "c" })
  eq(1, #h)
  eq("change", h[1].kind)
  eq(2, h[1].buf_start)
  eq(1, h[1].buf_count)
  eq({ "old" }, h[1].base_lines)
end)

test("diff: new file -> single add hunk covering everything", function()
  local h = diff.hunks("", { "x", "y" })
  eq(1, #h)
  eq("add", h[1].kind)
  eq(1, h[1].buf_start)
  eq(2, h[1].buf_count)
end)

test("diff: deletion at top of file", function()
  local h = diff.hunks("gone\na\n", { "a" })
  eq(1, #h)
  eq("delete", h[1].kind)
  eq(0, h[1].buf_start)
end)

test("diff: base without trailing newline", function()
  local h = diff.hunks("a\nb", { "a", "b" })
  eq({}, h)
end)

test("diff: hash is stable under unrelated-line moves and changes with content", function()
  local lines1 = { "pad", "a", "new", "c" }
  local h1 = diff.hunks("pad\na\nold\nc\n", lines1)[1]
  local lines2 = { "pad", "pad2", "a", "new", "c" } -- hunk shifted down one line
  local h2 = diff.hunks("pad\npad2\na\nold\nc\n", lines2)[1]
  eq(diff.hash("f.txt", h1, lines1), diff.hash("f.txt", h2, lines2), "same content, different position")

  local lines3 = { "pad", "a", "different", "c" }
  local h3 = diff.hunks("pad\na\nold\nc\n", lines3)[1]
  assert(diff.hash("f.txt", h1, lines1) ~= diff.hash("f.txt", h3, lines3), "content change must change hash")
end)

---------------------------------------------------------------- diff.word_diff

test("word_diff: identical lines -> nil", function()
  eq(nil, (diff.word_diff("local x = 1", "local x = 1")))
end)

test("word_diff: single changed word, both sides", function()
  local old_spans, new_spans = diff.word_diff("foo old bar", "foo new bar")
  eq({ { 4, 7 } }, old_spans)
  eq({ { 4, 7 } }, new_spans)
end)

test("word_diff: multiple spans", function()
  local old_spans, new_spans = diff.word_diff("keep alpha keep beta keep", "keep ALPHA keep BETA keep")
  eq({ { 5, 10 }, { 16, 20 } }, old_spans)
  eq({ { 5, 10 }, { 16, 20 } }, new_spans)
end)

test("word_diff: whitespace-only change", function()
  local old_spans, new_spans = diff.word_diff("a b and more here", "a  b and more here")
  eq({ { 1, 2 } }, old_spans)
  eq({ { 1, 3 } }, new_spans)
end)

test("word_diff: pure insertion highlights only the new side", function()
  local old_spans, new_spans = diff.word_diff("foo bar", "foo extra bar")
  eq({}, old_spans, "nothing removed on the old side")
  eq(1, #new_spans)
  eq("extra ", ("foo extra bar"):sub(new_spans[1][1] + 1, new_spans[1][2]))
end)

test("word_diff: completely different pair -> nil (whole-line tint suffices)", function()
  eq(nil, (diff.word_diff("foo bar baz", "qux quux corge")))
end)

test("word_diff: very long line -> nil", function()
  eq(nil, (diff.word_diff(("x"):rep(1500) .. " old", ("x"):rep(1500) .. " new")))
end)

---------------------------------------------------------------- render: deleted-lines cap

local render = require("neo-review.render")

-- baseline with 20 lines deleted between "a" and "c"
local function big_delete()
  local base = { "a" }
  for i = 1, 20 do
    base[#base + 1] = "gone " .. i
  end
  base[#base + 1] = "c"
  return table.concat(base, "\n") .. "\n"
end

test("render: large deletion is capped with a '+N more' tail", function()
  require("neo-review.config").setup({ overlay_max_lines = 5 })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "c" })
  local hunks = diff.hunks(big_delete(), { "a", "c" })
  eq(1, #hunks)
  eq("delete", hunks[1].kind)
  render.apply(buf, hunks, { overlay = true, reviewed = function()
    return false
  end })

  local virt
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    virt = m[4].virt_lines or virt
  end
  assert(virt, "no virt_lines extmark")
  eq(6, #virt, "5 capped lines + tail marker")
  eq("gone 1", virt[1][1][1])
  assert(virt[#virt][1][1]:find("+15 more deleted lines", 1, true), virt[#virt][1][1])
  eq("NeoReviewDeleteMore", virt[#virt][1][2])

  -- a cap larger than the block leaves it whole, no tail
  require("neo-review.config").setup({ overlay_max_lines = 50 })
  render.apply(buf, hunks, { overlay = true, reviewed = function()
    return false
  end })
  virt = nil
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    virt = m[4].virt_lines or virt
  end
  eq(20, #virt, "uncapped block, no tail marker")

  vim.api.nvim_buf_delete(buf, { force = true })
  require("neo-review.config").setup({})
end)

test("render: word-diff spans on buffer line and deleted virt_line", function()
  require("neo-review.config").setup({})
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "foo new bar", "c" })
  local hunks = diff.hunks("a\nfoo old bar\nc\n", { "a", "foo new bar", "c" })
  eq(1, #hunks)
  eq("change", hunks[1].kind)
  render.apply(buf, hunks, { overlay = true, reviewed = function()
    return false
  end })

  local inline, virt, tint
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    if m[4].hl_group == "NeoReviewAddInline" then
      inline = { row = m[2], col = m[3], end_col = m[4].end_col }
    elseif m[4].hl_group == "NeoReviewAdd" then
      tint = m
    end
    virt = m[4].virt_lines or virt
  end
  assert(inline, "no NeoReviewAddInline extmark")
  -- tint must be a range highlight with hl_eol, NOT line_hl_group: as of
  -- nvim 0.12 the line_hl layer covers range-highlight bgs (the word spans)
  assert(tint, "no NeoReviewAdd tint extmark")
  eq(true, tint[4].hl_eol, "tint must be a range mark with hl_eol")
  eq(2, tint[4].end_row, "tint range must cover the changed line")
  assert(tint[4].line_hl_group == nil, "tint must not use line_hl_group")
  eq({ row = 1, col = 4, end_col = 7 }, inline, "span must cover 'new'")

  assert(virt, "no virt_lines extmark")
  eq(1, #virt)
  eq({ { "foo ", "NeoReviewDeleteVirt" }, { "old", "NeoReviewDeleteInline" }, { " bar", "NeoReviewDeleteVirt" } }, virt[1])

  -- word_diff = false reverts to whole-chunk virt lines and no inline marks
  require("neo-review.config").setup({ word_diff = false })
  render.apply(buf, hunks, { overlay = true, reviewed = function()
    return false
  end })
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    assert(m[4].hl_group ~= "NeoReviewAddInline", "inline mark despite word_diff=false")
    if m[4].virt_lines then
      eq({ { { "foo old bar", "NeoReviewDeleteVirt" } } }, m[4].virt_lines)
    end
  end

  vim.api.nvim_buf_delete(buf, { force = true })
  require("neo-review.config").setup({})
end)

test("peek: full deleted lines open in a read-only scratch split", function()
  require("neo-review.config").setup({ keymaps = false })
  local sess = require("neo-review.session")
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "c" })
  local hunks = diff.hunks(big_delete(), { "a", "c" })
  sess.bufs[buf] = { relpath = "f.txt", base_text = big_delete(), hunks = hunks }
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  require("neo-review.peek").show_deleted(buf)
  local sbuf = vim.api.nvim_get_current_buf()
  assert(sbuf ~= buf, "peek did not open a new buffer")
  eq(false, vim.bo[sbuf].modifiable)
  eq("nofile", vim.bo[sbuf].buftype)
  local got = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
  eq(20, #got)
  eq("gone 1", got[1])
  eq("gone 20", got[20])
  assert(vim.api.nvim_buf_get_name(sbuf):find("review://deleted/f.txt", 1, true))

  vim.cmd("close")
  sess.bufs[buf] = nil
  vim.api.nvim_buf_delete(buf, { force = true })
  require("neo-review.config").setup({})
end)

---------------------------------------------------------------- state

local state = require("neo-review.state")

test("state: toggle round-trip persists", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local reviewed = state.load(tmp)
  eq({}, reviewed)
  eq(true, state.toggle(tmp, reviewed, "head", "hash1"))
  local reloaded = state.load(tmp)
  eq(true, state.is_reviewed(reloaded, "head", "hash1"))
  eq(false, state.is_reviewed(reloaded, "head", "hash2"))
  eq(false, state.is_reviewed(reloaded, "other-baseline", "hash1"))
  eq(false, state.toggle(tmp, reloaded, "head", "hash1"))
  eq(false, state.is_reviewed(state.load(tmp), "head", "hash1"))
  vim.fn.delete(tmp, "rf")
end)

test("state: creates .review with gitignore for local/ and claims/", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  state.save(tmp, {})
  eq({ "local/", "claims/" }, vim.fn.readfile(tmp .. "/.review/.gitignore"))
  vim.fn.delete(tmp, "rf")
end)

---------------------------------------------------------------- git + baseline (integration, temp repo)

local git = require("neo-review.git")

local function sh(cwd, cmd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. " failed: " .. (res.stderr or ""))
end

test("git+baseline: changed files and hunks in a temp repo", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  sh(repo, { "git", "init", "-q", "-b", "main" })
  sh(repo, { "git", "config", "user.email", "t@t" })
  sh(repo, { "git", "config", "user.name", "t" })
  vim.fn.writefile({ "line1", "line2", "line3" }, repo .. "/tracked.txt")
  sh(repo, { "git", "add", "." })
  sh(repo, { "git", "commit", "-q", "-m", "init" })

  -- modify tracked, add untracked
  vim.fn.writefile({ "line1", "CHANGED", "line3" }, repo .. "/tracked.txt")
  vim.fn.writefile({ "brand new" }, repo .. "/new.txt")

  -- realpath both sides: on macOS the tempdir is under /var -> /private/var.
  eq(vim.uv.fs_realpath(repo), vim.uv.fs_realpath(git.root(repo .. "/tracked.txt")), "root")
  eq({ "new.txt", "tracked.txt" }, git.changed_files(repo, "HEAD"), "untracked file must be included")

  local base = git.show(repo, "HEAD", "tracked.txt")
  eq("line1\nline2\nline3\n", base, "git.show must not strip the trailing newline")
  local h = diff.hunks(base, { "line1", "CHANGED", "line3" })
  eq(1, #h)
  eq("change", h[1].kind)

  eq("", git.show(repo, "HEAD", "new.txt") or "", "untracked file has no baseline content")

  -- the plugin's own state dir must never appear in the changeset
  vim.fn.mkdir(repo .. "/.review/local", "p")
  vim.fn.writefile({ "{}" }, repo .. "/.review/local/state.json")
  eq({ "new.txt", "tracked.txt" }, git.changed_files(repo, "HEAD"), ".review/ is filtered out")

  -- file statuses: modified tracked, added untracked, deleted tracked
  vim.fn.writefile({ "doomed" }, repo .. "/doomed.txt")
  sh(repo, { "git", "add", "doomed.txt" })
  sh(repo, { "git", "commit", "-q", "-m", "add doomed" })
  vim.fn.delete(repo .. "/doomed.txt")
  local st = git.file_statuses(repo, "HEAD")
  eq("M", st["tracked.txt"])
  eq("A", st["new.txt"], "untracked reports as added")
  eq("D", st["doomed.txt"])
  vim.fn.delete(repo, "rf")
end)

---------------------------------------------------------------- threads: store

local store = require("neo-review.threads.store")

test("threads: create/reply/resolve round-trip, one file per message/event", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local id = store.create(tmp, {
    file = "src/a.lua",
    kind = "question",
    anchor = { line = 3, snippet = { "local x = 1" }, context_before = {}, context_after = {} },
    author = "ryan",
    role = "human",
    body = { "why is this 1?", "seems arbitrary" },
  })
  local t = store.load(tmp, id)
  eq("question", t.kind)
  eq("open", t.status)
  eq(1, #t.messages)
  eq({ "why is this 1?", "seems arbitrary" }, t.messages[1].body)

  store.reply(tmp, id, { author = "claude", role = "agent", body = { "it matches the spec" } })
  t = store.load(tmp, id)
  eq(2, #t.messages)
  eq("agent", t.messages[2].role)

  store.set_status(tmp, id, "resolved", "claude")
  eq("resolved", store.load(tmp, id).status)
  store.set_status(tmp, id, "open", "ryan")
  eq("open", store.load(tmp, id).status)

  -- every message and status event is its own file
  local files = vim.fn.readdir(tmp .. "/.review/threads/" .. id)
  eq(5, #files, "thread.json + 2 msgs + 2 status events")

  eq(1, #store.list(tmp))
  vim.fn.delete(tmp, "rf")
end)

test("threads: future timestamps are clamped to file mtime for ordering/status", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local id = store.create(tmp, {
    file = "a.lua", kind = "note",
    anchor = { line = 1, snippet = { "x" }, context_before = {}, context_after = {} },
    author = "ryan", role = "human", body = { "real message" },
  })
  local dir = tmp .. "/.review/threads/" .. id
  -- an "agent" writes a reply and a resolved event with invented timestamps
  -- 40 minutes in the future
  local future = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 2400)
  local fname = os.date("!%Y%m%dT%H%M%S", os.time() + 2400)
  vim.fn.writefile({ vim.json.encode({ author = "claude", role = "agent", ts = future, body = { "from the future" } }) },
    dir .. "/msg-" .. fname .. "-aaaa-claude.json")
  vim.fn.writefile({ vim.json.encode({ status = "resolved", author = "claude", ts = future }) },
    dir .. "/status-" .. fname .. "-bbbb-claude.json")
  -- a HUMAN reply written now (honest clock) — must sort AFTER the agent's
  -- clamped message, and its later real activity context stays coherent
  store.reply(tmp, id, { author = "ryan", role = "human", body = { "honest reply" } })

  local t = store.load(tmp, id)
  eq(3, #t.messages)
  eq("from the future", t.messages[2].body[1], "clamped agent msg sorts by real write time, not invented ts")
  eq(true, t.messages[2].ts_corrected)
  assert(t.messages[2].ts <= os.date("!%Y-%m-%dT%H:%M:%SZ"), "corrected ts must not be in the future")
  eq("honest reply", t.messages[3].body[1])
  -- the resolved event's ts was also clamped: it still wins as the latest
  -- event (nothing after it), but with a sane time
  eq("resolved", t.status)
  vim.fn.delete(tmp, "rf")
end)

---------------------------------------------------------------- threads: anchor

local anchor = require("neo-review.threads.anchor")

test("anchor: exact match survives shifts, prefers nearest, goes stale", function()
  local a = { line = 3, snippet = { "  return x" }, context_before = { "local function f()" }, context_after = { "end" } }
  -- unchanged
  eq(3, anchor.resolve(a, { "-- head", "local function f()", "  return x", "end" }))
  -- shifted down by insertions above
  eq(6, anchor.resolve(a, { "a", "b", "c", "d", "local function f()", "  return x", "end" }))
  -- duplicate snippet lines: nearest to stored line wins
  eq(4, anchor.resolve(a, { "  return x", "z", "z", "  return x", "z" }))
  -- snippet gone -> stale
  eq(nil, anchor.resolve(a, { "local function f()", "  return y", "end" }))
end)

test("anchor: context fallback when snippet neighbors changed", function()
  local a = {
    line = 2,
    snippet = { "  mid", "  tail" },
    context_before = { "top" },
    context_after = { "bottom" },
  }
  -- "  tail" edited away, but first snippet line + preceding context match
  eq(2, anchor.resolve(a, { "top", "  mid", "  TAIL-EDITED", "bottom" }))
end)

---------------------------------------------------------------- agent terminal (against stub-claude.sh)

local function with_agent_terminal(fn)
  local stub = root .. "/tests/stub-claude.sh"
  vim.uv.fs_chmod(stub, 493)
  local log = vim.fn.tempname()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local sess = require("neo-review.session")
  local prev_root = sess.root
  sess.root = repo
  require("neo-review.config").setup({
    keymaps = { agent_open = "<C-;>" },
    agent = { cmd = vim.fn.shellescape(stub) .. " " .. vim.fn.shellescape(log), ready_delay_ms = 0 },
  })
  local agent = require("neo-review.agent")
  local function lines(prefix)
    local out = {}
    for _, l in ipairs(vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}) do
      if vim.startswith(l, prefix) then
        out[#out + 1] = l
      end
    end
    return out
  end
  local ok, err = pcall(fn, agent, lines, repo)
  agent.stop()
  vim.wait(2000, function()
    return agent.status().buf == nil -- TermClose handled
  end, 20)
  vim.cmd("silent! only")
  sess.root = prev_root
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
  vim.fn.delete(log)
  assert(ok, err)
end

test("agent terminal: toggle shows a float over a hidden, unlisted terminal and hides it again", function()
  with_agent_terminal(function(agent, lines)
    eq("", agent.status_text())
    eq(nil, (agent.status_icon()))
    local orig = vim.api.nvim_get_current_win()

    agent.toggle()
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    assert(vim.api.nvim_win_get_config(win).relative ~= "", "terminal should open in a float")
    eq("terminal", vim.bo[buf].buftype)
    eq(false, vim.bo[buf].buflisted, "agent buffer must stay out of buffer lists")
    eq(1, vim.fn.maparg("<C-;>", "t", false, true).buffer, "toggle key must work inside the terminal")
    assert(vim.wait(2000, function()
      return #lines("SPAWN") == 1
    end, 20), "stub never started")
    eq("agent", agent.status_text())
    eq({ "●", "NeoReviewAgent" }, { agent.status_icon() })

    agent.toggle() -- focused -> hide
    eq(false, vim.api.nvim_win_is_valid(win))
    eq(orig, vim.api.nvim_get_current_win())
    assert(vim.api.nvim_buf_is_valid(buf), "hiding must keep the buffer")
    assert(agent.status().running, "hiding must keep the job")

    agent.toggle() -- hidden -> show the same buffer
    eq(buf, vim.api.nvim_get_current_buf())
    vim.wait(200)
    eq(1, #lines("SPAWN"), "must not respawn")

    vim.api.nvim_set_current_win(orig) -- leaving the float hides it
    assert(vim.wait(500, function()
      return not agent.status().visible
    end, 20), "float should hide when you leave it")
    assert(agent.status().running)
  end)
end)

test("agent terminal: ping auto-starts and types a one-line prompt of open threads", function()
  with_agent_terminal(function(agent, lines, repo)
    local function mk(file, body)
      return store.create(repo, {
        file = file,
        kind = "question",
        anchor = { line = 2, snippet = { "x" }, context_before = {}, context_after = {} },
        author = "ryan",
        role = "human",
        body = { body },
      })
    end
    local open_id = mk("src/open.lua", "why 30s?")
    local done_id = mk("src/done.lua", "settled")
    store.set_status(repo, done_id, "resolved", "ryan")

    local win, nwins = vim.api.nvim_get_current_win(), #vim.api.nvim_list_wins()
    agent.ping()
    eq(win, vim.api.nvim_get_current_win(), "ping must not steal focus")
    eq(nwins, #vim.api.nvim_list_wins(), "ping must not open a window")
    assert(vim.wait(3000, function()
      return #lines("RECV") == 1
    end, 20), "prompt never arrived: " .. vim.inspect(lines("")))
    eq(1, #lines("SPAWN"))
    local recv = lines("RECV")[1]
    assert(recv:find(open_id, 1, true), "open thread missing: " .. recv)
    assert(recv:find("src/open.lua:2", 1, true), "location missing: " .. recv)
    assert(not recv:find(done_id, 1, true), "resolved thread leaked: " .. recv)

    agent.ping() -- already running: sends immediately, no respawn
    assert(vim.wait(2000, function()
      return #lines("RECV") == 2
    end, 20), "second ping never arrived")
    eq(1, #lines("SPAWN"))
  end)
end)

test("agent terminal: stop kills the process and its buffer; next toggle starts fresh", function()
  with_agent_terminal(function(agent, lines)
    local events = {}
    local au = vim.api.nvim_create_autocmd("User", {
      pattern = "NeoReviewAgentStateChanged",
      callback = function(ev)
        events[#events + 1] = ev.data.running
      end,
    })
    agent.toggle()
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.wait(2000, function()
      return #lines("SPAWN") == 1
    end, 20))
    agent.stop()
    assert(vim.wait(2000, function()
      return not agent.status().running and #events == 2
    end, 20), "stop did not end the job: " .. vim.inspect(events))
    eq({ true, false }, events)
    eq("", agent.status_text())
    assert(vim.wait(500, function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 20), "exited terminal buffer should be wiped")
    eq(false, agent.status().visible)
    vim.api.nvim_del_autocmd(au)

    agent.toggle()
    assert(vim.wait(2000, function()
      return #lines("SPAWN") == 2
    end, 20), "reopen did not spawn a fresh process")
  end)
end)

test("skill: auto_install on setup links missing skills and repairs dangling ones, not stale ones", function()
  local fake_home = vim.fn.tempname()
  vim.fn.mkdir(fake_home .. "/skills", "p")
  local prev = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = fake_home
  local skill = require("neo-review.skill")
  -- neo-review: dangling (its target directory is gone)
  vim.uv.fs_symlink(fake_home .. "/gone/skill", fake_home .. "/skills/neo-review", { dir = true })
  eq("dangling", (skill.status_of("neo-review")))
  eq("missing", (skill.status_of("guided-review")))
  -- legacy review-comments link from the old layout, now dangling: removed
  vim.uv.fs_symlink(fake_home .. "/gone/skill", fake_home .. "/skills/review-comments", { dir = true })
  -- a legacy-named link to someone else's live skill: left alone
  vim.fn.mkdir(fake_home .. "/theirs", "p")
  require("neo-review").setup({ keymaps = false, skill = { auto_install = true } })
  vim.wait(500, function()
    return skill.status() == "installed"
  end, 20)
  eq("installed", (skill.status()))
  eq(nil, vim.uv.fs_lstat(fake_home .. "/skills/review-comments"), "dangling legacy link removed")
  vim.uv.fs_symlink(fake_home .. "/theirs", fake_home .. "/skills/review-comments", { dir = true })
  skill.auto_install()
  eq("link", vim.uv.fs_lstat(fake_home .. "/skills/review-comments").type, "foreign legacy-named link kept")

  -- stale (deliberately pointed at another existing checkout): left alone
  local elsewhere = fake_home .. "/dev-checkout"
  vim.fn.mkdir(elsewhere, "p")
  vim.uv.fs_unlink(fake_home .. "/skills/guided-review")
  vim.uv.fs_symlink(elsewhere, fake_home .. "/skills/guided-review", { dir = true })
  skill.auto_install()
  eq("stale", (skill.status_of("guided-review")))

  vim.env.CLAUDE_CONFIG_DIR = prev
  require("neo-review.config").setup({})
  vim.fn.delete(fake_home, "rf")
end)

---------------------------------------------------------------- skill install

test("skill: install links every skill, is idempotent, replaces stale, refuses conflicts", function()
  local fake_home = vim.fn.tempname()
  vim.fn.mkdir(fake_home, "p")
  local prev = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = fake_home

  local skill = require("neo-review.skill")
  eq("missing", (skill.status()))
  skill.install()
  eq("installed", (skill.status()))
  for _, name in ipairs({ "neo-review", "guided-review" }) do
    local link = fake_home .. "/skills/" .. name
    eq("link", vim.uv.fs_lstat(link).type)
    assert(vim.fn.filereadable(link .. "/SKILL.md") == 1, name .. "/SKILL.md not reachable through symlink")
    local head = vim.fn.readfile(link .. "/SKILL.md", "", 2)[2]
    eq("name: " .. name, head, "frontmatter name matches directory")
  end
  skill.install() -- idempotent
  eq("installed", (skill.status()))

  -- stale: an explicit install replaces it
  local link = fake_home .. "/skills/guided-review"
  vim.uv.fs_unlink(link)
  vim.uv.fs_symlink(fake_home, link, { dir = true })
  eq("stale", (skill.status_of("guided-review")))
  skill.install()
  eq("installed", (skill.status_of("guided-review")))

  -- conflict: a real directory in the way is never touched
  link = fake_home .. "/skills/neo-review"
  vim.uv.fs_unlink(link)
  vim.fn.mkdir(link, "p")
  eq("conflict", (skill.status()))
  local prev_notify = vim.notify
  vim.notify = function() end
  skill.install()
  vim.notify = prev_notify
  eq("directory", vim.uv.fs_lstat(link).type, "must not replace a real directory")

  vim.env.CLAUDE_CONFIG_DIR = prev
  vim.fn.delete(fake_home, "rf")
end)

---------------------------------------------------------------- arrival notifications

test("threads: poll-style sync notifies on external arrivals, local sync stays silent", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local sess = require("neo-review.session")
  local prev_root, prev_enabled = sess.root, sess.enabled
  sess.root, sess.enabled = repo, true
  local threads = require("neo-review.threads")
  local store = require("neo-review.threads.store")

  local notes = {}
  local prev_notify = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end

  threads.sync({ notify = true }) -- baseline, empty
  store.create(repo, { file = "a.txt", kind = "note", anchor = { line = 1, snippet = { "x" }, context_before = {}, context_after = {} }, author = "agent", role = "agent", body = { "external comment" } })
  threads.sync() -- local/silent path
  local silent = #vim.tbl_filter(function(m)
    return m:find("new comment", 1, true)
  end, notes)
  eq(0, silent, "silent sync must not announce")

  local id2 = store.create(repo, { file = "a.txt", kind = "note", anchor = { line = 1, snippet = { "x" }, context_before = {}, context_after = {} }, author = "agent", role = "agent", body = { "second" } })
  store.reply(repo, id2, { author = "agent", role = "agent", body = { "and a reply" } })
  -- reply within the same thread counts as part of the new thread; add one to an OLD thread
  store.reply(repo, threads.threads[1] and threads.threads[1].id or id2, { author = "agent", role = "agent", body = { "old-thread reply" } })
  threads.sync({ notify = true })
  local announced = vim.tbl_filter(function(m)
    return m:find("new", 1, true) and m:find("review:", 1, true)
  end, notes)
  eq(1, #announced, "expected one arrival notification: " .. vim.inspect(notes))
  assert(announced[1]:find("1 new comment thread", 1, true), announced[1])
  assert(announced[1]:find("1 new reply", 1, true), announced[1])

  vim.notify = prev_notify
  sess.root, sess.enabled = prev_root, prev_enabled
  threads.threads = {}
  vim.fn.delete(repo, "rf")
end)

---------------------------------------------------------------- review progress: file-level marking + content invalidation

test("attach: buffer reload (external edit + :edit) re-attaches and re-renders", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function shr(cmd)
    assert(vim.system(cmd, { cwd = repo, text = true }):wait().code == 0)
  end
  shr({ "git", "init", "-q", "-b", "main" })
  shr({ "git", "config", "user.email", "t@t" })
  shr({ "git", "config", "user.name", "t" })
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/f.txt")
  shr({ "git", "add", "." })
  shr({ "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "one", "CHANGED", "three" }, repo .. "/f.txt")

  require("neo-review.config").setup({ keymaps = false })
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/f.txt")
  local buf = vim.api.nvim_get_current_buf()
  local review = require("neo-review")
  local sess = require("neo-review.session")
  review.enable()
  assert(sess.bufs[buf], "buffer not attached after enable")
  eq(1, #sess.bufs[buf].hunks)

  -- an "agent" edits the file on disk while it's open; the reload detaches
  -- buf_attach callbacks — the session must re-attach on its own
  -- (change + separate trailing add = 2 hunks, distinguishable from before)
  vim.fn.writefile({ "one", "CHANGED", "three", "four" }, repo .. "/f.txt")
  vim.cmd("edit!")
  assert(
    vim.wait(2000, function()
      local c = sess.bufs[buf]
      return c and #c.hunks == 2
    end, 20),
    "buffer did not re-attach with fresh hunks after reload"
  )

  -- and the overlay actually re-rendered (extmarks present again)
  local render = require("neo-review.render")
  assert(#vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {}) > 0, "no extmarks after reload")

  review.disable()
  vim.cmd.cd(root)
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
end)

test("review-progress: file marking, !! statuses, content invalidation, skip-nav", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function sh3(cmd)
    assert(vim.system(cmd, { cwd = repo, text = true }):wait().code == 0)
  end
  sh3({ "git", "init", "-q", "-b", "main" })
  sh3({ "git", "config", "user.email", "t@t" })
  sh3({ "git", "config", "user.name", "t" })
  vim.fn.writefile({ "a", "b", "c", "d", "e" }, repo .. "/f1.txt")
  vim.fn.writefile({ "x", "y" }, repo .. "/f2.txt")
  sh3({ "git", "add", "." })
  sh3({ "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "A", "b", "c", "d", "E" }, repo .. "/f1.txt") -- two hunks
  vim.fn.writefile({ "x", "Y" }, repo .. "/f2.txt") -- one hunk

  require("neo-review.config").setup({ keymaps = false })
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/f1.txt")
  local review = require("neo-review")
  review.enable()

  local info = review.file_review_info("f1.txt")
  eq(2, info.total)
  eq(0, info.reviewed)
  local done, total = review.progress()
  eq(0, done)
  eq(2, total)

  -- mark whole file (auto-advance jumps to f2 — harmless headless)
  review.mark_file_reviewed("f1.txt")
  info = review.file_review_info("f1.txt")
  eq(2, info.reviewed, "all hunks marked")
  done = review.progress()
  eq(1, done)

  -- explorer status codes: reviewed file fades as "!!", outstanding stays " M"
  local sess = require("neo-review.session")
  local codes = require("neo-review.integrations.snacks_explorer").review_statuses(sess.root)
  eq("!!", codes["f1.txt"])
  eq(" M", codes["f2.txt"])

  -- skip-nav: f1 fully reviewed -> next candidate file from anywhere is f2
  local nav = require("neo-review.nav")
  eq("f2.txt", nav.next_file_with_candidates(nil, 1))
  require("neo-review.config").options.review.skip_reviewed = false
  eq("f1.txt", nav.next_file_with_candidates(nil, 1), "skip off visits reviewed files again")
  require("neo-review.config").options.review.skip_reviewed = true

  -- content invalidation: an "agent" edits one reviewed hunk in f1's buffer
  local f1buf = vim.fn.bufnr(repo .. "/f1.txt")
  vim.api.nvim_buf_set_lines(f1buf, 0, 1, false, { "AGENT-EDITED" })
  review.refresh(f1buf)
  info = review.file_review_info("f1.txt")
  eq(2, info.total)
  eq(1, info.reviewed, "edited hunk returns to outstanding; untouched hunk stays reviewed")
  eq(0, (review.progress()), "file no longer fully reviewed")
  eq("f1.txt", nav.next_file_with_candidates(nil, 1), "file is back in the review queue")

  -- reset (bypass the confirm prompt)
  local prev_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end
  review.clear_reviewed()
  eq(0, review.file_review_info("f1.txt").reviewed)

  -- review-all: every hunk in every file marked in one go
  review.review_all()
  eq(2, (review.progress()), "both files fully reviewed")
  eq(2, review.file_review_info("f1.txt").reviewed)
  eq(1, review.file_review_info("f2.txt").reviewed)
  vim.fn.confirm = prev_confirm

  review.disable()
  vim.cmd.cd(root)
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
end)

---------------------------------------------------------------- tree-level reviewed toggle

test("mark_tree_reviewed: folder toggle marks/unmarks everything under it", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo .. "/sub", "p")
  local function sht(cmd)
    assert(vim.system(cmd, { cwd = repo, text = true }):wait().code == 0)
  end
  sht({ "git", "init", "-q", "-b", "main" })
  sht({ "git", "config", "user.email", "t@t" })
  sht({ "git", "config", "user.name", "t" })
  vim.fn.writefile({ "a" }, repo .. "/top.txt")
  vim.fn.writefile({ "b" }, repo .. "/sub/one.txt")
  vim.fn.writefile({ "c" }, repo .. "/sub/two.txt")
  sht({ "git", "add", "." })
  sht({ "git", "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "A" }, repo .. "/top.txt")
  vim.fn.writefile({ "B" }, repo .. "/sub/one.txt")
  vim.fn.writefile({ "C" }, repo .. "/sub/two.txt")

  require("neo-review.config").setup({ keymaps = false })
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/top.txt")
  local review = require("neo-review")
  review.enable()

  -- relative folder: only sub/* flips to reviewed
  review.mark_tree_reviewed("sub")
  eq(1, review.file_review_info("sub/one.txt").reviewed)
  eq(1, review.file_review_info("sub/two.txt").reviewed)
  eq(0, review.file_review_info("top.txt").reviewed)

  -- absolute path to the same folder: everything under it reviewed -> unmark
  review.mark_tree_reviewed(repo .. "/sub")
  eq(0, review.file_review_info("sub/one.txt").reviewed)
  eq(0, review.file_review_info("sub/two.txt").reviewed)

  -- no changed files under a path -> no-op
  review.mark_tree_reviewed("nosuch")
  eq(0, (review.progress()))

  -- "" (or the repo root) = the whole changeset
  review.mark_tree_reviewed("")
  eq(3, (review.progress()))

  review.disable()
  vim.cmd.cd(root)
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
end)

test("threads: in-place edits are picked up (poll fingerprint + reload)", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local sess = require("neo-review.session")
  local prev_root = sess.root
  sess.root = repo
  local threads = require("neo-review.threads")
  local id = store.create(repo, { file = "a.txt", kind = "note", anchor = { line = 1, snippet = { "x" }, context_before = {}, context_after = {} }, author = "claude", role = "agent", body = { "retrieveWiki writes it" }, series = { id = "s-1", pos = 3 } })
  local dir = repo .. "/.review/threads/" .. id
  local before = threads._fingerprint()
  -- same byte length, different text: size-only detection would miss it
  local msg = vim.fn.glob(dir .. "/msg-*.json")
  local body = table.concat(vim.fn.readfile(msg), "\n"):gsub("retrieveWiki writes it", "appendWikiQueryLog did")
  vim.fn.writefile(vim.split(body, "\n"), msg)
  local meta = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/thread.json"), "\n"))
  meta.series.pos = 1 -- renumber in place (same length as 3)
  vim.fn.writefile({ vim.json.encode(meta) }, dir .. "/thread.json")
  assert(threads._fingerprint() ~= before, "same-size in-place edit not detected")
  threads.reload()
  eq({ "appendWikiQueryLog did" }, threads.threads[1].messages[1].body)
  eq(1, threads.threads[1].series.pos)
  sess.root = prev_root
  threads.threads = {}
  vim.fn.delete(repo, "rf")
end)

---------------------------------------------------------------- walkthrough series

local function anc(line, text)
  return { line = line, snippet = { text }, context_before = {}, context_after = {} }
end

test("series: thread.json field loads; malformed values make the thread standalone", function()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local base = { file = "a.lua", kind = "note", anchor = anc(1, "x"), author = "claude", role = "agent", body = { "hi" } }
  local ok_id = store.create(tmp, vim.tbl_extend("force", base, { series = { id = "s-1", pos = 2.5 } }))
  eq({ id = "s-1", pos = 2.5 }, store.load(tmp, ok_id).series)
  eq(nil, store.load(tmp, store.create(tmp, base)).series, "no field -> standalone")
  for i, bad in ipairs({ "s-1", { pos = 1 }, { id = "", pos = 1 }, { id = "s-1", pos = "1" } }) do
    local id = "bad" .. i
    local dir = tmp .. "/.review/threads/" .. id
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ vim.json.encode({ version = 1, id = id, file = "a.lua", kind = "note", created = "2026-01-01T00:00:00Z", anchor = anc(1, "x"), series = bad }) }, dir .. "/thread.json")
    local t = store.load(tmp, id)
    assert(t, "malformed series must not drop the thread")
    eq(nil, t.series, "malformed series #" .. i)
  end
  vim.fn.delete(tmp, "rf")
end)

test("series: rank/total are stable and stop_sequence chains series by age", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  vim.fn.writefile({ "l1", "l2", "l3", "l4", "l5" }, repo .. "/a.txt")
  local sess = require("neo-review.session")
  local prev_root = sess.root
  sess.root = repo
  local threads = require("neo-review.threads")
  local function mk(line, series, body)
    return store.create(repo, { file = "a.txt", kind = "note", anchor = anc(line, "l" .. line), author = "claude", role = "agent", body = { body }, series = series })
  end
  -- series A (older): written out of order; pos decides, fraction slots in
  local a3 = mk(1, { id = "s-a", pos = 3 }, "a3")
  local a1 = mk(5, { id = "s-a", pos = 1 }, "a1")
  local a2 = mk(3, { id = "s-a", pos = 2.5 }, "a2")
  local b1 = mk(2, { id = "s-b", pos = 1 }, "b1")
  local lone = mk(4, nil, "standalone")
  local stale = mk(9, { id = "s-b", pos = 2 }, "stale") -- snippet l9 doesn't exist
  store.set_status(repo, a2, "resolved", "ryan")
  threads.reload()

  local by = {}
  for _, t in ipairs(threads.threads) do
    by[t.id] = t
  end
  eq("1/3", threads.position(by[a1]))
  eq("2/3", threads.position(by[a2]), "resolved stop keeps its number")
  eq("3/3", threads.position(by[a3]))
  eq("1/2", threads.position(by[b1]))
  eq("2/2", threads.position(by[stale]), "stale stop still counted")
  eq(nil, threads.position(by[lone]))

  eq({ a1, a2, a3, b1, stale }, vim.tbl_map(function(t)
    return t.id
  end, threads.stop_sequence()), "series A (older) then B; resolved + stale included")
  eq({ a3, b1, lone, a1 }, vim.tbl_map(function(t)
    return t.id
  end, threads.comment_sequence()), "]c stream: open + anchored, by line")

  sess.root = prev_root
  threads.threads = {}
  vim.fn.delete(repo, "rf")
end)

test("series nav: ]r walks stops incl. resolved, ]c skips them, pane follows, draft protected", function()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function shr(cmd)
    assert(vim.system(cmd, { cwd = repo, text = true }):wait().code == 0)
  end
  shr({ "git", "init", "-q", "-b", "main" })
  shr({ "git", "config", "user.email", "t@t" })
  shr({ "git", "config", "user.name", "t" })
  local a, b = {}, {}
  for i = 1, 10 do
    a[i], b[i] = "a" .. i, "b" .. i
  end
  vim.fn.writefile(a, repo .. "/a.txt")
  vim.fn.writefile(b, repo .. "/b.txt")
  shr({ "git", "add", "." })
  shr({ "git", "commit", "-q", "-m", "init" })

  local function mk(file, line, series, body)
    return store.create(repo, { file = file, kind = "note", anchor = anc(line, file:sub(1, 1) .. line), author = "claude", role = "agent", body = { body }, series = series })
  end
  -- walkthrough order b:5 -> a:8 -> a:2 (deliberately not positional)
  local s1 = mk("b.txt", 5, { id = "s-w", pos = 1 }, "stop one")
  local s2 = mk("a.txt", 8, { id = "s-w", pos = 2 }, "stop two")
  local s3 = mk("a.txt", 2, { id = "s-w", pos = 3 }, "stop three")
  mk("a.txt", 5, nil, "standalone")
  -- stale stop between 1 and 2 (snippet "z1" is nowhere): counted, stepped over
  store.create(repo, { file = "a.txt", kind = "note", anchor = anc(1, "z1"), author = "claude", role = "agent", body = { "gone" }, series = { id = "s-w", pos = 1.5 } })

  -- A foreign buffer-local ]c (like LazyVim's next-class) must survive review mode.
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/a.txt")
  local abuf = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "]c", "<Nop>", { buffer = abuf, desc = "foreign class jump" })

  require("neo-review.config").setup({})
  local review = require("neo-review")
  local nav = require("neo-review.nav")
  local ui = require("neo-review.threads.ui")
  local threads = require("neo-review.threads")
  review.enable()
  eq("Review: next comment (review mode)", vim.fn.maparg("]c", "n", false, true).desc, "review claims ]c")

  local function here()
    local cache = require("neo-review.session").bufs[vim.api.nvim_get_current_buf()]
    return (cache and cache.relpath or "?") .. ":" .. vim.api.nvim_win_get_cursor(0)[1]
  end

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  nav.stop(1)
  eq("b.txt:5", here(), "no current stop -> stop 1")
  nav.stop(1)
  eq("a.txt:8", here(), "stop 2 (stale stop in between stepped over)")
  store.set_status(repo, s2, "resolved", "ryan")
  threads.sync()
  nav.stop(1)
  eq("a.txt:2", here(), "from a RESOLVED stop, ]r still advances")
  nav.stop(-1)
  eq("a.txt:8", here(), "[r lands on the resolved stop")
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  nav.stop(1)
  eq("a.txt:2", here(), "cursor wandered off: continue from last stop")
  nav.stop(1)
  eq("b.txt:5", here(), "wraps to stop 1")

  -- ]c: open threads positionally, resolved stop a:8 skipped
  vim.cmd.edit(repo .. "/a.txt")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local walk = {}
  for _ = 1, 4 do
    nav.comment(1)
    walk[#walk + 1] = here()
  end
  eq({ "a.txt:2", "a.txt:5", "b.txt:5", "a.txt:2" }, walk)
  nav.comment(-1)
  eq("b.txt:5", here(), "[c wraps backwards")

  -- labels: inline virt text and resolved stop's quiet position
  vim.cmd.edit(repo .. "/a.txt")
  local virt = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(abuf, threads.ns, 0, -1, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      virt[#virt + 1] = chunk[1]
    end
  end
  local joined = table.concat(virt, "|")
  assert(joined:find("4/4 · note", 1, true), joined)
  assert(joined:find("✓ 3/4", 1, true), joined)

  -- pane follows ]c/]r and keeps focus when used from inside it
  local by = {}
  for _, t in ipairs(threads.threads) do
    by[t.id] = t
  end
  ui.open(by[s1])
  local pane = vim.api.nvim_get_current_win()
  eq(s1, ui.buf_thread_id(vim.api.nvim_get_current_buf()))
  assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("1/4", 1, true), "pane header shows position")
  nav.stop(1) -- from the pane: ui.open remembered stop 1
  eq(pane, vim.api.nvim_get_current_win(), "focus stays in pane")
  eq(s2, ui.buf_thread_id(vim.api.nvim_win_get_buf(pane)), "pane retargeted to stop 2")
  nav.comment(1) -- from pane showing a:8 -> next open after it is b:5
  eq(s1, ui.buf_thread_id(vim.api.nvim_win_get_buf(pane)))
  eq(pane, vim.api.nvim_get_current_win())

  -- unsent draft: pane is not switched
  local pbuf = vim.api.nvim_win_get_buf(pane)
  vim.api.nvim_buf_set_lines(pbuf, -1, -1, false, { "half-typed reply" })
  eq(true, vim.bo[pbuf].modified)
  nav.stop(1)
  eq(s1, ui.buf_thread_id(vim.api.nvim_win_get_buf(pane)), "draft protects the pane")
  eq("half-typed reply", vim.api.nvim_buf_get_lines(pbuf, -2, -1, false)[1])
  vim.bo[pbuf].modified = false
  vim.api.nvim_win_close(pane, true)

  review.disable()
  eq("foreign class jump", vim.fn.maparg("]c", "n", false, true).desc, "displaced buffer-local map restored")

  vim.cmd.cd(root)
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
end)

----------------------------------------------------------------

if failed > 0 then
  io.write(string.format("\n%d test(s) FAILED\n", failed))
  os.exit(1)
end
io.write("\nall tests passed\n")
os.exit(0)
