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

// Diagnostic: `Roost --tabs` lists what Roost believes is a real terminal tab.
// A session whose tty is not in this list can never be typed into.
if args.contains("--tabs") {
    let sem = DispatchSemaphore(value: 0)
    ITerm.fetchNames { names, live in
        print("live tabs (\(live.count)):")
        for t in live.sorted() { print("  \(t)   \(names[t] ?? "(no title)")") }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// Design harness for the reply UI. Developer scaffolding, off unless asked for.
if args.contains("--preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)          // a normal window, so it can take focus
    let preview = PreviewController()
    app.delegate = preview
    app.run()
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar agent — no Dock icon
app.run()
