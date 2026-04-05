#!/bin/bash
# simple_onboard.sh
# Automated NemoClaw sandbox creation using OpenShell + Ollama
# No interactive prompts. Run after setup_nemoclaw.sh.

set -euo pipefail

SANDBOX_NAME="${1:-nemoclaw-ollama}"
CREDENTIALS_FILE="$HOME/.nemoclaw/credentials.json"

echo "🤖 NemoClaw Simple Onboard — sandbox: $SANDBOX_NAME"
echo ""

# --- Verify prerequisites ---
if ! command -v openshell >/dev/null 2>&1; then
  echo "❌ openshell not found. Install it first:"
  echo "   curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash"
  exit 1
fi

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo "❌ credentials.json not found. Run ./setup_nemoclaw.sh first."
  exit 1
fi

export DOCKER_HOST=unix:///var/run/docker.sock

# --- Read Ollama host and model from credentials ---
WIN_IP=$(python3 -c "
import json, sys
try:
    c = json.load(open('$CREDENTIALS_FILE'))
    host = c.get('ollama', {}).get('host', '')
    ip = host.replace('http://', '').split(':')[0]
    print(ip)
except Exception as e:
    print('')
")

MODEL=$(python3 -c "
import json
try:
    c = json.load(open('$CREDENTIALS_FILE'))
    print(c.get('ollama', {}).get('model', 'qwen2.5-coder:14b-instruct-q4_K_M'))
except Exception:
    print('qwen2.5-coder:14b-instruct-q4_K_M')
")

if [[ -z "$WIN_IP" ]]; then
  WIN_IP=$(ip route | awk '/default/ {print $3; exit}')
fi

echo "🌐 Ollama host: http://$WIN_IP:11434"
echo "🧠 Model: $MODEL"
echo ""

# --- Verify gateway is running ---
echo "🔍 Checking OpenShell gateway..."
GW_STATUS=$(openshell gateway info --name nemoclaw 2>&1 || openshell status 2>&1 || true)
if echo "$GW_STATUS" | grep -qi "connection refused\|transport error\|no gateway"; then
  echo "❌ OpenShell gateway is not running."
  echo "   Start it first:  ./start_nemoclaw.sh"
  echo "   Then re-run:     ./simple_onboard.sh"
  exit 1
fi
echo "✅ Gateway is reachable."

# --- Test Ollama connectivity ---
echo "🔍 Testing Ollama connectivity..."
if curl -s --max-time 5 "http://$WIN_IP:11434/api/tags" | grep -q '"models"'; then
  echo "✅ Ollama is reachable."
else
  echo "⚠️  Ollama did not respond. Continue anyway? (Ctrl-C to abort, Enter to continue)"
  read -r
fi

# --- Register Ollama provider (using openai type + Ollama's /v1 compat endpoint) ---
# OpenShell has no native 'ollama' type. Ollama exposes an OpenAI-compatible REST
# API at /v1, so we register it as type 'openai' with a custom base_url.
echo "🔌 Registering Ollama provider with OpenShell..."
if openshell provider list 2>/dev/null | grep -q "ollama-local"; then
  echo "ℹ️  Provider 'ollama-local' already registered."
else
  openshell provider create \
    --name ollama-local \
    --type openai \
    --credential OPENAI_API_KEY=ollama \
    --config base_url="http://$WIN_IP:11434/v1" && echo "✅ Provider registered." || {
    echo "❌ Failed to register provider."
    echo "   Manual command:"
    echo "     openshell provider create --name ollama-local --type openai \\"
    echo "       --credential OPENAI_API_KEY=ollama \\"
    echo "       --config base_url=http://$WIN_IP:11434/v1"
    exit 1
  }
fi

# --- Set gateway inference to use Ollama ---
echo "🧠 Configuring gateway inference → Ollama ($MODEL)..."
openshell inference set \
  --provider ollama-local \
  --model "$MODEL" \
  --no-verify 2>/dev/null && echo "✅ Inference configured." || \
  echo "⚠️  inference set failed (gateway may still work without this step)."

# --- Create OpenClaw sandbox ---
echo "📦 Creating sandbox '$SANDBOX_NAME'..."
if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
  echo "ℹ️  Sandbox '$SANDBOX_NAME' already exists."
else
  if openshell sandbox create \
      --name "$SANDBOX_NAME" \
      --from openclaw \
      --provider ollama-local 2>&1; then
    echo "✅ Sandbox '$SANDBOX_NAME' created."
  else
    echo "⚠️  Create with --from openclaw failed, trying bare create..."
    openshell sandbox create --name "$SANDBOX_NAME" --provider ollama-local && \
      echo "✅ Sandbox '$SANDBOX_NAME' created." || {
      echo "❌ Sandbox creation failed."
      echo ""
      echo "Troubleshooting:"
      echo "  openshell gateway info --name nemoclaw"
      echo "  openshell provider list"
      echo "  openshell sandbox create --name $SANDBOX_NAME --from openclaw --provider ollama-local"
      exit 1
    }
  fi
fi

# --- Verify ---
echo ""
echo "📋 Current sandbox list:"
openshell sandbox list 2>/dev/null || echo "(openshell sandbox list failed)"

echo ""
echo "📋 Inference config:"
openshell inference get 2>/dev/null || true

echo ""
echo "✅ Onboarding complete!"
echo ""
echo "Next steps:"
echo "  Connect to sandbox:  nemoclaw $SANDBOX_NAME connect"
echo "  Start GUI:           source .venv/bin/activate && streamlit run nemo_gui.py"
echo "  Open in browser:     http://127.0.0.1:8501"
