import AppKit

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // menu bar agent — no Dock icon
app.run()
