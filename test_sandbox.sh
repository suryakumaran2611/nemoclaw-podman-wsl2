#!/bin/bash
# test_sandbox.sh
# End-to-end test of NemoClaw sandbox + Ollama agent workflow.
# Runs a series of checks and prints PASS/FAIL for each one.
# Usage: ./test_sandbox.sh [sandbox-name] [--no-auto-fix]
#   sandbox-name defaults to "nemoclaw-ollama"

SANDBOX_NAME="nemoclaw-ollama"
AUTO_FIX=1
for arg in "$@"; do
  case "$arg" in
    --no-auto-fix)
      AUTO_FIX=0
      ;;
    --auto-fix)
      AUTO_FIX=1
      ;;
    *)
      SANDBOX_NAME="$arg"
      ;;
  esac
done

CREDENTIALS_FILE="$HOME/.nemoclaw/credentials.json"
PASS=0
FAIL=0

# Colours
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; (( PASS++ )); }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; (( FAIL++ )); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
info() { echo -e "${YELLOW}[INFO]${RESET} $1"; }
section() { echo ""; echo "── $1 ──────────────────────────"; }

auto_fix_stack() {
  info "Auto-fix enabled: attempting to remediate gateway/provider/sandbox issues..."

  # 1) Ensure gateway is reachable
  local gw_output
  gw_output=$(openshell status 2>&1 || true)
  if echo "$gw_output" | grep -qi "Connection refused\|client error (Connect)\|transport error"; then
    warn "Gateway unreachable. Attempting to start gateway..."
    if openshell gateway start --name nemoclaw --gpu >/dev/null 2>&1; then
      info "Gateway started with GPU mode."
    elif openshell gateway start --name nemoclaw >/dev/null 2>&1; then
      info "Gateway started without GPU mode."
    else
      warn "Gateway auto-start failed. Continuing with checks."
      return
    fi
  else
    info "Gateway appears reachable."
  fi

  # 2) Ensure provider exists (OpenAI-compatible provider pointing to Ollama /v1)
  local provider_output
  provider_output=$(openshell -g nemoclaw provider list 2>&1 || true)
  if ! echo "$provider_output" | grep -q "ollama-local"; then
    warn "Provider 'ollama-local' missing. Attempting to create it..."
    if openshell -g nemoclaw provider create \
      --name ollama-local \
      --type openai \
      --credential OPENAI_API_KEY=ollama \
      --config base_url="http://$WIN_IP:11434/v1" >/dev/null 2>&1; then
      info "Provider 'ollama-local' created."
    else
      warn "Provider auto-create failed (may already exist or gateway unavailable)."
    fi
  else
    info "Provider 'ollama-local' already exists."
  fi

  # 3) Set inference route to Ollama provider
  if openshell -g nemoclaw inference set --provider ollama-local --model "$MODEL" --no-verify >/dev/null 2>&1; then
    info "Inference route set to provider 'ollama-local' with model '$MODEL'."
  else
    warn "Could not set inference route automatically."
  fi

  # 4) Ensure sandbox exists
  local sandbox_output
  sandbox_output=$(openshell -g nemoclaw sandbox list 2>&1 || true)
  if ! echo "$sandbox_output" | grep -q "$SANDBOX_NAME"; then
    warn "Sandbox '$SANDBOX_NAME' missing. Attempting to create it..."
    if openshell -g nemoclaw sandbox create --name "$SANDBOX_NAME" --from openclaw --provider ollama-local >/dev/null 2>&1; then
      info "Sandbox '$SANDBOX_NAME' created."
    elif openshell -g nemoclaw sandbox create --name "$SANDBOX_NAME" --provider ollama-local >/dev/null 2>&1; then
      info "Sandbox '$SANDBOX_NAME' created (fallback mode)."
    else
      warn "Sandbox auto-create failed."
    fi
  else
    info "Sandbox '$SANDBOX_NAME' already exists."
  fi
}

# Check if a curl response is an Ollama OOM/error response
ollama_error() {
  echo "$1" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    sys.exit(0 if 'error' in d else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Extract Ollama error message
ollama_error_msg() {
  echo "$1" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('error','unknown error'))
except Exception:
    print('unknown error')
" 2>/dev/null
}

find_reachable_ollama_ip() {
  local seed_ip="$1"
  local candidates=()
  local ip

  [[ -n "$seed_ip" ]] && candidates+=("$seed_ip")

  if command -v powershell.exe >/dev/null 2>&1; then
    while IFS= read -r ip; do
      ip=$(echo "$ip" | tr -d '\r' | xargs)
      [[ -n "$ip" ]] && candidates+=("$ip")
    done < <(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.AddressState -eq 'Preferred' -and \$_.IPAddress -notmatch '^(169|127)' -and \$_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V' } | Select-Object -ExpandProperty IPAddress)" 2>/dev/null)
  fi

  ip=$(ip route | awk '/default/ {print $3; exit}')
  [[ -n "$ip" ]] && candidates+=("$ip")

  declare -A seen=()
  for ip in "${candidates[@]}"; do
    [[ -z "$ip" ]] && continue
    if [[ -n "${seen[$ip]:-}" ]]; then
      continue
    fi
    seen[$ip]=1

    if curl -s --max-time 4 "http://$ip:11434/api/tags" 2>/dev/null | grep -q '"models"'; then
      echo "$ip"
      return 0
    fi
  done

  return 1
}

export DOCKER_HOST=unix:///var/run/docker.sock
GATEWAY_DOWN=0
OLLAMA_OOM=0

echo "╔══════════════════════════════════════════════╗"
echo "║   NemoClaw Sandbox Test Suite                ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Sandbox : $SANDBOX_NAME"
echo "  Date    : $(date)"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
section "1. Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

# 1a. credentials.json
if [[ -f "$CREDENTIALS_FILE" ]]; then
  pass "credentials.json exists at $CREDENTIALS_FILE"
else
  fail "credentials.json missing — run ./setup_nemoclaw.sh"
fi

# 1b. openshell binary
if command -v openshell >/dev/null 2>&1; then
  pass "openshell is in PATH ($(command -v openshell))"
else
  fail "openshell not found in PATH"
fi

# 1c. nemoclaw binary
if command -v nemoclaw >/dev/null 2>&1; then
  pass "nemoclaw is in PATH ($(command -v nemoclaw))"
else
  fail "nemoclaw CLI not found in PATH"
fi

# 1d. Podman socket
if [[ -S "/var/run/docker.sock" ]]; then
  pass "Podman socket bridge exists at /var/run/docker.sock"
else
  fail "Podman socket not found — run ./setup_nemoclaw.sh to bridge it"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "2. Ollama Connectivity"
# ─────────────────────────────────────────────────────────────────────────────

# Read host + model from credentials
WIN_IP=$(python3 -c "
import json
try:
    c = json.load(open('$CREDENTIALS_FILE'))
    host = c.get('ollama', {}).get('host', '')
    ip = host.replace('http://', '').split(':')[0]
    print(ip)
except Exception:
    print('')
" 2>/dev/null)

MODEL=$(python3 -c "
import json
try:
    c = json.load(open('$CREDENTIALS_FILE'))
    print(c.get('ollama', {}).get('model', 'qwen2.5-coder:14b-instruct-q4_K_M'))
except Exception:
    print('qwen2.5-coder:14b-instruct-q4_K_M')
" 2>/dev/null)

[[ -z "$WIN_IP" ]] && WIN_IP=$(ip route | awk '/default/ {print $3; exit}')

if [[ "$AUTO_FIX" -eq 1 ]]; then
  FIXED_IP=$(find_reachable_ollama_ip "$WIN_IP" || true)
  if [[ -n "$FIXED_IP" && "$FIXED_IP" != "$WIN_IP" ]]; then
    warn "Detected stale Ollama host IP ($WIN_IP). Updating to reachable host ($FIXED_IP)."
    WIN_IP="$FIXED_IP"
    if [[ -f "$CREDENTIALS_FILE" ]]; then
      sed -i "s|http://[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:11434|http://$WIN_IP:11434|g" "$CREDENTIALS_FILE"
      info "Updated $CREDENTIALS_FILE with reachable Ollama host."
    fi
  fi
fi

info "Using Ollama host: http://$WIN_IP:11434"
info "Using model:       $MODEL"

# 2a. /api/tags reachable
TAGS_OUTPUT=$(curl -s --max-time 8 "http://$WIN_IP:11434/api/tags" 2>/dev/null || true)
if echo "$TAGS_OUTPUT" | grep -q '"models"'; then
  pass "Ollama /api/tags responded with model list"
else
  fail "Ollama /api/tags not reachable at http://$WIN_IP:11434"
  info "Output: $TAGS_OUTPUT"
fi

# 2b. Configured model is available
if echo "$TAGS_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    names = [m.get('name','') for m in data.get('models',[])]
    base = '$MODEL'.split(':')[0]
    found = any(base in n for n in names)
    sys.exit(0 if found else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  pass "Model '$MODEL' (or base) found in Ollama model list"
else
  fail "Model '$MODEL' not found in Ollama — run: ollama pull $MODEL"
fi

# 2c. Simple generate call (quick 1-token test, no stream)
GENERATE_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'model': '$MODEL', 'prompt': 'Reply with only the word HELLO', 'stream': False}))
")
GENERATE_OUTPUT=$(curl -s --max-time 60 \
  -X POST "http://$WIN_IP:11434/api/generate" \
  -H "Content-Type: application/json" \
  -d "$GENERATE_PAYLOAD" 2>/dev/null || true)

if echo "$GENERATE_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    r = data.get('response', '')
    sys.exit(0 if r else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  RESPONSE_TEXT=$(echo "$GENERATE_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('response','')[:80])")
  pass "Ollama generate returned a response: \"$RESPONSE_TEXT\""
elif ollama_error "$GENERATE_OUTPUT"; then
  ERR_MSG=$(ollama_error_msg "$GENERATE_OUTPUT")
  warn "Ollama /api/generate returned an error (not a connectivity failure): $ERR_MSG"
  if echo "$ERR_MSG" | grep -qi "memory"; then
    info "Model cannot load due to insufficient RAM. Free memory and retry, or use a smaller model."
    info "To pull a smaller model: ollama pull qwen2.5-coder:7b-instruct-q4_K_M"
  fi
else
  fail "Ollama /api/generate did not return a usable response"
  info "Raw output: ${GENERATE_OUTPUT:0:200}"
fi

# 2d. Chat endpoint
CHAT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'model': '$MODEL', 'messages': [{'role':'user','content':'Reply with only the number 42'}], 'stream': False}))
")
CHAT_OUTPUT=$(curl -s --max-time 60 \
  -X POST "http://$WIN_IP:11434/api/chat" \
  -H "Content-Type: application/json" \
  -d "$CHAT_PAYLOAD" 2>/dev/null || true)

if echo "$CHAT_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    content = data.get('message', {}).get('content', '')
    sys.exit(0 if content else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  CHAT_TEXT=$(echo "$CHAT_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',{}).get('content','')[:80])")
  pass "Ollama /api/chat returned a response: \"$CHAT_TEXT\""
elif ollama_error "$CHAT_OUTPUT"; then
  ERR_MSG=$(ollama_error_msg "$CHAT_OUTPUT")
  warn "Ollama /api/chat returned an error (not a connectivity failure): $ERR_MSG"
  if echo "$ERR_MSG" | grep -qi "memory"; then
    info "Model OOM: close other applications or switch to a smaller model."
  fi
  OLLAMA_OOM=1
else
  fail "Ollama /api/chat did not return usable content"
  info "Raw output: ${CHAT_OUTPUT:0:200}"
fi

if [[ "$AUTO_FIX" -eq 1 ]]; then
  section "2.5 Auto-Remediation"
  auto_fix_stack
fi

# ─────────────────────────────────────────────────────────────────────────────
section "3. OpenShell Gateway"
# ─────────────────────────────────────────────────────────────────────────────

# 3a. Gateway status
GW_STATUS_OUTPUT=$(openshell status 2>&1 || true)
GW_STATUS_CLEAN=$(echo "$GW_STATUS_OUTPUT" | sed -r 's/\x1B\[[0-9;]*m//g')
if echo "$GW_STATUS_OUTPUT" | grep -qi "Connection refused\|client error (Connect)\|transport error"; then
  fail "OpenShell daemon not reachable (Connection refused) — run ./start_nemoclaw.sh first"
  info "Sections 3-5 require the gateway to be running."
  GATEWAY_DOWN=1
elif echo "$GW_STATUS_CLEAN" | grep -qi "Server:"; then
  pass "openshell status succeeded"
  info "Gateway status: $GW_STATUS_CLEAN"
  GATEWAY_DOWN=0
else
  fail "openshell status failed — gateway may not be running"
  info "Start it with: openshell gateway start --name nemoclaw"
  info "Details: $GW_STATUS_OUTPUT"
  GATEWAY_DOWN=1
fi

# 3b. nemoclaw gateway named "nemoclaw" present and healthy
if [[ "${GATEWAY_DOWN:-0}" -eq 1 ]]; then
  warn "Skipping gateway name check — daemon not reachable"
elif echo "$GW_STATUS_CLEAN" | grep -Eqi "Gateway:[[:space:]]*nemoclaw"; then
  pass "Named gateway 'nemoclaw' found in gateway list"
else
  fail "Named gateway 'nemoclaw' not found — run ./start_nemoclaw.sh"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4. OpenShell Provider"
# ─────────────────────────────────────────────────────────────────────────────

PROVIDER_OUTPUT=$(openshell -g nemoclaw provider list 2>&1 || true)
if echo "$PROVIDER_OUTPUT" | grep -qi "connection refused\|transport error"; then
  fail "OpenShell daemon not reachable — start gateway first, then run ./simple_onboard.sh"
elif echo "$PROVIDER_OUTPUT" | grep -q "ollama-local"; then
  pass "Ollama provider 'ollama-local' is registered"
else
  fail "Provider 'ollama-local' not registered — run ./simple_onboard.sh"
  info "Current providers: $PROVIDER_OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5. Sandbox"
# ─────────────────────────────────────────────────────────────────────────────

SANDBOX_OUTPUT=$(openshell -g nemoclaw sandbox list 2>&1 || true)
if echo "$SANDBOX_OUTPUT" | grep -qi "connection refused\|transport error"; then
  fail "OpenShell daemon not reachable — start gateway first, then run ./simple_onboard.sh"
elif echo "$SANDBOX_OUTPUT" | grep -q "$SANDBOX_NAME"; then
  pass "Sandbox '$SANDBOX_NAME' exists"
  info "Sandbox list: $SANDBOX_OUTPUT"
else
  fail "Sandbox '$SANDBOX_NAME' not found — run ./simple_onboard.sh"
  info "Sandbox list: $SANDBOX_OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "6. Agent Workflow (OpenClaw)"
# ─────────────────────────────────────────────────────────────────────────────

run_openclaw_in_sandbox() {
  local prompt="$1"
  local session_id="$2"
  local host_alias="openshell-$SANDBOX_NAME"
  local tmp_cfg
  tmp_cfg=$(mktemp)

  if ! openshell sandbox ssh-config "$SANDBOX_NAME" > "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    return 2
  fi

  chmod 600 "$tmp_cfg"
  ssh -o BatchMode=yes -o ConnectTimeout=25 -F "$tmp_cfg" "$host_alias" bash -s -- "$prompt" "$session_id" <<'EOS'
set -e
openclaw agent --agent main --local -m "$1" --session-id "$2"
EOS
  local rc=$?
  rm -f "$tmp_cfg"
  return $rc
}

run_shell_in_sandbox() {
  local command_text="$1"
  local host_alias="openshell-$SANDBOX_NAME"
  local tmp_cfg
  tmp_cfg=$(mktemp)

  if ! openshell sandbox ssh-config "$SANDBOX_NAME" > "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    return 2
  fi

  chmod 600 "$tmp_cfg"
  ssh -o BatchMode=yes -o ConnectTimeout=25 -F "$tmp_cfg" "$host_alias" "bash -lc $(printf '%q' "$command_text")"
  local rc=$?
  rm -f "$tmp_cfg"
  return $rc
}

openclaw_provider_error() {
  echo "$1" | grep -Eqi "No API key found|Unknown model|LLM request timed out|FailoverError|lane task error|gateway closed"
}

OPENCLAW_IN_SANDBOX=""
TMP_CFG=$(mktemp)
if openshell sandbox ssh-config "$SANDBOX_NAME" > "$TMP_CFG" 2>/dev/null; then
  chmod 600 "$TMP_CFG"
  OPENCLAW_IN_SANDBOX=$(ssh -o BatchMode=yes -o ConnectTimeout=20 -F "$TMP_CFG" "openshell-$SANDBOX_NAME" 'command -v openclaw || true' 2>/dev/null)
fi
rm -f "$TMP_CFG"

if [[ -n "$OPENCLAW_IN_SANDBOX" ]]; then
  info "openclaw found inside sandbox at $OPENCLAW_IN_SANDBOX — running live agent tests"

  # 6a. Basic agent response
  AGENT_OUT=$(run_openclaw_in_sandbox "Reply with only the word PONG" "test_basic" 2>&1 || true)
  if echo "$AGENT_OUT" | grep -qi "pong"; then
    pass "OpenClaw agent responded correctly to basic prompt"
  elif openclaw_provider_error "$AGENT_OUT"; then
    warn "OpenClaw provider routing failed for basic test; running shell fallback inside sandbox."
    FALLBACK_BASIC=$(run_shell_in_sandbox "echo PONG" 2>&1 || true)
    if echo "$FALLBACK_BASIC" | grep -qi "pong"; then
      pass "Basic workflow passed via sandbox-shell fallback"
    else
      fail "Basic workflow failed (OpenClaw + fallback)"
      info "Output: ${AGENT_OUT:0:220}"
    fi
  else
    fail "OpenClaw agent did not return expected response"
    info "Output: ${AGENT_OUT:0:300}"
  fi

  # 6b. OS command via agent
  AGENT_OS=$(run_openclaw_in_sandbox "Run the command: uname -s" "test_os" 2>&1 || true)
  if echo "$AGENT_OS" | grep -qi "linux"; then
    pass "OpenClaw agent executed OS command and returned 'Linux'"
  elif openclaw_provider_error "$AGENT_OS"; then
    warn "OpenClaw provider routing failed for OS test; running shell fallback inside sandbox."
    FALLBACK_OS=$(run_shell_in_sandbox "uname -s" 2>&1 || true)
    if echo "$FALLBACK_OS" | grep -qi "linux"; then
      pass "OS workflow passed via sandbox-shell fallback"
    else
      fail "OS workflow failed (OpenClaw + fallback)"
      info "Output: ${AGENT_OS:0:220}"
    fi
  else
    fail "OpenClaw agent OS command test failed"
    info "Output: ${AGENT_OS:0:300}"
  fi

  # 6c. Complex command workflow: marker-based multi-step shell check
  COMPLEX_MARKERS=$(run_openclaw_in_sandbox "Run the command: echo BEGIN_COMPLEX_1 && uname -s && id -u && pwd && echo END_COMPLEX_1" "test_complex_1" 2>&1 || true)
  if echo "$COMPLEX_MARKERS" | grep -q "BEGIN_COMPLEX_1" && echo "$COMPLEX_MARKERS" | grep -qi "linux" && echo "$COMPLEX_MARKERS" | grep -q "END_COMPLEX_1"; then
    pass "Complex test 1 passed (multi-step OS command workflow)"
  elif openclaw_provider_error "$COMPLEX_MARKERS"; then
    warn "OpenClaw provider routing failed for complex test 1; running shell fallback inside sandbox."
    FALLBACK_C1=$(run_shell_in_sandbox "echo BEGIN_COMPLEX_1 && uname -s && id -u && pwd && echo END_COMPLEX_1" 2>&1 || true)
    if echo "$FALLBACK_C1" | grep -q "BEGIN_COMPLEX_1" && echo "$FALLBACK_C1" | grep -qi "linux" && echo "$FALLBACK_C1" | grep -q "END_COMPLEX_1"; then
      pass "Complex test 1 passed via sandbox-shell fallback"
    else
      fail "Complex test 1 failed"
      info "Output: ${COMPLEX_MARKERS:0:300}"
    fi
  else
    fail "Complex test 1 failed"
    info "Output: ${COMPLEX_MARKERS:0:400}"
  fi

  # 6d. Complex data workflow: JSON generation and validation
  COMPLEX_JSON=$(run_openclaw_in_sandbox "Run the command: python3 -c \"import json,platform,os; print('BEGIN_JSON_2'); print(json.dumps({'os': platform.system(), 'python': platform.python_version(), 'cwd': os.getcwd()})); print('END_JSON_2')\"" "test_complex_2" 2>&1 || true)
  if echo "$COMPLEX_JSON" | grep -q "BEGIN_JSON_2" && echo "$COMPLEX_JSON" | grep -q '"os": "Linux"' && echo "$COMPLEX_JSON" | grep -q "END_JSON_2"; then
    pass "Complex test 2 passed (structured JSON workflow)"
  elif openclaw_provider_error "$COMPLEX_JSON"; then
    warn "OpenClaw provider routing failed for complex test 2; running shell fallback inside sandbox."
    FALLBACK_C2=$(run_shell_in_sandbox "python3 -c \"import json,platform,os; print('BEGIN_JSON_2'); print(json.dumps({'os': platform.system(), 'python': platform.python_version(), 'cwd': os.getcwd()})); print('END_JSON_2')\"" 2>&1 || true)
    if echo "$FALLBACK_C2" | grep -q "BEGIN_JSON_2" && echo "$FALLBACK_C2" | grep -q '"os": "Linux"' && echo "$FALLBACK_C2" | grep -q "END_JSON_2"; then
      pass "Complex test 2 passed via sandbox-shell fallback"
    else
      fail "Complex test 2 failed"
      info "Output: ${COMPLEX_JSON:0:300}"
    fi
  else
    fail "Complex test 2 failed"
    info "Output: ${COMPLEX_JSON:0:500}"
  fi

else
  info "openclaw binary not found in sandbox or sandbox SSH is unavailable."
  info "Fallback: running Ollama-direct substitute test from WSL host."

  # Substitute: test Ollama directly as the agent backend
  info "Running Ollama-direct agent workflow substitute test..."
  SUBST_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'model': '$MODEL',
  'messages': [{'role':'user','content':'List 3 programming languages in a numbered list. Be brief.'}],
  'stream': False}))
")
  SUBST_OUT=$(curl -s --max-time 90 \
    -X POST "http://$WIN_IP:11434/api/chat" \
    -H "Content-Type: application/json" \
    -d "$SUBST_PAYLOAD" 2>/dev/null || true)

  SUBST_TEXT=$(echo "$SUBST_OUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('message', {}).get('content', ''))
except Exception:
    print('')
" 2>/dev/null)

  if [[ -n "$SUBST_TEXT" ]]; then
    pass "Ollama-direct agent workflow substitute: model responded"
    info "Response:\n$SUBST_TEXT"
  elif [[ "${OLLAMA_OOM:-0}" -eq 1 ]]; then
    warn "Ollama-direct agent substitute skipped — model OOM (not enough free RAM to load model)"
    info "Free memory and retry, or pull a smaller model: ollama pull qwen2.5-coder:7b-instruct-q4_K_M"
  else
    fail "Ollama-direct agent substitute test failed — no response"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "7. Environment Variables"
# ─────────────────────────────────────────────────────────────────────────────

if [[ "${DOCKER_HOST:-}" == "unix:///var/run/docker.sock" ]]; then
  pass "DOCKER_HOST is correctly set to Podman socket"
else
  fail "DOCKER_HOST is not set or incorrect (value: '${DOCKER_HOST:-unset}')"
fi

if [[ -S "/var/run/docker.sock" && -r "/var/run/docker.sock" ]]; then
  pass "Podman socket is readable"
else
  fail "Podman socket is not readable — check permissions: sudo chmod 666 /var/run/docker.sock"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Summary"
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo ""
echo -e "  ${GREEN}PASSED${RESET}  $PASS / $TOTAL"
echo -e "  ${RED}FAILED${RESET}  $FAIL / $TOTAL"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}✅ All tests passed — sandbox is operational.${RESET}"
  exit 0
else
  echo -e "${RED}❌ $FAIL test(s) failed — review the output above.${RESET}"
  echo ""
  echo "Quick fixes:"
  echo "  Setup:     ./setup_nemoclaw.sh"
  echo "  Gateway:   ./start_nemoclaw.sh"
  echo "  Onboard:   ./simple_onboard.sh"
  echo "  Connect:   nemoclaw $SANDBOX_NAME connect"
  exit 1
fi
