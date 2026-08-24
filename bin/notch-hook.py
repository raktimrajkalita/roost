#!/usr/bin/env python3
"""
Claude Code notch monitor - status reporter.
Called by hooks. Writes one JSON state file per session and, on done/waiting,
plays a metallic chime + posts a macOS notification (so you know WHICH session).

Usage:  notch-hook.py <event>
  event in: working | done | waiting | ended | tool
Reads the hook JSON payload from stdin.
"""
import sys, os, json, time, subprocess, hashlib

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".claude-notch")
STATE = os.path.join(ROOT, "state")
SOUNDS = os.path.join(ROOT, "sounds")
MUTED = os.path.join(ROOT, "muted")           # touch this file to mute sound
DISABLED = os.path.join(ROOT, "disabled")     # touch this file to silence everything
MUTE_DIR = os.path.join(ROOT, "mutes")        # per-session mute flags (mutes/<fid>)

os.makedirs(STATE, exist_ok=True)
os.makedirs(MUTE_DIR, exist_ok=True)


def read_payload():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def short_action(data):
    """Turn a PreToolUse payload into a line like 'Read app-sidebar.tsx'."""
    tool = data.get("tool_name") or "Working"
    ti = data.get("tool_input") or {}
    detail = ""
    if isinstance(ti, dict):
        if ti.get("file_path"):
            detail = os.path.basename(ti["file_path"])
        elif ti.get("path"):
            detail = os.path.basename(ti["path"])
        elif ti.get("command"):
            detail = str(ti["command"]).strip().split("\n")[0][:48]
        elif ti.get("pattern"):
            detail = str(ti["pattern"])[:48]
        elif ti.get("url"):
            detail = str(ti["url"])[:48]
        elif ti.get("description"):
            detail = str(ti["description"])[:48]
    return (tool + (" " + detail if detail else "")).strip()


def notify(title, message):
    if os.path.exists(DISABLED):
        return
    msg = message.replace('"', "'")[:120]
    ttl = title.replace('"', "'")[:80]
    script = 'display notification "%s" with title "%s"' % (msg, ttl)
    try:
        subprocess.Popen(["osascript", "-e", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def play(sound):
    if os.path.exists(MUTED) or os.path.exists(DISABLED):
        return
    p = os.path.join(SOUNDS, sound)
    if not os.path.exists(p):
        return
    try:
        subprocess.Popen(["afplay", p],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else "working"
    data = read_payload()

    sid = data.get("session_id") or os.environ.get("CLAUDE_SESSION_ID") or "unknown"
    # keep filenames safe
    fid = hashlib.sha1(sid.encode()).hexdigest()[:16]
    smuted = os.path.exists(os.path.join(MUTE_DIR, fid))  # this session muted by the user
    cwd = data.get("cwd") or os.getcwd()
    project = os.path.basename(cwd.rstrip("/")) or cwd
    statefile = os.path.join(STATE, fid + ".json")

    if event == "ended":
        try:
            os.remove(statefile)
        except OSError:
            pass
        return

    # merge with any existing state so we keep last_action across events
    state = {}
    if os.path.exists(statefile):
        try:
            with open(statefile) as f:
                state = json.load(f)
        except Exception:
            state = {}

    state.update({
        "session_id": sid,
        "project": project,
        "cwd": cwd,
        "iterm_session": os.environ.get("ITERM_SESSION_ID", ""),
        "term_session": os.environ.get("TERM_SESSION_ID", ""),
        "term_program": os.environ.get("TERM_PROGRAM", ""),
        "updated": time.time(),
    })

    if event == "tool":
        state["status"] = "thinking"
        state["last_action"] = short_action(data)
    elif event == "working":
        state["status"] = "thinking"
        p = data.get("prompt")
        if p:
            state["last_action"] = "You: " + str(p).strip().split("\n")[0][:48]
    elif event == "done":
        state["status"] = "done"
        state["done_at"] = time.time()
        if not smuted:
            play("done.wav")
            notify(project + " - done", state.get("last_action", "Claude finished a turn"))
    elif event == "waiting":
        state["status"] = "waiting"
        msg = data.get("message") or "needs your input"
        state["last_action"] = str(msg)[:60]
        if not smuted:
            play("waiting.wav")
            notify(project + " - waiting", str(msg)[:100])

    try:
        with open(statefile, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


if __name__ == "__main__":
    main()
