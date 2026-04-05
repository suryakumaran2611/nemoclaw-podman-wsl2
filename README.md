# NemoClaw: WSL2 + Windows Podman + Windows Ollama

**Target Hardware:** MSI Vector (RTX 5070 Ti / 12GB VRAM)  
**Environment:** WSL2 Ubuntu · Rootful Podman on Windows · Ollama on Windows

## Architecture

```
Windows Host
├── Podman Desktop (rootful)   ← container runtime
│   └── socket: /mnt/wsl/podman-sockets/podman-machine-default/podman-root.sock
└── Ollama (listening on 0.0.0.0:11434)  ← AI model server

WSL2 Ubuntu
├── /var/run/docker.sock  ← symlink → Podman rootful socket (no Docker installed)
├── DOCKER_HOST=unix:///var/run/docker.sock
├── ~/.nemoclaw/credentials.json  ← Ollama host + model
├── nemoclaw / openshell CLIs
└── Streamlit GUI (nemo_gui.py)  ← talks directly to Ollama REST API
```

There is **no Docker** in this setup. All container operations go through the
Podman rootful socket bridged to `/var/run/docker.sock`.

---

## File Inventory

| File | Purpose |
|------|---------|
| `setup_nemoclaw.sh` | One-time setup: socket bridge, credentials, auto-IP update in bashrc, sandbox creation |
| `start_nemoclaw.sh` | Daily startup: bridge socket, start gateway + NemoClaw service |
| `simple_onboard.sh` | Automated sandbox creation via OpenShell (no interactive prompts) |
| `wsl_nemoclaw_autoupdate.sh` | Refresh Windows host IP in credentials.json when WSL restarts |
| `test_sandbox.sh` | End-to-end sandbox + Ollama test suite |
| `nemo_gui.py` | Streamlit dashboard — chat, gateway control, health checks |
| `requirements.txt` | Python deps for nemo_gui.py |

---

## 1. Windows Host Preparation

### 1a. Ollama

Open PowerShell (does not require Admin):

```powershell
# Allow Ollama to listen on all interfaces
[System.Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0', 'User')
```

Open PowerShell **as Administrator**:

```powershell
# Open firewall for WSL2 to reach Ollama
Set-NetFirewallRule -DisplayName "Ollama" -RemoteAddress Any
```

Fully quit and restart the Ollama app after changing the environment variable.

### 1b. Podman

NemoClaw requires **rootful** Podman so it can manage its internal K3s network.
Run these commands in Windows PowerShell or the Podman Desktop terminal:

```bash
podman machine stop
podman machine set --rootful
podman machine start
```

---

## 2. WSL2 First-Time Setup

```bash
# Clone or copy the repo files into WSL
chmod +x setup_nemoclaw.sh start_nemoclaw.sh simple_onboard.sh \
         wsl_nemoclaw_autoupdate.sh test_sandbox.sh

# Install Python dependencies (uses venv)
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## 3. setup_nemoclaw.sh

Run once after cloning. Run again any time the Podman socket changes.

```bash
./setup_nemoclaw.sh
```

What it does, in order:

1. **Verifies** the Podman rootful socket exists at  
   `/mnt/wsl/podman-sockets/podman-machine-default/podman-root.sock`
2. **Bridges** it to `/var/run/docker.sock` so NemoClaw and OpenShell treat it
   as a Docker-compatible socket
3. **Detects** the correct Windows host IP using PowerShell, excluding virtual
   adapters (`vEthernet`, `WSL`, `Hyper-V`)
4. **Writes** `~/.nemoclaw/credentials.json` with the Ollama host and model
5. **Seeds** `~/.bashrc` with `DOCKER_HOST`, a `docker=podman` alias, and an
   `update_nemoclaw_ip()` function that refreshes the IP on every new shell
6. **Creates** the OpenShell sandbox automatically (if `openshell` is available):
   - Registers `ollama-local` provider pointing at the detected Ollama host
   - Creates `nemoclaw-ollama` sandbox backed by that provider

---

## 4. simple_onboard.sh

If the sandbox was not created by `setup_nemoclaw.sh` (e.g. the gateway was not
running yet), run this script after `./start_nemoclaw.sh`:

```bash
./simple_onboard.sh             # creates sandbox named "nemoclaw-ollama"
./simple_onboard.sh my-sandbox  # custom sandbox name
```

What it does:

1. Reads host and model from `~/.nemoclaw/credentials.json`
2. Tests Ollama connectivity (warns but continues if unreachable)
3. Registers `ollama-local` provider with OpenShell (idempotent)
4. Creates the named sandbox — falls back to provider-less creation if needed
5. Lists current sandboxes to confirm success

---

## 5. Daily Startup (start_nemoclaw.sh)

```bash
./start_nemoclaw.sh
```

- Sets `DOCKER_HOST`
- Starts `openshell gateway --name nemoclaw --gpu`
- Starts `nemoclaw start`
- Drops into `openshell term` (interactive sandbox shell) — **this blocks the terminal**

Because `start_nemoclaw.sh` opens `openshell term` at the end, open a **second WSL terminal** to run the Streamlit dashboard:

Then start the Streamlit dashboard:

```bash
source .venv/bin/activate
streamlit run nemo_gui.py --server.headless true --server.port 8501
```

Open in the **Windows browser** (not WSL browser):

```
http://127.0.0.1:8501
```

---

## 6. wsl_nemoclaw_autoupdate.sh

WSL2 assigns a new IP to the Windows host after every reboot. Run this script
to refresh `credentials.json` without re-running the full setup:

```bash
./wsl_nemoclaw_autoupdate.sh
```

The `~/.bashrc` block added by `setup_nemoclaw.sh` also calls
`update_nemoclaw_ip()` automatically every time a new shell opens, so manual
execution is only needed if you want to refresh mid-session.

---

## 7. test_sandbox.sh

Runs a full end-to-end test of the stack and prints colour-coded `[PASS]` /
`[FAIL]` for each check.

```bash
./test_sandbox.sh                # tests sandbox "nemoclaw-ollama"
./test_sandbox.sh my-sandbox     # tests a custom sandbox name
```

**Test sections:**

| # | Section | What is checked |
|---|---------|-----------------|
| 1 | Prerequisites | `credentials.json`, `openshell`, `nemoclaw` in PATH, Podman socket |
| 2 | Ollama Connectivity | `/api/tags`, model availability, `/api/generate`, `/api/chat` |
| 3 | OpenShell Gateway | `gateway list` works, `nemoclaw` gateway present |
| 4 | OpenShell Provider | `ollama-local` registered |
| 5 | Sandbox | Named sandbox exists in `sandbox list` |
| 6 | Agent Workflow | If `openclaw` is in PATH: basic response, `uname -s` OS command, credentials audit. If not in PATH (normal when running outside sandbox): falls back to an Ollama `/api/chat` call with a real model prompt as a substitute |
| 7 | Environment | `DOCKER_HOST` set correctly, socket readable |

Exit code `0` = all pass. Exit code `1` = failures with quick-fix commands printed.

---

## 8. Streamlit Dashboard (nemo_gui.py)

### Features

- **Connection Manager**: configure `WIN_IP` and `OLLAMA_HOST`, live health check
- **Sandbox & Gateway**: start/stop gateway, start/stop NemoClaw service
- **Create Sandbox**: register Ollama provider and create sandbox in one click
- **Agent Chat**: sends prompts **directly to Ollama REST API** — no `openclaw`
  binary or sandbox connection required
- **Hardware Monitor**: `nvidia-smi` GPU metrics
- **OpenShell Control**: list providers, list sandboxes, gateway status
- **Quick Actions**: project file analysis, git status, README generation

### Chat interface

The chat panel calls `POST /api/chat` (with `/api/generate` fallback) on the
configured Ollama host. It does **not** require the sandbox to be connected or
`openclaw` to be in the WSL PATH. As long as Ollama is running on Windows and
the host IP is correct in the sidebar, the chat works immediately.

### Launching

```bash
source .venv/bin/activate
streamlit run nemo_gui.py --server.headless true --server.port 8501
```

Open `http://127.0.0.1:8501` from a Windows browser. Streamlit runs headless
in WSL — never try to open the browser from the WSL terminal.

---

## 9. Credentials File

`~/.nemoclaw/credentials.json` is the single source of truth for the Ollama
endpoint. All scripts read from and write to this file.

```json
{
  "provider": "ollama",
  "ollama": {
    "host": "http://192.168.29.86:11434",
    "model": "qwen2.5-coder:14b-instruct-q4_K_M"
  }
}
```

Permissions are set to `600` (owner read/write only).

---

## 10. OpenShell Sandbox Management

```bash
openshell gateway list          # list running gateways
openshell provider list         # list registered providers
openshell sandbox list          # list sandboxes

# Manually register Ollama provider
openshell provider add \
  --name ollama-local \
  --type ollama \
  --host http://<windows-ip>:11434 \
  --model qwen2.5-coder:14b-instruct-q4_K_M

# Manually create sandbox
openshell sandbox create --name nemoclaw-ollama --provider ollama-local

# Connect to sandbox
nemoclaw nemoclaw-ollama connect
```

---

## 11. Agent Commands (inside sandbox)

Once connected to the sandbox (`nemoclaw <name> connect`), OpenClaw is
available and you can run agent commands:

```bash
openclaw agent --agent main --local \
  -m "Your prompt here" \
  --session-id my_session
```

**Example prompts:**

```bash
# System info
openclaw agent --agent main --local -m "Run: uname -a" --session-id s1

# GPU status
openclaw agent --agent main --local -m "Run: nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader" --session-id s2

# Credentials audit
openclaw agent --agent main --local -m "Run: cat ~/.nemoclaw/credentials.json" --session-id s3

# Ollama connectivity
openclaw agent --agent main --local -m "Run: curl -s http://\$(ip route | awk '/default/{print \$3}'):11434/api/tags" --session-id s4
```

The dashboard **Create Sandbox** button and `simple_onboard.sh` handle provider
registration and sandbox creation so you can skip directly to `connect`.

---

## 12. Podman as Docker in WSL

The `setup_nemoclaw.sh` script adds this block to `~/.bashrc`:

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
alias docker=podman

update_nemoclaw_ip() {
    local win_ip
    win_ip=$(ip route | awk '/default/ {print $3; exit}')
    if [[ -n "$win_ip" && -f "$HOME/.nemoclaw/credentials.json" ]]; then
        sed -i "s|http://[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:11434|http://$win_ip:11434|g" \
            "$HOME/.nemoclaw/credentials.json"
    fi
}
update_nemoclaw_ip
```

Any Docker-style client in WSL automatically routes to Windows Podman.

---

## 13. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `docker: Cannot connect to Docker daemon` | Re-run `./setup_nemoclaw.sh`; ensure Podman machine is started in rootful mode |
| Ollama health check fails | Confirm `OLLAMA_HOST=0.0.0.0` is set on Windows and Ollama is restarted; check firewall rule |
| Wrong Windows IP detected | Run `./wsl_nemoclaw_autoupdate.sh`; or enter the correct IP manually in the GUI sidebar |
| Gateway start fails | Run `openshell gateway list` to check for stale gateway, then `openshell gateway destroy --name nemoclaw` |
| Sandbox creation fails | Ensure gateway is running first with `./start_nemoclaw.sh`, then run `./simple_onboard.sh` |
| `openclaw: command not found` | Connect to the sandbox first: `nemoclaw nemoclaw-ollama connect` (OpenClaw lives inside the sandbox, not in WSL) |
| Streamlit won't start | Activate the venv: `source .venv/bin/activate` |
| Chat returns no response | Check Ollama host in sidebar and click **Check Ollama Health** |
| GPU not detected | `nvidia-smi` requires CUDA drivers in WSL; GPU metrics degrade gracefully to "unavailable" |

---

## 14. Full Startup Sequence

```bash
# 1. One-time setup (only needed once or after IP changes)
./setup_nemoclaw.sh

# 2. Create sandbox (only needed once, or if gateway wasn't running during setup)
./start_nemoclaw.sh          # start gateway first
./simple_onboard.sh          # create sandbox

# 3. Verify everything is working
./test_sandbox.sh

# 4. Every day
./start_nemoclaw.sh
source .venv/bin/activate
streamlit run nemo_gui.py --server.headless true --server.port 8501
# Open http://127.0.0.1:8501 in Windows browser
```

---

## 15. Hardware Notes (RTX 5070 Ti / 12GB VRAM)

- The `qwen2.5-coder:14b-instruct-q4_K_M` model uses ~8–10 GB VRAM
- GPU passthrough is via NVIDIA's WSL2 driver (no separate install needed)
- Enable Cooler Boost with **Fn + F8** if the laptop exceeds 90 °C
- Windows may throttle the WSL2 instance at 100 °C, causing request timeouts
- Monitor with: `nvidia-smi --query-gpu=temperature.gpu,memory.used --format=csv,noheader`
