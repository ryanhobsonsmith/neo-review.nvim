-- :NeoReviewSkillInstall — make the plugin's Claude Code skills discoverable
-- by any Claude Code session on this machine, by symlinking each
-- skills/<name>/ directory into ~/.claude/skills/<name>. Symlinks (not
-- copies) so installed skills track the plugin working copy.
--
--   neo-review     /neo-review <request>: thread format + house rules, then
--                  do the request (default: respond to open threads)
--   guided-review  /guided-review: presenter-style tour of a PR or codebase
local M = {}

M.NAMES = { "neo-review", "guided-review" }

-- Names this plugin used to install. Their links are removed when they are
-- dangling or still point into this plugin (never someone else's skill).
M.LEGACY = { "review-comments" }

local function skills_dir()
  local config_dir = vim.env.CLAUDE_CONFIG_DIR or (vim.env.HOME .. "/.claude")
  return config_dir .. "/skills"
end

---The plugin's skills/<name>/ directory (source of the symlink).
local function source_dir(name)
  local f = vim.api.nvim_get_runtime_file("skills/" .. name .. "/SKILL.md", false)[1]
  return f and vim.fs.dirname(f) or nil
end

---@alias review.SkillState "installed"|"stale"|"dangling"|"missing"|"conflict"

---State of one skill's link. "stale" = a link to somewhere else (maybe a
---deliberate dev checkout — only an explicit install replaces it);
---"dangling" = a link whose target is gone (e.g. the plugin moved its skill
---directory) — safe to repair automatically.
---@return review.SkillState, string detail
function M.status_of(name)
  local link = skills_dir() .. "/" .. name
  local st = vim.uv.fs_lstat(link)
  if not st then
    return "missing", link .. " does not exist"
  end
  if st.type ~= "link" then
    return "conflict", link .. " exists but is not a symlink (not ours — won't touch it)"
  end
  local target = vim.uv.fs_readlink(link)
  local src = source_dir(name)
  if src and target and vim.fs.normalize(target) == vim.fs.normalize(src) then
    return "installed", link .. " → " .. target
  end
  if not vim.uv.fs_stat(link) then
    return "dangling", link .. " → " .. tostring(target) .. " (target missing)"
  end
  return "stale", link .. " → " .. tostring(target) .. " (expected " .. tostring(src) .. ")"
end

---Remove legacy links we own. Returns the names removed.
local function remove_legacy()
  local removed = {}
  local src = source_dir(M.NAMES[1])
  local plugin_root = src and vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(src))) or nil
  for _, name in ipairs(M.LEGACY) do
    local link = skills_dir() .. "/" .. name
    local st = vim.uv.fs_lstat(link)
    if st and st.type == "link" then
      local target = vim.fs.normalize(vim.uv.fs_readlink(link) or "")
      local dangling = vim.uv.fs_stat(link) == nil
      local ours = plugin_root ~= nil and target:sub(1, #plugin_root + 1) == plugin_root .. "/"
      if dangling or ours then
        vim.uv.fs_unlink(link)
        removed[#removed + 1] = name
      end
    end
  end
  return removed
end

local SEVERITY = { installed = 0, stale = 1, dangling = 2, missing = 3, conflict = 4 }

---Combined state over all skills: the worst one, with every non-installed
---skill's detail.
---@return review.SkillState, string detail
function M.status()
  local worst, details = "installed", {}
  for _, name in ipairs(M.NAMES) do
    local state, detail = M.status_of(name)
    if SEVERITY[state] > SEVERITY[worst] then
      worst = state
    end
    details[#details + 1] = name .. ": " .. detail
  end
  return worst, table.concat(details, "; ")
end

---Link one skill. Returns true when it is installed afterwards.
local function install_one(name, allowed)
  local state, detail = M.status_of(name)
  if state == "installed" then
    return true
  end
  if not allowed[state] then
    if state == "conflict" then
      vim.notify("neo-review: " .. detail, vim.log.levels.ERROR)
    end
    return false
  end
  local src = source_dir(name)
  if not src then
    vim.notify("neo-review: skills/" .. name .. "/SKILL.md not found on runtimepath", vim.log.levels.ERROR)
    return false
  end
  local link = skills_dir() .. "/" .. name
  vim.fn.mkdir(skills_dir(), "p")
  if state ~= "missing" then
    vim.uv.fs_unlink(link)
  end
  local ok, err = vim.uv.fs_symlink(src, link, { dir = true })
  if not ok then
    vim.notify("neo-review: failed to symlink skill " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function report(changed, removed)
  if #removed > 0 then
    vim.notify("neo-review: removed old skill link" .. (#removed == 1 and "" or "s") .. ": " .. table.concat(removed, ", "))
  end
  if #changed > 0 then
    vim.notify(
      "neo-review: skill"
        .. (#changed == 1 and "" or "s")
        .. " installed: "
        .. table.concat(changed, ", ")
        .. " — Claude Code sessions can now run /neo-review and /guided-review"
    )
  end
end

---Explicit install: links every skill, replacing stale/dangling links;
---never touches a real directory in the way.
function M.install()
  local removed = remove_legacy()
  local changed = {}
  for _, name in ipairs(M.NAMES) do
    local before = M.status_of(name)
    if install_one(name, { missing = true, dangling = true, stale = true }) and before ~= "installed" then
      changed[#changed + 1] = name
    end
  end
  if #changed == 0 and M.status() == "installed" then
    vim.notify("neo-review: skills already installed (" .. table.concat(M.NAMES, ", ") .. ")")
  end
  report(changed, removed)
end

---setup()-time install (skill.auto_install): only missing or dangling
---links, so a link deliberately pointed elsewhere is left alone.
function M.auto_install()
  local removed = remove_legacy()
  local changed = {}
  for _, name in ipairs(M.NAMES) do
    local before = M.status_of(name)
    if (before == "missing" or before == "dangling") and install_one(name, { missing = true, dangling = true }) then
      changed[#changed + 1] = name
    end
  end
  report(changed, removed)
end

return M
