# Changelog

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
