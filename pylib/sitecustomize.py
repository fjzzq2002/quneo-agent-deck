"""QuNeo Agent Deck tqdm bridge.

Auto-loaded by Python in every interpreter via PYTHONPATH (setup.sh adds
~/.quneo-deck/pylib to PYTHONPATH in your shell rc). Installs an import
hook that patches tqdm on import: bars with a known total mirror their
progress to ~/.quneo-deck/bars/<pid>-<id>.json, which the deck paints onto
the QuNeo's horizontal sliders (poll.py ships them from clusters too).

Zero overhead unless tqdm is actually imported. Fail-silent everywhere:
a broken bridge must never break someone's training run.
"""
import sys


def _patch(module):
    std = getattr(module, "std", None) or sys.modules.get("tqdm.std")
    T = std.tqdm if std is not None else module.tqdm
    if getattr(T, "_quneo_patched", False):
        return
    T._quneo_patched = True

    import json
    import os
    import socket
    import time

    bars_dir = os.path.expanduser("~/.quneo-deck/bars")
    hostname = socket.gethostname()
    last_write = {}

    def _bar_path(bar):
        return os.path.join(bars_dir, "%d-%d.json" % (os.getpid(), id(bar)))

    def _report(bar):
        try:
            total = getattr(bar, "total", None)
            if not total:
                return
            os.makedirs(bars_dir, exist_ok=True)
            state = {
                "frac": max(0.0, min(1.0, float(bar.n) / float(total))),
                "desc": str(getattr(bar, "desc", "") or ""),
                "pid": os.getpid(),
                "host": hostname,
                "updated": time.time(),
            }
            tmp = _bar_path(bar) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(state, f)
            os.replace(tmp, _bar_path(bar))
        except Exception:
            pass

    orig_refresh = T.refresh
    orig_close = T.close

    def refresh(self, *args, **kwargs):
        result = orig_refresh(self, *args, **kwargs)
        try:
            now = time.time()
            if now - last_write.get(id(self), 0.0) > 0.15:
                last_write[id(self)] = now
                _report(self)
        except Exception:
            pass
        return result

    def close(self):
        try:
            orig_close(self)
        finally:
            try:
                os.remove(_bar_path(self))
            except Exception:
                pass
            last_write.pop(id(self), None)

    T.refresh = refresh
    T.close = close


class _TqdmPatchFinder:
    """Meta-path finder: waits for `import tqdm`, patches it, retires."""

    def find_spec(self, name, path=None, target=None):
        if name != "tqdm":
            return None
        import importlib.util
        try:
            sys.meta_path.remove(self)
        except ValueError:
            pass
        try:
            spec = importlib.util.find_spec("tqdm")
        except Exception:
            spec = None
        if spec is None or spec.loader is None:
            return None
        spec.loader = _WrapLoader(spec.loader)
        return spec


class _WrapLoader:
    def __init__(self, loader):
        self._loader = loader

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        self._loader.exec_module(module)
        try:
            _patch(module)
        except Exception:
            pass

    def __getattr__(self, name):
        return getattr(self._loader, name)


try:
    sys.meta_path.insert(0, _TqdmPatchFinder())
except Exception:
    pass
