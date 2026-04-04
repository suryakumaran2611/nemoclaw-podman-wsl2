import json
import os
import subprocess
from pathlib import Path

import streamlit as st

CONFIG_PATH = Path.home() / ".nemoclaw" / "credentials.json"


def run_cmd(cmd, timeout=60, shell=True):
    env = os.environ.copy()
    env["DOCKER_HOST"] = "unix:///var/run/docker.sock"
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


def get_default_win_ip():
    rc, out, err = run_cmd("ip route | awk '/default/ {print $3; exit}'")
    if rc != 0 or not out:
        return ""
    return out.strip()


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
    cmd = f"curl -s --max-time 5 {host}/v1/tags"
    rc, out, err = run_cmd(cmd)
    if rc != 0:
        return False, err or out or "curl failed"
    try:
        data = json.loads(out)
        return True, json.dumps(data, indent=2)
    except Exception:
        return True, out


def gateway_status():
    rc, out, err = run_cmd("openshell gateway list")
    if rc != 0:
        return "unknown", err or "Failed to query gateway status"
    lines = [line for line in out.splitlines() if line.strip()]
    for line in lines:
        if "nemoclaw" in line:
            if "Healthy" in line or "healthy" in line:
                return "running", line.strip()
            return "stopped", line.strip()
    return "stopped", "Named gateway not found"


def list_providers():
    return run_cmd("openshell provider list")


def list_sandboxes():
    return run_cmd("openshell sandbox list")


def run_gateway_start():
    return run_cmd("openshell gateway start --name nemoclaw --gpu")


def run_gateway_stop():
    return run_cmd("openshell gateway stop --name nemoclaw")


def run_nemoclaw_start():
    return run_cmd("nemoclaw start")


def run_nemoclaw_stop():
    return run_cmd("nemoclaw stop")


def run_chat(prompt):
    if not prompt:
        return 1, "", "Prompt is empty"
    command = ["openshell", "exec", "--name", "nemoclaw", "agent", "-m", prompt]
    return run_cmd_list(command, timeout=120)


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

if "last_output" not in st.session_state:
    st.session_state.last_output = ""
if "messages" not in st.session_state:
    st.session_state.messages = []

config = read_config() or {}
ollama_config = config.get("ollama", {})
default_host = ollama_config.get("host") or f"http://{get_default_win_ip()}:11434"
default_model = ollama_config.get("model") or "qwen2.5-coder:14b-instruct-q4_K_M"

with st.sidebar:
    st.header("Connection Manager")
    win_ip = st.text_input("Windows Host IP", value=get_default_win_ip())
    ollama_host = st.text_input("OLLAMA_HOST", value=default_host)
    model = st.selectbox(
        "Ollama Model",
        ["qwen2.5-coder:14b-instruct-q4_K_M", "gemma4:e4b"],
        index=0 if default_model.startswith("qwen2.5") else 1,
    )
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
    st.header("OpenShell Control")
    if st.button("List Providers"):
        rc, out, err = list_providers()
        st.session_state.last_output = out or err
        st.code(out or err)
    if st.button("List Sandboxes"):
        rc, out, err = list_sandboxes()
        st.session_state.last_output = out or err
        st.code(out or err)
    if st.button("Refresh Gateway Status"):
        status, status_msg = gateway_status()
        st.session_state.last_output = status_msg
        st.info(status_msg)

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
    prompt = st.text_input("Send a command to NemoClaw", "")
    if st.button("Send to Agent"):
        if prompt:
            st.session_state.messages.append({"role": "user", "content": prompt})
            rc, out, err = run_chat(prompt)
            if rc == 0:
                st.session_state.messages.append({"role": "assistant", "content": out})
            else:
                st.session_state.messages.append({"role": "assistant", "content": err or out})

    for message in st.session_state.messages:
        if message["role"] == "user":
            st.markdown(f"**You:** {message['content']}")
        else:
            st.markdown(f"**Agent:** {message['content']}")

    st.markdown("---")
    st.subheader("Custom OpenShell Command")
    custom_cmd = st.text_input("Command", "openshell status")
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
