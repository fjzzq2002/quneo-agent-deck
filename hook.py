#!/usr/bin/env python3
"""Claude Code hook -> QuNeo deck state.

Receives hook JSON on stdin, writes ~/.quneo-deck/state/<session_id>.json.
Must never print to stdout (UserPromptSubmit stdout becomes model context).

Besides status, records enough forensics for the deck app to jump back to
the session's terminal tab: the claude process pid, its tty, and the
terminal app at the top of its process tree.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time

STATE = os.path.expanduser("~/.quneo-deck/state")

CONFIG = os.path.expanduser("~/.quneo-deck/config.json")

# Sounds mirror the pad colors: orange (turn finished) and red (needs
# input). Defaults below; override via config.json ("ready_sound" /
# "attention_sound": a /System/Library/Sounds basename, or "off"),
# which the QuNeoDeck menu bar app writes.
SOUND_DEFAULTS = {"Stop": "Glass", "Notification": "Submarine"}
SOUND_CONFIG_KEY = {"Stop": "ready_sound", "Notification": "attention_sound"}


def sound_for(event):
    key = SOUND_CONFIG_KEY.get(event)
    if not key:
        return None
    name = SOUND_DEFAULTS[event]
    try:
        with open(CONFIG) as f:
            name = json.load(f).get(key, name)
    except Exception:
        pass
    if not name or name == "off":
        return None
    return "/System/Library/Sounds/%s.aiff" % name

STATUS_FOR_EVENT = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "Stop": "ready",
    "Notification": "attention",
}


def proc_chain():
    """(pid, tty, command) tuples from our parent up toward pid 1."""
    chain = []
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1:
            break
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,tty=,command=", "-p", str(pid)],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            if not out:
                break
            ppid_s, tty, command = out.split(None, 2)
            chain.append((pid, tty, command))
            pid = int(ppid_s)
        except Exception:
            break
    return chain


def is_claude(command):
    """Match the claude executable itself, not paths mentioning claude."""
    first = command.split()[0] if command else ""
    return os.path.basename(first).lower().startswith("claude")


def inspect_tree():
    """Return (claude_pid, tty, terminal_app_name)."""
    chain = proc_chain()
    claude_pid = next((p for p, _, c in chain if is_claude(c)), None)
    term = None
    for _, _, command in chain:
        m = re.search(r"/([^/]+)\.app/", command)
        if m:
            term = re.sub(r" Helper.*$", "", m.group(1))
            break  # innermost .app walking upward = the host app
    # The claude process's tty, else the nearest ancestor that has one.
    tty = None
    for pid, t, _ in chain:
        if t and t not in ("?", "??") and (claude_pid is None or pid == claude_pid or tty is None):
            if pid == claude_pid:
                tty = "/dev/" + t
                break
            if tty is None:
                tty = "/dev/" + t
    return claude_pid, tty, term


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    sid = data.get("session_id")
    event = data.get("hook_event_name")
    if not sid or not event:
        return

    os.makedirs(STATE, exist_ok=True)
    path = os.path.join(STATE, sid + ".json")

    if event == "SessionEnd":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return

    status = STATUS_FOR_EVENT.get(event)
    if status is None:
        return

    if event == "Notification":
        # Notification covers both real blockers (permission prompts) and a
        # soft "waiting for your input" nudge after ~60s idle. Only the
        # former deserves the red light; the idle nudge is phantom urgency.
        msg = (data.get("message") or "").lower()
        if "waiting for" in msg and "input" in msg:
            return

    now = time.time()
    prev = {}
    try:
        with open(path) as f:
            prev = json.load(f)
    except Exception:
        pass

    if prev.get("pid"):
        pid, tty, term = prev.get("pid"), prev.get("tty"), prev.get("term")
    else:
        pid, tty, term = inspect_tree()

    state = dict(prev)  # preserve keys owned by others (e.g. the deck app)
    state.update({
        "session_id": sid,
        "status": status,
        "cwd": data.get("cwd") or prev.get("cwd", ""),
        "pid": pid,
        "tty": tty,
        "term": term,
        "host": socket.gethostname(),
        "ssh_conn": os.environ.get("SSH_CONNECTION"),
        "created": prev.get("created", now),
        "updated": now,
    })

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)

    sound = sound_for(event)
    if sound and os.path.exists(sound):
        try:
            subprocess.Popen(
                ["afplay", sound],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception:
            pass


if __name__ == "__main__":
    main()
