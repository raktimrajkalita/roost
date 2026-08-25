# Changelog

## v2.2 — quality of life (2026-08-25)

- **The panel no longer dips as it opens.** The grow spring was under-damped, so it overshot its
  final height and settled back — with the top anchored, that rebound read as the panel dropping
  and then re-aligning. It's near-critically damped now, and the same motion runs in reverse on
  close: out of a notch-sized sliver in both axes, and back into it the same way, strictly
  top-pinned throughout. Pending window resizes are cancelled on show and hide so a queued one
  can't shift the frame mid-animation.

- **Keep a search result on the notch.** Hovering a search hit that isn't currently on the panel
  offers a **+** — the exact inverse of the ✕ that removes one. Deliberately not a pin: a pin
  promises permanence this doesn't have. A kept session skips the 20-minute dormancy cutoff and
  any earlier dismissal, and stays until you ✕ it or Roost restarts — the same in-memory contract
  as everything else, so nothing accumulates on disk. ✕ always overrides a keep, and the button
  flips to ✕ the moment the row lands on the panel.
- **Click outside to dismiss.** While searching the panel is pinned open, so a click anywhere
  outside it now exits search and collapses the panel entirely. Uses a global mouse monitor,
  which by design only sees events bound for other apps — clicks inside the panel never fire it.
- **👻 in the empty state**, with real layout spacing beside it (a word space renders tight
  against an emoji).

## v2.1 — search + UI retouch (2026-08-25)

### Search
- **Search every session from the notch.** A lens in the notch strip morphs into an ✕ and a
  search field descends out of the notch. It searches session name, project folder and last
  action across **every** session on disk — including ones long dormant and dropped from the
  panel, and ones you've dismissed — so a session that finished three hours ago is still findable.
- The panel is a non-activating window, which can never become key, so a text field in it would
  receive no keystrokes. It's now a `KeyablePanel` that can take key focus; opening search
  activates briefly and closing hands focus straight back to your terminal.
- The panel is pinned open while searching, so moving the mouse away no longer yanks it shut
  mid-type.

### Indicators — one family, two hues
- **thinking → Bloom**: nine dots on a phyllotaxis spiral (golden angle 137.5°, radius √n),
  each breathing on a staggered phase. Rendered white — thinking has no hue, because it needs
  nothing from you.
- **waiting → a single amber dot**, pulsing.
- **done → Settle**: the halo contracts onto a core and holds. Driven off the session's own
  `done_at`, so it resolves once on arrival and never replays.
- Colour now means something: amber = answer me, green = finished. Two hues in the whole panel
  instead of three saturated ones printed twice per row.

### Panel polish
- **The status word is gone, replaced by elapsed time** (`now`, `3m`, `2h`). The word only
  repeated the icon beside it and the sentence under it; the age is information you had nowhere else.
- **Quiet right edge.** The bell no longer renders on every row at rest — hover a row and the
  controls take the timestamp's slot, in a fixed-width well so nothing shifts. A muted session
  still shows its bell, because there it's a state rather than a control.
- **Row weight carries the hierarchy**: actionable rows sit forward, working rows sit back.
- **Rows swipe out.** Dismissing one, or clearing the finished ones with refresh, slides them
  off to the trailing edge while the rest close the gap — and the window resizes on the same clock.
- **Inner glow along the bottom edge** that reports the whole panel's state: a white breath while
  anything is thinking, amber when something is blocked on you, green when everything is done,
  a quiet blue when nothing is running.
- Window resizes are coalesced, and while searching the window only ever grows — the visible edge
  is drawn by SwiftUI, so the panel shrinks softly inside a window that stays put instead of snapping.
- The strip controls (reload left, search right) live inside the notch strip itself rather than
  overlaid on the panel, so the panel's spring can't drag them around.

## v2.0 — native rewrite (2026-08-24)

A ground-up native **Swift / AppKit / SwiftUI** rewrite, replacing the Hammerspoon
prototype. Same reporter, same `~/.claude-notch/state` data layer — new UI engine,
packaged as a real double-clickable `Roost.app`.

### New UI engine
- Menu-bar agent (`NSStatusItem`, `.accessory` policy — no Dock icon) driving a
  borderless, non-activating `NSPanel` at `.popUpMenu` level with a transparent background.
- **Real glass:** `NSVisualEffectView` (`.hudWindow`, behind-window) backdrop instead of CSS blur.
- **Real notch geometry:** panel width/position derived from `NSScreen.safeAreaInsets.top`
  and the `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` gap.
- Closed hover-trigger is the physical notch only (inset 8px); the open panel is wider (420px).

### Look & feel
- **Notch-shouldered shape** (`NotchPanelShape`): flat top flush with the menu bar, concave
  flared shoulders at the top corners, vertical body walls, rounded bottom — reads as the notch
  growing down, not a floating rectangle.
- **Grow-out-of-the-notch animation:** open/close is a SwiftUI scale + opacity spring from a
  notch-sized sliver into the full panel and back (no text reflow); the window defers removal
  until the collapse settles.
- **Absolute-black notch strip:** the top band (exactly the physical-notch height) is 100% opaque
  black with *no* blur, so it fuses seamlessly with the notch; frosted glass only below it,
  easing to 40% at the bottom.
- Tuned background blur (`~35%`).
- **Status indicators** as one visual family (`TimelineView(.animation)`): thinking = three dots
  swelling in sequence, waiting = a breathing halo dot, done = a static check.
- Muted bell is white (was amber).

### Quality of life
- **Works in any terminal:** hook-driven monitoring already ran everywhere; click-to-jump now
  dispatches per terminal. iTerm2 uses its `unique id`, Terminal.app matches by `tty` (the reporter
  records the tab's controlling tty via `ps`), and other terminals fall back to raising the app.
- **Dismiss a row:** hover a row and click the ✕ to remove it; it comes back the moment that
  session next updates (per-session, in-memory).
- **Terminal.app names:** the panel shows a Terminal tab's custom title (its rename) when set,
  fetched by `tty` alongside the iTerm names — both guarded by `is running` so a background
  refresh never launches a closed terminal.
- **Shows everywhere:** the auto-drop now appears on whatever Space is active and over fullscreen
  apps — fixed `NSPanel.hidesOnDeactivate` (default `true`) suppressing the panel whenever another
  app was frontmost; panel is now `.screenSaver` level with `[.canJoinAllSpaces, .fullScreenAuxiliary]`.
- **Refresh clears done:** the reload button hides every finished row; they stay hidden until a
  *new* completion arrives (tracked by `done_at` vs a dismissal timestamp).
- **10-row cap + scroll:** the panel shows at most 10 rows and scrolls beyond that.
- **Env-configurable launch preview** via `ROOST_PREVIEW=<seconds>` (default 3).
- Status normalization carried over: idle "waiting for input" pings never read as real prompts;
  silent-5-min `thinking` → done; dormant (>20 min) sessions drop off.

### Packaging & distribution
- `build-app.sh` assembles, ad-hoc-signs, and (with `--install`) installs `Roost.app` to
  `/Applications` and registers a login item — Command Line Tools only, no Xcode.
- Custom app icon: the pixel-art "roost" wordmark, converted to a native squircle `.icns`
  by `icon/png-to-icns.swift` (headless CoreGraphics).
- `Info.plist` with `LSUIElement` and `NSAppleEventsUsageDescription` for the iTerm2 Automation grant.

## v1.0 — Hammerspoon prototype

The original: a `hs.webview` notch panel driven by the same python reporter. Retired and
preserved in [`legacy/hammerspoon/`](legacy/hammerspoon/) and in the git history.
