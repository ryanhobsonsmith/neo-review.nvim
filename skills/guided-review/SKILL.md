---
name: guided-review
description: Present a PR, changeset, codebase, or subsystem the way its author would walk fellow engineers through it — a free-form overview sent to the user plus an ordered series of review-comment threads they step through in Neovim (neo-review.nvim, `]r`). Use when the user runs /guided-review or asks for a guided review, walkthrough, tour, or presentation of a PR, branch, set of changes, codebase, or part of one.
argument-hint: "[base ref | branch | PR number | codebase | path] [what to focus on]"
---

# Guided review

Walk the user through a changeset the way the author would present their PR
to teammates, or through a codebase or subsystem the way its maintainer
would onboard a new engineer. First make sure they understand what it does
and how it works as a whole. Then guide them through the most important
code one stop at a time, in the order that builds understanding fastest.

You deliver two things:

1. **Tour threads**: an ordered series of `note` threads in
   `.review/threads/`, anchored on the code. The user steps through them in
   Neovim with `]r` / `[r`.
2. **An overview**: a free-form write-up in your final message.

This is a presentation, not a code change: write only under
`.review/threads/`, never to source files.

Arguments: `$ARGUMENTS` (may be empty).

## 0. Thread format

Tour stops are ordinary review-comment threads. Before writing any file,
read the `neo-review` skill (also at `.review/SKILL.md` in repos where the
plugin has run). It defines `thread.json`, anchors (snippets copied
verbatim from the file), message files, the `series` field, real-clock
timestamps, and the rules for editing your own threads. Everything below
assumes it.

## 1. Pin down the scope

Interpret the arguments:

- **Empty**: a guided PR review of the work in progress, chosen like this:
  1. **Uncommitted changes, if there are any.** Check with
     `git status --porcelain -- . ':!.review'`. Excluding `.review/`
     matters, because review threads are usually untracked files
     themselves. If anything is listed, the scope is exactly those changes:
     `git diff HEAD` for staged and unstaged edits, plus untracked files
     from `git ls-files --others --exclude-standard -- . ':!.review'`.
     Committed branch work is out of scope in this case.
  2. **Otherwise, the branch against `origin/main`**:
     `git diff $(git merge-base origin/main HEAD) HEAD`. If the repo's
     default branch isn't `main`, use what
     `git symbolic-ref refs/remotes/origin/HEAD` names.
  3. **If both are empty**, there is nothing to present. Tell the user and
     stop.

  Say which of these you used at the top of the overview.
- **A ref or branch name**: the scope is everything since that base,
  committed or not: `git diff $(git merge-base <ref> HEAD)` plus untracked
  files.
- **A PR number**: `gh pr view <n> --json title,body,baseRefName,headRefName`.
  Anchors must match the files on disk, so the PR's head must be checked
  out. If it isn't, stop and ask the user to check it out. Never switch
  branches yourself.
- **"codebase", "this repo", a directory, or a subsystem name**: a
  codebase tour. There is no diff; the scope is the whole repo or that
  part of it. Start from the README, build and package manifests, and the
  entry points, then follow the main paths through the core modules.
- **Anything else**: treat it as guidance on what to emphasize.

Ignore `.review/` itself. Gather the author's intent from
`git log --reverse <base>..HEAD` and, when a PR exists, its title and body
(skip quietly if `gh` is unavailable).

## 2. Understand it before writing anything

Read the whole diff. Then read the changed files in full where it matters,
plus enough unchanged code (callers, callees, types) to explain how the
pieces connect. For a codebase tour, read until you can explain the main
flows end to end; don't try to cover every file. Work out:

- **Problem**: what was wrong or missing, and why it matters. For a
  codebase: what the system is for and who or what calls it.
- **Key idea**: the one or two sentences that explain the solution. This is
  the mental model a reviewer needs before any code makes sense.
- **Flow**: how control and data move through the new code, end to end.
- **Core, supporting, mechanical**: core is the mechanism itself.
  Supporting is wiring, config, and tests. Mechanical is renames, moves,
  formatting, generated code, and lockfiles. Mechanical changes get a
  sentence in the overview and never a stop.
- **Risks and tradeoffs**: what could break, what was chosen over what,
  what was deliberately left out, and where a reviewer should push. For a
  codebase: the conventions a newcomer must follow, the fragile or
  surprising parts, and where the complexity lives.

**Verify every factual claim before you write it.** Check function names,
who calls what, and which module writes which data by reading or grepping
the code. A confident wrong statement in a walkthrough does more harm than
leaving the point out.

## 3. Plan the tour

Choose stops the way a good presenter would, and write the plan down for
yourself (ordered `file:line` + headline) before creating any thread.

- **Stop 1 is the map.** Anchor it at the entry point: where the new
  behavior begins, or the central type or function. In a few lines, say
  what the change does, the key idea, and the route the tour will take
  ("we start where requests come in, follow them into X, see how Y handles
  failure, and finish with the tests").
- **Follow the flow, not the file list**: entry point, core mechanism, how
  its results are used, edge cases and error handling, integration and
  config, then the tests that prove it. Returning to a file later is fine.
- **One idea per stop.** Anchor on the line that best shows it: a
  signature, the key condition, or the call that ties things together.
  Never a blank line or a closing brace.
- **Size to the scope**: about 3–5 stops for a small change, 6–10 for a
  typical PR or subsystem, and at most ~15 for a large PR or a whole
  codebase. Cover the important sections, not every hunk or file.

If `.review/threads/` already holds an earlier tour of the same scope, ask
the user whether to replace it before writing a second one. Delete the old
stops only if they say so.

## 4. Write the stops

- Every stop is `kind: "note"` and shares one fresh `series.id` (`s-` +
  hex). `series.pos` runs 1..N in tour order.
- **First line**: a short, self-contained headline. It is shown next to the
  code as the stop's summary. Never write a position like "3/9" anywhere;
  the editor displays it.
- **Body**, roughly 3–12 lines:
  - what this code does and **why it is written this way**
  - how it connects to the previous or next stop ("this is where the token
    from the previous stop gets checked")
  - anything subtle: invariants, ordering assumptions, failure modes,
    alternatives that were rejected
  - refer to nearby code by symbol name, not line number, because lines
    shift
- Write like a colleague presenting at a review: plain, direct, specific.
  Don't narrate obvious code line by line.
- **Found a real problem while preparing?** Don't bury it in the tour.
  Leave a separate `issue` or `question` thread with no `series`, and call
  it out in the overview.

After writing all stops, re-read each one against the code. Fix mistakes by
editing your stop files in place rather than adding correction replies.

## 5. The overview (your final message)

Write it for an engineer about to review the code. Someone who reads only
the overview should understand the change; the tour adds the code-level
detail. Cover:

- **What and why**: the problem and the outcome, in a short paragraph.
- **How it works**: the solution as a whole, meaning the key idea and the
  end-to-end flow. Add a small diagram only if it genuinely helps.
- **The tour**: the stops in order, one line each, headline plus
  `file:line`.
- **What to scrutinize**: risks, tradeoffs, open questions, and anything
  you found while preparing, including the issue threads you left.
- **Also changed**: one or two sentences on supporting and mechanical
  changes that have no stop.
- **Scope**: the base ref the changeset was measured against, or the part
  of the codebase covered.
- **How to follow along**: in Neovim with review mode on (`<leader>rr`),
  press `]r` to jump to stop 1 and keep pressing it to advance; `[r` goes
  back. `<leader>rc` opens a stop's thread and `<leader>rt` lists every
  stop in order. They can reply in any stop's thread and then ask you to
  answer their comments.

## After the tour

When the user replies in stop threads, answer them following the
`neo-review` skill. If they ask to restructure the tour (reorder, split,
merge, or drop a stop), edit the series in place.
