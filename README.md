# QuNeo Agent Deck

Codex Micro at home: a Keith McMillen **QuNeo** MIDI controller as a
physical control deck for AI coding agents — **Claude Code** (local and on
remote clusters over ssh) and **OpenAI Codex CLI**. Every session gets a
light-up pad, the rotaries are googly eyes that stare at whatever needs
you, and the whole thing runs from a tiny macOS menu bar app.

https://github.com/user-attachments/... *(demo video)*

## What the hardware does

**16 pads = live agent sessions**

| Pad | Meaning |
|---|---|
| 🟢 pulsing green | agent is working |
| 🟠 solid orange | turn finished — output waiting (plays a chime) |
| 🔴 fast-blinking red | blocked on you: permission prompt or question (plays sonar) |
| dim green | idle |
| off | free slot |

Pads arrange in **columns per project**, growing top-down; drag blocks
around in the Arrange Pads panel and placements persist (a project's
sessions land on its remembered "home" column forever after).
**Pressing a pad jumps to that session's exact terminal**: Warp tab (via a
tty title-marker trick), iTerm2/Terminal.app tab (AppleScript, by tty),
Cursor/VS Code terminal pane (companion extension), or the remembered
window for anything else — including cluster sessions.

**2 rotaries = googly eyes**

- calm wandering gaze when all is well
- lock onto the pad that needs attention (each eye computes its own angle
  — they converge), with a relieved look-away when you resolve it
- track the pad being jumped to
- **they're also buttons**: tap left = F13 (bind to your dictation app),
  tap right = Return, both together = Esc

**4 vertical sliders = tentacles**

- ambient display: slow breathing when idle, VU-dance scaled by how many
  agents are working, alarm pumping on attention, a left-to-right swoosh
  when a turn completes
- tap top third = ↑, tap bottom third = ↓, rest a finger = scroll wheel

**Menu bar app**: a little robot face whose pupils mirror the hardware
eyes (red + wide when something needs you), with a session list, drag
arrangement panel, sound pickers, video mode (full-duty LEDs, no PWM
flicker on camera), pause, and start-at-login.

## Install

```sh
./setup.sh                      # local Mac
./setup-remote.sh <ssh-host>    # each cluster
```

See **[SETUP.md](SETUP.md)** for requirements, macOS permissions (read the
rebuild-vs-Accessibility note!), configuration, and troubleshooting.

## How it works

- **Claude Code sessions**: [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)
  (`hook.py`) fire on session lifecycle events and write per-session state
  files to `~/.quneo-deck/state/`, recording pid/tty/host-app forensics
  from the process tree for later jumping.
- **Remote sessions**: the deck polls each cluster's state dir over a
  persistent ssh connection (2s cadence); `poll.py` reaps dead sessions
  server-side. Jump-back resolves `$SSH_CONNECTION`'s client port to your
  local ssh process via `lsof` — single-hop sessions land on the exact
  terminal pane.
- **Codex sessions**: no hooks exist, so the deck discovers `codex`
  processes by scanning, infers working/idle from CPU-time deltas, and
  gets turn-complete events from Codex's `notify` hook (`codex-notify.py`).
- **The app** (`QuNeoDeck.swift`, a single-file AppKit + CoreMIDI binary)
  paints LEDs at 4 Hz (eyes at 10 Hz), listens for pad/rotary/slider input,
  and does the jumping via AppleScript, the Accessibility API, synthetic
  events, and a ~60-line VS Code extension (`ide-bridge/`) that focuses
  exact terminal panes through per-window unix sockets.

Assumes the QuNeo **factory default preset** — all MIDI mappings
(pad LEDs = note pairs 2i/2i+1 on ch 1, rotary LEDs = CC6/7, slider
positions = CC1-11, pad input = notes 36-51) are documented inline in
`QuNeoDeck.swift`.

## Repo map

```
QuNeoDeck.swift    the menu bar app (build: swiftc -O QuNeoDeck.swift -o QuNeoDeck)
hook.py            Claude Code hook -> state files (+ sounds)
poll.py            remote-side poller/reaper/acker (deployed by setup-remote.sh)
codex-notify.py    Codex CLI notify hook -> state files
ide-bridge/        VS Code/Cursor extension: focus exact terminal panes
midispy.swift      debug tool: log everything the QuNeo sends
setup.sh           local install (build + hooks + codex + extension)
setup-remote.sh    cluster install (deploy + remote hooks + register)
```

---

Built in one long conversation with Claude Code, for Claude Code. 🦑
