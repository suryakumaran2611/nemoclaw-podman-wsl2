#!/bin/bash
# start_nemoclaw.sh

export DOCKER_HOST=unix:///var/run/docker.sock
OPENCLAW_MODEL="gemma4:e4b"

echo "🔥 Starting OpenShell gateway (nemoclaw)..."
# Try with --gpu first; fall back gracefully if GPU not allocatable
if ! openshell gateway start --name nemoclaw --gpu --recreate 2>&1; then
  echo "⚠️  GPU start failed, retrying without --gpu..."
  openshell gateway start --name nemoclaw --recreate
fi

echo "🛡️ Starting NemoClaw Services..."
nemoclaw start

echo ""
echo "✅ Gateway and NemoClaw are running."
echo "   Runtime model target: $OPENCLAW_MODEL"
echo "   To create the Ollama sandbox: ./simple_onboard.sh"
echo "   To start the GUI (in a new terminal):"
echo "     source .venv/bin/activate && streamlit run nemo_gui.py --server.headless true --server.port 8501"
echo ""
echo "✨ Entering OpenShell interactive terminal..."
openshell term
