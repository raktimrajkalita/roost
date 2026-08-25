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
    private var updatePoll: Timer?       // reads the updater's progress file
    private var realPct = 0              // last milestone the updater actually reported
    private var stepStart = Date()       // when that milestone landed
    private var shownPct = 0             // eased, monotonic value on screen

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
        model.onUpdateNow = { [weak self] in self?.startUpdate() }
        model.onUpdateDismiss = { [weak self] in self?.setUpdate(.none) }
        buildPanel()
        refresh()
        showInstalledIfJustUpdated()
        // quiet check shortly after launch, then daily
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.checkForUpdates(announce: false)
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(announce: false)
        }
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
        let banner: CGFloat = model.update == .none ? 0 : (model.searching ? 42 : 50)
        let total = notchHeight + searchBar + banner + body
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

    // MARK: updates — surfaced in the panel, never in a modal

    /// `announce` shows "checking"/"up to date" too; the silent background poll only speaks
    /// up when there's actually something to install.
    func checkForUpdates(announce: Bool) {
        if announce {
            setUpdate(.checking)
            pinnedUntil = Date().addingTimeInterval(6)
            if !visible { show() }
        }
        Updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                if announce { self.setUpdate(.upToDate, clearAfter: 3) }   // don't nag about network trouble
            case .success(nil):
                if announce { self.setUpdate(.upToDate, clearAfter: 3) }
            case .success(.some(let u)):
                self.setUpdate(.available(u.count))
                self.pinnedUntil = Date().addingTimeInterval(5)
                if !self.visible { self.show() }
            }
        }
    }

    private func setUpdate(_ s: UpdateState, clearAfter: Double? = nil) {
        withAnimation(.easeInOut(duration: 0.24)) { model.update = s }
        relayout(allowShrink: true)
        if let t = clearAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.model.update == s else { return }
                withAnimation(.easeInOut(duration: 0.24)) { self.model.update = .none }
                self.relayout(allowShrink: true)
            }
        }
    }

    private func startUpdate() {
        guard let repo = Updater.sourcePath else {
            setUpdate(.none)
            return
        }
        try? FileManager.default.removeItem(atPath: Updater.progressPath)
        realPct = 0; shownPct = 0; stepStart = Date()
        setUpdate(.installing(0))
        pinnedUntil = Date().addingTimeInterval(180)     // keep it on screen through the rebuild
        if !visible { show() }
        Updater.install(from: repo) { [weak self] err in
            guard let self else { return }
            if err != nil { self.setUpdate(.none); return }
            // follow the updater's own progress file until this process is replaced
            self.updatePoll?.invalidate()
            self.updatePoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate(); }
                guard let p = Updater.readProgress() else { return }
                if p < 0 {                                // updater bailed (dirty repo)
                    t.invalidate()
                    self.setUpdate(.none)
                    return
                }
                self.pinnedUntil = Date().addingTimeInterval(30)
                if p >= 100 {                             // finished; normally we're killed before
                    t.invalidate()                        // this, but if we survive, don't sit at 99
                    self.model.update = .installing(100)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.setUpdate(.none)
                    }
                    return
                }
                if p != self.realPct { self.realPct = p; self.stepStart = Date() }
                // A release build is whole-module, so one [N/M] step does most of the work and
                // the bar would sit still for a minute. Ease toward the next milestone while a
                // step runs — motion without ever claiming ground we haven't actually taken.
                let cap = p >= 85 ? p : min(84, p + 45)
                let dt = Date().timeIntervalSince(self.stepStart)
                let eased = Double(p) + (Double(cap) - Double(p)) * (1 - exp(-dt / 14))
                let show = max(self.shownPct, min(Int(eased), 99))
                guard show != self.shownPct else { return }
                self.shownPct = show
                self.model.update = .installing(show)
            }
        }
    }

    /// The updater leaves a marker; if it's here, this launch is the one after an update.
    private func showInstalledIfJustUpdated() {
        let f = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-notch/updated")
        guard FileManager.default.fileExists(atPath: f) else { return }
        // the marker is consumed here, so this only ever shows once per update; it then waits
        // for the ✕ rather than timing out, and dismissing it is final
        try? FileManager.default.removeItem(atPath: f)
        pinnedUntil = Date().addingTimeInterval(5)
        setUpdate(.installed)
    }

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
