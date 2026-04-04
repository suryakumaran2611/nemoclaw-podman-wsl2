#!/bin/bash
# setup_nemoclaw.sh

set -euo pipefail

echo "🚀 Starting NemoClaw Automation for WSL2/Podman..."

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

WIN_IP=$(ip route | awk '/default/ {print $3; exit}')
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
    "model": "qwen2.5-coder:14b-instruct-q4_K_M"
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

echo "✅ Setup Complete. Run ./start_nemoclaw.sh to begin."
