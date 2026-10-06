# neo-review.nvim

Hunk-style review of AI-agent (or any) changes, fully inside Neovim: a
toggleable hunk overlay on your normal buffers, diffed live against a
switchable baseline, with persisted reviewed-state. Review is read-and-comment
only — it never mutates your files.

Three ways to work with it: pure human review (overlay + hunks +
reviewed-state), collaboration with any external Claude Code session through
persisted comment threads, or an agent terminal the editor opens and pings
for you.

## Agent terminal

The editor can run one plain interactive `claude` per Neovim instance, the
same TUI you'd run yourself, in a hidden terminal that never shows up in
your buffer list. `<C-;>` / `:NeoReviewAgentOpen` shows it in a centered
float, starting `claude` if it isn't running. Press `<C-;>` again from inside
the float (even while typing) to hide it. `q` in normal mode also hides it,
and so does moving to another window. Hiding leaves the session running.

`<leader>ra` / `:NeoReviewAgentPing` starts `claude` in the background if
needed. It types a one-line prompt listing the open comment threads
(pointing at `.review/SKILL.md`) and submits it, without opening anything.
Press `<C-;>` to watch. If `claude` is sitting on a dialog, such as the
first-run "trust this folder?" check, the ping shows the float and asks you
to answer the dialog instead of typing into it. `:NeoReviewAgentStop` ends
the process.

Everything else happens in the TUI itself: `/neo-review`, `/guided-review`,
permissions, `/model`. To see what the agent is doing, look at the terminal.
`<C-;>` needs a terminal that sends extended keys (Ghostty, kitty, WezTerm;
inside tmux, set `extended-keys on`). Otherwise remap `keymaps.agent_open`.

```lua
agent = {
  cmd = "claude --permission-mode auto", -- must accept claude flags (wrappers: pass "$@")
  hooks = true,          -- report claude's activity back to Neovim (below)
  ready_delay_ms = 1500, -- boot time a fresh claude gets before a ping is typed
},
```

claude starts in auto mode, so routine actions don't stop for approval. To
know what it's doing while the float is hidden, the plugin starts it with
`--settings` hooks (on top of your own). The hooks report back to this
Neovim over `$NVIM`:

- An alert when claude needs your permission, and when it finishes a turn
  you weren't watching.
- A status icon: `⏸` red = waiting for permission, `●` orange = working,
  `●` green = idle, `○` dim = starting, hidden when not running. Use
  `require("neo-review").lualine()` for lualine, or
  `require("neo-review").statusline_icon()` for a native 'statusline'.
- `require("neo-review").statusline()` returns the text form,
  `agent:working` and so on.
- `User NeoReviewAgentStateChanged` fires on every change, with
  `data = { running, activity }`.

With `hooks = false` the indicator only says whether claude is running.

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
| `:NeoReviewAgentOpen` / `:NeoReviewAgentPing` / `:NeoReviewAgentStop` | Show/hide the agent terminal float / type an open-threads prompt into it / end its process |

## Comment threads (phase 2)

Line-anchored conversation threads, persisted in `.review/threads/` as a
directory per thread with one file per message and status events as marker
files, so the editor and an agent writing at the same time never clobber
each other and projects may commit them. Agents may edit their own threads
in place to correct them. Threads render as a gutter `●` plus a one-line virtual summary; enter
one (`<leader>rc`) and it opens octo-style as a real buffer in a split —
type your reply at the bottom, `:w` sends it, `<leader>rx` resolves/reopens
(also works on a commented code line), `q` closes; replying to a resolved
thread reopens it. `]c`/`[c` jump between open comments (cross-file; from
the thread pane too, and an open pane follows along). Agent walkthroughs are
ordered *series* of threads: `]r`/`[r` walk the stops in order (resolved
stops included) and each shows its position (`2/6`) inline, in the pane
header, and in the threads picker. Anchors store snippet +
context + Treesitter symbol and re-resolve by content, so threads survive
edits and go *stale* (still listed) rather than pointing at wrong lines.

Agents participate by editing files directly: neo-review.nvim writes
`.review/SKILL.md` (schema + etiquette) into the repo on first use — point
Claude Code at it and it can leave review comments, reply to yours, and
resolve threads; the plugin polls and re-renders within a few seconds.

## Using with an external Claude Code session (hunk-style)

No agent terminal required — run Claude Code yourself in a terminal in the
repo and drive everything from there. One-time setup: `:NeoReviewSkillInstall`
(or `skill = { auto_install = true }`) symlinks the plugin's two skills,
`neo-review` and `guided-review`, into `~/.claude/skills/`:

- `/neo-review [request]` primes the agent with the thread format and house
  rules, checks open threads, then does whatever you ask while keeping the
  threads in step with its work. With no request it responds to every
  thread awaiting it. For example:
  - `/neo-review` — answer and act on the comments I left
  - `/neo-review conduct a PR review of this code` — review comments
    anchored on the lines they're about
  - `/neo-review give me a tour of this codebase` — hands off to
    guided-review
  - `/neo-review implement the retry logic` — does the work, then replies
    to and resolves the threads it settled
- `/guided-review [base | PR number | codebase | path] [focus]`: the agent
  presents a change like its author would to teammates, or a codebase like
  a maintainer onboarding you. You get a free-form overview in the terminal
  (what and why, how it works as a whole, what to scrutinize) plus an
  ordered series of stops through the most important code, which you
  follow with `]r` / `[r`.

The agent also picks these skills up on its own when you mention review
comments or ask for a walkthrough, without the slash command.

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
next/prev open comment · `]r`/`[r` next/prev walkthrough stop ·
`<C-;>` show/hide agent terminal · `<leader>ra` ping agent.

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
(richer pickers/explorer integration), the `claude` CLI (agent terminal).

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
in `state.json`, per-user) is always gitignored via a self-written `.review/.gitignore`;
`threads/` uses one file per message (rarely edited in place), so projects
may choose to commit it.

## License

MIT
