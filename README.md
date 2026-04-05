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

This script fixes the socket, detects the Windows host IP using PowerShell if available, and writes the hidden NemoClaw credentials.

```bash
#!/bin/bash
# setup_nemoclaw.sh

set -euo pipefail

echo "🚀 Starting NemoClaw Automation for WSL2/Podman..."

# 1. Fix Podman Socket Bridge
echo "🔗 Bridging Podman Rootful Socket..."
sudo rm -f /var/run/docker.sock
sudo ln -s /mnt/wsl/podman-sockets/podman-machine-default/podman-root.sock /var/run/docker.sock
sudo chmod 666 /var/run/docker.sock

# 2. Detect Windows Host IP
WIN_IP=""
if command -v powershell.exe >/dev/null 2>&1; then
  WIN_IP=$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169|127)' } | Select-Object -ExpandProperty IPAddress)" | tr -d '\r' | awk 'NF {print; exit}')
fi
if [[ -z "$WIN_IP" ]]; then
  WIN_IP=$(ip route | grep default | awk '{print $3}')
fi
if [[ -z "$WIN_IP" ]]; then
  echo "❌ Unable to detect Windows host IP from WSL2."
  exit 1
fi

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

## 6. Using Ollama with NemoClaw

NemoClaw uses Ollama as a REST provider from Windows. The WSL guest must be able to reach Ollama over the Windows host IP and port `11434`.

1. Ensure Windows Ollama is running.
2. Set the host variable in Windows PowerShell:

```powershell
[System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')
```

3. Allow port `11434` through Windows Firewall for the WSL IP range.
4. Restart the Ollama app fully after changing the host.

### Verify Ollama from WSL

From Ubuntu WSL, confirm connectivity using the current Ollama REST path:

```bash
WIN_IP=$(ip route | awk '/default/ {print $3; exit}')
curl http://$WIN_IP:11434/api/tags
```

If this returns a JSON object containing `"models"`, the network path is working.

If the default route IP is not reachable, use the dashboard's detected Windows host candidates or copy the actual Windows host IP from PowerShell / `ipconfig` and use that address instead.

### NemoClaw Ollama credentials

The install script writes `~/.nemoclaw/credentials.json` with the current Windows host IP and the configured model:

```json
{
  "provider": "ollama",
  "ollama": {
    "host": "http://<windows-ip>:11434",
    "model": "qwen2.5-coder:14b-instruct-q4_K_M"
  }
}
```

If WSL IP changes, rerun `./wsl_nemoclaw_autoupdate.sh` or reopen a shell after setup.

## 7. Streamlit NemoClaw Commander

A single Streamlit dashboard is now the primary GUI for NemoClaw. It can perform key NemoClaw and OpenShell sandbox actions in a WSL2 environment.

### Features

- Connection Manager for `WIN_IP` and `OLLAMA_HOST`
- Ollama health check via the WSL HTTP path
- Sandbox gateway start/stop and status display
- NemoClaw service start/stop controls
- Automated full system health check
- OpenShell sandbox listing and control commands
- Direct link to the official NemoClaw web UI on the Windows host
- Hardware monitor with `nvidia-smi` metrics when available
- Quick Actions for project analysis, git status, and README generation

### Install and launch

Install Python dependencies in WSL:

```bash
python -m pip install -r requirements.txt
```

Run the dashboard:

```bash
streamlit run nemo_gui.py
```

Open the browser on Windows at:

```text
http://127.0.0.1:8501
```

### Notes

- The dashboard runs inside WSL and uses `DOCKER_HOST=unix:///var/run/docker.sock` for every command.
- Make sure the Podman rootful socket is bridged before launching Streamlit.
- Streamlit is configured to run headless (no auto-browser opening) to avoid WSL browser issues.
- Telemetry and email prompts are disabled via `.streamlit/config.toml`.
- The sidebar includes a Quick Start checklist with clickable buttons for setup, gateway service startup, and health checks.

### Troubleshooting

- **"Connection refused" errors**: Ensure Podman Machine is running and rootful mode is enabled.
- **Ollama health check fails**: Verify Windows Ollama is running and firewall allows port 11434.
- **Windows Web UI not reachable**: Use the detected Windows host IP from the sidebar and open `http://<windows-ip>:18789` in a Windows browser. If the dashboard shows the wrong IP, enter the correct one manually in the sidebar and save the Ollama config.
- **Browser won't open**: Streamlit runs headless in WSL - always open `http://127.0.0.1:8501` from Windows browser.
- **Streamlit email prompt**: The config disables this.

### OpenNemo Test Checklist

1. Run `./setup_nemoclaw.sh`.
2. Run `./start_nemoclaw.sh`.
3. Confirm gateway status:

```bash
openshell gateway list
```

4. Confirm Ollama health:

```bash
WIN_IP=$(ip route | awk '/default/ {print $3; exit}')
curl http://$WIN_IP:11434/v1/models
```

5. Use the dashboard "Run Full System Check" button.
6. Verify `OpenShell exec support` is enabled in the dashboard.
7. Use the dashboard chat panel to send prompts.
8. If exec is unsupported, use `openshell term` or upgrade OpenShell.

### Example Prompts

Use these as full OpenNemo test cases in the dashboard chat or via `agent -m`:

```bash
agent -m "What is the OS name and version?"
agent -m "Show me the current working directory, list the files, and tell me which shell is active."
agent -m "List all available OpenShell providers and sandboxes currently configured."
agent -m "Give me a summary of GPU VRAM usage, temperature, and system health."
agent -m "Read the contents of /etc/os-release and summarize the distribution info."
agent -m "Display the first 20 lines of the NemoClaw repo README and tell me if the config file exists."
agent -m "Check whether the Docker host socket at /var/run/docker.sock is available and report its permissions."
```

### OS-level interaction tests

These prompts deliberately test NemoClaw with operating-system-level actions and environment awareness.

```bash
agent -m "Run 'uname -a' and summarize the kernel version and machine architecture."
agent -m "Show me environment variables related to OLLAMA_HOST, DOCKER_HOST, and PATH."
agent -m "List the contents of the current user's home directory and identify any .nemoclaw files."
agent -m "Report the output of 'ps -ef | grep openshell' and whether the gateway process is running."
agent -m "Inspect /proc/meminfo and describe available memory and swap usage."
agent -m "Check if nvidia-smi is installed; if yes, return the GPU name and memory usage."
agent -m "Read the current bash configuration from ~/.bashrc and identify the NemoClaw startup block."
```

### E2E OpenNemo test scenarios

Run these in sequence to verify full interaction from host to sandbox:

1. `openshell gateway list` — verify gateway status.
2. `openshell provider list` — confirm provider discovery.
3. `openshell sandbox list` — confirm sandbox availability.
4. Send an agent prompt via the dashboard: `What is the OS name?`.
5. Send an OS-level prompt: `List the current directory and report the top 5 files by size.`
6. Send an Ollama-specific prompt: `Which Ollama model is currently configured in ~/.nemoclaw/credentials.json?`.
7. Send a hardware probe prompt: `Report GPU name, VRAM used, VRAM total, and temperature.`

### Example custom OpenShell commands

```bash
openshell provider list
openshell sandbox list
openshell gateway list
openshell --help
```

### Pre-backed test examples

These are ready-to-run prompts intended to verify OpenNemo capabilities end-to-end:

```bash
agent -m "Detect and return the Windows host IP from WSL and tell me if Ollama is reachable at port 11434."
agent -m "Run 'ls -la ~/.nemoclaw' and tell me whether credentials.json exists and is readable."
agent -m "Use the current NemoClaw environment to locate the Podman socket file /var/run/docker.sock and report its permissions."
agent -m "Inspect the current WSL network route, find the default gateway, and verify connectivity to the Windows host."
agent -m "Read the first 10 lines of ~/.bashrc and verify the NemoClaw startup IP updater is present."
```

### Example validation workflows

- **Basic health validation:** run `Run Full System Check` in the dashboard, then send `What is the current OS and GPU status?`.
- **Sandbox interaction validation:** start the gateway, then use the chat panel to request `List open sandboxes and providers`.
- **OS-level validation:** use the chat panel to request `Show me environment variables for OLLAMA_HOST, DOCKER_HOST, and USER`.
- **Model validation:** ask `Which Ollama model is configured in ~/.nemoclaw/credentials.json?` and verify the response.

openshell gateway list
openshell --help
```

### Recommended test workflow

- Start the gateway.
- Run the system health check.
- Send a simple prompt such as `What is the OS name?`.
- Send a second prompt such as `What model is configured in Ollama?`.
- Validate the agent response and the `Last Output` panel.

Because your setup involves Rootful Podman and a 14B model, the GPU will draw significant power.

- Thermal Ceiling: Your 12GB VRAM may be at ~90% capacity.
- Manual Fan Control: Use Fn + F8 (Cooler Boost). If the laptop hits 100°C, Windows may throttle the WSL2 instance, causing timeouts.

## Usage

1. Copy these files into the repository: `setup_nemoclaw.sh`, `start_nemoclaw.sh`, `wsl_nemoclaw_autoupdate.sh`, `nemo_gui.py`, and `requirements.txt`.
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

5. Start the Streamlit dashboard:

```bash
streamlit run nemo_gui.py
```

6. Open the browser on Windows at:

```text
http://127.0.0.1:8501
```

**Note:** Streamlit runs headless in WSL - do not try to open the browser from WSL terminal. Always open from Windows browser.

Install dependencies in WSL:

```bash
python -m pip install -r requirements.txt
```

Run the dashboard:

```bash
streamlit run nemo_gui.py
```

Open the browser on Windows at:

```text
http://127.0.0.1:8501
```

The dashboard includes:
- Connection Manager for WIN_IP and Ollama
- Sandbox gateway start/stop controls
- Chat interface to send prompts to the NemoClaw sandbox
- Hardware monitor with `nvidia-smi` data
- Quick actions for project analysis, git status, and README generation

