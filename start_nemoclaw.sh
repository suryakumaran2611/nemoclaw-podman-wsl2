#!/bin/bash
# start_nemoclaw.sh

export DOCKER_HOST=unix:///var/run/docker.sock

echo "🔥 Initializing RTX 5070 Ti Gateway..."
openshell gateway start --name nemoclaw --gpu

echo "🛡️ Starting NemoClaw Services..."
nemoclaw start

echo "✨ System Ready. Entering Sandbox..."
openshell term
