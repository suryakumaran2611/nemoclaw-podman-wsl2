#!/bin/bash
# auto_onboard_nemoclaw.sh
# Automated NemoClaw onboarding script for Ollama integration
chmod +x "$0"
set -euo pipefail

echo "🤖 Starting Automated NemoClaw Onboarding..."

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

# Set environment variables for automation
export DOCKER_HOST=unix:///var/run/docker.sock
export OLLAMA_HOST="http://$WIN_IP:11434"

echo "🔍 Checking current sandbox status..."
SANDBOX_NAME="nemoclaw-auto"

# Check if sandbox already exists
if openshell sandbox list | grep -q "$SANDBOX_NAME"; then
    echo "ℹ️  Sandbox '$SANDBOX_NAME' already exists."
    echo "🔗 Connecting to existing sandbox..."
    nemoclaw "$SANDBOX_NAME" connect
    echo "✅ Connected to sandbox '$SANDBOX_NAME'"
    exit 0
fi

echo "🏗️  Creating new sandbox with Ollama integration..."

# Create expect script for automated onboarding
cat > /tmp/nemoclaw_onboard.exp << 'EOF'
#!/usr/bin/expect -f

set timeout 300

spawn nemoclaw onboard

# Wait for initial prompt
expect "Welcome to NemoClaw onboarding"
send "\r"

# Choose sandbox name
expect "Enter sandbox name"
send "nemoclaw-auto\r"

# Choose provider (Ollama)
expect "Choose inference provider"
send "1\r"  # Assuming Ollama is option 1

# Configure Ollama settings
expect "Ollama host"
send "\r"  # Use default from credentials

expect "Ollama model"
send "\r"  # Use default from credentials

# Accept default security policies
expect "Configure security policies"
send "\r"

# Complete onboarding
expect "Onboarding complete"
send "\r"

expect eof
EOF

chmod +x /tmp/nemoclaw_onboard.exp

# Run automated onboarding
echo "⚙️  Running automated onboarding process..."
/tmp/nemoclaw_onboard.exp

# Clean up
rm -f /tmp/nemoclaw_onboard.exp

# Verify sandbox creation
echo "🔍 Verifying sandbox creation..."
if openshell sandbox list | grep -q "$SANDBOX_NAME"; then
    echo "✅ Sandbox '$SANDBOX_NAME' created successfully!"
else
    echo "❌ Sandbox creation failed. Checking logs..."
    openshell doctor logs --name "$SANDBOX_NAME" || true
    exit 1
fi

# Connect to the sandbox
echo "🔗 Connecting to sandbox..."
nemoclaw "$SANDBOX_NAME" connect

echo "✅ Automated onboarding complete!"
echo "🎯 You can now use OpenClaw agent commands:"
echo "   openclaw agent --agent main --local -m \"Your prompt here\" --session-id session1"