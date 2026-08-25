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


def controlling_tty():
    """The tab's tty (e.g. /dev/ttys005) — the stable per-tab id Terminal.app exposes
    via AppleScript. `ps` reports this process's controlling terminal even when the
    hook's stdio is piped; on macOS /dev/tty only names itself, so it can't be used."""
    try:
        out = subprocess.run(["ps", "-o", "tty=", "-p", str(os.getpid())],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        if out and out not in ("?", "??", "-"):
            if out.startswith("/dev/"):
                return out
            if out.startswith("tty"):
                return "/dev/" + out         # ps gives "ttys005" -> /dev/ttys005
            return "/dev/tty" + out          # some builds abbreviate as "s005"
    except Exception:
        pass
    for fd in (0, 1, 2):                      # last resort if stdio happens to be a tty
        try:
            if os.isatty(fd):
                return os.ttyname(fd)
        except OSError:
            pass
    return ""


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


def audio_is_playing():
    """True if something is already playing audio on this Mac (music, video,
    a browser tab, etc.), so we can boost the chime to cut through it."""
    try:
        out = subprocess.run(["pmset", "-g", "assertions"],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return False
    # Browsers hold a "Playing audio" assertion; coreaudiod holds an active
    # output context assertion whenever audio is flowing to the output device.
    return ("Playing audio" in out) or ("coreaudiod" in out and "output.context" in out)


def play(sound):
    if os.path.exists(MUTED) or os.path.exists(DISABLED):
        return
    p = os.path.join(SOUNDS, sound)
    if not os.path.exists(p):
        return
    vol = "2.0" if audio_is_playing() else "1.0"   # 200% so it's audible over music
    try:
        # start_new_session detaches afplay into its own session so it survives the
        # short-lived hook process being reaped (otherwise the chime gets cut off).
        subprocess.Popen(["afplay", "-v", vol, p],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def _extract_text(content):
    if isinstance(content, str):
        return content.strip() or None
    if isinstance(content, list):
        parts = [b["text"] for b in content
                 if isinstance(b, dict) and b.get("type") == "text" and b.get("text")]
        t = " ".join(parts).strip()
        return t or None
    return None


def last_assistant_text(path):
    """Pull Claude's final reply text from the session transcript (JSONL).
    Reads only the tail of the file so it's fast even on long sessions."""
    if not path or not os.path.exists(path):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > 200000:                 # only need the last messages
                f.seek(size - 200000)
                f.readline()                  # drop the partial first line
            blob = f.read().decode("utf-8", "replace")
        last = None
        for line in blob.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message") if isinstance(obj.get("message"), dict) else obj
            is_assistant = obj.get("type") == "assistant" or (isinstance(msg, dict) and msg.get("role") == "assistant")
            if is_assistant and isinstance(msg, dict):
                text = _extract_text(msg.get("content"))
                if text:
                    last = text
        return last
    except Exception:
        return None


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
        "tty": controlling_tty(),
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
        reply = last_assistant_text(data.get("transcript_path"))
        if reply:
            state["last_action"] = "Claude: " + " ".join(reply.split())[:200]
        if not smuted:
            play("done.wav")   # the chime + notch panel are the notification (no macOS banner)
    elif event == "waiting":
        # Claude Code's Notification hook fires for two different things:
        #   (a) a real permission / answer popup ("... needs your permission ..."),
        #   (b) an idle "waiting for your input" ping ~60s after a turn finishes.
        # Only (a) is a "reply to me" prompt. (b) after a completed task must stay
        # done, and must NOT play the chime.
        msg = data.get("message") or ""
        low = msg.lower()
        if "waiting for" in low and "input" in low:
            state["status"] = "done"          # idle after completion, not a real prompt
        else:
            state["status"] = "waiting"       # a genuine popup asking you to answer
            state["last_action"] = (msg or "needs your reply")[:60]
            if not smuted:
                play("waiting.wav")   # chime only, no macOS banner

    try:
        with open(statefile, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


if __name__ == "__main__":
    main()
