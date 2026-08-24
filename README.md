# 🪺 Roost

**Your Claude Code sessions, watched from the notch.** A tiny macOS companion that lives in the notch, shows every running Claude Code session at a glance, chimes when one finishes, and jumps you straight to the right terminal tab.

![Roost preview](docs/preview.png)

---

## The pain point

I run a *lot* of Claude Code sessions at once, spread across iTerm2 tabs and windows. Two things kept biting me:

1. **I'd miss when a session finished.** It would go quiet waiting for me while I was heads-down in another tab, and I wouldn't notice for minutes.
2. **I'd click the wrong one.** With a dozen near-identical terminal tabs, finding *which* session just needed me was a guessing game.

I wanted something ambient: a single place, always in view, that tells me what every session is doing and nudges me the moment one needs me, without me having to go looking.

The notch is dead space at the top of every modern MacBook. So I put it to work.

## What Roost does

- **One glance, every session.** Hover the notch and the whole panel becomes the hover zone — it stays open while your cursor is on it and snaps back when you leave. Each row shows a live status: `thinking`, `waiting`, or `done`, plus the current action (e.g. "Read app-sidebar.tsx").
- **It comes to you.** When a session finishes, the panel auto-drops for 3 seconds and plays a short metallic chime — and if music or a video is already playing, the chime is boosted so it cuts through. Move onto the panel within those 3s and it stays.
- **Your names, not folders.** Roost shows each session's **iTerm2 tab name** (the name Claude Code sets, e.g. "MYPROJ", "Aina Main"), falling back to the folder name only when a tab has none.
- **Click to teleport.** Click a session and Roost focuses that exact iTerm2 tab, no more hunting.
- **Per-session mute.** Each row has its own speaker button. Silence a chatty session without muting the rest. There's a global mute too.
- **Never gets stuck.** Statuses self-correct (an idle "waiting for input" ping is never mistaken for a real prompt), and dormant sessions drop off on their own so the panel only shows what's actually active.
- **Menu bar fallback.** A menu bar item shows live counts and the full list, in case you want it without the notch.

Status is real, not guessed: green = done and waiting for you, amber = blocked on your input or a permission, blue = actively thinking.

## How it works

Two small layers, no server, no daemon of its own:

```
Claude Code hooks ──▶ reporter (python) ──▶ ~/.claude-notch/state/*.json ──▶ Hammerspoon UI (webview)
   Stop / Notification /      writes one json per        one file per session          reads the folder, draws the
   PreToolUse / etc.          session; plays the chime    (status + last action)        notch panel + menu bar
```

1. **Reporter.** Claude Code fires lifecycle [hooks](hooks/settings.snippet.json). A tiny python script (`bin/notch-hook.py`) turns each event into a status, writes it to a per-session JSON file, and on `done` / a real prompt plays the metallic chime (unless that session is muted). The notch panel + chime *are* the notification — no macOS banners.
2. **UI.** A [Hammerspoon](https://www.hammerspoon.org) config (`hammerspoon/init.lua`) watches that folder and renders the panel as a transparent `hs.webview` (HTML/CSS/JS), so it can do real glass edges, high corner radius, and micro-animations. Clicks post back to Lua, which drives AppleScript to focus the right iTerm2 session by its unique id.

The panel is absolute black on purpose: it fuses with the physical notch and hides it, so it reads as the notch *growing* downward rather than a floating window.

## Install

**Requirements:** macOS, [Hammerspoon](https://www.hammerspoon.org), and [Claude Code](https://claude.com/claude-code). A notch is nice but not required, the panel just drops from the top center.

```bash
git clone https://github.com/raktimrajkalita/roost.git
cd roost
./install.sh                       # copies the reporter + sounds into ~/.claude-notch/
brew install --cask hammerspoon    # the UI engine
open -a Hammerspoon                 # grant Accessibility when asked
```

Then add the hooks from [`hooks/settings.snippet.json`](hooks/settings.snippet.json) into your `~/.claude/settings.json` (merge into any existing `"hooks"` block; the installer prints the exact snippet). New sessions report automatically; restart open ones to pick up the hooks.

On the first click-to-focus, macOS will ask to let Hammerspoon control iTerm2, approve it once.

## Customization

- **Use your own sound.** Drop any short audio in as `~/.claude-notch/sounds/done.wav` (and `waiting.wav`). The bundled chimes are generated from scratch by `bin/gen-sounds.py` (pure additive synthesis, no samples), so they're royalty-free, run it again to retune.
- **Mute.** Per session: click its speaker. Mute all sound: `touch ~/.claude-notch/muted` (or the menu bar toggle). Fully silence: `touch ~/.claude-notch/disabled`.
- **Force refresh.** Hit **⌃⌥⌘R** (or menu bar → Force refresh) to re-fetch tab names + state and re-render instantly — handy right after you rename a tab.
- **Tweak the look.** Colors, corner radius, and animations all live in the CSS inside `hammerspoon/init.lua`. Reload with `hs.reload()`.

## A few engineering notes

Things I learned the fun way building this:

- **No flicker on hover.** The webview shell loads *once*; rows are updated in place via a keyed diff (only genuinely new sessions animate). Reloading the HTML on every hover was the original cause of a flutter.
- **Closing the bezel seam.** The panel overshoots a few pixels *above* the screen top so the black runs behind the bezel with no hairline gap.
- **Glass without real blur.** Hammerspoon can't expose macOS's desktop backdrop-blur, so the "glass" is opaque black plus light-edge cues, which is also what makes the notch disappear.
- **`hs.fs.dir` must be iterated inline**, not captured into a variable, or it loses its directory state.
- **The chime must be detached.** `afplay` is launched with `start_new_session` so it survives the short-lived hook process being reaped — otherwise the sound gets cut off most of the time.
- **Robust reload by design.** The panel renders on the webview's `didFinishNavigation` event (not a timed guess), a 4s sweep self-heals a detached shell, and one `forceRefresh` (bound to ⌃⌥⌘R) re-fetches everything — so a Hammerspoon reload can never strand it blank or stale.
- **`tab` is a reserved word inside iTerm2's AppleScript** (it's the tab *class*), so the real tab character used as a field delimiter has to be grabbed *outside* the `tell` block.

## Credits

Built by [Raktim Raj Kalita](https://github.com/raktimrajkalita) as a weekend "scratch my own itch" project. UI powered by [Hammerspoon](https://www.hammerspoon.org); status comes from [Claude Code](https://claude.com/claude-code) hooks. Bundled sounds are synthesized, not sampled.

## License

[MIT](LICENSE).
