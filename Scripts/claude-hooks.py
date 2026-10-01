#!/usr/bin/env python3
"""Adds or removes the Claude Code hooks that tell NotchKit what Claude is doing.

    claude-hooks.py install [settings.json]
    claude-hooks.py remove  [settings.json]

The settings file defaults to ~/.claude/settings.json. Other hooks in it are left alone, the previous
file is kept next to it as settings.json.notchkit-backup, and running install twice changes nothing.

Each hook opens a notchkit:// URL, and only if NotchKit is already running:
    UserPromptSubmit -> Claude is working
    Stop             -> Claude finished
    Notification     -> Claude needs input
    SessionEnd       -> clears the status
"""
import json
import os
import shutil
import sys

EVENTS = {"UserPromptSubmit": "working", "Stop": "finished", "Notification": "input", "SessionEnd": "ended"}
MARK = "_notchkit"


def command(event):
    # `|| true`: a hook must never fail Claude's turn because the notch isn't there.
    return "pgrep -xq NotchKit && open -g 'notchkit://claude?event=%s' || true" % event


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("install", "remove"):
        sys.exit(__doc__)
    path = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/.claude/settings.json")

    settings = {}
    if os.path.exists(path):
        try:
            with open(path) as file:
                settings = json.load(file)
        except ValueError:
            sys.exit("%s isn't valid JSON. Nothing was changed." % path)
        if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
            sys.exit("%s doesn't look like a Claude Code settings file." % path)
        shutil.copy2(path, path + ".notchkit-backup")

    hooks = settings.setdefault("hooks", {})
    for name, event in EVENTS.items():
        entries = [entry for entry in hooks.get(name, []) if not (isinstance(entry, dict) and entry.get(MARK))]
        if action == "install":
            entries.append({"hooks": [{"type": "command", "command": command(event), "timeout": 5}], MARK: True})
        if entries:
            hooks[name] = entries
        else:
            hooks.pop(name, None)
    if not hooks:
        del settings["hooks"]

    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".notchkit-tmp"
    with open(temporary, "w") as file:
        json.dump(settings, file, indent=2, ensure_ascii=False)
        file.write("\n")
    os.replace(temporary, path)
    print("Hooks installed. New Claude Code sessions will report to NotchKit." if action == "install" else "Hooks removed.")


if __name__ == "__main__":
    main()
