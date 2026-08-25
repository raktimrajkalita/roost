import AppKit
import SwiftUI

/// A borderless panel refuses key status by default, so a text field inside it would
/// never receive a keystroke. Search needs it, so allow it explicitly.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the notch panel window, hover detection, positioning, and auto-drop.
/// Trigger-to-open is ONLY the physical notch (slightly inset); the expanded
/// panel is wider and, once open, the whole panel is the keep-open area.
final class NotchController {
    private let store: SessionStore
    private let model = NotchModel()
    private var panel: NSPanel!
    private var pollTimer: Timer?

    private var visible = false
    private var lastInside = Date.distantPast
    private var pinnedUntil = Date.distantPast
    private var prevDone = 0
    private var hideWork: DispatchWorkItem?
    private var layoutWork: DispatchWorkItem?
    private var clickAway: Any?          // global mouse monitor while searching

    private let panelWidth: CGFloat = 380
    private let rowAnim: Double = 0.28        // row swipe-out; the window shrinks on the same clock

    init(store: SessionStore) {
        self.store = store
        model.width = panelWidth
        model.onFocus = { ITerm.focus(session: $0) }
        model.onMute = { [weak self] id in self?.store.toggleMute(id: id) }
        model.onDismiss = { [weak self] id in self?.store.dismiss(id: id) }
        model.onReload = { [weak self] in self?.store.forceRefresh() }
        model.onKeep = { [weak self] id in self?.store.keep(id: id) }
        model.searchFn = { [weak self] q in self?.store.search(q) ?? [] }
        model.onLayout = { [weak self] in self?.relayout() }
        model.onSearchWillOpen = { [weak self] in
            guard let self else { return }
            // Make room BEFORE anything animates. The new space is transparent and the panel is
            // top-anchored, so growing instantly is invisible; growing late (or with display:false)
            // shows a stale frame, which is what made the panel blink.
            self.layoutWork?.cancel()
            var f = self.panelFrame(searchOverride: true)
            f.origin.x = self.panel.frame.origin.x
            if f.height > self.panel.frame.height {
                self.panel.setFrame(f, display: true, animate: false)
            }
            NSApp.activate(ignoringOtherApps: true)         // an accessory app must activate to take keys
            self.panel.makeKeyAndOrderFront(nil)
            self.startClickAway()
        }
        model.onSearchDidClose = { [weak self] in
            guard let self else { return }
            self.stopClickAway()
            NSApp.deactivate()                              // hand focus back to whatever you were in
            self.layoutWork?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {   // let the bar retract first
                self.relayout(allowShrink: true)
            }
        }
        buildPanel()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in self?.tick() }
        // brief preview at launch so it's obvious it renders; then normal hover/auto-drop
        let preview = Double(ProcessInfo.processInfo.environment["ROOST_PREVIEW"] ?? "3") ?? 3
        pinnedUntil = Date().addingTimeInterval(preview)
        show()
        FileHandle.standardError.write(
            "[roost] notchScreen=\(notchScreen.localizedName) notchH=\(notchHeight) trigger=\(triggerRect()) panel=\(panelFrame())\n"
            .data(using: .utf8)!)
    }

    // MARK: geometry

    /// The screen that actually has the notch (fallback to main).
    private var notchScreen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var notchHeight: CGFloat { max(notchScreen.safeAreaInsets.top, 32) }

    /// Physical notch bounds, from the gap between the two menu-bar side areas.
    private func notchRect() -> CGRect {
        let s = notchScreen
        let f = s.frame
        var leftMaxX = f.midX - 100, rightMinX = f.midX + 100
        if let l = s.auxiliaryTopLeftArea { leftMaxX = l.maxX }
        if let r = s.auxiliaryTopRightArea { rightMinX = r.minX }
        return CGRect(x: leftMaxX, y: f.maxY - notchHeight,
                      width: max(rightMinX - leftMaxX, 120), height: notchHeight)
    }

    /// Open-trigger: the notch, slightly inset so it's "just inside the notch".
    private func triggerRect() -> CGRect { notchRect().insetBy(dx: 8, dy: 0) }

    /// `searchOverride` lets us measure the searching layout before the flag actually flips.
    private func panelFrame(searchOverride: Bool? = nil) -> CGRect {
        let s = notchScreen
        let f = s.frame
        let rowH: CGFloat = 49
        let count = model.rows.count                               // search results when searching
        let shown = min(count, 10)                                 // cap the panel at 10 rows; the rest scrolls
        let body = count == 0 ? 46 : (CGFloat(shown) * rowH + 16)
        let searchBar: CGFloat = (searchOverride ?? model.searching) ? 44 : 0
        let total = notchHeight + searchBar + body
        let W = model.width + model.flareW * 2            // body + the two top shoulders
        return CGRect(x: f.midX - W / 2, y: f.maxY - total, width: W, height: total)
    }

    // MARK: panel

    private func buildPanel() {
        panel = KeyablePanel(contentRect: panelFrame(),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false          // accessory app is never "active" — don't let the panel get suppressed
        panel.level = .screenSaver               // topmost: above the menu bar/notch AND over another app's fullscreen
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // the SwiftUI view draws its own shadow
        // show on every Space, and join a fullscreen app's space instead of hiding behind it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.alphaValue = 0
        model.notchHeight = notchHeight
    }

    private func updateContent() {
        model.notchHeight = notchHeight
        // rows animate in/out (dismiss and refresh both swipe them off to the trailing edge);
        // unchanged rows are matched by id and just slide into their new slot
        withAnimation(.easeInOut(duration: rowAnim)) {
            model.sessions = store.sessions
        }
        let f = panelFrame()                     // collapsed target = the physical notch, as a fraction of the full panel
        model.collapsedScaleX = min(max(notchRect().width / f.width, 0.2), 0.9)
        model.collapsedScaleY = min(max(notchHeight / f.height, 0.05), 0.9)
    }

    // MARK: public — called by AppController on every store change

    func refresh() {
        let done = store.sessions.filter { $0.status == "done" }.count
        updateContent()
        if visible { relayout(allowShrink: true) }   // grow/shrink alongside the row animation
        if done > prevDone {                     // a session just finished -> notification drop
            pinnedUntil = Date().addingTimeInterval(3)
            if !visible { show() }
        }
        prevDone = done
    }

    // MARK: show / hide

    private func show() {
        hideWork?.cancel(); hideWork = nil
        layoutWork?.cancel()                     // no window animation while the panel springs open
        updateContent()
        panel.setFrame(panelFrame(), display: true, animate: false)   // full-size window; SwiftUI does the grow
        panel.alphaValue = 1
        // re-assert every drop so it lands on whatever Space / fullscreen app is active right now
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        visible = true
        model.expanded = true                    // springs open from the notch
    }

    private func hide() {
        visible = false
        layoutWork?.cancel()                     // don't resize the window mid-collapse
        model.expanded = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visible == false else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)   // remove after the collapse settles
    }

    // MARK: hover loop

    // MARK: click-away

    /// While searching the panel is pinned, so a click anywhere outside it has to dismiss the
    /// whole thing explicitly. A global monitor only sees events destined for OTHER apps, so
    /// clicks inside our own panel never trigger it.
    private func startClickAway() {
        guard clickAway == nil else { return }
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.collapseFromSearch()
        }
    }

    private func stopClickAway() {
        if let m = clickAway { NSEvent.removeMonitor(m) }
        clickAway = nil
    }

    /// Clicked outside: leave search and put the panel away entirely.
    private func collapseFromSearch() {
        guard model.searching else { return }
        stopClickAway()
        withAnimation(.easeOut(duration: 0.2)) {
            model.searching = false
            model.query = ""
        }
        NSApp.deactivate()
        pinnedUntil = .distantPast
        lastInside = .distantPast
        hide()
    }

    /// Re-measure the window after the rows or the search bar change.
    /// Coalesced, because every keystroke fires this and interrupting an in-flight window
    /// animation is what makes the panel stutter.
    private func relayout(allowShrink: Bool = false) {
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visible else { return }
            var target = self.panelFrame()
            // While searching, only ever grow. The visible edge is drawn by SwiftUI, so the panel
            // can shrink softly inside a window that stays put — no snapping frame.
            if self.model.searching && !allowShrink && target.height < self.panel.frame.height {
                return
            }
            if abs(target.height - self.panel.frame.height) < 0.5 { return }
            target.origin.x = self.panel.frame.origin.x
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().setFrame(target, display: true)
            }
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func tick() {
        let m = NSEvent.mouseLocation           // screen coords, bottom-left origin
        let now = Date()
        let inTrigger = triggerRect().contains(m)
        let overPanel = visible && panel.frame.contains(m)
        let inside = inTrigger || overPanel
        if inside { lastInside = now }
        let want = inside
            || model.searching                  // never yank the panel away mid-search
            || now < pinnedUntil
            || (visible && now.timeIntervalSince(lastInside) < 0.25)
        if want {
            if !visible { show() }
        } else if visible {
            hide()
        }
    }
}
