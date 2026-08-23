local M = {}

---Run a git command synchronously. Returns stdout on success, nil on failure.
---Output is trimmed unless opts.raw (raw matters for file content, where
---trailing newlines are significant to the diff).
---@param args string[]
---@param cwd string?
---@param opts { raw: boolean }?
---@return string?
local function git(args, cwd, opts)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local ok, proc = pcall(vim.system, cmd, { text = true, cwd = cwd })
  if not ok then
    return nil
  end
  local res = proc:wait()
  if res.code ~= 0 then
    return nil
  end
  local out = res.stdout or ""
  if opts and opts.raw then
    return out
  end
  return (out:gsub("%s+$", ""))
end

M._git = git

---Repo root for a path (nil when not in a git repo).
---@param path string
---@return string?
function M.root(path)
  local dir = vim.fs.dirname(path)
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  return git({ "rev-parse", "--show-toplevel" }, dir)
end

---Path relative to the repo root.
function M.rel(root, abs)
  local r = vim.fs.normalize(root) .. "/"
  local a = vim.fs.normalize(abs)
  if a:sub(1, #r) == r then
    return a:sub(#r + 1)
  end
  return a
end

---The repo's trunk branch as a remote ref ("origin/main"), best effort.
---@return string?
function M.trunk(root)
  local head = git({ "symbolic-ref", "refs/remotes/origin/HEAD" }, root)
  if head then
    return (head:gsub("^refs/remotes/", ""))
  end
  for _, cand in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if git({ "rev-parse", "--verify", "--quiet", cand }, root) then
      return cand
    end
  end
  return nil
end

---Resolve a rev to a commit sha.
function M.resolve(root, rev)
  return git({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, root)
end

---Merge base of a ref and HEAD.
function M.merge_base(root, ref)
  return git({ "merge-base", ref, "HEAD" }, root)
end

---File content at a rev. nil when the file does not exist there (e.g. new file).
---@return string?
function M.show(root, rev, relpath)
  return git({ "show", rev .. ":" .. relpath }, root, { raw = true })
end

---Changed files (repo-relative) between a baseline commit-ish and the working
---tree, including untracked files. rev == "HEAD" covers the default baseline.
---@return string[]
function M.changed_files(root, rev)
  local seen, files = {}, {}
  local function add(p)
    -- The plugin's own metadata is never part of the changeset under review.
    if p == "" or p == ".review" or p:sub(1, 8) == ".review/" then
      return
    end
    if not seen[p] and vim.fn.isdirectory(root .. "/" .. p) == 0 then
      seen[p] = true
      files[#files + 1] = p
    end
  end

  local diff = git({ "diff", "--name-only", rev }, root)
  if diff then
    for line in diff:gmatch("[^\n]+") do
      add(line)
    end
  end
  -- Untracked files never appear in `git diff`; a brand-new file is one
  -- all-added hunk and must show up like any other change.
  local untracked = git({ "ls-files", "--others", "--exclude-standard" }, root)
  if untracked then
    for line in untracked:gmatch("[^\n]+") do
      add(line)
    end
  end
  table.sort(files)
  return files
end

---Per-file status vs a baseline rev: "A" added, "M" modified, "D" deleted,
---"R" renamed. Untracked files report "A" (added relative to the baseline).
---@return table<string, string>
function M.file_statuses(root, rev)
  local statuses = {}
  local diff = git({ "diff", "--name-status", rev }, root)
  if diff then
    for line in diff:gmatch("[^\n]+") do
      -- "M\tpath" / "A\tpath" / "R100\told\tnew"
      local code, rest = line:match("^(%a)%d*\t(.+)$")
      if code then
        local path = rest:match("\t(.+)$") or rest -- renames: take the new path
        statuses[path] = (code == "A" or code == "M" or code == "D" or code == "R") and code or "M"
      end
    end
  end
  local untracked = git({ "ls-files", "--others", "--exclude-standard" }, root)
  if untracked then
    for line in untracked:gmatch("[^\n]+") do
      statuses[line] = "A"
    end
  end
  return statuses
end

return M
