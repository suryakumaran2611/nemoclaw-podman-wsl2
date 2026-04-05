# NemoClaw Agent Setup Guide
## WSL2 + Windows Podman + Windows Ollama Configuration

This guide provides complete instructions for setting up NemoClaw in WSL2 with Windows-hosted Podman and Ollama services.

## System Architecture

- **NemoClaw**: Runs in WSL2 Ubuntu environment
- **Podman**: Container runtime on Windows host
- **Ollama**: AI model server on Windows host
- **Network**: WSL accesses Windows services via detected host IP

## Prerequisites

### Windows Host Setup

1. **Install Podman Desktop** on Windows
2. **Install Ollama** on Windows
3. **Configure Ollama** for network access:
   ```powershell
   [System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')
   Set-NetFirewallRule -DisplayName "Ollama" -RemoteAddress Any
   ```
4. **Start Podman Machine** in rootful mode:
   ```bash
   podman machine stop
   podman machine set --rootful
   podman machine start
   ```

### WSL2 Environment

- Ubuntu 22.04+ in WSL2
- Python 3.8+ with pip
- Access to Windows host via network

## Installation Steps

### 1. Install NemoClaw

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

### 2. Run Setup Script

Execute the automated setup script:

```bash
./setup_nemoclaw.sh
```

This script will:
- ✅ Detect Windows Podman socket
- ✅ Create Docker socket bridge (`/var/run/docker.sock` → Podman socket)
- ✅ Detect correct Windows host IP (excludes virtual adapters)
- ✅ Configure Ollama credentials
- ✅ Set up automatic IP updates on WSL startup

### 3. Verify Setup

Check that everything is configured correctly:

```bash
# Check socket bridge
ls -la /var/run/docker.sock

# Check credentials
cat ~/.nemoclaw/credentials.json

# Test Ollama connectivity
WIN_IP=$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.AddressState -eq 'Preferred' -and \$_.IPAddress -notmatch '^(169|127)' -and \$_.InterfaceAlias -notmatch 'vEthernet|WSL|Hyper-V' } | Select-Object -ExpandProperty IPAddress | Select-Object -First 1)" | tr -d '\r')
curl http://$WIN_IP:11434/api/tags
```

## Onboarding Process

### Create Your First Sandbox

```bash
nemoclaw onboard
```

This interactive process will:
- Create a sandboxed OpenClaw instance
- Configure inference providers (Ollama)
- Set up security policies
- Install OpenClaw agent inside the sandbox

### Connect to Sandbox

```bash
nemoclaw <sandbox-name> connect
```

Replace `<sandbox-name>` with the name chosen during onboarding (typically `my-assistant`).

## Agent Usage

### Direct Agent Commands

Once connected to a sandbox, use OpenClaw agent commands:

```bash
openclaw agent --agent main --local -m "Your prompt here" --session-id unique_session
```

### Web Interface

Start the Streamlit dashboard for GUI access:

```bash
cd /path/to/nemoclaw-podman-wsl2
source .venv/bin/activate
streamlit run nemo_gui.py --server.headless true --server.port 8501
```

Access at: `http://127.0.0.1:8501` (open in Windows browser)

## Agent Command Examples

### System Information
```bash
openclaw agent --agent main --local -m "What is the OS name and version?" --session-id sys_info
openclaw agent --agent main --local -m "Show me environment variables related to OLLAMA_HOST, DOCKER_HOST, and PATH" --session-id env_check
```

### File Operations
```bash
openclaw agent --agent main --local -m "List all files in the current directory and check disk space" --session-id file_audit
openclaw agent --agent main --local -m "Read the contents of /etc/os-release and summarize the distribution info" --session-id os_info
```

### Hardware Monitoring
```bash
openclaw agent --agent main --local -m "Check if nvidia-smi is installed; if yes, return the GPU name and memory usage" --session-id gpu_check
openclaw agent --agent main --local -m "Inspect /proc/meminfo and describe available memory and swap usage" --session-id mem_info
```

### Network Diagnostics
```bash
openclaw agent --agent main --local -m "Detect and return the Windows host IP from WSL and tell me if Ollama is reachable at port 11434" --session-id network_test
openclaw agent --agent main --local -m "Inspect the current WSL network route, find the default gateway, and verify connectivity to the Windows host" --session-id route_check
```

### Configuration Audit
```bash
openclaw agent --agent main --local -m "Run 'ls -la ~/.nemoclaw' and tell me whether credentials.json exists and is readable" --session-id config_check
openclaw agent --agent main --local -m "Read the current bash configuration from ~/.bashrc and identify the NemoClaw startup block" --session-id bashrc_check
```

## Maintenance Commands

### Update Windows IP (if network changes)

```bash
./wsl_nemoclaw_autoupdate.sh
```

### Check Gateway Status

```bash
openshell gateway list
openshell gateway status --name nemoclaw
```

### View Logs

```bash
openshell gateway logs --name nemoclaw
openshell doctor logs --name nemoclaw
```

### Restart Services

```bash
openshell gateway destroy --name nemoclaw
openshell gateway start --name nemoclaw --gpu
```

## Troubleshooting

### "Docker is not running" Error

**Cause**: Podman socket not accessible or Docker command not available.

**Solution**:
1. Ensure Podman Desktop is running on Windows
2. Verify socket bridge: `ls -la /var/run/docker.sock`
3. Check Podman machine: `podman machine list` (on Windows)

### Wrong Windows IP Detected

**Cause**: Virtual adapter IP selected instead of physical adapter.

**Solution**:
- The setup script now excludes virtual adapters automatically
- Manual override: `./wsl_nemoclaw_autoupdate.sh`
- Check adapters: `powershell.exe Get-NetIPAddress -AddressFamily IPv4`

### Ollama Connection Failed

**Cause**: Firewall blocking or wrong IP/port.

**Solution**:
1. Verify Ollama is running on Windows
2. Check firewall: `Set-NetFirewallRule -DisplayName "Ollama" -RemoteAddress Any`
3. Test connectivity: `curl http://<windows-ip>:11434/api/tags`

### Gateway Startup Failed

**Cause**: Leftover containers or network conflicts.

**Solution**:
```bash
openshell gateway destroy --name nemoclaw
# Clean up any leftover networks/containers on Windows Podman
openshell gateway start --name nemoclaw --gpu
```

### Agent Commands Fail

**Cause**: Not connected to sandbox or OpenClaw not available.

**Solution**:
1. Connect to sandbox: `nemoclaw <sandbox-name> connect`
2. Verify OpenClaw: `which openclaw`
3. Check sandbox status: `openshell sandbox list`

## Configuration Files

### ~/.nemoclaw/credentials.json
```json
{
  "provider": "ollama",
  "ollama": {
    "host": "http://<windows-ip>:11434",
    "model": "qwen2.5-coder:14b-instruct-q4_K_M"
  }
}
```

### ~/.bashrc (auto-generated)
```bash
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
```

## Performance Optimization

### GPU Configuration
- Ensure GPU passthrough is enabled in WSL2
- Use `--gpu` flag when starting gateway
- Monitor temperatures: `nvidia-smi`

### Memory Management
- 14B model requires significant VRAM
- Monitor usage: `nvidia-smi --query-gpu=memory.used,memory.total --format=csv`
- Consider model quantization for lower memory usage

### Network Optimization
- Keep WSL and Windows on same network segment
- Avoid VPNs that might interfere with local networking
- Use wired connection for better stability

## Security Considerations

- NemoClaw runs in sandboxed environment
- OpenShell provides additional security layers
- Credentials stored with restricted permissions (600)
- Network policies limit agent capabilities

## Support and Resources

- **NemoClaw Documentation**: https://docs.nvidia.com/nemoclaw/
- **OpenShell Documentation**: https://github.com/NVIDIA/OpenShell
- **Community Discord**: https://discord.gg/XFpfPv9Uvx
- **GitHub Issues**: https://github.com/NVIDIA/NemoClaw/issues

## Quick Start Checklist

- [ ] Windows: Install Podman Desktop and Ollama
- [ ] Windows: Configure Ollama for network access
- [ ] Windows: Start Podman machine in rootful mode
- [ ] WSL: Run `./setup_nemoclaw.sh`
- [ ] WSL: Run `nemoclaw onboard`
- [ ] WSL: Connect to sandbox with `nemoclaw <name> connect`
- [ ] WSL: Start dashboard with `streamlit run nemo_gui.py`
- [ ] Windows: Open `http://127.0.0.1:8501` in browser
- [ ] Test agent commands in the chat interface

## Advanced Configuration

### Custom Models
Edit `~/.nemoclaw/credentials.json` to change the Ollama model:
```json
{
  "provider": "ollama",
  "ollama": {
    "host": "http://192.168.29.86:11434",
    "model": "your-custom-model"
  }
}
```

### Multiple Sandboxes
Create additional sandboxes with different configurations:
```bash
nemoclaw onboard  # Creates another sandbox
nemoclaw list     # Shows all sandboxes
```

### Network Policies
Customize sandbox security policies:
```bash
openshell policy list --sandbox <name>
openshell policy add --sandbox <name> --type network --allow <rule>
```</content>
<parameter name="filePath">/home/suryakumaran/nemoclaw-podman-wsl2/agent.md