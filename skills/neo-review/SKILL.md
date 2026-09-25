---
name: neo-review
description: Primes you to work with the user's neo-review.nvim review-comment threads in .review/threads/ (line-anchored conversations rendered live in their Neovim) and then do what they ask. Use for /neo-review with any request, and whenever the user mentions review comments or threads, asks you to answer or address comments they left, to review a PR or changes with inline comments, or for a tour or walkthrough of a changeset or codebase.
argument-hint: "[request — default: respond to open threads]"
---

# neo-review: working with review threads

The user reviews code in Neovim with neo-review.nvim. Conversations about
code live as threads in `.review/threads/`, each anchored to a line. The
user reads and replies to them in the editor; you read and write the files
directly. This skill gives you the format and the house rules, then you do
what the user asked.

**Request:** $ARGUMENTS

## What to do

1. **Check the threads first, whatever the request.** Load them (see
   "Reading threads") and note which are open and awaiting you: the last
   message is from a human. The user may already have asked something about
   the very code you are about to touch.
2. **Do the request:**
   - **Empty**, or you were pointed at this file without a specific
     request: respond to every thread awaiting you ("Workflow: respond to
     threads").
   - **"Answer my questions", "address my comments", "fix what I
     flagged"**: the same workflow, limited to what they asked for.
   - **"Review this PR" / "review my changes"**: "Workflow: review a
     changeset".
   - **A tour or walkthrough** of a PR, branch, changeset, codebase, or
     subsystem: follow the `guided-review` skill. It plans the tour, writes
     the stops in this format, and ends with an overview for the user.
   - **Anything else** (implement, refactor, debug, explain): do it, and
     keep the threads in step with your work (next step).
3. **Keep threads in step with your work**, whatever the request:
   - If your work settles an open thread, reply saying what you changed and
     resolve it. If you're unsure it's what they wanted, reply and leave it
     open.
   - If you change a line one of your own threads is anchored to, update
     that thread's anchor (see "Editing your own threads"). If your change
     leaves a human's thread pointing at code that no longer exists, say so
     in your report.
   - When something needs the user's attention at a specific line, such as
     a decision to confirm, a risk, or an open question, leave a thread
     there rather than burying it in terminal output.
   - Don't answer threads the request didn't cover. List them in your
     report instead.
4. **Report back in the terminal**: what you did; one line per thread you
   created, replied to, resolved, or edited; and any threads still awaiting
   a response.

**Editor sync:** while review mode is on, Neovim polls `.review/threads/`
every ~3 seconds and renders new threads, replies, and edits automatically.
You never need to ping the editor. If the user says nothing appeared, have
them check review mode is on (`<leader>rr` / `:NeoReviewToggle`).

Each message and status change is its own file, so your writes and the
human's never overwrite each other. You may edit files **you** wrote to
correct them (see "Editing your own threads").

## Reading threads

List `.review/threads/*/`. For each thread, read `thread.json` and every
`msg-*.json` (ordered by `ts`), and compute its status from `status-*.json`
(latest `ts` wins; no status file means open). A thread is **awaiting you**
when it is open and its last message has `"role": "human"`. Read the
anchored code too: the snippet locates it even if lines have moved.

## Finding the changeset

State which baseline you used when you report back.

- Working-tree changes (default): `git diff HEAD` plus untracked files via
  `git ls-files --others --exclude-standard` (a new file is part of the
  changeset).
- PR view ("review this PR/branch"): diff from the merge base,
  `git diff $(git merge-base origin/main HEAD)` (substitute the repo's
  trunk; check `git symbolic-ref refs/remotes/origin/HEAD`).
- Ignore `.review/` itself.

## Format

One directory per thread: `.review/threads/<id>/` where `<id>` is a short
unique hex string you generate (e.g. from timestamp + random).

`thread.json` — written at creation:

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
  between 2 and 3). To reorder, edit the `pos` values.
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

## Workflow: respond to threads

1. Take the threads awaiting you (see "Reading threads"), limited to what
   the request asked for.
2. Do what each one asks: answer the question, make the change, or explain
   why not.
3. Reply in the thread saying exactly what you changed, or answering the
   question. Then add a `resolved` status event when it is settled. If
   you're unsure it's what they wanted, or you asked them something back,
   leave it open.
4. Report per-thread outcomes in the terminal too.

## Workflow: review a changeset and leave comments

When asked to "review this PR / my changes and add comments":

1. Compute the changeset (see "Finding the changeset") and read the changed files —
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

## Tours and walkthroughs

Follow the `guided-review` skill. If it isn't available, the minimum is:
plan every stop first, then write one `note` thread per stop sharing one
`series.id` with `series.pos` 1..N in tour order. Each stop's first line is
a plain headline, never "2/6"; the editor shows the position. Tell the user
to follow along with `]r` / `[r`, and give them a written overview.

## Editing your own threads

Fix mistakes in place rather than piling on correction replies — for
example, a walkthrough stop that misnames a function, anchors the wrong
line, or sits in the wrong order.

- Edit only files you wrote: your `thread.json` (anchor, kind, `series`) and
  your own `msg-*.json` bodies. **Never edit a human's message.**
- Keep a message's `ts` and filename unchanged when editing it — they fix
  its place in the conversation.
- If a human has already replied to the message you want to change, don't
  rewrite it under them: add a reply with the correction instead.
- Resolve/reopen by adding a new status file, never by editing one.
- Delete a thread only when the user asks you to (e.g. "drop stop 4") and
  only one you created. Otherwise resolve it.

## Etiquette

- **Replying**: add a `msg-*.json` in the existing thread dir. Reply in the
  thread rather than creating a duplicate.
- **Resolving**: when you implement what a thread asks, reply describing the
  change, and add a `resolved` status event. If unsure whether it's
  addressed, reply and leave it open for the human.
- Never touch `.review/local/` or `.review/claims/` (per-user editor state).
- Don't delete threads or files except as allowed under "Editing" above.
  A human reply through the editor reopens a resolved thread
  automatically; if you disagree with a resolution, reply and add an
  `open` status event.
