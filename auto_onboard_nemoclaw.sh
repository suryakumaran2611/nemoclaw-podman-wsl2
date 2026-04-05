#!/bin/bash
# auto_onboard_nemoclaw.sh
# Automated NemoClaw onboarding script for Ollama integration
# Uses the same gateway-routed flow as simple_onboard.sh/test_sandbox.sh.

set -euo pipefail

echo "🤖 Starting Automated NemoClaw Onboarding..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_NAME="${1:-nemoclaw-auto}"

# Check prerequisites
if ! command -v nemoclaw >/dev/null 2>&1; then
    echo "❌ NemoClaw not found. Please install it first:"
    echo "curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash"
    exit 1
fi

if ! command -v openshell >/dev/null 2>&1; then
    echo "❌ OpenShell not found. Please ensure it's installed with NemoClaw."
    exit 1
fi

# Check if credentials exist
if [[ ! -f "$HOME/.nemoclaw/credentials.json" ]]; then
    echo "❌ Credentials not found. Please run ./setup_nemoclaw.sh first."
    exit 1
fi

echo "⚙️  Running non-interactive onboarding via simple_onboard.sh..."
"$SCRIPT_DIR/simple_onboard.sh" "$SANDBOX_NAME"

# Connect to the sandbox
echo "🔗 Connecting to sandbox..."
nemoclaw "$SANDBOX_NAME" connect

echo "✅ Automated onboarding complete!"
echo "🎯 You can now use OpenClaw agent commands:"
echo "   openclaw agent --agent main --local -m \"Your prompt here\" --session-id session1"