#!/usr/bin/env python3
"""
Tristimulator OCIO scripting daemon.
Do not run directly — launched by Tristimulator at startup.

Loads the user's rules script once, then loops reading JSON contexts from
stdin and writing evaluate() results to stdout, one JSON object per line.
"""
import sys
import json
import traceback
import importlib.util

# Keep a reference to the real stdout for IPC. User scripts may call print(),
# which would corrupt the JSON protocol if it went to the same pipe.
_ipc_stdout = sys.stdout
sys.stdout = sys.stderr


def _load_module(path):
    spec = importlib.util.spec_from_file_location("tristimulator_rules", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load script at: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _reply(obj):
    _ipc_stdout.write(json.dumps(obj) + "\n")
    _ipc_stdout.flush()


def main():
    if len(sys.argv) < 2:
        _reply({"_error": "Usage: tristimulator_daemon.py <script_path>"})
        sys.exit(1)

    script_path = sys.argv[1]
    module = None

    try:
        module = _load_module(script_path)
    except Exception as exc:
        _reply({"_error": f"Failed to load script: {exc}"})
        # Keep running — the app may send a reload command later.

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            _reply({"_error": f"Invalid JSON from app: {exc}"})
            continue

        # Control messages
        cmd = msg.get("_command")
        if cmd == "ping":
            _reply({"_pong": True})
            continue
        if cmd == "reload":
            try:
                module = _load_module(script_path)
                _reply({"_reloaded": True})
            except Exception as exc:
                _reply({"_error": f"Reload failed: {exc}"})
            continue

        # Normal evaluate call
        if module is None:
            _reply({})
            continue

        if not hasattr(module, "evaluate"):
            _reply({"_error": "Script must define an evaluate(ctx) function"})
            continue

        try:
            result = module.evaluate(msg)
            _reply(result if isinstance(result, dict) else {})
        except Exception:
            _reply({"_error": traceback.format_exc().strip()})


if __name__ == "__main__":
    main()
