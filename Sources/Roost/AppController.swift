import AppKit

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = SessionStore()
    private var notch: NotchController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪺"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        notch = NotchController(store: store)
        store.onChange = { [weak self] in
            self?.updateTitle()
            self?.notch.refresh()
        }
        store.start()
        updateTitle()
    }

    private func updateTitle() {
        statusItem.button?.title = store.menuBarTitle
    }

    @objc private func focus(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? Session else { return }
        ITerm.focus(session: session)
    }

    // MARK: updates

    /// Answers in the notch panel rather than a modal alert.
    @objc private func checkForUpdates() {
        notch.checkForUpdates(announce: true)
    }
}

/// Collapse whitespace and clip to a length the menu can wear.
private func clip(_ s: String, _ n: Int) -> String {
    let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return t.count <= n ? t : String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let sessions = store.sessions
        if sessions.isEmpty {
            let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for s in sessions {
                // last_action carries up to 200 chars of Claude's reply; unclipped it stretches
                // the menu across the whole screen
                let title = "\(s.statusGlyph)  \(clip(s.displayName, 24))  ·  \(clip(s.lastAction, 32))"
                let item = NSMenuItem(title: title, action: #selector(focus(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let upd = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Roost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
