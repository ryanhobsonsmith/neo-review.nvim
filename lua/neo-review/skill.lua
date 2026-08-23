-- :NeoReviewSkillInstall — make the review-comments skill discoverable by any
-- Claude Code session on this machine, by symlinking the plugin's skill/
-- directory into ~/.claude/skills/. A symlink (not a copy) so the installed
-- skill tracks the plugin working copy.
local M = {}

M.NAME = "review-comments"

local function skills_dir()
  local config_dir = vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")
  return config_dir .. "/skills"
end

---The plugin's skill/ directory (source of the symlink).
local function source_dir()
  local f = vim.api.nvim_get_runtime_file("skill/SKILL.md", false)[1]
  return f and vim.fs.dirname(f) or nil
end

---@return "installed"|"stale"|"missing"|"conflict", string detail
function M.status()
  local link = skills_dir() .. "/" .. M.NAME
  local st = vim.uv.fs_lstat(link)
  if not st then
    return "missing", link .. " does not exist"
  end
  if st.type ~= "link" then
    return "conflict", link .. " exists but is not a symlink (not ours — won't touch it)"
  end
  local target = vim.uv.fs_readlink(link)
  local src = source_dir()
  if src and target and vim.fs.normalize(target) == vim.fs.normalize(src) then
    return "installed", link .. " → " .. target
  end
  return "stale", link .. " → " .. tostring(target) .. " (expected " .. tostring(src) .. ")"
end

function M.install()
  local src = source_dir()
  if not src then
    vim.notify("neo-review: skill/SKILL.md not found on runtimepath", vim.log.levels.ERROR)
    return
  end
  local state, detail = M.status()
  if state == "installed" then
    vim.notify("neo-review: skill already installed (" .. detail .. ")")
    return
  end
  if state == "conflict" then
    vim.notify("neo-review: " .. detail, vim.log.levels.ERROR)
    return
  end
  local link = skills_dir() .. "/" .. M.NAME
  vim.fn.mkdir(skills_dir(), "p")
  if state == "stale" then
    vim.uv.fs_unlink(link)
  end
  local ok, err = vim.uv.fs_symlink(src, link, { dir = true })
  if not ok then
    vim.notify("neo-review: failed to symlink skill: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("neo-review: skill installed — Claude Code sessions can now be told e.g. \"act on my review comments\" (" .. link .. ")")
end

return M
