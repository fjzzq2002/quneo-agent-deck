#!/bin/bash
# QuNeo Agent Deck — local (macOS) setup. Idempotent; run again after updates.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== QuNeo Agent Deck setup =="
echo "repo: $DIR"

# --- 1. Build ------------------------------------------------------------
command -v swiftc >/dev/null 2>&1 || {
    echo "error: swiftc not found — install Xcode Command Line Tools first:"
    echo "  xcode-select --install"
    exit 1
}
echo "-> building QuNeoDeck (menu bar app)..."
swiftc -O "$DIR/QuNeoDeck.swift" -o "$DIR/QuNeoDeck"
echo "-> building midispy (MIDI debug tool)..."
swiftc -O "$DIR/midispy.swift" -o "$DIR/midispy"

# --- 2. State dir ----------------------------------------------------------
mkdir -p "$HOME/.quneo-deck/state"

# --- 3. Claude Code hooks --------------------------------------------------
echo "-> installing Claude Code hooks into ~/.claude/settings.json..."
python3 - "$DIR" <<'PYEOF'
import json, os, shutil, sys
deck = sys.argv[1]
path = os.path.expanduser("~/.claude/settings.json")
settings = {}
if os.path.exists(path):
    shutil.copy(path, path + ".bak-quneo")
    with open(path) as f:
        settings = json.load(f)
hook = {
    "type": "command",
    "command": "python3 %s/hook.py 2>/dev/null || true" % deck,
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

# --- 4. Codex CLI notify (optional) ---------------------------------------
if [ -f "$HOME/.codex/config.toml" ]; then
    echo "-> installing Codex notify hook into ~/.codex/config.toml..."
    python3 - "$DIR" <<'PYEOF'
import re, sys
deck = sys.argv[1]
import os
path = os.path.expanduser("~/.codex/config.toml")
with open(path) as f:
    content = f.read()
if re.search(r"^notify\s*=", content, re.M):
    print("   notify already configured — unchanged")
else:
    with open(path + ".bak-quneo", "w") as f:
        f.write(content)
    line = 'notify = ["python3", "%s/codex-notify.py"]\n' % deck
    with open(path, "w") as f:
        f.write(line + content)  # must be top-level: before any [table]
    print("   notify installed (backup: config.toml.bak-quneo)")
PYEOF
else
    echo "-> no ~/.codex/config.toml — skipping Codex integration"
fi

# --- 5. IDE bridge extension (Cursor / VS Code) ----------------------------
for extdir in "$HOME/.cursor/extensions" "$HOME/.vscode/extensions"; do
    if [ -d "$extdir" ]; then
        rm -rf "$extdir/ziqian.quneo-deck-bridge-0.1.0"
        cp -R "$DIR/ide-bridge" "$extdir/ziqian.quneo-deck-bridge-0.1.0"
        echo "-> ide-bridge extension installed into $extdir (restart the editor)"
    fi
done

# --- Done -------------------------------------------------------------------
cat <<TXT

== setup complete ==

next steps:
  1. plug in the QuNeo (factory default preset) and launch the app:
       $DIR/QuNeoDeck &
  2. grant Accessibility when prompted (System Settings > Privacy &
     Security > Accessibility) — needed for tab jumping and eye hotkeys.
     NOTE: rebuilding invalidates this grant unless you codesign; see
     SETUP.md "permissions" for the self-signed-certificate fix.
  3. click the menu bar face > "Start at Login" to make it permanent.
  4. restart your Claude Code sessions — hooks attach at session start.
  5. sanity checks: "$DIR/QuNeoDeck --test" (pad sweep),
     "--eyes" (googly eyes demo).

for a remote cluster: ./setup-remote.sh <ssh-host>   (see SETUP.md)
TXT
