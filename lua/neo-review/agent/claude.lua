-- Claude Code transport: one long-lived `claude -p --input-format stream-json`
-- process per Neovim instance, controlled over stdin/stdout NDJSON.
--
-- WIRE PROTOCOL (verified empirically against claude 2.1.234, 2026-08-17 —
-- officially undocumented; the Agent SDK is the supported façade over it.
-- If a CLI update breaks this, :checkhealth neo-review reports here):
--   stdin  → {"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]}}
--   stdin  → {"type":"control_response","response":{"subtype":"success",
--             "request_id":…,"response":{"behavior":"allow","updatedInput":…}}}
--            (or behavior:"deny" with "message")
--   stdin  → {"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}
--   stdout → {"type":"system","subtype":"init","session_id":…,"model":…}
--   stdout → {"type":"assistant","message":{content blocks incl. tool_use}}
--   stdout → {"type":"control_request","request_id":…,"request":{"subtype":"can_use_tool",
--             "tool_name":…,"input":…,"permission_suggestions":…,"tool_use_id":…}}
--   stdout → {"type":"result","subtype":"success","session_id":…,"result":…,
--             "total_cost_usd":…,"permission_denials":[…]}  (one per turn)
--
-- Billing: spawning the `claude` binary inherits its subscription login.
-- ANTHROPIC_API_KEY is scrubbed from the child env because headless mode
-- silently prefers it over subscription OAuth (API-rate charges).
local M = {}

---@class review.AgentTransport
---@field proc vim.SystemObj?
---@field state "stopped"|"starting"|"idle"|"working"
---@field session_id string?
---@field queue string[] queued prompts while a turn is in flight
---@field handlers table

local T = {
  proc = nil,
  state = "stopped",
  session_id = nil,
  queue = {},
  handlers = {},
  inflight = false,
  _reqn = 0,
}
M._t = T

local function scrub_env()
  local env = {}
  for k, v in pairs(vim.uv.os_environ()) do
    if k ~= "ANTHROPIC_API_KEY" and k ~= "CLAUDE_CODE_ENTRYPOINT" and k ~= "CLAUDECODE" then
      env[k] = v
    end
  end
  return env
end

local function emit(name, ...)
  if T.handlers[name] then
    T.handlers[name](...)
  end
end

local function writeln(obj)
  if T.proc then
    T.proc:write(vim.json.encode(obj) .. "\n")
  end
end

local function set_state(s)
  if T.state ~= s then
    T.state = s
    emit("state", s)
  end
end

local function send_user_turn(text)
  writeln({
    type = "user",
    message = { role = "user", content = { { type = "text", text = text } } },
  })
  T.inflight = true
  set_state("working")
end

local function on_event(ev)
  local t = ev.type
  if t == "system" and ev.subtype == "init" then
    T.session_id = ev.session_id
    -- NOTE: the CLI emits init only AFTER receiving its first stdin line, so
    -- a turn is usually already in flight by the time init arrives — don't
    -- clobber the working state.
    if not T.inflight then
      set_state("idle")
    end
    emit("init", ev)
  elseif t == "control_request" then
    local req = ev.request or {}
    if req.subtype == "can_use_tool" then
      emit("permission", {
        request_id = ev.request_id,
        tool_name = req.tool_name,
        display_name = req.display_name or req.tool_name,
        input = req.input,
        description = req.description,
        suggestions = req.permission_suggestions,
      })
    end
  elseif t == "assistant" then
    emit("assistant", ev)
  elseif t == "result" then
    T.inflight = false
    T.session_id = ev.session_id or T.session_id
    emit("result", ev)
    if #T.queue > 0 then
      send_user_turn(table.remove(T.queue, 1))
    else
      set_state("idle")
    end
  end
  emit("event", ev)
end

---@param opts { cwd: string, cmd: string?, argv_prefix: string[]?, model: string?, resume: string?, permission_mode: string?, handlers: table }
---@return boolean ok, string? err
function M.start(opts)
  if T.proc then
    return false, "already running"
  end
  -- argv_prefix replaces the bare binary (e.g. a `docker run -i … image
  -- claude` prefix from the sandbox); stream-json rides stdio either way.
  local cmd = vim.deepcopy(opts.argv_prefix or { opts.cmd or "claude" })
  vim.list_extend(cmd, { "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio" })
  if opts.model then
    vim.list_extend(cmd, { "--model", opts.model })
  end
  if opts.permission_mode then
    vim.list_extend(cmd, { "--permission-mode", opts.permission_mode })
  end
  if opts.resume then
    vim.list_extend(cmd, { "--resume", opts.resume })
  end

  T.handlers = opts.handlers or {}
  T.queue = {}
  T.session_id = nil

  local stdout_buf = ""
  local ok, proc = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    env = scrub_env(),
    stdin = true,
    stdout = function(_, data)
      if not data then
        return
      end
      stdout_buf = stdout_buf .. data
      while true do
        local nl = stdout_buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = stdout_buf:sub(1, nl - 1)
        stdout_buf = stdout_buf:sub(nl + 1)
        local decoded_ok, ev = pcall(vim.json.decode, line)
        if decoded_ok and type(ev) == "table" then
          vim.schedule(function()
            on_event(ev)
          end)
        end
      end
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        vim.schedule(function()
          emit("stderr", data)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      T.proc = nil
      set_state("stopped")
      emit("exit", res.code)
    end)
  end)
  if not ok then
    return false, "failed to spawn " .. (opts.cmd or "claude") .. ": " .. tostring(proc)
  end
  T.proc = proc
  set_state("starting")
  return true
end

---Send a user turn. Written immediately unless a turn is already in flight
---(the CLI accepts — indeed requires — stdin before it emits init).
function M.send(text)
  if not T.proc then
    return false, "agent not running"
  end
  if T.inflight then
    T.queue[#T.queue + 1] = text
  else
    send_user_turn(text)
  end
  return true
end

---Answer a permission request.
---@param request_id string
---@param allow boolean
---@param input table? original tool input (echoed back on allow)
---@param message string? denial reason
function M.respond_permission(request_id, allow, input, message)
  local response
  if allow then
    response = { behavior = "allow", updatedInput = input or vim.empty_dict() }
  else
    response = { behavior = "deny", message = message or "denied by user in Neovim" }
  end
  writeln({
    type = "control_response",
    response = { subtype = "success", request_id = request_id, response = response },
  })
end

---Interrupt the in-flight turn.
function M.interrupt()
  T._reqn = T._reqn + 1
  writeln({
    type = "control_request",
    request_id = "nvim-" .. T._reqn,
    request = { subtype = "interrupt" },
  })
end

function M.stop()
  if T.proc then
    T.proc:kill(15)
  end
end

function M.status()
  return { state = T.state, session_id = T.session_id, queued = #T.queue }
end

return M
