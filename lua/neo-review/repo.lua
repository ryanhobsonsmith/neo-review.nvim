-- Scaffolding for <root>/.review/: directories, the self-managed gitignore
-- (local/ and claims/ are per-user, never committed), and SKILL.md so agents
-- working in the repo learn the comment-thread format.
local M = {}

---@param root string
function M.ensure(root)
  local dir = root .. "/.review"
  local created = vim.fn.isdirectory(dir) == 0
  vim.fn.mkdir(dir .. "/local", "p")
  vim.fn.mkdir(dir .. "/threads", "p")
  if created or vim.fn.filereadable(dir .. "/.gitignore") == 0 then
    vim.fn.writefile({ "local/", "claims/" }, dir .. "/.gitignore")
  end
  -- Install/refresh the in-repo skill copy. The plugin's template is
  -- canonical and .review/SKILL.md is never hand-edited, so overwrite
  -- whenever the content drifts (e.g. after plugin updates fix the skill).
  local template = vim.api.nvim_get_runtime_file("skills/neo-review/SKILL.md", false)[1]
  if template then
    local want = vim.fn.readfile(template)
    local have = vim.fn.filereadable(dir .. "/SKILL.md") == 1 and vim.fn.readfile(dir .. "/SKILL.md") or nil
    if not have or not vim.deep_equal(want, have) then
      vim.fn.writefile(want, dir .. "/SKILL.md")
    end
  end
end

return M
