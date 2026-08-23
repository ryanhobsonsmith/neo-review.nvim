#!/usr/bin/env bash
# Offline stand-in for the claude CLI speaking just enough of the stream-json
# protocol (as documented in lua/review/agent/claude.lua) to test the
# transport: init -> user turn -> permission round-trip -> result -> second
# turn -> result. Ignores its arguments.

emit() { printf '%s\n' "$1"; }

emit '{"type":"system","subtype":"init","session_id":"fake-session-1234","model":"fake-model"}'

read -r _turn1 || exit 0
emit '{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"x.txt","content":"hi"},"description":"x.txt"}}'

read -r resp || exit 0
case "$resp" in
  *'"behavior":"allow"'*)
    emit '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
    emit '{"type":"result","subtype":"success","session_id":"fake-session-1234","result":"done","total_cost_usd":0.01,"permission_denials":[]}'
    ;;
  *)
    emit '{"type":"result","subtype":"success","session_id":"fake-session-1234","result":"denied","permission_denials":[{"tool_name":"Write"}]}'
    ;;
esac

read -r _turn2 || exit 0
emit '{"type":"result","subtype":"success","session_id":"fake-session-1234","result":"second","total_cost_usd":0.01,"permission_denials":[]}'

# stay alive until stdin closes
while read -r _; do :; done
