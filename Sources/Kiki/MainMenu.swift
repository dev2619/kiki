import AppKit

/// Menú principal estándar de macOS, requerido para que los atajos de teclado
/// del sistema funcionen dentro de la ventana de Ajustes.
///
/// kiki es una app `.accessory` (menu bar, sin Dock) y por defecto
/// `NSApplication` nunca instala un `mainMenu` — sin él, AppKit no tiene
/// dónde registrar los atajos estándar (Cmd+Q, Cmd+W, Cmd+M) ni, crítico,
/// las acciones `nil`-target de la cadena de responders que hacen funcionar
/// Cmd+C/V/X/A/Z (copiar/pegar/cortar/seleccionar todo/deshacer) en los
/// `TextField` de las secciones Diccionario y Snippets.
///
/// El menú es inofensivo mientras la app está en modo `.accessory` (no se
/// muestra) y se activa solo cuando `SettingsWindowController.show()` sube
/// la política de activación a `.regular` para abrir Ajustes.
///
/// Sin `@MainActor`: `main.swift` es un top-level script (contexto
/// no-aislado bajo swift-tools 5.10) que ya invoca APIs de AppKit
/// (`NSApplication.setActivationPolicy`) directamente en ese mismo
/// contexto — aislar esta función a `@MainActor` rompería esa llamada
/// síncrona. El proceso entero corre en el hilo principal de todos modos
/// (app de UI clásica de AppKit), así que no hay riesgo real de
/// concurrencia aquí.
func installMainMenu() {
    let mainMenu = NSMenu()

    mainMenu.addItem(appMenuItem())
    mainMenu.addItem(editMenuItem())

    let windowMenuItem = windowMenuItemBuilder()
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenuItem.submenu
}

/// Menú de la app (primer ítem, título = nombre de la app): solo lo
/// imprescindible — Salir (Cmd+Q). AppKit sustituye automáticamente el
/// literal "kiki" en runtime por el nombre real de la app si hiciera falta,
/// pero como el bundle ya se llama "kiki" lo dejamos explícito en español.
private func appMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "kiki")

    submenu.addItem(
        NSMenuItem(
            title: "Salir de kiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

    item.submenu = submenu
    return item
}

/// Menú Editar: acciones estándar de edición de texto, enrutadas vía
/// selectores `nil`-target de la cadena de responders (target: nil) — así
/// llegan al `NSText`/`NSTextField` con foco en cada momento, sin acoplar
/// este menú a ninguna vista concreta de Ajustes.
private func editMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "Editar")

    submenu.addItem(
        NSMenuItem(title: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(
        title: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    submenu.addItem(redo)

    submenu.addItem(NSMenuItem.separator())

    submenu.addItem(
        NSMenuItem(title: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    submenu.addItem(
        NSMenuItem(title: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    submenu.addItem(
        NSMenuItem(title: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    submenu.addItem(
        NSMenuItem(
            title: "Seleccionar todo", action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"))

    item.submenu = submenu
    return item
}

/// Menú Ventana: minimizar/cerrar estándar, más registro como
/// `NSApp.windowsMenu` (hecho por el caller) para que AppKit gestione la
/// lista de ventanas abiertas automáticamente.
private func windowMenuItemBuilder() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "Ventana")

    submenu.addItem(
        NSMenuItem(
            title: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"))
    submenu.addItem(
        NSMenuItem(
            title: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

    item.submenu = submenu
    return item
}
