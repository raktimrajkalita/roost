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
                let title = "\(s.statusGlyph)  \(s.displayName)  —  \(s.lastAction)"
                let item = NSMenuItem(title: title, action: #selector(focus(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Roost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
