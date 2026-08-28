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
MAX_MSG = 4000                                # full message kept for the panel; last_action stays short

os.makedirs(STATE, exist_ok=True)
os.makedirs(MUTE_DIR, exist_ok=True)


def read_payload():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def _norm_tty(t):
    if not t or t in ("?", "??", "-"):
        return ""
    if t.startswith("/dev/"):
        return t
    if t.startswith("tty"):
        return "/dev/" + t
    return "/dev/tty" + t


def controlling_tty():
    """The tab's tty (e.g. /dev/ttys005) — Terminal.app's stable per-tab id. The hook is
    usually detached from the controlling terminal (ps on our own pid gives '??'), so walk
    up the parent chain until we reach the process (claude / login shell) that owns a tty."""
    pid = os.getpid()
    for _ in range(12):
        try:
            line = subprocess.run(["ps", "-o", "tty=,ppid=", "-p", str(pid)],
                                  capture_output=True, text=True, timeout=2).stdout.split()
        except Exception:
            break
        if not line:
            break
        got = _norm_tty(line[0])
        if got:
            return got
        ppid = line[1] if len(line) > 1 else "1"
        if ppid in ("0", "1"):
            break
        try:
            pid = int(ppid)
        except ValueError:
            break
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
    """Claude's final reply for the CURRENT turn, or None if it isn't written yet.

    Returning None matters more than returning something. The Stop hook can fire in the
    same second the transcript is flushed, and the naive "last assistant message in the
    file" is then the PREVIOUS turn's reply — truthy, stale, and indistinguishable from a
    good read. So anchor on position: a reply only counts if it appears after the last
    user entry. If it doesn't, the turn hasn't landed yet and the caller should retry.

    Reads only the tail of the file so it stays fast on long sessions.
    """
    if not path or not os.path.exists(path):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > 200000:                 # only need the last messages
                f.seek(size - 200000)
                f.readline()                  # drop the partial first line
            blob = f.read().decode("utf-8", "replace")

        last_user = -1
        replies = []                          # (line index, text)
        for i, line in enumerate(blob.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message") if isinstance(obj.get("message"), dict) else obj
            if not isinstance(msg, dict):
                continue
            role = msg.get("role")
            if obj.get("type") == "user" or role == "user":
                last_user = i             # includes tool results, which is correct: they
                continue                  # still separate one reply chunk from the next
            if obj.get("type") == "assistant" or role == "assistant":
                text = _extract_text(msg.get("content"))
                if text:
                    replies.append((i, text))

        for i, text in reversed(replies):
            if i > last_user:
                return text
        return None                           # reply for this turn hasn't been flushed yet
    except Exception:
        return None


def assistant_text_settled(path, tries=8, delay=0.2):
    """last_assistant_text, but tolerant of the transcript still being flushed.

    The Stop hook can fire before Claude's final message has been written to the JSONL,
    which silently loses the reply. Retry briefly instead. Worst case ~1.6s, inside the
    hook's 5s timeout, and the chime has already played by the time we get here."""
    for i in range(tries):
        text = last_assistant_text(path)
        if text:
            return text
        if i < tries - 1:
            time.sleep(delay)
    return None


def classify_prompt(msg):
    """What kind of answer the session is blocked on.

    'permission' means a numbered selector, which a digit answers, not prose.
    'input' means free text is expected. Deliberately conservative: anything we
    can't positively identify as a permission popup is treated as free text, so
    Roost never sends a bare digit at something that wanted a sentence."""
    low = (msg or "").lower()
    for marker in ("permission", "approve", "wants to use", "allow"):
        if marker in low:
            return "permission"
    return "input"


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
        "transcript_path": data.get("transcript_path") or state.get("transcript_path", ""),
        "updated": time.time(),
    })

    if event == "tool":
        state["status"] = "thinking"
        state["last_action"] = short_action(data)
        state["prompt_kind"] = ""            # nothing to answer while it works
        state["message"] = ""
    elif event == "working":
        state["status"] = "thinking"
        state["prompt_kind"] = ""
        state["message"] = ""                # drop the previous turn's text rather than show it stale
        p = data.get("prompt")
        if p:
            state["last_action"] = "You: " + str(p).strip().split("\n")[0][:48]
    elif event == "done":
        state["status"] = "done"
        state["done_at"] = time.time()
        if not smuted:
            play("done.wav")   # chime first — it must not queue behind the transcript read below
        reply = assistant_text_settled(data.get("transcript_path"))
        if reply:
            state["last_action"] = "Claude: " + " ".join(reply.split())[:200]
            state["message"] = reply[:MAX_MSG]   # full text, for the panel to expand
            state["prompt_kind"] = "input"       # a finished turn takes a free-text follow-up
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
            # Keep Claude's reply: this ping lands ~60s after a turn ends, and that text is
            # exactly what the panel wants to show. Only a stale popup gets dropped.
            if state.get("prompt_kind") == "permission":
                state["message"] = ""
            state["prompt_kind"] = "idle"     # at the prompt box, so free text, not a digit
        else:
            state["status"] = "waiting"       # a genuine popup asking you to answer
            state["last_action"] = (msg or "needs your reply")[:60]
            state["message"] = msg[:MAX_MSG]
            state["prompt_kind"] = classify_prompt(msg)
            if not smuted:
                play("waiting.wav")   # chime only, no macOS banner

    try:
        with open(statefile, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


if __name__ == "__main__":
    main()
