# Setup

## What you need

- **macOS** with Xcode Command Line Tools (`xcode-select --install` — for `swiftc`)
- A **Keith McMillen QuNeo** on its **factory default preset** (preset 1;
  if you've never touched the Mode button, you're on it). All the MIDI
  mappings in this project — pad LEDs, rotary LEDs, slider CCs — assume it.
- **Claude Code** (hooks power the whole thing)
- Optional: **OpenAI Codex CLI** (`~/.codex/` present), **Cursor/VS Code**
  (for exact-terminal jumping), an ssh-reachable **cluster** running Claude
  Code

## Local setup

```sh
git clone <this-repo> && cd quneo-agent-deck
./setup.sh
```

The script builds the app, installs the Claude Code hooks into
`~/.claude/settings.json` (backing up the original), wires Codex's `notify`
if you have Codex, and drops the IDE-bridge extension into
Cursor/VS Code's extension folders. Everything is idempotent — rerun after
pulling updates.

Then:

1. `./QuNeoDeck &` — the little robot face appears in your menu bar
2. Grant **Accessibility** when prompted (see Permissions below)
3. Menu bar face → **Start at Login**
4. Restart your Claude Code sessions (hooks attach at session start)

Sanity checks: `./QuNeoDeck --test` (green/red pad sweep, orange flash),
`./QuNeoDeck --eyes` (googly eye demo). If the sweep lights the wrong
controls, you're not on the factory preset.

## Remote cluster

```sh
./setup-remote.sh my-cluster-alias
```

Run from your Mac. Needs key-based ssh (no password prompts) and python3 +
Claude Code on the remote. It deploys the hook + poller, merges hooks into
the remote `~/.claude/settings.json`, and registers the host in
`~/.quneo-deck/config.json` so the running deck polls it every 2 seconds
over a persistent ControlMaster connection. Remote sessions appear on pads
marked ☁️; sounds play locally; pad presses acknowledge across ssh.

Shared-home clusters get a bonus: sessions on compute nodes write state to
the same NFS home the login node serves, so they're all visible through
one ssh target.

## Permissions (macOS)

Two grants, both one-time-ish:

- **Accessibility** (System Settings → Privacy & Security → Accessibility):
  needed for tab jumping, window raising, and the eye hotkeys. The first
  jump attempt triggers the system prompt.
- **Automation → System Events**: a dialog appears the first time an eye
  sends a keystroke; click Allow.

**The rebuild gotcha**: macOS ties the Accessibility grant to the binary's
code signature, and unsigned builds get a new one every compile — so after
every rebuild you must toggle the grant off/on. The permanent fix: create a
self-signed code-signing certificate once (Keychain Access → Certificate
Assistant → Create a Certificate → type "Code Signing", name it e.g.
`quneo-deck`), then build with:

```sh
swiftc -O QuNeoDeck.swift -o QuNeoDeck && codesign -f -s quneo-deck QuNeoDeck
```

and the grant survives rebuilds.

## Configuration

- `~/.quneo-deck/config.json` — sounds (also settable from the menu),
  `video_mode`, `remotes`
- `~/.quneo-deck/arrangement.json` — pad assignments and per-project home
  pads (managed by the Arrange Pads panel; delete to re-layout)
- Eye hotkeys and tentacle zones/timings: named constants at the top of
  their sections in `QuNeoDeck.swift`. The left eye sends **F13** — bind
  that in your dictation app (most shortcut recorders will capture it if
  you tap the eye while recording). Right eye = Return, both eyes = Esc.

## Troubleshooting

- `~/.quneo-deck/app.log` — the deck narrates everything: jumps taken and
  why, hotkeys fired, AX permission state at startup, codex discoveries.
- `~/.quneo-deck/state/*.json` — ground truth for what the pads display.
- `./midispy` — logs every MIDI message the QuNeo sends; use it to verify
  preset mappings if controls seem dead or scrambled.
- Icon missing from the menu bar: it's probably hidden behind the notch —
  quit some other menu bar apps, or tighten `NSStatusItemSpacing`.
- Wrong LEDs lighting: wrong preset. Tap the Mode button (top-left round
  button), then tap pad 1 to select the factory preset.

## Uninstall

Quit the app; delete the hook entries from `~/.claude/settings.json` (or
restore `settings.json.bak-quneo`), the `notify` line from
`~/.codex/config.toml`, `~/.quneo-deck/`, the LaunchAgent
`~/Library/LaunchAgents/com.quneo.agentdeck.plist` if you enabled Start at
Login, and the `ziqian.quneo-deck-bridge-*` folder from your editor's
extensions directory. Same on any cluster: `~/.quneo-deck/` plus the hook
entries in the remote settings.
