#!/bin/bash
# wsl_nemoclaw_autoupdate.sh

set -euo pipefail

CREDENTIALS_FILE="$HOME/.nemoclaw/credentials.json"
OPENCLAW_MODEL="gemma4:e4b"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo "⚠️  No credentials file found at $CREDENTIALS_FILE"
  echo "Run ./setup_nemoclaw.sh first."
  exit 1
fi

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

echo "🌐 Updating NemoClaw Windows host IP to $WIN_IP"
sed -i "s|http://[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:11434|http://$WIN_IP:11434|g" "$CREDENTIALS_FILE"

# Keep credentials model aligned with current OpenClaw runtime baseline.
python3 - "$CREDENTIALS_FILE" "$OPENCLAW_MODEL" <<'PY'
import json
import sys

path = sys.argv[1]
model = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
  data = json.load(f)

data.setdefault("ollama", {})["model"] = model

with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2)
  f.write("\n")
PY

echo "✅ Updated $CREDENTIALS_FILE"
