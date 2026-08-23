local git = require("neo-review.git")

local M = {}

---@class review.Baseline
---@field kind "head"|"ref"
---@field ref string?      user-supplied ref (kind == "ref")
---@field commit string?   resolved commit sha (kind == "ref")

---@type review.Baseline
M.current = { kind = "head" }

---Human-readable label for the winbar/messages.
function M.label()
  if M.current.kind == "head" then
    return "working tree"
  end
  return M.current.ref
end

---Key for scoping reviewed-state per baseline.
function M.key()
  if M.current.kind == "head" then
    return "head"
  end
  return M.current.commit
end

---The rev to read baseline file content from.
---@return string
function M.rev()
  if M.current.kind == "head" then
    return "HEAD"
  end
  return M.current.commit
end

---Set the baseline. args:
---  nil / ""      -> working tree vs HEAD (default)
---  "main"        -> merge-base(trunk, HEAD), the PR view
---  any rev       -> merge-base is NOT applied for arbitrary revs unless it is
---                   the trunk; the rev itself is used
---@param arg string?
---@return boolean ok
---@return string? err
function M.set(root, arg)
  arg = arg and vim.trim(arg) or ""
  if arg == "" then
    M.current = { kind = "head" }
    return true
  end
  if arg == "--session" then
    return false, "session baselines are not implemented yet"
  end

  local rev = arg
  local trunk = git.trunk(root)
  -- "main" (or the actual trunk name) means "what a PR would show": diff from
  -- the merge-base so upstream commits you haven't rebased on don't pollute it.
  if trunk and (arg == "main" or arg == "master" or arg == trunk or "origin/" .. arg == trunk) then
    local mb = git.merge_base(root, trunk)
    if not mb then
      return false, "no merge-base between " .. trunk .. " and HEAD"
    end
    rev = mb
  end

  local commit = git.resolve(root, rev)
  if not commit then
    return false, "cannot resolve rev: " .. arg
  end
  M.current = { kind = "ref", ref = arg, commit = commit }
  return true
end

---Baseline content for a file. "" when the file doesn't exist at the baseline
---(new/untracked file -> everything is one added hunk).
---@return string
function M.file_text(root, relpath)
  return git.show(root, M.rev(), relpath) or ""
end

---All files changed vs the current baseline.
---@return string[]
function M.changed_files(root)
  return git.changed_files(root, M.rev())
end

return M
