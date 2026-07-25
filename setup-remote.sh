#!/bin/bash
# QuNeo Agent Deck — remote cluster setup. Run FROM your Mac:
#   ./setup-remote.sh <ssh-host>
# Requirements: key-based ssh (no interactive prompts), python3 on the
# remote, Claude Code installed there. Idempotent.
set -euo pipefail
HOST="${1:?usage: setup-remote.sh <ssh-host>}"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== QuNeo Agent Deck remote setup: $HOST =="

echo "-> checking connectivity..."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" \
    'command -v python3 >/dev/null || { echo "python3 missing on remote"; exit 1; }; echo "   connected: $(hostname)"'

echo "-> deploying hook.py + poll.py + tqdm bridge..."
ssh -o BatchMode=yes "$HOST" 'mkdir -p ~/.quneo-deck/state ~/.quneo-deck/bars ~/.quneo-deck/pylib'
scp -q "$DIR/hook.py" "$DIR/poll.py" "$HOST":.quneo-deck/
scp -q "$DIR/pylib/sitecustomize.py" "$HOST":.quneo-deck/pylib/

echo "-> adding PYTHONPATH export to remote shell rc files..."
ssh -o BatchMode=yes "$HOST" '
MARK="# quneo-agent-deck tqdm bridge"
LINE="export PYTHONPATH=\"\$HOME/.quneo-deck/pylib\${PYTHONPATH:+:\$PYTHONPATH}\""
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$rc" ] && ! grep -qF "$MARK" "$rc"; then
        printf "\n%s\n%s\n" "$MARK" "$LINE" >> "$rc"
        echo "   added to $rc"
    fi
done'

echo "-> installing Claude Code hooks on $HOST..."
ssh -o BatchMode=yes "$HOST" python3 <<'PYEOF'
import json, os, shutil
path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-quneo")
    with open(path) as f:
        settings = json.load(f)
hook = {
    "type": "command",
    "command": "python3 ~/.quneo-deck/hook.py 2>/dev/null || true",
    "timeout": 10,
    "async": True,
}
hooks = settings.setdefault("hooks", {})
added = 0
for ev in ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]:
    entries = hooks.setdefault(ev, [])
    if not any("hook.py" in json.dumps(e) for e in entries):
        entries.append({"hooks": [hook]})
        added += 1
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("   %d hook events added (backup: settings.json.bak-quneo)" % added
      if added else "   hooks already present — unchanged")
PYEOF

echo "-> registering $HOST in local deck config..."
python3 - "$HOST" <<'PYEOF'
import json, os, sys
path = os.path.expanduser("~/.quneo-deck/config.json")
config = {}
try:
    with open(path) as f:
        config = json.load(f)
except Exception:
    pass
remotes = config.setdefault("remotes", [])
if sys.argv[1] not in remotes:
    remotes.append(sys.argv[1])
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
    print("   added — deck polls it every 2s while running")
else:
    print("   already registered")
PYEOF

cat <<TXT

== remote setup complete ==

restart your Claude Code sessions on $HOST — hooks attach at session start.
they'll appear on the pads marked with a cloud within a couple of seconds.

notes:
  - shared-home clusters: sessions on compute nodes are covered too.
  - jumping back lands on the exact local terminal for single-hop ssh
    (SSH_CONNECTION port matching); multihop falls back to the window
    that was frontmost when the session appeared.
TXT
