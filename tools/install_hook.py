#!/usr/bin/env python3
"""Install (or remove) the Claude Code hooks that ping Thread Suit.

Merges into Claude Code's settings.json (~/.claude, or $CLAUDE_CONFIG_DIR as
Claude Code itself uses it) without touching other settings or hooks, keeps a
backup next to it, and is safe to run more than once: an older copy of these
hooks is upgraded in place. Works the same on macOS, Linux and Windows.

Usage: python3 tools/install_hook.py [--uninstall]
       (on Windows: py tools/install_hook.py [--uninstall])
"""
import json, os, shutil, sys

CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
URL = "http://127.0.0.1:47321/changed"
COMMAND = f"curl -s -m 1 -X POST {URL} >/dev/null 2>&1 || true"
HOOK = {"type": "command", "command": COMMAND, "async": True, "timeout": 3}
EVENTS = {
    "UserPromptSubmit": None,
    "Stop": None,
    "PostToolUse": "mcp__hearthbot__post_message|mcp__hearthbot__rename_thread|mcp__hearthbot__set_thread_resolved"
    "|mcp__claude-code-remote__send_message",
}


def is_ours(group):
    return any(URL in h.get("command", "") for h in group.get("hooks", []))


def load():
    if not os.path.exists(SETTINGS):
        return {}
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            settings = json.load(f)
    except (ValueError, OSError) as e:
        sys.exit(f"Can't read {SETTINGS}: {e}\nFix or move that file, then run this again. Nothing was changed.")
    if not isinstance(settings, dict):
        sys.exit(f"{SETTINGS} isn't a JSON object. Nothing was changed.")
    return settings


def main():
    args = sys.argv[1:]
    if any(a not in ("--uninstall",) for a in args):
        print(__doc__.strip())
        sys.exit(0 if any(a in ("-h", "--help") for a in args) else 2)
    uninstall = "--uninstall" in args
    settings = load()
    hooks = settings.setdefault("hooks", {})
    changed = False
    for event, matcher in EVENTS.items():
        groups = hooks.get(event, [])
        kept = [g for g in groups if not is_ours(g)]
        if uninstall:
            if len(kept) != len(groups):
                changed = True
            if kept:
                hooks[event] = kept
            else:
                hooks.pop(event, None)
            continue
        ours = [g for g in groups if is_ours(g)]
        if ours:
            if len(ours) == 1 and ours[0].get("matcher") == matcher and ours[0].get("hooks") == [HOOK]:
                continue  # already installed and current
            hooks[event] = kept  # outdated: replace below
            groups = kept
        group = {"hooks": [HOOK]}
        if matcher:
            group["matcher"] = matcher
        hooks[event] = groups + [group]
        changed = True
    if not hooks:
        settings.pop("hooks", None)
    if not changed:
        print("Nothing to change: hooks are already " + ("absent." if uninstall else "installed."))
        return
    if os.path.exists(SETTINGS):
        shutil.copy2(SETTINGS, SETTINGS + ".bak")
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    os.replace(tmp, SETTINGS)
    print(("Removed" if uninstall else "Installed") + f" Thread Suit hooks in {SETTINGS} (backup: {SETTINGS}.bak).")
    if not uninstall:
        for event, matcher in EVENTS.items():
            print(f"  {event}" + (f" for {matcher}" if matcher else ""))
    print("Sessions already running may need a restart to load the change.")


if __name__ == "__main__":
    main()
