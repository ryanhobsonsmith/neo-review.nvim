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

test("threads: create/reply/resolve round-trip, append-only files", function()
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

  -- append-only invariant: thread dir contains only ever-growing distinct files
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

---------------------------------------------------------------- agent transport (against fake-claude.sh)

test("agent transport: init, turn queue, permission round-trip, results", function()
  local fake = root .. "/tests/fake-claude.sh"
  vim.uv.fs_chmod(fake, 493) -- 0755
  local transport = require("neo-review.agent.claude")

  local events = { states = {}, results = {}, permissions = {} }
  local ok, err = transport.start({
    cwd = root,
    cmd = fake,
    handlers = {
      state = function(s)
        events.states[#events.states + 1] = s
      end,
      permission = function(req)
        events.permissions[#events.permissions + 1] = req
        transport.respond_permission(req.request_id, true, req.input)
      end,
      result = function(ev)
        events.results[#events.results + 1] = ev.result
      end,
    },
  })
  assert(ok, err)

  -- send both turns immediately: first goes out on init, second queues
  transport.send("turn one")
  transport.send("turn two")

  assert(vim.wait(5000, function()
    return #events.results == 2
  end, 20), "timed out waiting for two results: " .. vim.inspect(events))

  eq({ "done", "second" }, events.results)
  eq(1, #events.permissions)
  eq("Write", events.permissions[1].tool_name)
  eq("req-1", events.permissions[1].request_id)
  eq("fake-session-1234", transport.status().session_id)
  eq("idle", transport.status().state)
  -- lifecycle: starting -> idle (init) -> working -> idle -> working -> idle
  eq("starting", events.states[1])
  eq("idle", events.states[#events.states])

  transport.stop()
  assert(vim.wait(3000, function()
    return transport.status().state == "stopped"
  end, 20), "transport did not stop")
end)

---------------------------------------------------------------- agent controller: permission inbox (A)

test("agent controller: permission lands in inbox, never auto-answers; explicit respond flows", function()
  local fake = root .. "/tests/fake-claude.sh"
  vim.uv.fs_chmod(fake, 493)

  -- isolated temp repo so review state stays out of the plugin repo
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function sh2(cmd)
    assert(vim.system(cmd, { cwd = repo, text = true }):wait().code == 0)
  end
  sh2({ "git", "init", "-q", "-b", "main" })
  sh2({ "git", "config", "user.email", "t@t" })
  sh2({ "git", "config", "user.name", "t" })
  vim.fn.writefile({ "x" }, repo .. "/f.txt")
  sh2({ "git", "add", "." })
  sh2({ "git", "commit", "-q", "-m", "init" })

  require("neo-review.config").setup({
    keymaps = false,
    -- sandbox off: this test must exercise the fake binary directly, never
    -- docker (which may exist and have the image on a dev machine)
    agent = { cmd = fake, auto_allow_tools = {}, sandbox = { enabled = false } },
  })
  vim.cmd.cd(repo)
  vim.cmd.edit(repo .. "/f.txt")
  require("neo-review").enable()

  local agent = require("neo-review.agent")
  agent.start()
  assert(vim.wait(3000, function()
    return agent.status().state ~= "stopped"
  end, 20), "agent did not start")

  require("neo-review.agent.claude").send("turn one")
  assert(vim.wait(5000, function()
    return agent.pending_count() == 1
  end, 20), "permission never landed in inbox")
  -- inbox semantics: request is parked, agent still working, no auto-answer
  eq("working", agent.status().state)
  assert(agent.status_text():find("⏸1", 1, true), "status_text missing pending marker: " .. agent.status_text())

  assert(agent.respond_pending("once"))
  assert(vim.wait(5000, function()
    return agent.status().state == "idle"
  end, 20), "no result after allow")
  eq(0, agent.pending_count())

  agent.stop()
  vim.wait(2000, function()
    return agent.status().state == "stopped"
  end, 20)
  require("neo-review").disable()
  vim.cmd.cd(root)
  require("neo-review.config").setup({})
  vim.fn.delete(repo, "rf")
end)

---------------------------------------------------------------- sandbox argv builder (offline)

test("sandbox: sbx argv, per-project name, and custom overrides", function()
  local sess = require("neo-review.session")
  local prev_root = sess.root
  sess.root = "/repo/x"
  require("neo-review.config").setup({})
  local sandbox = require("neo-review.agent.sandbox")
  eq("claude-x", sandbox.sandbox_name())
  eq("claude-y", sandbox.sandbox_name("/other/y"))
  eq({ "sbx", "exec", "-i", "claude-x", "claude" }, sandbox.argv_prefix())

  -- custom argv_prefix override replaces the sbx prefix entirely
  require("neo-review.config").setup({ agent = { sandbox = { argv_prefix = { "asb", "run", "claude" } } } })
  eq({ "asb", "run", "claude" }, require("neo-review.agent.sandbox").argv_prefix())

  -- function form: computed per repo root (e.g. per-project sbx sandbox)
  require("neo-review.config").setup({
    agent = {
      sandbox = {
        argv_prefix = function(ctx)
          return { "sbx", "exec", "-i", "claude-" .. vim.fn.fnamemodify(ctx.root, ":t"), "claude" }
        end,
      },
    },
  })
  eq({ "sbx", "exec", "-i", "claude-x", "claude" }, require("neo-review.agent.sandbox").argv_prefix())

  sess.root = prev_root
  require("neo-review.config").setup({})
end)

test("skill: auto_install on setup when missing", function()
  local fake_home = vim.fn.tempname()
  vim.fn.mkdir(fake_home, "p")
  local prev = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = fake_home
  require("neo-review").setup({ keymaps = false, skill = { auto_install = true } })
  vim.wait(500, function()
    return require("neo-review.skill").status() == "installed"
  end, 20)
  eq("installed", (require("neo-review.skill").status()))
  vim.env.CLAUDE_CONFIG_DIR = prev
  require("neo-review.config").setup({})
  vim.fn.delete(fake_home, "rf")
end)

---------------------------------------------------------------- skill install

test("skill: install symlinks, is idempotent, refuses non-symlink conflicts", function()
  local fake_home = vim.fn.tempname()
  vim.fn.mkdir(fake_home, "p")
  local prev = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = fake_home

  local skill = require("neo-review.skill")
  eq("missing", (skill.status()))
  skill.install()
  eq("installed", (skill.status()))
  local link = fake_home .. "/skills/review-comments"
  eq("link", vim.uv.fs_lstat(link).type)
  assert(vim.fn.filereadable(link .. "/SKILL.md") == 1, "SKILL.md not reachable through symlink")
  skill.install() -- idempotent
  eq("installed", (skill.status()))

  -- conflict: a real directory in the way is never touched
  vim.uv.fs_unlink(link)
  vim.fn.mkdir(link, "p")
  eq("conflict", (skill.status()))
  skill.install()
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

  require("neo-review.config").setup({ keymaps = false, agent = { sandbox = { enabled = false } } })
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

  require("neo-review.config").setup({ keymaps = false, agent = { sandbox = { enabled = false } } })
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
  vim.fn.confirm = prev_confirm
  eq(0, review.file_review_info("f1.txt").reviewed)

  review.disable()
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
