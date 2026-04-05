import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlparse

import streamlit as st

CONFIG_PATH = Path.home() / ".nemoclaw" / "credentials.json"


def command_exists(command):
    return shutil.which(command) is not None


def run_cmd(cmd, timeout=60, shell=True):
    env = os.environ.copy()
    env["DOCKER_HOST"] = "unix:///var/run/docker.sock"
    if shell:
        cmd = f"/bin/bash -lc {shlex.quote(cmd)}"
    result = subprocess.run(
        cmd,
        shell=shell,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    return result.returncode, stdout, stderr


def run_cmd_list(cmd_list, timeout=60):
    env = os.environ.copy()
    env["DOCKER_HOST"] = "unix:///var/run/docker.sock"
    result = subprocess.run(
        cmd_list,
        shell=False,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    return result.returncode, stdout, stderr


def run_cmd_no_shell(cmd_list, timeout=60):
    env = os.environ.copy()
    env["DOCKER_HOST"] = "unix:///var/run/docker.sock"
    result = subprocess.run(
        cmd_list,
        shell=False,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    stdout = result.stdout.strip()
    stderr = result.stderr.strip()
    return result.returncode, stdout, stderr


def parse_host_from_url(host):
    if not host:
        return ""
    host = host.strip()
    if host.startswith("http://") or host.startswith("https://"):
        parsed = urlparse(host)
        return parsed.hostname or ""
    if ":" in host:
        return host.split(":")[0]
    return host


def get_windows_host_ips():
    ips = []
    rc, out, _ = run_cmd("ip route | awk '/default/ {print $3; exit}'")
    if rc == 0 and out:
        ips.append(out.strip())

    rc, out, _ = run_cmd_list(
        [
            "powershell.exe",
            "-NoProfile",
            "-Command",
            "& { Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169|127)' } | Select-Object -ExpandProperty IPAddress }",
        ]
    )
    if rc == 0 and out:
        for line in out.splitlines():
            ip = line.strip()
            if ip and ip not in ips:
                ips.append(ip)

    return ips


def find_best_ollama_host():
    candidates = get_windows_host_ips()
    for ip in candidates:
        test_host = f"http://{ip}:11434"
        healthy, _ = check_ollama_health(test_host)
        if healthy:
            return test_host, candidates, f"Detected Ollama at {ip}"
    return (f"http://{candidates[0]}:11434" if candidates else "", candidates, "No reachable Ollama host detected")


def is_ollama_reachable(host_ip):
    rc, out, _ = run_cmd(f"curl -s --max-time 2 http://{host_ip}:11434/api/tags")
    return rc == 0 and '"models"' in out


def get_default_win_ip():
    for ip in get_windows_host_ips():
        if is_ollama_reachable(ip):
            return ip
    rc, out, err = run_cmd("ip route | awk '/default/ {print $3; exit}'")
    return out.strip() if rc == 0 and out else ""


def read_config():
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except json.JSONDecodeError:
            return None
    return None


def write_config(host, model):
    payload = {
        "provider": "ollama",
        "ollama": {
            "host": host,
            "model": model,
        },
    }
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(payload, indent=2))
    return payload


def check_ollama_health(host):
    if not host:
        return False, "Ollama host is empty."
    if not host.startswith("http"):
        host = "http://" + host
    paths = ["/api/tags", "/v1/tags", "/v1/models"]
    for path in paths:
        cmd = f"curl -s --max-time 5 {host.rstrip('/')}{path}"
        rc, out, err = run_cmd(cmd)
        if rc != 0:
            continue
        if not out:
            continue
        if path.endswith("/api/tags"):
            try:
                data = json.loads(out)
                return True, json.dumps(data, indent=2)
            except Exception:
                return False, out
        if path.endswith("/v1/tags") or path.endswith("/v1/models"):
            try:
                data = json.loads(out)
                return True, json.dumps(data, indent=2)
            except Exception:
                return True, out
    return False, err or out or "curl failed"


def gateway_status():
    if not command_exists("openshell"):
        return "unknown", "OpenShell not installed or not in PATH. Install OpenShell in WSL before using gateway commands."

    rc, out, err = run_cmd("openshell gateway info --name nemoclaw")
    if rc == 0:
        return "running", out.strip() or "Gateway is running"

    err_text = err.strip() or out.strip() or "Failed to query gateway status"
    if "unrecognized subcommand 'info'" in err_text or "unrecognized command 'info'" in err_text:
        rc, out, err = run_cmd("openshell gateway list")
        if rc == 0:
            lines = [line for line in out.splitlines() if line.strip()]
            for line in lines:
                if "nemoclaw" in line:
                    if "Healthy" in line or "healthy" in line:
                        return "running", line.strip()
                    return "stopped", line.strip()
            return "stopped", "Named gateway not found"
        err_text = err.strip() or out.strip() or "Failed to query gateway status"
        if "unrecognized subcommand 'list'" in err_text or "unrecognized command 'list'" in err_text:
            return "unknown", "Gateway list unsupported by this OpenShell version. Use the Start Gateway button or update OpenShell."

    return "unknown", err_text


def detect_exec_support():
    if not command_exists("openshell"):
        return False, "OpenShell not installed or not in PATH. Install it in WSL."

    rc, out, err = run_cmd("openshell exec --help")
    if rc == 0:
        return True, "openshell exec supported"
    message = err.strip() or out.strip()
    if "unrecognized subcommand 'exec'" in message or "unrecognized command 'exec'" in message:
        return False, "OpenShell does not support exec on this version. Use direct shell commands or update OpenShell."
    return False, message or "openshell exec not supported"


def run_system_health(win_ip, host):
    try:
        checks = {}
        checks["gateway"], checks["gateway_msg"] = gateway_status()
        healthy, message = check_ollama_health(host)
        checks["ollama"] = "ok" if healthy else "fail"
        checks["ollama_msg"] = message
        rc, out, err = list_providers()
        checks["providers"] = "ok" if rc == 0 else "fail"
        checks["providers_msg"] = out or err
        rc, out, err = list_sandboxes()
        checks["sandboxes"] = "ok" if rc == 0 else "fail"
        checks["sandboxes_msg"] = out or err
        healthy, gpu_data = query_nvidia()
        checks["gpu"] = "ok" if healthy else "warn"
        checks["gpu_msg"] = gpu_data
        checks["exec_support"], checks["exec_msg"] = detect_exec_support()
        return checks
    except Exception as e:
        return {
            "gateway": "error",
            "gateway_msg": f"Exception during health check: {str(e)}",
            "ollama": "error",
            "ollama_msg": f"Exception during health check: {str(e)}",
            "providers": "error",
            "providers_msg": f"Exception during health check: {str(e)}",
            "sandboxes": "error",
            "sandboxes_msg": f"Exception during health check: {str(e)}",
            "gpu": "error",
            "gpu_msg": f"Exception during health check: {str(e)}",
            "exec_support": False,
            "exec_msg": f"Exception during health check: {str(e)}",
        }


def list_providers():
    if not command_exists("openshell"):
        return 127, "", "OpenShell not installed or not in PATH."
    return run_cmd("openshell provider list")


def list_sandboxes():
    if not command_exists("openshell"):
        return 127, "", "OpenShell not installed or not in PATH."
    return run_cmd("openshell sandbox list")


def run_gateway_start():
    if not command_exists("openshell"):
        return 127, "", "OpenShell not installed or not in PATH."

    rc, out, err = run_cmd("openshell gateway start --name nemoclaw --gpu")
    if rc != 0 and ("unrecognized option '--gpu'" in err or "unknown option '--gpu'" in err):
        return run_cmd("openshell gateway start --name nemoclaw")
    return rc, out, err


def run_gateway_stop():
    if not command_exists("openshell"):
        return 127, "", "OpenShell not installed or not in PATH."
    return run_cmd("openshell gateway stop --name nemoclaw")


def run_nemoclaw_start():
    if not command_exists("nemoclaw"):
        return 127, "", "nemoclaw CLI not installed or not in PATH."
    return run_cmd("nemoclaw start")


def run_nemoclaw_stop():
    if not command_exists("nemoclaw"):
        return 127, "", "nemoclaw CLI not installed or not in PATH."
    return run_cmd("nemoclaw stop")


def run_setup_script():
    return run_cmd("bash ./setup_nemoclaw.sh", timeout=300)


def run_start_sequence():
    gateway_rc, gateway_out, gateway_err = run_gateway_start()
    nemoclaw_rc, nemoclaw_out, nemoclaw_err = run_nemoclaw_start()
    out = "Gateway output:\n" + (gateway_out or gateway_err or "(no output)")
    out += "\n\nNemoClaw output:\n" + (nemoclaw_out or nemoclaw_err or "(no output)")
    err = "".join([gateway_err or "", "\n", nemoclaw_err or ""]).strip()
    rc = 0 if gateway_rc == 0 and nemoclaw_rc == 0 else 1
    return rc, out, err


def run_chat(prompt, ollama_host, model):
    """Send prompt directly to Ollama REST API. No sandbox or openclaw required."""
    if not prompt:
        return 1, "", "Prompt is empty"

    host = (ollama_host or "").rstrip("/")
    if not host:
        return 1, "", "Ollama host not configured. Set it in the sidebar and save."

    model = model or "qwen2.5-coder:14b-instruct-q4_K_M"

    # Try /api/chat (conversational endpoint)
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    })
    cmd = f"curl -s --max-time 120 -X POST {host}/api/chat -H 'Content-Type: application/json' -d {shlex.quote(payload)}"
    rc, out, err = run_cmd(cmd, timeout=130)
    if rc == 0 and out:
        try:
            data = json.loads(out)
            msg = data.get("message", {})
            if isinstance(msg, dict) and "content" in msg:
                return 0, msg["content"], ""
            if "response" in data:
                return 0, data["response"], ""
        except json.JSONDecodeError:
            return 0, out, ""

    # Fallback: /api/generate
    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
    })
    cmd = f"curl -s --max-time 120 -X POST {host}/api/generate -H 'Content-Type: application/json' -d {shlex.quote(payload)}"
    rc, out, err = run_cmd(cmd, timeout=130)
    if rc == 0 and out:
        try:
            data = json.loads(out)
            return 0, data.get("response", out), ""
        except json.JSONDecodeError:
            return 0, out, ""

    return rc, out or "", err or "Ollama request failed. Check the host and model in the sidebar."


def create_sandbox(sandbox_name, win_ip, model):
    """Register Ollama as an OpenShell provider and create a sandbox.
    OpenShell has no native 'ollama' type; Ollama exposes an OpenAI-compatible
    API at /v1, so we register it as type 'openai' with a custom base_url.
    """
    if not command_exists("openshell"):
        return 1, "", "OpenShell not installed or not in PATH."

    rc, out, _ = run_cmd("openshell sandbox list")
    if rc == 0 and sandbox_name in out:
        return 0, f"Sandbox '{sandbox_name}' already exists.", ""

    # Register provider (idempotent — errors silently if already exists)
    run_cmd(
        f"openshell provider create --name ollama-local --type openai"
        f" --credential OPENAI_API_KEY=ollama"
        f" --config base_url=http://{win_ip}:11434/v1"
    )

    # Set gateway inference to use this provider
    run_cmd(
        f"openshell inference set --provider ollama-local"
        f" --model {shlex.quote(model)} --no-verify"
    )

    # Create OpenClaw sandbox backed by the provider
    rc, out, err = run_cmd(
        f"openshell sandbox create --name {shlex.quote(sandbox_name)}"
        f" --from openclaw --provider ollama-local"
    )
    if rc != 0:
        # Fallback: try without --from openclaw
        rc, out, err = run_cmd(
            f"openshell sandbox create --name {shlex.quote(sandbox_name)}"
            f" --provider ollama-local"
        )
    return rc, out, err



def query_nvidia():
    rc, out, err = run_cmd(
        "nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    )
    if rc != 0:
        return False, err or "nvidia-smi unavailable"
    parts = [p.strip() for p in out.split(",")]
    if len(parts) < 4:
        return False, out
    return True, {
        "name": parts[0],
        "memory_used_mb": parts[1],
        "memory_total_mb": parts[2],
        "temperature_c": parts[3],
    }


def quick_action(action_name):
    if action_name == "Analyze Project":
        return run_cmd("find . -maxdepth 2 -type f | sort | head -n 80")
    if action_name == "Check Git Status":
        return run_cmd("git status --short")
    if action_name == "Generate README":
        output_path = Path("README.generated.md")
        summary = ["# Generated README\n", "## Workspace Files\n"]
        for p in sorted(Path(".").glob("**/*")):
            if p.is_file() and p.name not in {"README.generated.md", "README.md"}:
                summary.append(f"- {p.as_posix()}\n")
        output_path.write_text("".join(summary), encoding="utf-8")
        return 0, f"Generated {output_path.resolve()}", ""
    return 1, "Unknown action", ""


st.set_page_config(page_title="NemoClaw Commander", layout="wide")

st.markdown(
    "<style>body { background-color: #020202; color: #c8ff7c; }"
    "div.block-container { padding: 1rem 2rem 2rem; }</style>",
    unsafe_allow_html=True,
)

st.title("🦾 NemoClaw Commander (RTX 5070 Ti)")

st.session_state.setdefault("last_output", "")
st.session_state.setdefault("messages", [])
st.session_state.setdefault("prompt", "")
st.session_state.setdefault("custom_cmd", "openshell status")
st.session_state.setdefault("system_check", None)
st.session_state.setdefault("startup_check", None)

config = read_config() or {}
ollama_config = config.get("ollama", {})
best_host, host_candidates, host_message = find_best_ollama_host()
saved_host = ollama_config.get("host")
if saved_host:
    saved_ok, _ = check_ollama_health(saved_host)
    default_host = saved_host if saved_ok else best_host or saved_host
else:
    default_host = best_host

default_model = ollama_config.get("model") or "gemma4:e4b"
default_win_ip = parse_host_from_url(default_host)

openshell_available = command_exists("openshell")
nemo_available = command_exists("nemoclaw")

if st.session_state.startup_check is None:
    st.session_state.startup_check = run_system_health(default_win_ip, default_host)

with st.sidebar:
    st.header("Connection Manager")
    st.markdown("**Environment:** WSL2 Ubuntu")
    st.write("OpenShell in PATH:", "yes" if openshell_available else "no")
    st.write("NemoClaw CLI in PATH:", "yes" if nemo_available else "no")
    if not openshell_available:
        st.warning("OpenShell is not installed or not available in WSL PATH.")
    if not nemo_available:
        st.warning("nemoclaw CLI is not installed or not available in WSL PATH.")

    st.subheader("Startup Health Check")
    check = st.session_state.startup_check
    if check:
        st.write("**Gateway:**", check["gateway"], check["gateway_msg"])
        st.write("**Ollama:**", check["ollama"], check["ollama_msg"])
        st.write("**Providers:**", check["providers"], check["providers_msg"])
        st.write("**Sandboxes:**", check["sandboxes"], check["sandboxes_msg"])
        st.write("**GPU:**", check["gpu"], check["gpu_msg"])
        st.write("**OpenShell exec support:**", "yes" if check["exec_support"] else "no (agent -m works)")
        if not check["exec_support"]:
            st.info("Agent commands available via 'agent -m' in chat panel.")
    else:
        st.info("Running startup environment validation...")

    win_ip = st.text_input("Windows Host IP", value=default_win_ip)
    ollama_host = st.text_input("OLLAMA_HOST", value=default_host)
    model_options = ["gemma4:e4b", "qwen2.5-coder:14b-instruct-q4_K_M"]
    model_index = model_options.index(default_model) if default_model in model_options else 0
    model = st.selectbox("Ollama Model", model_options, index=model_index)
    if host_candidates:
        st.markdown(f"**Detected Windows host candidates:** {', '.join(host_candidates)}")
        st.markdown(f"**Recommended Ollama host:** {best_host or 'none detected'}")
    if st.button("Save Ollama Config"):
        payload = write_config(ollama_host, model)
        st.success("Saved NemoClaw credentials.json")
        st.json(payload)
    if st.button("Check Ollama Health"):
        healthy, message = check_ollama_health(ollama_host)
        if healthy:
            st.success("Ollama is reachable")
            st.code(message)
        else:
            st.error("Ollama health check failed")
            st.code(message)

    st.markdown("---")
    st.header("Sandbox & Gateway")
    status, status_msg = gateway_status()
    if status == "running":
        st.success("Sandbox Gateway: running")
        st.write(status_msg)
    elif status == "stopped":
        st.error("Sandbox Gateway: stopped")
        st.write(status_msg)
    else:
        st.warning("Sandbox Gateway: unknown")
        st.write(status_msg)

    if st.button("Start Gateway"):
        rc, out, err = run_gateway_start()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("Gateway start requested")
        else:
            st.error("Gateway start failed")

    if st.button("Stop Gateway"):
        rc, out, err = run_gateway_stop()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("Gateway stop requested")
        else:
            st.error("Gateway stop failed")

    ui_host = parse_host_from_url(ollama_host) or win_ip
    ui_url = f"http://{ui_host}:18789" if ui_host else ""
    if ui_url:
        st.markdown(
            f'<a href="{ui_url}" target="_blank" style="display:inline-block;padding:0.55rem 0.9rem;background:#4F8AFF;color:#ffffff;border-radius:0.4rem;text-decoration:none;font-weight:600;">Open Official NemoClaw Web UI</a>',
            unsafe_allow_html=True,
        )
        st.info(f"Open this URL from Windows: {ui_url}")
    else:
        st.warning("Unable to detect a Windows host IP. Enter it manually above.")

    if st.button("Start NemoClaw Service"):
        rc, out, err = run_nemoclaw_start()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("NemoClaw service start requested")
        else:
            st.error("NemoClaw start failed")

    if st.button("Stop NemoClaw Service"):
        rc, out, err = run_nemoclaw_stop()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("NemoClaw stop requested")
        else:
            st.error("NemoClaw stop failed")

    st.markdown("---")
    st.header("Quick Start")
    if st.button("Run Setup Script"):
        rc, out, err = run_setup_script()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("Setup script completed")
        else:
            st.error("Setup script failed")

    if st.button("Start Gateway + Service"):
        rc, out, err = run_start_sequence()
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("Gateway and NemoClaw started")
        else:
            st.error("Start sequence failed")
            st.code(err)

    if st.button("Run Full System Check"):
        st.session_state.system_check = run_system_health(win_ip, ollama_host)

    if st.session_state.system_check is not None:
        check = st.session_state.system_check
        st.write("**Gateway:**", check["gateway"], check["gateway_msg"])
        st.write("**Ollama:**", check["ollama"], check["ollama_msg"])
        st.write("**Providers:**", check["providers"], check["providers_msg"])
        st.write("**Sandboxes:**", check["sandboxes"], check["sandboxes_msg"])
        st.write("**GPU:**", check["gpu"], check["gpu_msg"])
        st.write("**OpenShell exec support:**", "yes" if check["exec_support"] else "no (agent -m works)")
        if not check["exec_support"]:
            st.info("Agent commands available via 'agent -m' in chat panel.")

    st.markdown("---")
    st.header("OpenShell Control")
    if st.button("List Providers"):
        rc, out, err = list_providers()
        st.session_state.last_output = out or err
        st.code(out or err)
    if st.button("List Sandboxes"):
        rc, out, err = list_sandboxes()
        st.session_state.last_output = out or err
        st.code(out or err)
    sandbox_name_input = st.text_input("Sandbox Name", value="nemoclaw-ollama")
    if st.button("Create Sandbox"):
        rc, out, err = create_sandbox(sandbox_name_input, win_ip, model)
        st.session_state.last_output = out or err
        if rc == 0:
            st.success(f"Sandbox ready: {sandbox_name_input}")
            st.code(out or "(sandbox exists or was created)")
        else:
            st.error("Sandbox creation failed")
            st.code(err or out)
    if st.button("Refresh Gateway Status"):
        status, status_msg = gateway_status()
        st.session_state.last_output = status_msg
        st.info(status_msg)
    if st.button("Check Gateway Health"):
        rc, out, err = run_cmd("openshell gateway list")
        st.session_state.last_output = out or err
        if rc == 0:
            st.success("Gateway list retrieved")
            st.code(out)
        else:
            st.error("Failed to get gateway list")
            st.code(err or out)

    st.markdown("---")
    st.header("Quick Actions")
    action = st.selectbox("Action", ["Analyze Project", "Check Git Status", "Generate README"])
    if st.button("Run Action"):
        rc, out, err = quick_action(action)
        st.session_state.last_output = out or err
        if rc == 0:
            st.success(f"{action} completed")
            st.code(out or "(no output)")
        else:
            st.error(f"{action} failed")
            st.code(err or out)

cols = st.columns([2, 1])

with cols[0]:
    st.subheader("Chat Interface")

    # Chat uses direct Ollama API — no openclaw or sandbox required
    ollama_ok, _ = check_ollama_health(ollama_host)
    if ollama_ok:
        st.success(f"✅ Ollama reachable at `{ollama_host}` — chat is ready.")
    else:
        st.error(
            f"⚠️ **Ollama not reachable at {ollama_host}**  \n"
            "Check the host in the sidebar and ensure Ollama is running on Windows."
        )

    exec_supported, exec_msg = detect_exec_support()
    if exec_supported:
        st.success("OpenShell exec is available for direct shell commands.")
    else:
        st.info("OpenShell exec unavailable, but agent commands work via 'agent -m'.")
        st.info("Use the 'Open Official Web UI' button for full agent chat interface.")

    examples = {
        "Todo App Builder": ("agent", "Create a complete Todo app in Python using Streamlit. Include full code for app.py, requirements.txt, and one example task."),
        "Research Document": ("agent", "Research the current state of multimodal LLMs, summarize the findings, and produce a short report with headings and recommendations."),
        "OS & Environment Check": ("agent", "Run the command: uname -a && echo '---' && env | grep -E 'OLLAMA_HOST|DOCKER_HOST|PATH'"),
        "GPU Health Summary": ("agent", "Run the command: nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"),
        "NemoClaw Config Audit": ("agent", "Run the command: test -f ~/.nemoclaw/credentials.json && echo 'config exists' && cat ~/.nemoclaw/credentials.json"),
        "Windows Host Connectivity": ("agent", "Run the command: ip route | awk '/default/ {print $3; exit}' && curl -s --max-time 5 http://$(ip route | awk '/default/ {print $3; exit}'):11434/v1/tags")
    }

    st.markdown("**Example Prompts & Commands**")
    example_choice = st.selectbox("Choose a prebuilt example", list(examples.keys()))
    if st.button("Load Example"):
        example_type, example_text = examples[example_choice]
        st.session_state.prompt = example_text

    prompt = st.text_input("Send a command to NemoClaw", key="prompt")
    if st.button("Send to Agent"):
        if prompt:
            st.session_state.messages.append({"role": "user", "content": prompt})
            rc, out, err = run_chat(prompt, ollama_host, model)
            st.session_state.messages.append({"role": "assistant", "content": out or err or "Command executed"})

    for message in st.session_state.messages:
        if message["role"] == "user":
            st.markdown(f"**You:** {message['content']}")
        else:
            st.markdown(f"**Agent:** {message['content']}")

    st.markdown("---")
    st.subheader("Custom OpenShell / Shell Command")
    custom_cmd = st.text_input("Command", key="custom_cmd")
    if st.button("Run Custom Command"):
        if custom_cmd:
            rc, out, err = run_cmd(custom_cmd)
            st.session_state.last_output = out or err
            if rc == 0:
                st.success("Command executed")
                st.code(out or "(no output)")
            else:
                st.error("Command failed")
                st.code(err or out)

with cols[1]:
    st.subheader("Hardware Monitor")
    healthy, gpu_data = query_nvidia()
    if healthy:
        st.metric("GPU", gpu_data["name"])
        st.metric("VRAM Used (MB)", gpu_data["memory_used_mb"])
        st.metric("VRAM Total (MB)", gpu_data["memory_total_mb"])
        st.metric("Temp (°C)", gpu_data["temperature_c"])
    else:
        st.warning("nvidia-smi unavailable in WSL")
        st.info(gpu_data)

st.markdown("---")

st.subheader("Last Output")
st.code(st.session_state.last_output or "No command output yet.")

st.markdown("---")
st.write("**Note:** All commands are executed with `DOCKER_HOST=unix:///var/run/docker.sock`. Ensure the Podman socket is bridged and Ollama is reachable from WSL.")
