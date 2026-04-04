# NemoClaw v0.0.6: WSL2 + Podman + Windows Ollama Setup

Target Hardware: MSI Vector (RTX 5070 Ti / 12GB VRAM)
Environment: WSL2 (Ubuntu) + Rootful Podman + Windows-hosted Ollama

## 1. Windows Host Prep

1. Open PowerShell as Admin and run:

```powershell
Set-NetFirewallRule -DisplayName "Ollama" -RemoteAddress Any
```

2. Set the Ollama host environment variable:

```powershell
[System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')
```

3. Fully quit and restart the Ollama app.

## 2. Podman Configuration

NemoClaw requires Rootful mode to manage its internal K3s network.

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

## 3. Automation Scripts

Use the provided `setup_nemoclaw.sh` to automate the socket bridging and credential generation. Use `start_nemoclaw.sh` for daily operation.

### setup_nemoclaw.sh

This script fixes the socket, pulls the correct Windows IP, and writes the hidden NemoClaw credentials.

```bash
#!/bin/bash
# setup_nemoclaw.sh

echo "🚀 Starting NemoClaw Automation for WSL2/Podman..."

# 1. Fix Podman Socket Bridge
echo "🔗 Bridging Podman Rootful Socket..."
sudo rm -f /var/run/docker.sock
sudo ln -s /mnt/wsl/podman-sockets/podman-machine-default/podman-root.sock /var/run/docker.sock
sudo chmod 666 /var/run/docker.sock

# 2. Detect Windows Host IP
WIN_IP=$(ip route | grep default | awk '{print $3}')
echo "🌐 Detected Windows IP: $WIN_IP"

# 3. Create Credentials (Bypassing 'onboard' bug)
echo "📝 Writing credentials.json..."
mkdir -p ~/.nemoclaw
cat <<EOF > ~/.nemoclaw/credentials.json
{
  "provider": "ollama",
  "ollama": {
    "host": "http://$WIN_IP:11434",
    "model": "qwen2.5-coder:14b-instruct-q4_K_M"
  }
}
EOF
chmod 600 ~/.nemoclaw/credentials.json

echo "✅ Setup Complete. Run ./start_nemoclaw.sh to begin."
```

### start_nemoclaw.sh

This handles the "Day 2" operations, ensuring the gateway and services start in the correct order.

```bash
#!/bin/bash
# start_nemoclaw.sh

export DOCKER_HOST=unix:///var/run/docker.sock

echo "🔥 Initializing RTX 5070 Ti Gateway..."
openshell gateway start --name nemoclaw --gpu

echo "🛡️ Starting NemoClaw Services..."
nemoclaw start

echo "✨ System Ready. Entering Sandbox..."
openshell term
```

## 4. Auto-Update Windows IP on WSL Startup

WSL2 IPs change every reboot. The install script now adds an auto-update block to `~/.bashrc` so `~/.nemoclaw/credentials.json` refreshes each time you open a new shell.

A dedicated updater script is also included:

```bash
./wsl_nemoclaw_autoupdate.sh
```

This script is useful if you want to refresh the Windows host IP manually without restarting your shell.

## 5. Podman as Docker in WSL

The setup script also configures WSL to use the Podman rootful socket as the default `DOCKER_HOST`:

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
alias docker=podman
```

That means Docker-style clients in WSL will talk to the Windows Podman socket without extra manual configuration.

## Final Thermal Warning (MSI Vector)

Because your setup involves Rootful Podman and a 14B model, the GPU will draw significant power.

- Thermal Ceiling: Your 12GB VRAM may be at ~90% capacity.
- Manual Fan Control: Use Fn + F8 (Cooler Boost). If the laptop hits 100°C, Windows may throttle the WSL2 instance, causing timeouts.

## Usage

1. Copy these files into the repository: `setup_nemoclaw.sh`, `start_nemoclaw.sh`, and `wsl_nemoclaw_autoupdate.sh`.
2. Make them executable:

```bash
chmod +x setup_nemoclaw.sh start_nemoclaw.sh wsl_nemoclaw_autoupdate.sh
```

3. Run the setup script first:

```bash
./setup_nemoclaw.sh
```

4. After setup, start NemoClaw with:

```bash
./start_nemoclaw.sh
```

