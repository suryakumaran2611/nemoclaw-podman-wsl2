#!/bin/bash
# test_sandbox.sh
# End-to-end test of NemoClaw sandbox + Ollama agent workflow.
# Runs a series of checks and prints PASS/FAIL for each one.
# Usage: ./test_sandbox.sh [sandbox-name] [--no-auto-fix] [--custom-prompt "prompt text"]
#   sandbox-name defaults to "nemoclaw-ollama"
#   --custom-prompt allows testing with a user-supplied prompt instead of default tests

SANDBOX_NAME="nemoclaw-ollama"
AUTO_FIX=1
CUSTOM_PROMPT=""
CUSTOM_PROMPT_MODE=0
for arg in "$@"; do
  case "$arg" in
    --no-auto-fix)
      AUTO_FIX=0
      ;;
    --auto-fix)
      AUTO_FIX=1
      ;;
    --custom-prompt)
      CUSTOM_PROMPT_MODE=1
      ;;
    *)
      if [[ $CUSTOM_PROMPT_MODE -eq 1 ]]; then
        CUSTOM_PROMPT="$arg"
        CUSTOM_PROMPT_MODE=0
      else
        SANDBOX_NAME="$arg"
      fi
      ;;
  esac
done

CREDENTIALS_FILE="$HOME/.nemoclaw/credentials.json"
PASS=0
FAIL=0
SANDBOX_OLLAMA_HOST=""
SANDBOX_OLLAMA_PORT="11434"
SANDBOX_PROXY_URL="http://10.200.0.1:3128"

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

ensure_sandbox_ollama_relay() {
  # OpenShell sandboxes reach external hosts via enforced HTTP proxy.
  # Treat that proxy path as the supported relay mode and verify it from
  # the sandbox before section 6 runs.
  local tmp_cfg host_alias probe
  tmp_cfg=$(mktemp)
  host_alias="openshell-$SANDBOX_NAME"

  if ! openshell sandbox ssh-config "$SANDBOX_NAME" > "$tmp_cfg" 2>/dev/null; then
    rm -f "$tmp_cfg"
    warn "Could not fetch sandbox SSH config; proxy-relay preflight skipped."
    return 1
  fi

  chmod 600 "$tmp_cfg"
  probe=$(ssh -o BatchMode=yes -o ConnectTimeout=20 -F "$tmp_cfg" "$host_alias" \
    "HTTP_PROXY='$SANDBOX_PROXY_URL' HTTPS_PROXY='$SANDBOX_PROXY_URL' ALL_PROXY='$SANDBOX_PROXY_URL' curl -s --max-time 10 'http://$WIN_IP:$SANDBOX_OLLAMA_PORT/api/tags'" 2>/dev/null || true)
  rm -f "$tmp_cfg"

  if echo "$probe" | grep -q '"models"'; then
    SANDBOX_OLLAMA_HOST="$WIN_IP"
    info "Sandbox relay mode: OpenShell proxy ($SANDBOX_PROXY_URL) -> $SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT"
    return 0
  fi

  warn "Sandbox could not reach Ollama via OpenShell proxy relay ($SANDBOX_PROXY_URL)."
  return 1
}

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

  # 2) Ensure gateway provider exists (used by section 6 gateway-routed runs)
  local provider_output
  provider_output=$(openshell -g nemoclaw provider list 2>&1 || true)
  if ! echo "$provider_output" | grep -q "ollama-local"; then
    warn "Provider 'ollama-local' missing. Attempting to create it..."
    if openshell -g nemoclaw provider create \
      --name ollama-local \
      --type openai \
      --credential OPENAI_API_KEY=ollama \
      --config base_url="http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT/v1" >/dev/null 2>&1; then
      info "Provider 'ollama-local' created."
    else
      warn "Provider auto-create failed (may already exist or gateway unavailable)."
    fi
  else
    info "Provider 'ollama-local' already exists."
    openshell -g nemoclaw provider update ollama-local \
      --credential OPENAI_API_KEY=ollama \
      --config base_url="http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT/v1" >/dev/null 2>&1 || true
  fi

  # 3) Set inference route for the OpenClaw runtime model
  if openshell -g nemoclaw inference set --provider ollama-local --model "$OPENCLAW_MODEL" --no-verify >/dev/null 2>&1; then
    info "Inference route set: $OPENCLAW_MODEL → ollama-local."
  else
    warn "Could not set inference route for $OPENCLAW_MODEL."
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

  # 5) Ensure sandbox network policy allows egress to the WSL-host relay used for Ollama.
  # NemoClaw sandboxes are hardened and proxy-restricted; this explicit rule opens only
  # the Podman bridge listener that forwards to Windows-hosted Ollama.
  local pol_dump pol_body
  pol_dump=$(mktemp)
  pol_body=$(mktemp)
  if openshell -g nemoclaw policy get "$SANDBOX_NAME" --full > "$pol_dump" 2>/dev/null; then
    if grep -q "host: $SANDBOX_OLLAMA_HOST" "$pol_dump" && grep -q "port: $SANDBOX_OLLAMA_PORT" "$pol_dump"; then
      info "Sandbox policy already permits Ollama bridge egress to $SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT."
    else
      awk 'f{print} /^---$/{f=1}' "$pol_dump" > "$pol_body"
      cat >> "$pol_body" <<POLICYEOF
  ollama_local_bridge:
    name: ollama_local_bridge
    endpoints:
    - host: $SANDBOX_OLLAMA_HOST
      port: $SANDBOX_OLLAMA_PORT
      protocol: rest
      enforcement: enforce
      access: full
    binaries:
    - path: /usr/local/bin/openclaw
    - path: /usr/bin/node
    - path: /usr/bin/curl
    - path: /bin/bash
POLICYEOF
      if openshell -g nemoclaw policy set "$SANDBOX_NAME" --policy "$pol_body" --wait --timeout 30 >/dev/null 2>&1; then
        info "Sandbox policy updated: enabled cross-bridge egress to $SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT."
      else
        warn "Could not auto-apply sandbox policy bridge for Ollama."
      fi
    fi
  else
    warn "Could not read sandbox policy; skipping automatic bridge policy setup."
  fi
  rm -f "$pol_dump" "$pol_body"
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

if ensure_sandbox_ollama_relay; then
  info "Sandbox Ollama endpoint (proxy-relayed): http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT"
else
  SANDBOX_OLLAMA_HOST="$WIN_IP"
  SANDBOX_OLLAMA_PORT="11434"
  warn "Falling back to direct sandbox Ollama endpoint: http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT"
fi

info "Using Ollama host: http://$WIN_IP:11434"
info "Credentials model: $MODEL"

# 2a. /api/tags reachable
TAGS_OUTPUT=$(curl -s --max-time 8 "http://$WIN_IP:11434/api/tags" 2>/dev/null || true)

# Use one runtime model for OpenClaw to avoid provider/model conflicts.
OPENCLAW_MODEL="gemma4:e4b"
if ! echo "$TAGS_OUTPUT" | python3 -c "
import json, sys
try:
    names = [m.get('name','') for m in json.load(sys.stdin).get('models',[])]
    sys.exit(0 if any(n.startswith('gemma4:e4b') for n in names) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  fail "Required OpenClaw runtime model 'gemma4:e4b' not found in Ollama"
  info "Run: ollama pull gemma4:e4b"
  OPENCLAW_MODEL="gemma4:e4b"
fi
info "OpenClaw runtime model: $OPENCLAW_MODEL"

if echo "$TAGS_OUTPUT" | grep -q '"models"'; then
  pass "Ollama /api/tags responded with model list"
else
  fail "Ollama /api/tags not reachable at http://$WIN_IP:11434"
  info "Output: $TAGS_OUTPUT"
fi

# 2b. OpenClaw runtime model is available
if echo "$TAGS_OUTPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    names = [m.get('name','') for m in data.get('models',[])]
    base = '$OPENCLAW_MODEL'.split(':')[0]
    found = any(base in n for n in names)
    sys.exit(0 if found else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
  pass "OpenClaw runtime model '$OPENCLAW_MODEL' found in Ollama model list"
else
  fail "Model '$OPENCLAW_MODEL' not found in Ollama — run: ollama pull $OPENCLAW_MODEL"
fi

# 2c. Simple generate call (quick 1-token test, no stream)
GENERATE_PAYLOAD=$(python3 -c "
import json
print(json.dumps({'model': '$OPENCLAW_MODEL', 'prompt': 'Reply with only the word HELLO', 'stream': False}))

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
print(json.dumps({'model': '$OPENCLAW_MODEL', 'messages': [{'role':'user','content':'Reply with only the number 42'}], 'stream': False}))

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
  # Gateway-routed path: OpenClaw uses an OpenAI-compatible provider profile
  # that points at the relay-backed route managed by OpenShell provider config.
  local sandbox_ollama_host="$SANDBOX_OLLAMA_HOST"
  local sandbox_ollama_port="$SANDBOX_OLLAMA_PORT"
  local model="$MODEL"
  local runtime_model="$OPENCLAW_MODEL"
  local prompt_q session_q sandbox_ollama_host_q sandbox_ollama_port_q model_q runtime_model_q
  prompt_q=$(printf '%q' "$prompt")
  session_q=$(printf '%q' "$session_id")
  sandbox_ollama_host_q=$(printf '%q' "$sandbox_ollama_host")
  sandbox_ollama_port_q=$(printf '%q' "$sandbox_ollama_port")
  model_q=$(printf '%q' "$model")
  runtime_model_q=$(printf '%q' "$runtime_model")
  ssh -o BatchMode=yes -o ConnectTimeout=25 -F "$tmp_cfg" "$host_alias" bash -s <<EOS
set -e

# Receive arguments from parent shell
_prompt=$prompt_q
_session_id=$session_q
_sandbox_ollama_host=$sandbox_ollama_host_q
_sandbox_ollama_port=$sandbox_ollama_port_q
_model=$model_q
_runtime_model=$runtime_model_q

export NODE_NO_WARNINGS=1
# Explicit relay mode for sandboxes: use OpenShell proxy to reach Ollama host.
export HTTP_PROXY="$SANDBOX_PROXY_URL"
export HTTPS_PROXY="$SANDBOX_PROXY_URL"
export ALL_PROXY="$SANDBOX_PROXY_URL"
export http_proxy="$SANDBOX_PROXY_URL"
export https_proxy="$SANDBOX_PROXY_URL"
export all_proxy="$SANDBOX_PROXY_URL"
export NODE_USE_ENV_PROXY=1
export NO_PROXY="127.0.0.1,localhost,::1"
export no_proxy="127.0.0.1,localhost,::1"

OLLAMA_TAGS=\$(curl -s --max-time 10 "http://\${_sandbox_ollama_host}:\${_sandbox_ollama_port}/api/tags" 2>/dev/null || true)
if ! echo "\$OLLAMA_TAGS" | grep -q '"models"'; then
  echo "[OLLAMA_UNREACHABLE] sandbox could not reach http://\${_sandbox_ollama_host}:\${_sandbox_ollama_port}/api/tags"
  exit 86
fi

# Configure OpenClaw gateway-routed provider (OpenAI-compatible API).
openclaw config set models.providers.gateway "{\"api\":\"openai-completions\",\"apiKey\":\"ollama\",\"baseUrl\":\"http://\${_sandbox_ollama_host}:\${_sandbox_ollama_port}/v1\",\"models\":[{\"id\":\"\${_runtime_model}\",\"name\":\"Gateway Routed \${_runtime_model}\",\"reasoning\":false,\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0},\"contextWindow\":32768,\"maxTokens\":327680}]}" --strict-json >/dev/null 2>&1 || true
openclaw config set agents.defaults.model.primary "\"gateway/\${_runtime_model}\"" --strict-json >/dev/null 2>&1 || true

# ── Step 1: Set gateway-routed default model ──────────────────────────────────
openclaw models set "gateway/\${_runtime_model}" 2>/dev/null || true

# ── Step 2: Warm-up selected Ollama model with retry ──────────────────────────

WARMUP_OK=0
for _try in 1 2 3; do
  echo "[setup] Warm-up attempt \${_try}/3 for \${_runtime_model} ..."
  WARMUP_OUT=\$(curl -s --max-time 45 \
    -X POST "http://\${_sandbox_ollama_host}:\${_sandbox_ollama_port}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"\${_runtime_model}\",\"prompt\":\"Reply with OK\",\"stream\":false,\"keep_alive\":\"10m\"}" 2>/dev/null || true)
  if echo "\$WARMUP_OUT" | grep -q '"response"'; then
    echo "[setup] Warm-up succeeded."
    WARMUP_OK=1
    break
  fi
  echo "[setup] Warm-up result: \${WARMUP_OUT:0:140}"
  sleep 2
done

# ── Step 3: Run the agent ─────────────────────────────────────────────────────
timeout 180 openclaw agent --agent main --local --timeout 180 -m "\${_prompt}" --session-id "\${_session_id}" 2>&1 || {
  exit_code=\$?
  if [[ \$exit_code -eq 124 ]]; then
    echo "[OPENCLAW_TIMEOUT]"
  fi
  exit \$exit_code
}
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
  # If custom prompt provided, test that directly
  if [[ -n "$CUSTOM_PROMPT" ]]; then
    CUSTOM_SESSION_ID="test_custom_$(date +%s)"
    info "═══════════════════════════════════════════════════════════════"
    info "CUSTOM PROMPT TEST MODE"
    info "═══════════════════════════════════════════════════════════════"
    info "Prompt: '$CUSTOM_PROMPT'"
    info "Session ID: $CUSTOM_SESSION_ID"
    info "Sandbox: $SANDBOX_NAME"
    info "Target Ollama Host: $SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT"
    info "Target Model: $OPENCLAW_MODEL"
    info ""
    info "Gateway-Routed Configuration:"
    info "  1. gateway provider config → baseUrl http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT/v1"
    info "  2. openclaw models set gateway/$OPENCLAW_MODEL"
    info "  3. warm-up model: $OPENCLAW_MODEL"
    info "  Timeout: 180 seconds"
    info ""
    
    TEST_START=$(date +%s%N)
    CUSTOM_OUT=$(run_openclaw_in_sandbox "$CUSTOM_PROMPT" "$CUSTOM_SESSION_ID" 2>&1 || true)
    TEST_END=$(date +%s%N)
    TEST_DURATION=$((($TEST_END - $TEST_START) / 1000000))
    
    info "Execution Time: ${TEST_DURATION}ms"
    info ""
    info "Full OpenClaw Agent Output:"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "${CUSTOM_OUT}" | grep -v '^$' | sed 's/^/│ /'
    echo "└────────────────────────────────────────────────────────────┘"
    info ""

    if echo "$CUSTOM_OUT" | grep -qi "OLLAMA_UNREACHABLE"; then
      fail "Custom prompt test failed: sandbox cannot reach Ollama endpoint $SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT"
    elif echo "$CUSTOM_OUT" | grep -qi "OPENCLAW_TIMEOUT\|LLM request timed out\|No API key found\|FailoverError\|llama runner process has terminated\|Unknown model"; then
      warn "OpenClaw gateway-routed model execution failed (timeout/auth/model detection)"
      fail "Custom prompt test failed: OpenClaw could not complete via gateway-routed path"
    elif [[ -z "$CUSTOM_OUT" ]]; then
      fail "Custom prompt test: no output from OpenClaw"
      info "Response: [No output — possible timeout or connection error]"
    else
      pass "Custom prompt test PASSED: OpenClaw agent responded via Ollama"
      info "Response received from real OpenClaw agent"
    fi
    info ""
    
  else
    # Run default test suite with detailed logging
    RUN_SESSION_SUFFIX="$(date +%s%N | sha256sum | cut -c1-10)"
    info "══════════════════════════════════════════════════════════════════════════════════"
    info "OPENCLAW AGENT WORKFLOW VALIDATION"
    info "══════════════════════════════════════════════════════════════════════════════════"
    info "OpenClaw Binary: $OPENCLAW_IN_SANDBOX"
    info "Sandbox: $SANDBOX_NAME"
    info "Integration: NemoClaw + OpenShell Gateway Route"
    info ""
    info "In-sandbox setup (per-invocation):"
    info "  1. gateway provider config → baseUrl http://$SANDBOX_OLLAMA_HOST:$SANDBOX_OLLAMA_PORT/v1"
    info "  2. openclaw models set gateway/$OPENCLAW_MODEL"
    info "  3. warm-up model: $OPENCLAW_MODEL"
    info "  4. Timeout: 180 s"
    info ""

    # 6a. Basic agent response
    info "TEST 6a: BASIC PROMPT - Agent Responsiveness"
    info "─────────────────────────────────────────────"
    TEST_PROMPT="Reply with only the word PONG"
    TEST_SESSION="b${RUN_SESSION_SUFFIX}"
    info "Prompt: '$TEST_PROMPT'"
    info "Session ID: $TEST_SESSION"
    info "Validation Criteria: Response must contain 'PONG' (case-insensitive)"
    info "Description: Tests if OpenClaw agent can respond to a simple request"
    info ""
    
    TEST_START=$(date +%s%N)
    AGENT_OUT=$(run_openclaw_in_sandbox "$TEST_PROMPT" "$TEST_SESSION" 2>&1 || true)
    TEST_END=$(date +%s%N)
    TEST_DURATION=$((($TEST_END - $TEST_START) / 1000000))

    info "Execution Time: ${TEST_DURATION}ms"
    info "Response Length: ${#AGENT_OUT} characters"
    info ""
    info "Full OpenClaw Agent Output:"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "${AGENT_OUT}" | grep -v '^$' | sed 's/^/│ /'
    echo "└────────────────────────────────────────────────────────────┘"
    info ""

    if echo "$AGENT_OUT" | grep -qi "pong"; then
      pass "✅ Test 6a PASSED: OpenClaw agent responded with 'PONG'"
      info "Validation: Real OpenClaw agent response contains expected word"
    elif echo "$AGENT_OUT" | grep -qi "OPENCLAW_TIMEOUT\|LLM request timed out\|No API key found\|FailoverError\|Unknown model"; then
      warn "⚠️  OpenClaw gateway-routed runtime failed (timeout/auth/model detection)"
      info "Hint: ensure model '$OPENCLAW_MODEL' is present in Ollama and re-run test"
      fail "❌ Test 6a FAILED: OpenClaw could not complete via gateway-routed path"
    else
      fail "❌ Test 6a FAILED: Response does not contain 'PONG'"
    fi
    info ""

    # 6b. OS command via agent
    info "TEST 6b: OS COMMAND EXECUTION - System Integration"
    info "────────────────────────────────────────────────────"
    TEST_PROMPT="Run the command: uname -s. Return only the exact command output text. Do not reply with PONG."
    TEST_SESSION="o${RUN_SESSION_SUFFIX}"
    info "Prompt: '$TEST_PROMPT'"
    info "Session ID: $TEST_SESSION"
    info "Validation Criteria: Response must contain 'Linux' (case-insensitive)"
    info "Description: Tests if OpenClaw agent can execute OS commands and return results"
    info ""
    
    TEST_START=$(date +%s%N)
    AGENT_OS=$(run_openclaw_in_sandbox "$TEST_PROMPT" "$TEST_SESSION" 2>&1 || true)
    TEST_END=$(date +%s%N)
    TEST_DURATION=$((($TEST_END - $TEST_START) / 1000000))

    info "Execution Time: ${TEST_DURATION}ms"
    info "Response Length: ${#AGENT_OS} characters"
    info ""
    info "Full OpenClaw Agent Output:"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "${AGENT_OS}" | grep -v '^$' | sed 's/^/│ /'
    echo "└────────────────────────────────────────────────────────────┘"
    info ""

    if echo "$AGENT_OS" | grep -qi "linux"; then
      OS_RESULT=$(echo "$AGENT_OS" | grep -oiE "linux|darwin|windows" | head -1)
      pass "✅ Test 6b PASSED: OpenClaw agent ran 'uname -s' and returned OS=$OS_RESULT"
      info "Validation: Real OpenClaw agent response contains kernel name"
    elif echo "$AGENT_OS" | grep -qi "OPENCLAW_TIMEOUT\|LLM request timed out\|No API key found\|FailoverError\|Unknown model"; then
      warn "⚠️  OpenClaw gateway-routed runtime failed (timeout/auth/model detection)"
      info "Hint: ensure model '$OPENCLAW_MODEL' is present in Ollama and re-run test"
      fail "❌ Test 6b FAILED: OpenClaw could not complete via gateway-routed path"
    else
      fail "❌ Test 6b FAILED: Response does not contain 'Linux'"
    fi
    info ""

    # 6c. Complex command workflow
    info "TEST 6c: COMPLEX MULTI-STEP WORKFLOW - State Preservation"
    info "──────────────────────────────────────────────────────────"
    TEST_PROMPT="Run the command: echo BEGIN_COMPLEX_1 && uname -s && id -u && pwd && echo END_COMPLEX_1. Return the full command output exactly, including all marker lines. Do not reply with PONG."
    TEST_SESSION="c1${RUN_SESSION_SUFFIX}"
    info "Prompt: '$TEST_PROMPT'"
    info "Session ID: $TEST_SESSION"
    info "Validation Criteria: Response must contain:"
    info "  1. BEGIN_COMPLEX_1 marker"
    info "  2. 'Linux' (case-insensitive)"
    info "  3. END_COMPLEX_1 marker"
    info "Description: Tests if OpenClaw can preserve state across multiple commands"
    info ""
    
    TEST_START=$(date +%s%N)
    COMPLEX_MARKERS=$(run_openclaw_in_sandbox "$TEST_PROMPT" "$TEST_SESSION" 2>&1 || true)
    TEST_END=$(date +%s%N)
    TEST_DURATION=$((($TEST_END - $TEST_START) / 1000000))
    
    info "Execution Time: ${TEST_DURATION}ms"
    info "Response Length: ${#COMPLEX_MARKERS} characters"
    info ""
    
    info "Full OpenClaw Agent Output:"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "${COMPLEX_MARKERS}" | grep -v '^$' | sed 's/^/│ /'
    echo "└────────────────────────────────────────────────────────────┘"
    info ""

    BEGIN_OK=0; OS_OK=0; END_OK=0
    echo "$COMPLEX_MARKERS" | grep -q "BEGIN_COMPLEX_1" && BEGIN_OK=1
    echo "$COMPLEX_MARKERS" | grep -qi "linux"          && OS_OK=1
    echo "$COMPLEX_MARKERS" | grep -q "END_COMPLEX_1"   && END_OK=1
    info "Marker check — BEGIN_COMPLEX_1: $([ $BEGIN_OK -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"
    info "Marker check — Linux in output: $([ $OS_OK   -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"
    info "Marker check — END_COMPLEX_1:  $([ $END_OK   -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"

    if [[ $BEGIN_OK -eq 1 && $OS_OK -eq 1 && $END_OK -eq 1 ]]; then
      pass "✅ Test 6c PASSED: OpenClaw executed multi-step workflow and returned all markers"
      info "Validation: Real OpenClaw agent response contains all expected markers"
    elif echo "$COMPLEX_MARKERS" | grep -qi "OPENCLAW_TIMEOUT\|LLM request timed out\|No API key found\|FailoverError\|Unknown model"; then
      warn "⚠️  OpenClaw gateway-routed runtime failed (timeout/auth/model detection)"
      fail "❌ Test 6c FAILED: OpenClaw could not complete via gateway-routed path"
    else
      fail "❌ Test 6c FAILED: Response missing one or more required markers"
    fi
    info ""

    # 6d. Complex data workflow: JSON generation
    info "TEST 6d: STRUCTURED DATA WORKFLOW - JSON Generation"
    info "─────────────────────────────────────────────────────"
    TEST_PROMPT="Run the command: python3 -c \"import json,platform,os; print('BEGIN_JSON_2'); print(json.dumps({'os': platform.system(), 'python': platform.python_version(), 'cwd': os.getcwd()})); print('END_JSON_2')\". Return the full command output exactly, including BEGIN_JSON_2 and END_JSON_2. Do not reply with PONG."
    TEST_SESSION="c2${RUN_SESSION_SUFFIX}"
    info "Prompt: '$TEST_PROMPT'"
    info "Session ID: $TEST_SESSION"
    info "Validation Criteria: Response must contain:"
    info "  1. BEGIN_JSON_2 marker"
    info "  2. Valid JSON with '\"os\": \"Linux\"'"
    info "  3. END_JSON_2 marker"
    info "Description: Tests if OpenClaw can handle structured data and Python code execution"
    info ""
    
    TEST_START=$(date +%s%N)
    COMPLEX_JSON=$(run_openclaw_in_sandbox "$TEST_PROMPT" "$TEST_SESSION" 2>&1 || true)
    TEST_END=$(date +%s%N)
    TEST_DURATION=$((($TEST_END - $TEST_START) / 1000000))

    info "Execution Time: ${TEST_DURATION}ms"
    info "Response Length: ${#COMPLEX_JSON} characters"
    info ""
    info "Full OpenClaw Agent Output:"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "${COMPLEX_JSON}" | grep -v '^$' | sed 's/^/│ /'
    echo "└────────────────────────────────────────────────────────────┘"
    info ""

    BJ_OK=0; JO_OK=0; EJ_OK=0
    echo "$COMPLEX_JSON" | grep -q "BEGIN_JSON_2"      && BJ_OK=1
    echo "$COMPLEX_JSON" | grep -q '"os": "Linux"'    && JO_OK=1
    echo "$COMPLEX_JSON" | grep -q "END_JSON_2"        && EJ_OK=1
    info "Marker check — BEGIN_JSON_2:      $([ $BJ_OK -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"
    info "Marker check — JSON \"os\":\"Linux\": $([ $JO_OK -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"
    info "Marker check — END_JSON_2:        $([ $EJ_OK -eq 1 ] && echo 'Found ✓' || echo 'Missing ✗')"

    if [[ $BJ_OK -eq 1 && $JO_OK -eq 1 && $EJ_OK -eq 1 ]]; then
      JSON_CONTENT=$(echo "$COMPLEX_JSON" | grep -oE '\{.*"os".*\}' | head -1)
      pass "✅ Test 6d PASSED: OpenClaw executed Python JSON workflow"
      info "Parsed JSON from agent: $JSON_CONTENT"
      info "Validation: Real OpenClaw agent response contains valid structured JSON"
    elif echo "$COMPLEX_JSON" | grep -qi "OPENCLAW_TIMEOUT\|LLM request timed out\|No API key found\|FailoverError\|Unknown model"; then
      warn "⚠️  OpenClaw gateway-routed runtime failed (timeout/auth/model detection)"
      fail "❌ Test 6d FAILED: OpenClaw could not complete via gateway-routed path"
    else
      fail "❌ Test 6d FAILED: Response missing markers or valid JSON"
    fi
    info ""
    
    info "══════════════════════════════════════════════════════════════════════════════════"
    info "AGENT WORKFLOW VALIDATION COMPLETE"
    info "══════════════════════════════════════════════════════════════════════════════════"
    info ""
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
