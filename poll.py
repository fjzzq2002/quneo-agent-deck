#!/usr/bin/env python3
"""Remote-side poller for the QuNeo deck.

Run over ssh by the deck app. Default: reap dead/stale sessions and print
the survivors as a JSON array. With --ack <id>: dim that session to idle.

Pid liveness is only checked for sessions on THIS host — on a cluster with
shared home, state files written by compute nodes hold pids the login node
cannot see. Those are pruned by staleness instead.
"""
import json
import os
import socket
import sys
import time

STATE = os.path.expanduser("~/.quneo-deck/state")
BARS = os.path.expanduser("~/.quneo-deck/bars")
STALE_SECONDS = 48 * 3600
BAR_STALE_SECONDS = 6 * 3600


def ack(sid):
    path = os.path.join(STATE, sid + ".json")
    try:
        with open(path) as f:
            d = json.load(f)
        if d.get("status") in ("ready", "attention"):
            d["status"] = "idle"
            d["updated"] = time.time()
            with open(path, "w") as f:
                json.dump(d, f)
    except Exception:
        pass


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--ack":
        ack(sys.argv[2])
        return
    if not os.path.isdir(STATE):
        print("[]")
        return
    host = socket.gethostname()
    now = time.time()
    out = []
    for fn in os.listdir(STATE):
        if not fn.endswith(".json"):
            continue
        path = os.path.join(STATE, fn)
        try:
            with open(path) as f:
                d = json.load(f)
        except Exception:
            continue
        pid = d.get("pid")
        dead = False
        if pid and d.get("host") in (None, host):
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                dead = True
            except Exception:
                pass
        if dead or now - d.get("updated", 0) > STALE_SECONDS:
            try:
                os.remove(path)
            except Exception:
                pass
            continue
        out.append(d)

    bars = []
    if os.path.isdir(BARS):
        for fn in os.listdir(BARS):
            if not fn.endswith(".json"):
                continue
            path = os.path.join(BARS, fn)
            try:
                with open(path) as f:
                    b = json.load(f)
            except Exception:
                continue
            pid = b.get("pid")
            dead = False
            if pid and b.get("host") in (None, host):
                try:
                    os.kill(int(pid), 0)
                except ProcessLookupError:
                    dead = True
                except Exception:
                    pass
            if dead or now - b.get("updated", 0) > BAR_STALE_SECONDS:
                try:
                    os.remove(path)
                except Exception:
                    pass
                continue
            bars.append(b)
    print(json.dumps({"sessions": out, "bars": bars}))


if __name__ == "__main__":
    main()
