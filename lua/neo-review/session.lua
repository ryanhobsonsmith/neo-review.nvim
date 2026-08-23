-- Shared mutable session state, kept in its own module so nav/picker/init can
-- all reach it without circular requires.
local M = {
  enabled = false,
  root = nil, ---@type string?
  reviewed = {}, -- loaded reviewed-state table
  ---@type table<integer, { relpath: string, base_text: string, hunks: review.Hunk[] }>
  bufs = {},
  files = {}, ---@type string[] changed files (repo-relative, sorted)
  statuses = {}, ---@type table<string, string> relpath -> "A"|"M"|"D"|"R"
}

function M.reset()
  M.enabled = false
  M.root = nil
  M.reviewed = {}
  M.bufs = {}
  M.files = {}
  M.statuses = {}
end

---Position of a file in the changed-file list (nil if unchanged).
function M.file_index(relpath)
  for i, f in ipairs(M.files) do
    if f == relpath then
      return i
    end
  end
  return nil
end

return M
