import AppKit

// Diagnostic: `Roost --check-tty /dev/ttys005` reports whether Roost would consider it
// safe to type into that tab, and why not if it wouldn't. Exits without starting the UI.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--check-tty") {
    let tty = i + 1 < args.count ? args[i + 1] : ""
    switch ITerm.foregroundCheck(tty: tty) {
    case .ok:
        print("ALLOW   \(tty)")
        exit(0)
    case .refused(let why):
        print("REFUSE  \(tty): \(why)")
        exit(1)
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar agent — no Dock icon
app.run()
