local M = {}

M.defaults = {
  -- Rich overlay (line tints + deleted baseline lines as virtual lines) when
  -- review mode is on. Signs are always shown while review mode is on.
  overlay = true,
  -- Max deleted baseline lines rendered inline per hunk. A virt_lines block
  -- taller than the window can't be scrolled through (the cursor can only
  -- rest on real lines), so "auto" caps at window height - 2; the remainder
  -- is reachable via keymaps.show_deleted. Set an integer for a fixed cap.
  overlay_max_lines = "auto",
  -- Word-level (intra-line) highlights on change hunks: the changed span is
  -- highlighted on both the buffer line and the deleted virt_line above
  -- (gitsigns-style word_diff). Only applies while the overlay is on.
  word_diff = true,
  winbar = true,
  update_debounce = 150,
  review = {
    -- ]h/[h, ]H/[H, quickfix, and the hunks picker skip hunks already
    -- marked reviewed (un-review paths: :NeoReviewHunks!, files picker,
    -- :NeoReviewUnreviewAll).
    skip_reviewed = true,
    -- After <leader>rV marks a whole file reviewed, jump to the next
    -- unreviewed file's first hunk.
    advance_after_file = true,
  },
  signs = {
    add = "▐",
    change = "▐",
    delete = "▁",
    reviewed = "▏",
  },
  skill = {
    -- Symlink the plugin's skills (neo-review, guided-review) into
    -- ~/.claude/skills on setup() when missing or dangling (they point at
    -- this plugin's directory, so they track plugin updates). Links you
    -- pointed elsewhere are left alone. Explicit: :NeoReviewSkillInstall.
    auto_install = false,
  },
  comments = {
    -- Author name for your messages; nil = `git config user.name`.
    author = nil,
    -- Notify when threads/replies arrive from outside this Neovim (an agent
    -- or another tool writing .review/threads/).
    notify_new = true,
  },
  agent = {
    cmd = "claude",
    model = nil, -- nil = the CLI's default model
    -- Default permission mode; per-repo override via :NeoReviewAgentMode
    -- ("default" | "acceptEdits" | "plan" | "bypassPermissions" — the last
    -- only makes sense inside a sandbox).
    permission_mode = "default",
    -- Named presets bundling model + permission mode (+ optional sandbox
    -- override). Select with :NeoReviewAgentProfile (persisted per repo).
    -- Precedence: explicit :NeoReviewAgentMode/:NeoReviewAgentModel/
    -- :NeoReviewAgentSandbox choices beat the profile; the profile beats
    -- agent.model/agent.permission_mode below.
    profiles = {
      review = { model = "sonnet", permission_mode = "auto" },
      deep = { model = "opus", permission_mode = "plan" },
    },
    -- Tools approved without entering the permission inbox. Curated safe
    -- baseline: read-only inspection + the agent's own todo bookkeeping.
    -- File WRITES are governed by permission_mode (acceptEdits), not this.
    auto_allow_tools = { "Read", "Glob", "Grep", "LSP", "TodoWrite", "WebFetch" },
    sandbox = {
      -- The wrapped session runs inside a Docker Sandboxes (sbx) microVM —
      -- per-project persistent sandbox, deny-by-default egress filtered by
      -- domain name (`sbx policy`), proxy-injected credentials. When
      -- enabled (the default) and sbx is unavailable, starting the agent
      -- FAILS with instructions; there is no fallback sandbox. Direct
      -- unsandboxed execution is the explicit :NeoReviewAgentSandbox off
      -- choice (per repo).
      enabled = true,
      -- Replace the `sbx exec -i <name> claude` prefix with your own
      -- wrapper: a list, or function({ root = <repo root> }) -> list. Must
      -- end with the claude binary (the transport appends its flags).
      argv_prefix = nil,
    },
  },
  integrations = {
    -- While review mode is on with a non-default baseline, the snacks
    -- explorer shows git status vs the baseline (see
    -- lua/neo-review/integrations/snacks_explorer.lua and :checkhealth neo-review).
    snacks_explorer = true,
  },
  -- Set to false to define no keymaps (commands still work).
  keymaps = {
    toggle = "<leader>rr",
    next_hunk = "]h",
    prev_hunk = "[h",
    next_file = "]H", -- next changed file's first outstanding hunk
    prev_file = "[H",
    mark_reviewed = "<leader>rv",
    review_file = "<leader>rV", -- toggle whole file reviewed (+ auto-advance)
    show_deleted = "gh", -- full deleted lines of the hunk at cursor, in a split
    files = "<leader>rf",
    hunks = "<leader>rh",
    comment = "<leader>rc", -- open thread at cursor, or start a new one
    threads = "<leader>rt",
    resolve = "<leader>rx", -- toggle resolved: in a thread buffer or on a commented line
    explorer = "<leader>re", -- compound toggle: review mode on + explorer open, filtered + expanded to the changeset (again = close)
    explorer_filter = nil, -- changed-only filter alone (:NeoReviewExplorerFilter); no default key
    explorer_expand = "<leader>rE", -- snacks explorer: expand tree to reveal all changed files
    explorer_review = "<leader>rv", -- IN the explorer list: toggle reviewed for the file/folder under the cursor (buffer-local while review is on)
    agent_ping = "<leader>ra", -- alert the wrapped agent session about open threads
    agent_permission = "<leader>rp", -- review the pending permission request(s)

    next_comment = "]c", -- next open comment, by file then line
    prev_comment = "[c",
    next_stop = "]r", -- next walkthrough stop (series order; includes resolved stops)
    prev_stop = "[r",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
