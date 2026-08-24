import AppKit
import SwiftUI

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

    private let panelWidth: CGFloat = 380

    init(store: SessionStore) {
        self.store = store
        model.width = panelWidth
        model.onFocus = { ITerm.focus(uuid: $0) }
        model.onMute = { [weak self] id in self?.store.toggleMute(id: id) }
        model.onReload = { [weak self] in self?.store.forceRefresh() }
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

    private func panelFrame() -> CGRect {
        let s = notchScreen
        let f = s.frame
        let rowH: CGFloat = 49
        let shown = min(store.sessions.count, 10)                  // cap the panel at 10 rows; the rest scrolls
        let body = store.sessions.isEmpty ? 46 : (CGFloat(shown) * rowH + 16)
        let total = notchHeight + body
        let W = model.width + model.flareW * 2            // body + the two top shoulders
        return CGRect(x: f.midX - W / 2, y: f.maxY - total, width: W, height: total)
    }

    // MARK: panel

    private func buildPanel() {
        panel = NSPanel(contentRect: panelFrame(),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu                 // above the menu bar / notch
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // the SwiftUI view draws its own shadow
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        panel.alphaValue = 0
        model.notchHeight = notchHeight
    }

    private func updateContent() {
        model.notchHeight = notchHeight
        model.sessions = store.sessions          // SwiftUI updates rows in place, no re-animation
        let f = panelFrame()                     // collapsed target = the physical notch, as a fraction of the full panel
        model.collapsedScaleX = min(max(notchRect().width / f.width, 0.2), 0.9)
        model.collapsedScaleY = min(max(notchHeight / f.height, 0.05), 0.9)
    }

    // MARK: public — called by AppController on every store change

    func refresh() {
        let done = store.sessions.filter { $0.status == "done" }.count
        updateContent()
        if visible { panel.setFrame(panelFrame(), display: true, animate: false) }
        if done > prevDone {                     // a session just finished -> notification drop
            pinnedUntil = Date().addingTimeInterval(3)
            if !visible { show() }
        }
        prevDone = done
    }

    // MARK: show / hide

    private func show() {
        hideWork?.cancel(); hideWork = nil
        updateContent()
        panel.setFrame(panelFrame(), display: true, animate: false)   // full-size window; SwiftUI does the grow
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        visible = true
        model.expanded = true                    // springs open from the notch
    }

    private func hide() {
        visible = false
        model.expanded = false                   // springs closed back into the notch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visible == false else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)   // remove after the collapse settles
    }

    // MARK: hover loop

    private func tick() {
        let m = NSEvent.mouseLocation           // screen coords, bottom-left origin
        let now = Date()
        let inTrigger = triggerRect().contains(m)
        let overPanel = visible && panel.frame.contains(m)
        let inside = inTrigger || overPanel
        if inside { lastInside = now }
        let want = inside
            || now < pinnedUntil
            || (visible && now.timeIntervalSince(lastInside) < 0.25)
        if want {
            if !visible { show() }
        } else if visible {
            hide()
        }
    }
}
