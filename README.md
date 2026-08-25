# neo-review.nvim

Hunk-style review of AI-agent (or any) changes, fully inside Neovim: a
toggleable hunk overlay on your normal buffers, diffed live against a
switchable baseline, with persisted reviewed-state. Review is read-and-comment
only — it never mutates your files.

Three ways to work with it: pure human review (overlay + hunks +
reviewed-state), collaboration with any external Claude Code session through
persisted comment threads, or a wrapped agent session the editor owns.

## Wrapped agent session

Each Neovim instance can own one Claude Code session, wrapped as a
long-lived `claude -p --input-format stream-json` subprocess (subscription-
billed; `ANTHROPIC_API_KEY` is scrubbed from the child env). Thread-driven —
no chat surface: `<leader>ra` / `:NeoReviewAgentPing` alerts the session about
open comment threads; it replies/resolves through `.review/threads/` files
and the editor renders them live. **Permissions are an inbox, not a popup**: a request never opens UI on
arrival — the winbar shows `agent:working ⏸1`, a passive notification
fires, and the agent waits. `<leader>rp` reviews it deliberately in a float
(full command/file content shown) where only explicit keys answer: `y`
allow once, `Y` allow that tool for the session, `n` deny — closing the
float leaves it pending; cancel can never deny. Prompt volume stays low
via a curated read-only `agent.auto_allow_tools` baseline and a
claude-style permission mode: `:NeoReviewAgentMode` (picker showing current)
or `:NeoReviewAgentMode acceptEdits|plan|default|bypassPermissions`,
persisted per repo; a running session restarts in place via `--resume`.
`:NeoReviewAgentStatus` shows state/profile/model/mode/session/queue/pending.
`:NeoReviewAgentStart [--resume]`, `:NeoReviewAgentStop`,
`:NeoReviewAgentInterrupt`, and `:NeoReviewAgentFork` (opens the real TUI on a
`--fork-session` of the wrapped session in a terminal split — `sbx exec -it`
into the sandbox when sandboxed; whether the last session was sandboxed is
persisted per repo, so forking works across Neovim restarts). Agent state
shows in the review winbar (`[review:auto⛨]` = review profile, auto mode,
sandboxed). The wire protocol is
unofficial — verified against claude 2.1.234; protocol notes live in
`lua/neo-review/agent/claude.lua`, and `:checkhealth neo-review` reports on it.

`:NeoReviewAgentLog` toggles a live, read-only split tailing everything the
session does — turns sent, assistant text, tool calls with a one-line input
summary (`→ Bash  $ npm test`), tool results, permission requests/answers,
per-turn cost, and stderr — the place to look when the agent seems to hang.
Windows parked at the bottom follow new output; scroll up and they stay put.
The log is a scratch buffer (`review://agent-log`, capped at 2000 lines), so
it keeps collecting in the background whether or not it's visible.

### Profiles (model + mode presets)

`agent.profiles` names presets bundling a model, a permission mode, and
optionally a sandbox override; switch with `:NeoReviewAgentProfile` (picker
showing current) or `:NeoReviewAgentProfile deep|none`, persisted per repo.
`:NeoReviewAgentModel opus|haiku|<full id>|default` sets an ad-hoc model
override the same way. Defaults:

```lua
agent = {
  profiles = {
    review = { model = "sonnet", permission_mode = "auto" },
    deep = { model = "opus", permission_mode = "plan" },
    -- yours: yolo = { model = "opus", permission_mode = "bypassPermissions", sandbox = true },
  },
},
```

Precedence, last explicit action wins: an explicit
`:NeoReviewAgentMode`/`:NeoReviewAgentModel`/`:NeoReviewAgentSandbox` choice
beats the active profile; the profile beats `agent.model` /
`agent.permission_mode` from `setup()`; selecting a profile clears earlier
ad-hoc overrides. A running session restarts in place onto the same
conversation via `--resume` — except when the change flips the sandbox
on/off, which starts a fresh session (transcripts don't cross the sandbox
boundary).

### Statusline

The review winbar only renders on review-attached buffers; for an always-on
indicator use the statusline component — returns `""` while the agent is
stopped, else e.g. `agent:working ⏸1 [review:auto⛨]`:

```lua
-- lualine
lualine_x = {
  { function() return require("neo-review").statusline() end },
},
```

If the full string is too noisy, there's a compact color-coded icon:
`⏸N` red = pending approvals, `●` orange = working, `●` green = idle,
`○` dim = starting, hidden when stopped (colors via the `NeoReviewAgent*`
highlight groups, linked to the diagnostic palette by default):

```lua
-- lualine: ready-made component, e.g. bottom-right
table.insert(opts.sections.lualine_z, require("neo-review").lualine())
-- native 'statusline': returns "%#Hl#icon%*"
--   require("neo-review").statusline_icon()
```

Every observable change (state, permission inbox, queue, stop) fires
`User NeoReviewAgentStateChanged` with
`data = { state, session_id, queued, pending, mode, profile, sandboxed }` —
native-'statusline' users can redraw on it:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "NeoReviewAgentStateChanged",
  callback = function() vim.cmd("redrawstatus") end,
})
```

### Sandbox (Docker Sandboxes / sbx microVMs)

By default the wrapped session runs inside a
[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) microVM — the
plugin deliberately ships **no sandbox implementation of its own**. sbx
provides a per-project persistent sandbox (`claude-<dirname>`, created
automatically on first agent start), its own kernel, deny-by-default egress
filtered **by domain name** at a host-side proxy (`sbx policy log` shows
denials, `sbx policy allow network <host>` allows), and proxy-injected
credentials that never enter the VM. Setup is sbx's, once per machine:
install sbx (`brew trust docker/tap && brew install docker/tap/sbx`) and
`sbx login`.

When the sandbox is enabled (the default) and sbx is unavailable, the agent
**refuses to start** with instructions — there is no silent fallback.
Running directly on the host is an explicit per-repo choice
(`:NeoReviewAgentSandbox off`), where permission prompts are the only
guardrail. Sandboxed sessions default to `auto` permission mode (the microVM
is the boundary; the classifier still routes flagged actions to the inbox);
`bypassPermissions` is refused outside the sandbox. No-arg
`:NeoReviewAgentSandbox` shows status; `agent.sandbox.argv_prefix` (list or
`function({root})`) swaps in a custom wrapper instead of sbx.

## Commands

| Command | |
|---|---|
| `:NeoReviewToggle` | Review mode on/off (signs, overlay, winbar) |
| `:NeoReviewBaseline [rev]` | Switch baseline. Empty = working tree vs `HEAD` (incl. untracked files). `main` = merge-base with the trunk (the PR view). Any rev works. |
| `:NeoReviewFiles` / `:NeoReviewHunks[!]` | Pickers; reviewed hunks hidden (`!` shows them dimmed, `<a-r>` toggles in-picker) |
| `:NeoReviewExplorer` | Compound toggle: review mode on + snacks explorer open, filtered and expanded to the changeset |
| `:NeoReviewQuickfix` | Outstanding hunks → quickfix (reviewed hidden, counted in the title) |
| `:NeoReviewMarkReviewed` | Toggle reviewed-state for the hunk under the cursor (persisted, per-baseline, content-addressed so it survives edits elsewhere) |
| `:NeoReviewMarkFileReviewed [file]` | Toggle a whole file reviewed (all hunks; auto-advances to the next unreviewed file) |
| `:NeoReviewReviewAll` / `:NeoReviewUnreviewAll` | Mark every hunk in the changeset reviewed / reset all reviewed-state (both confirmed) |
| `:NeoReviewComment [kind]` | Open the comment thread at the cursor, or start a new one (`question`/`issue`/`suggestion`/…) |
| `:NeoReviewThreads` | Picker of all comment threads (open/resolved/stale) |
| `:NeoReviewResolve` | Toggle resolved for the thread here (thread buffer or code line) |
| `:NeoReviewThreadDelete` / `:NeoReviewCleanResolved` | Delete one thread / all resolved threads (confirmed; human-only cleanup) |

## Comment threads (phase 2)

Line-anchored conversation threads, persisted in `.review/threads/` using an
append-only, conflict-free-by-construction format (directory per thread, one
immutable file per message, status via marker events) so projects may commit
them. Threads render as a gutter `●` plus a one-line virtual summary; enter
one (`<leader>rc`) and it opens octo-style as a real buffer in a split —
type your reply at the bottom, `:w` sends it, `<leader>rx` resolves/reopens
(also works on a commented code line), `q` closes; replying to a resolved
thread reopens it. `]c`/`[c` jump between comments (cross-file). Anchors store snippet +
context + Treesitter symbol and re-resolve by content, so threads survive
edits and go *stale* (still listed) rather than pointing at wrong lines.

Agents participate by editing files directly: neo-review.nvim writes
`.review/SKILL.md` (schema + etiquette) into the repo on first use — point
Claude Code at it and it can leave review comments, reply to yours, and
resolve threads; the plugin polls and re-renders within a few seconds.

## Using with an external Claude Code session (hunk-style)

No wrapped session required — run Claude Code yourself in a terminal in the
repo and drive everything from there. One-time setup: `:NeoReviewSkillInstall`
symlinks the `review-comments` skill into `~/.claude/skills/`, making these
just work in any repo:

- *"See the review comments I left for you and act on them"*
- *"Review this PR and add comments for all issues you find"*
- *"Walk me through this PR leaving comments in relevant places"* (numbered
  stops you follow with `]c`)

With review mode on, Neovim picks up agent-written threads within ~3s and
notifies (`review: 2 new comment threads (]c to jump, <leader>rt to list)`,
disable via `comments = { notify_new = false }`). The skill symlink tracks
the plugin working copy, so skill updates need no reinstall.

Default keymaps (set on `setup()`): `<leader>rr` toggle · `<leader>re`
review explorer (one key from cold: review mode + filtered/expanded
explorer; again = close) · `]h`/`[h` next/prev outstanding hunk with
cross-file wrap · `]H`/`[H` next/prev changed file's first outstanding
hunk · `<leader>rv` mark hunk reviewed · `<leader>rV` mark whole file
reviewed + advance (lock/generated files) · `gh` view full deleted
lines of the hunk in a read-only split · `<leader>rf`/`<leader>rh`
pickers · `<leader>rc` comment · `<leader>rt` threads picker · `]c`/`[c`
next/prev comment.

**Review progress model**: reviewed-state is content-hashed, so an agent (or
you) editing a reviewed hunk automatically returns it — and its file — to
outstanding, while untouched hunks stay reviewed. Navigation, pickers, and
quickfix skip reviewed hunks (`review = { skip_reviewed = false }` to visit
everything); the winbar shows `✓ files-done/total`; un-review via
`<leader>rv`/`rV` toggles, `:NeoReviewHunks!`, or `:NeoReviewUnreviewAll`.
`review = { advance_after_file = false }` disables the rV auto-advance.

Deleted baseline lines render inline as virtual lines, capped just below the
window height (a taller virtual block can't be scrolled through — the cursor
can only rest on real lines). Past the cap you get a `… +N more deleted lines`
marker; `gh` opens the whole block in a split. Tune with
`overlay_max_lines = "auto" | <integer>`.

Change hunks get gitsigns-style **word-level highlights**: the changed span
inside each paired old/new line is highlighted (`NeoReviewAddInline` on the
buffer line, `NeoReviewDeleteInline` on the deleted virtual line above). Like
delta, the new side of a change hunk uses the same green tint as an added
line (`NeoReviewAdd`) — the red deleted block above carries the old side. The
span colors are delta-style: derived from the line tint's background,
intensified, with the syntax foreground left intact — override the
`Review*Inline` groups (or the line groups they derive from) to re-tint.
Pairs that are entirely different, or very long
lines, fall back to the whole-line tint. Disable with `word_diff = false`.

While review mode is on, the nav/comment keys are claimed
buffer-locally on attached buffers (so they beat gitsigns' buffer-local maps
in LazyVim) and released when review mode turns off.

## Snacks integration

With snacks.nvim installed the pickers are snacks-native (color-coded `+`/`~`/`-`
status symbols, fuzzy matching, preview). Additionally, while review mode is
on, the snacks explorer's git-status column shows status **vs the review
baseline** (per-kind colors; staged/unstaged distinction is hidden while
reviewing), fully-reviewed files **fade** (ignored-style `!!` status), and
the row of the file you're editing gets a clear highlight
(`NeoReviewExplorerCursor`, default `Visual`) instead of the near-invisible
unfocused cursorline (opt out of all of it:
`integrations = { snacks_explorer = false }`). While review mode is on,
`<leader>rv` inside the explorer list toggles reviewed for the file **or
whole folder** under the cursor — marks everything outstanding beneath it,
or unmarks it all when it's already fully reviewed
(`keymaps = { explorer_review = … }` to rebind). This patches snacks internals;
if a snacks update breaks it the plugin fails closed with a warning — run
`:checkhealth neo-review` to see exactly which seam moved, and see the header of
`lua/neo-review/integrations/snacks_explorer.lua` for the design.

## Installation (lazy.nvim)

```lua
{
  "ryanhobsonsmith/neo-review.nvim",
  opts = {
    -- skill = { auto_install = true }, -- let external Claude Code sessions
                                        -- participate with zero setup
  },
}
```

Requires Neovim 0.10+ (0.12 recommended) and git. Optional: snacks.nvim
(richer pickers/explorer integration), the `claude` CLI (agent features),
sbx / Docker Sandboxes (agent sandbox — required unless you explicitly opt
out per repo with `:NeoReviewAgentSandbox off`).

## Development (contributors)

```sh
./dev/sandbox.sh                         # clone YOUR real config (LazyVim) into NVIM_APPNAME=review
                                         # + inject this working copy as a dev plugin
alias rnvim='NVIM_APPNAME=review nvim'   # fully isolated: own config clone, own plugin installs/state
make test                                # headless test suite
```

`./dev/sandbox.sh` refreshes the clone from your real config repo (committed
state only); `--reset` rebuilds everything from scratch. For a dependency-free
minimal sandbox instead, symlink `dev/config/init.lua` to
`~/.config/review-min/init.lua` and use `NVIM_APPNAME=review-min`.

## Repo state on disk

`.review/` in a reviewed project holds plugin state. `local/` (reviewed-hunks
in `state.json`; per-repo agent choices in `agent.json`: `last_session_id`,
`permission_mode`, `sandbox`, `sandboxed`, `profile`, `model` — all per-user)
is always gitignored via a self-written `.review/.gitignore`;
`threads/` uses an append-only, conflict-free-by-construction format so
projects may choose to commit it.

## License

MIT
