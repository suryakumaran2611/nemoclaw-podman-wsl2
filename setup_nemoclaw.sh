#!/bin/bash
# setup_nemoclaw.sh

set -euo pipefail

echo "🚀 Starting NemoClaw Automation for WSL2/Podman..."

OPENCLAW_MODEL="gemma4:e4b"

SOCKET_TARGET="/mnt/wsl/podman-sockets/podman-machine-default/podman-root.sock"

if [[ ! -S "$SOCKET_TARGET" ]]; then
  echo "❌ Expected Podman rootful socket not found at $SOCKET_TARGET"
  echo "Make sure Podman Machine is started and rootful mode is enabled."
  exit 1
fi

echo "🔗 Bridging Podman Rootful Socket..."
sudo rm -f /var/run/docker.sock
sudo ln -sf "$SOCKET_TARGET" /var/run/docker.sock
sudo chmod 666 /var/run/docker.sock

WIN_IP=""
if command -v powershell.exe >/dev/null 2>&1; then
  WIN_IP=$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.AddressState -eq 'Preferred' -and \$_.IPAddress -notmatch '^(169|127)' -and \$_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V' } | Select-Object -ExpandProperty IPAddress | Select-Object -First 1)" | tr -d '\r')
fi

if [[ -z "$WIN_IP" ]]; then
  WIN_IP=$(ip route | awk '/default/ {print $3; exit}')
fi

if [[ -z "$WIN_IP" ]]; then
  echo "❌ Unable to detect Windows host IP from WSL2."
  exit 1
fi

echo "🌐 Detected Windows IP: $WIN_IP"

echo "📝 Writing credentials.json..."
mkdir -p "$HOME/.nemoclaw"
cat <<EOF > "$HOME/.nemoclaw/credentials.json"
{
  "provider": "ollama",
  "ollama": {
    "host": "http://$WIN_IP:11434",
    "model": "$OPENCLAW_MODEL"
  }
}
EOF
chmod 600 "$HOME/.nemoclaw/credentials.json"

BASHRC="$HOME/.bashrc"
STARTUP_MARKER="# NemoClaw WSL2 Startup Configuration"
if ! grep -qF "$STARTUP_MARKER" "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" <<'EOF'

# NemoClaw WSL2 Startup Configuration
export DOCKER_HOST=unix:///var/run/docker.sock
alias docker=podman

update_nemoclaw_ip() {
    local win_ip
    win_ip=$(ip route | awk '/default/ {print $3; exit}')
    if [[ -n "$win_ip" && -f "$HOME/.nemoclaw/credentials.json" ]]; then
        sed -i "s|http://[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:11434|http://$win_ip:11434|g" "$HOME/.nemoclaw/credentials.json"
    fi
}

update_nemoclaw_ip
EOF
  echo "✅ Added NemoClaw startup config to $BASHRC"
else
  echo "ℹ️ NemoClaw startup config already exists in $BASHRC"
fi

# --- Automated OpenShell sandbox setup ---
# Only attempted when the gateway is already running. If it's not, instructions
# are printed so the user can run ./simple_onboard.sh after ./start_nemoclaw.sh.
if command -v openshell >/dev/null 2>&1; then
  SANDBOX_NAME="nemoclaw-ollama"
  # Check gateway reachability before attempting provider/sandbox commands
  GW_CHECK=$(openshell status 2>&1 || true)
  if echo "$GW_CHECK" | grep -qi "connection refused\|transport error"; then
    echo "ℹ️  OpenShell gateway not running — skipping sandbox auto-create."
    echo "    After running ./start_nemoclaw.sh, run ./simple_onboard.sh"
  else
    echo "🏗️  Checking OpenShell sandbox '$SANDBOX_NAME'..."
    if openshell -g nemoclaw sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
      echo "ℹ️  Sandbox '$SANDBOX_NAME' already exists."
    else
      echo "🔌 Registering Ollama provider (openai-compat type)..."
      openshell -g nemoclaw provider create \
        --name ollama-local \
        --type openai \
        --credential OPENAI_API_KEY=ollama \
        --config base_url="http://$WIN_IP:11434/v1" 2>/dev/null || true

      openshell -g nemoclaw provider update ollama-local \
        --credential OPENAI_API_KEY=ollama \
        --config base_url="http://$WIN_IP:11434/v1" 2>/dev/null || true

      echo "🧠 Setting gateway inference to Ollama..."
      openshell -g nemoclaw inference set \
        --provider ollama-local \
        --model "$OPENCLAW_MODEL" \
        --no-verify 2>/dev/null || true

      echo "📦 Creating sandbox '$SANDBOX_NAME'..."
      if openshell -g nemoclaw sandbox create \
          --name "$SANDBOX_NAME" \
          --from openclaw \
          --provider ollama-local 2>/dev/null; then
        echo "✅ Sandbox '$SANDBOX_NAME' created successfully."
      else
        echo "⚠️  Sandbox creation failed (start the gateway first, then run ./simple_onboard.sh)."
        echo "    Manual steps after ./start_nemoclaw.sh:"
        echo "      openshell -g nemoclaw provider create --name ollama-local --type openai --credential OPENAI_API_KEY=ollama --config base_url=http://$WIN_IP:11434/v1"
        echo "      openshell -g nemoclaw inference set --provider ollama-local --model $OPENCLAW_MODEL --no-verify"
        echo "      openshell -g nemoclaw sandbox create --name $SANDBOX_NAME --from openclaw --provider ollama-local"
      fi
    fi
  fi
else
  echo "ℹ️  OpenShell not found — skipping sandbox setup."
fi

echo "✅ Setup Complete. Run ./start_nemoclaw.sh to begin."
