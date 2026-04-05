#!/bin/bash
# wsl_nemoclaw_autoupdate.sh

set -euo pipefail

CREDENTIALS_FILE="$HOME/.nemoclaw/credentials.json"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo "⚠️  No credentials file found at $CREDENTIALS_FILE"
  echo "Run ./setup_nemoclaw.sh first."
  exit 1
fi

WIN_IP=""
if command -v powershell.exe >/dev/null 2>&1; then
  WIN_IP=$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169|127)' } | Select-Object -ExpandProperty IPAddress)" | tr -d '\r' | awk 'NF {print; exit}')
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
echo "✅ Updated $CREDENTIALS_FILE"
