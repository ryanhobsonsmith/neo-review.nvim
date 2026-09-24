---
name: review-comments
description: Read, write, and act on code-review comment threads stored in the repo's .review/threads/ directory (rendered live in Neovim by neo-review.nvim). Use when the user asks you to act on / address review comments they left, review a PR/diff/changes and leave comments, or walk them through a changeset with inline comments.
---

# Review comment threads

This repo uses file-based review threads in `.review/threads/`. The human
reads and replies to them inside Neovim (neo-review.nvim); you read and write
them with normal file tools. **Append-only: never edit or delete an existing
file** — thread state is derived from the set of files, and immutability is
what keeps the format merge-conflict-free.

**Editor sync:** while review mode is on, Neovim polls `.review/threads/`
every ~3 seconds and renders new threads/replies automatically — you never
need to ping the editor. If the user says nothing appeared, have them check
review mode is on (`<leader>rr` / `:NeoReviewToggle`).

## Finding the changeset

State which baseline you used when you report back.

- Working-tree changes (default): `git diff HEAD` plus untracked files via
  `git ls-files --others --exclude-standard` (a new file is part of the
  changeset).
- PR view ("review this PR/branch"): diff from the merge base —
  `git diff $(git merge-base origin/main HEAD)` (substitute the repo's
  trunk; check `git symbolic-ref refs/remotes/origin/HEAD`).
- Ignore `.review/` itself.

## Format

One directory per thread: `.review/threads/<id>/` where `<id>` is a short
unique hex string you generate (e.g. from timestamp + random).

`thread.json` — written once at creation, never modified:

```json
{
  "version": 1,
  "id": "68a1b2c3d4",
  "file": "src/auth/session.ts",
  "kind": "question",
  "created": "2026-08-11T19:03:00Z",
  "anchor": {
    "line": 44,
    "snippet": ["    return issueSession(claims.sub);"],
    "context_before": ["    const claims = verifyJwt(token);", "    if (!claims.sub) throw new AuthError(\"no-subject\");"],
    "context_after": ["  }", ""],
    "symbol": "refreshSession"
  }
}
```

- `file`: repo-relative path. `kind`: one of `question`, `issue`,
  `suggestion`, `nitpick`, `note`, `praise`.
- `anchor.line`: 1-based line the comment targets, at creation time.
  `snippet`: that line's (or lines') exact text **copied verbatim from the
  current file content**. `context_before`/`_after`: up to 2 surrounding
  lines each. `symbol`: enclosing function/class name if known. The editor
  re-locates the thread by content — an inaccurate snippet makes the thread
  go stale (unanchored), so exact snippet text matters more than the line
  number.
- `series` (optional, walkthroughs only): `{ "id": "s-68adf3a19c", "pos": 1 }`.
  Every stop of one walkthrough shares the `id` (`s-` + a hex string you
  generate like a thread id); `pos` orders the stops (1, 2, 3 …). The
  editor numbers the stops itself ("2/6") from `pos` — never write that
  number into a message. To add a stop to an existing walkthrough later,
  create a new thread with an unused `pos`; fractions are fine (`2.5` sits
  between 2 and 3). Never edit an existing `thread.json` to renumber.
  Ordinary review comments have no `series` field.

## Timestamps: always read the real clock

**Never estimate, invent, or round a timestamp** — messages and status
events are ordered by `ts`, and a guessed time (you do not know the current
time!) mis-sorts the conversation and can make a stale status event win.
Get both the `ts` field and the filename timestamp from the system clock:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ   # ts field, e.g. 2026-08-20T19:03:41Z
date -u +%Y%m%dT%H%M%S        # filename part, e.g. 20260820T190341
```

Run it fresh for every message you write (not once per session).

Messages — one file per message, named `msg-<UTCts>-<rand4hex>-<author>.json`
(e.g. `msg-20260811T190300-9f2a-claude.json`):

```json
{ "author": "claude", "role": "agent", "ts": "2026-08-11T19:03:00Z",
  "body": ["why 30s? our LB already normalizes clock skew —", "is this masking the real bug from #1204?"] }
```

- `role` is `"agent"` for you, `"human"` for people. `body` is an array of
  lines. Render order is by `ts`.
- The first line of a thread's first message is shown as its one-line
  summary in the editor — make it short and self-contained.

Status — a thread is open unless a status event says otherwise. To resolve or
reopen, add `status-<UTCts>-<rand4hex>-<author>.json`:

```json
{ "status": "resolved", "author": "claude", "ts": "2026-08-11T19:10:00Z" }
```

The event with the latest `ts` wins. Do not delete status files.

## Workflow: act on review comments

When asked to "see the comments I left" / "address review feedback":

1. List `.review/threads/*/`; for each, read `thread.json` + all
   `msg-*.json`, compute status from `status-*.json` (latest ts wins).
2. Threads that are OPEN and whose last message is from a human are awaiting
   you. Read the anchored code (the snippet locates it even if lines moved).
3. Do the work each thread asks for.
4. Reply in the thread describing exactly what you changed (or why you
   didn't), then add a `resolved` status event. If you're unsure the change
   is what they wanted, reply and **leave it open** for the human.
5. Summarize per-thread outcomes back to the user in the terminal too.

## Workflow: review a changeset and leave comments

When asked to "review this PR / my changes and add comments":

1. Compute the changeset (see baselines above) and read the changed files —
   full files where needed, not just the diff, so anchors are accurate.
2. One thread per distinct point, anchored to the exact line it's about,
   with `snippet` copied from the current file. Pick the `kind` honestly:
   `issue` (would block), `question`, `suggestion`, `nitpick`, `praise`.
3. Don't comment on every hunk — highlight what the reader wouldn't spot
   themselves: bugs, risks, hidden coupling, missing tests, good moves worth
   calling out. Quality over coverage.
4. Finish with a terminal summary: N comments, worst findings first, and
   remind the user they can jump between them with `]c` / `[c` or the
   `<leader>rt` picker in Neovim.

## Workflow: walkthrough ("walk me through this PR")

Narrate the changeset as ordered `note` threads the user follows in their
editor:

1. Read the whole changeset first; decide the order that tells the clearest
   story (rarely file order): entry point → core change → consequences.
2. Plan every stop before writing any. Then leave one `note` thread per
   stop, anchored where the reader should look, each with the same
   `series.id` and its `series.pos` (1 for the first stop, 2 for the next …).
   The first line is a plain headline ("the baseline ref that everything
   diffs against"); following lines explain what to see and why it matters.
   **Do not put "1/N" or "2/6" in message bodies** — the editor renders
   each stop's position from `series`.
3. Keep stops focused — 4–8 for a typical changeset. Point out risks and
   non-obvious connections, not line-by-line mechanics.
4. Tell the user to follow along with `]r` / `[r` (next / previous
   walkthrough stop, in order, from anywhere in the repo), and finish with
   a closing reply on stop 1 summarizing the whole changeset.

## Etiquette

- **Replying**: add a `msg-*.json` in the existing thread dir. Reply in the
  thread rather than creating a duplicate.
- **Resolving**: when you implement what a thread asks, reply describing the
  change, and add a `resolved` status event. If unsure whether it's
  addressed, reply and leave it open for the human.
- Never touch `.review/local/` or `.review/claims/` (per-user editor state).
- **Never delete** thread directories or files — cleanup is a human-only
  editor operation. A human reply through the editor reopens a resolved
  thread automatically; if you disagree with a resolution, reply and add an
  `open` status event rather than deleting anything.
