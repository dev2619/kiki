import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar app, sin Dock
installMainMenu() // atajos estándar (Cmd+Q/W/M, Cmd+C/V/X/A/Z) — activos solo cuando Ajustes sube la app a .regular
app.run()
