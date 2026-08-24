# Legacy — retired code, do not install

This folder holds the **original Hammerspoon prototype** of Roost. It has been
**superseded by the native `Roost.app`** (Swift/AppKit) at the repo root.

It's kept here only for history and reference. **Don't install this** — use the
native app instead:

```bash
# from the repo root
./install.sh
./build-app.sh --install
```

See the main [README](../README.md).

---

### `hammerspoon/init.lua`

The first version of Roost: a transparent `hs.webview` notch panel rendered in
HTML/CSS/JS and driven by [Hammerspoon](https://www.hammerspoon.org). It reads the
same `~/.claude-notch/state` folder as the native app, so the data layer (the
python reporter + hooks) is identical — only the UI engine differs. The native app
replaced it with real `NSVisualEffectView` glass, a proper notch-shouldered shape,
a spring animation, and a double-clickable `.app` that needs no Hammerspoon install.
