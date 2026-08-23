-- Per-user review state, persisted in <root>/.review/local/state.json.
-- .review/local/ and .review/claims/ are ephemeral per-user state and are
-- always gitignored (the plugin writes that gitignore itself); only
-- .review/threads/ (phase 2) is designed to be committable.
local M = {}

local function state_path(root)
  return root .. "/.review/local/state.json"
end

local function ensure_dirs(root)
  require("neo-review.repo").ensure(root)
end

---@return table  { [baseline_key]: { [hunk_hash]: true } }
function M.load(root)
  local path = state_path(root)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded.reviewed or {}
end

function M.save(root, reviewed)
  ensure_dirs(root)
  local blob = vim.json.encode({ version = 1, reviewed = reviewed })
  vim.fn.writefile(vim.split(blob, "\n"), state_path(root))
end

---@return boolean
function M.is_reviewed(reviewed, baseline_key, hash)
  local set = reviewed[baseline_key]
  return set ~= nil and set[hash] == true
end

---Set many hashes at once (file-level marking). value=false removes.
function M.set_many(root, reviewed, baseline_key, hashes, value)
  reviewed[baseline_key] = reviewed[baseline_key] or {}
  for _, h in ipairs(hashes) do
    reviewed[baseline_key][h] = value and true or nil
  end
  M.save(root, reviewed)
end

---Wipe all reviewed-state for one baseline (:NeoReviewUnreviewAll).
function M.clear_key(root, reviewed, baseline_key)
  reviewed[baseline_key] = nil
  M.save(root, reviewed)
end

---Toggle and persist. Returns the new value.
---@return boolean
function M.toggle(root, reviewed, baseline_key, hash)
  reviewed[baseline_key] = reviewed[baseline_key] or {}
  local now
  if reviewed[baseline_key][hash] then
    reviewed[baseline_key][hash] = nil
    now = false
  else
    reviewed[baseline_key][hash] = true
    now = true
  end
  M.save(root, reviewed)
  return now
end

return M
