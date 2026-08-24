-- Sandbox for the wrapped agent session: Docker Sandboxes (sbx) microVMs —
-- https://docs.docker.com/ai/sandboxes/
--
-- The claude process runs inside a per-project sbx sandbox instead of
-- directly on the host. All isolation is sbx's: its own kernel per sandbox,
-- deny-by-default egress filtered BY DOMAIN NAME at a host-side proxy (no
-- IP-allowlist staleness; `sbx policy log` shows denials), and proxy-injected
-- credentials that never enter the VM. Sandboxes are named
-- `claude-<workdir>` and persist per project; `sbx exec -i` passes the
-- stream-json stdio through unchanged, so the transport is identical to a
-- direct run.
--
-- There is deliberately NO fallback sandbox implementation: when the sandbox
-- is enabled (the default) and sbx is unavailable, starting the agent FAILS
-- with instructions. Direct (unsandboxed) execution is an explicit choice:
-- :NeoReviewAgentSandbox off.
local session = require("neo-review.session")

local M = {}

local function cfg()
  return require("neo-review.config").options.agent.sandbox
end

---sbx names sandboxes <agent>-<workdir basename>.
function M.sandbox_name(root)
  return "claude-" .. vim.fn.fnamemodify(root or session.root or "?", ":t")
end

---Is the sandbox active for this repo? Per-repo override in agent.json
---wins, then the active profile's sandbox field, then the config default.
---@param repo_state table the loaded .review/local/agent.json
---@param profile table? the active agent profile, if any
function M.enabled(repo_state, profile)
  if repo_state.sandbox ~= nil then
    return repo_state.sandbox
  end
  if profile and profile.sandbox ~= nil then
    return profile.sandbox
  end
  return cfg().enabled
end

---Resolve the user-supplied argv_prefix (list, or function receiving
---{ root = <repo root> } for custom wrappers).
---@return string[]?
local function custom_prefix()
  local custom = cfg().argv_prefix
  if type(custom) == "function" then
    local ok, result = pcall(custom, { root = session.root })
    return ok and result or nil
  end
  return custom
end

---Can we actually run sandboxed right now? Returns ok, reason.
---Failing preflight BLOCKS the agent (no silent fallback) — the reasons
---double as the user-facing fix instructions.
function M.preflight()
  local custom = custom_prefix()
  if custom then
    if vim.fn.executable(custom[1]) == 1 then
      return true
    end
    return false, "sandbox.argv_prefix command not found: " .. tostring(custom[1])
  end
  if vim.fn.executable("sbx") ~= 1 then
    return false, "sbx (Docker Sandboxes) not installed — brew trust docker/tap && brew install docker/tap/sbx (or :NeoReviewAgentSandbox off to run WITHOUT isolation)"
  end
  local ls = vim.system({ "sbx", "ls" }, { text = true }):wait()
  if ls.code ~= 0 then
    local out = (ls.stderr or "") .. (ls.stdout or "")
    if out:lower():find("unauthorized") or out:lower():find("sign in") then
      return false, "not signed in to Docker — run: sbx login"
    end
    return false, "sbx not ready (" .. vim.trim(out):sub(1, 120) .. ") — try: sbx daemon start"
  end
  return true
end

---Does this repo's sbx sandbox exist yet?
function M.sandbox_exists()
  local ls = vim.system({ "sbx", "ls" }, { text = true }):wait()
  return ls.code == 0 and (ls.stdout or ""):find(M.sandbox_name(), 1, true) ~= nil
end

---Create the per-project sandbox if missing (one-time per project;
---`sbx exec` starts stopped sandboxes but errors on missing ones).
---@return boolean ok, string? err
function M.ensure_sandbox()
  if custom_prefix() then
    return true -- custom wrappers manage their own lifecycle
  end
  if M.sandbox_exists() then
    return true
  end
  vim.notify("neo-review agent: creating sbx sandbox " .. M.sandbox_name() .. " (first use in this project)…")
  local res = vim.system({ "sbx", "run", "--detached", "claude" }, { cwd = session.root, text = true }):wait()
  if res.code ~= 0 then
    return false, "sbx run --detached failed: " .. vim.trim((res.stderr or "") .. (res.stdout or "")):sub(1, 200)
  end
  return true
end

---argv prefix replacing the bare "claude" binary. The transport appends the
---stream-json flags after the trailing "claude".
---@return string[]
function M.argv_prefix()
  local custom = custom_prefix()
  if custom then
    return vim.deepcopy(custom)
  end
  return { "sbx", "exec", "-i", M.sandbox_name(), "claude" }
end

function M.status_lines()
  local ok, reason = M.preflight()
  local lines = {
    "sbx:       " .. (vim.fn.executable("sbx") == 1 and "found" or "MISSING (brew trust docker/tap && brew install docker/tap/sbx)"),
  }
  if not ok then
    lines[#lines + 1] = "status:    NOT READY — " .. (reason or "?")
  elseif custom_prefix() then
    lines[#lines + 1] = "wrapper:   custom argv_prefix: " .. table.concat(custom_prefix(), " ")
  else
    lines[#lines + 1] = "sandbox:   " .. M.sandbox_name() .. (M.sandbox_exists() and " (exists)" or " (created on first agent start)")
    lines[#lines + 1] = "egress:    sbx name-based policy — `sbx policy log` / `sbx policy allow network <host>`"
    lines[#lines + 1] = "creds:     sbx proxy-injection — `sbx secret` (never enter the VM)"
  end
  return lines
end

return M
