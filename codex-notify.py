#!/usr/bin/env python3
"""Codex CLI notify hook -> QuNeo deck state.

Configured in ~/.codex/config.toml (setup.sh does this) as:
  notify = ["python3", "/path/to/quneo-agent-deck/codex-notify.py"]

Codex invokes it with a JSON payload as the last argument on events like
agent-turn-complete. The codex process is our ancestor, so the same
process-tree forensics as hook.py identify the session. Session ids are
"codex-<pid>", matching what the deck's process scanner writes.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hook  # reuse forensics + sound config

STATE = os.path.expanduser("~/.quneo-deck/state")


def find_codex():
    for pid, tty, command in hook.proc_chain():
        first = command.split()[0] if command else ""
        if os.path.basename(first) == "codex":
            t = None if not tty or tty.startswith("?") else "/dev/" + tty
            return pid, t
    return None, None


def codex_cwd(pid):
    try:
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                return line[1:]
    except Exception:
        pass
    return ""


def main():
    try:
        payload = json.loads(sys.argv[-1])
    except Exception:
        return
    etype = str(payload.get("type", ""))
    if "turn-complete" in etype:
        status, sound_event = "ready", "Stop"
    elif "approval" in etype or "input" in etype:
        status, sound_event = "attention", "Notification"
    else:
        return

    pid, tty = find_codex()
    if pid is None:
        return
    _, _, term = hook.inspect_tree()

    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, "codex-%d.json" % pid)
    prev = {}
    try:
        with open(path) as f:
            prev = json.load(f)
    except Exception:
        pass
    now = time.time()
    state = dict(prev)
    state.update({
        "session_id": "codex-%d" % pid,
        "agent": "codex",
        "status": status,
        "cwd": prev.get("cwd") or codex_cwd(pid),
        "pid": pid,
        "tty": tty or prev.get("tty"),
        "term": term or prev.get("term"),
        "host": hook.socket.gethostname(),
        "created": prev.get("created", now),
        "updated": now,
    })
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)

    sound = hook.sound_for(sound_event)
    if sound and os.path.exists(sound):
        subprocess.Popen(
            ["afplay", sound],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )


if __name__ == "__main__":
    main()
