import AppKit
import SwiftUI

/// Acento de marca kiki, mismo valor que `SettingsWindow.kikiAccent` — no se
/// reexporta esa constante `private` desde `SettingsWindow.swift`, así que se
/// repite aquí (dos literales de color en dos archivos son más baratos que
/// acoplar este archivo al de Ajustes).
private let kikiAccent = Color(red: 0x7C / 255.0, green: 0x5C / 255.0, blue: 0xFC / 255.0)

/// Ventana de onboarding "Preparando kiki…", mostrada SOLO durante la carga
/// de modelos del primer arranque (o cualquier arranque en frío mientras
/// prewarm/load corre — ver nota de `AppDelegate.loadModelInBackground` sobre
/// por qué se muestra siempre en vez de solo cuando hay descarga real).
///
/// Mismo patrón que `SettingsWindowController` (`NSHostingController` +
/// `NSWindow` creada por código, flip de `.accessory`→`.regular` mientras
/// está visible): kiki es una app `.accessory` (menu bar, sin Dock) y sin
/// subir a `.regular` la ventana puede aparecer sin foco de entrada real bajo
/// activación cooperativa — ver doc de `SettingsWindowController.show()`.
///
/// A diferencia de Ajustes, esta ventana nunca la reabre el usuario — se
/// muestra una sola vez por arranque y `dismiss()` solo la oculta
/// (`orderOut(nil)`, ver doc ahí sobre por qué NO se usa `close()`), nunca la
/// destruye. La instancia vive el resto del proceso, igual que
/// `settingsWindowController` — costo de memoria despreciable.
@MainActor
final class ModelLoadProgressWindowController {
    private var window: NSWindow?
    private let model = ModelLoadProgressModel()

    /// Sube a `.regular` (fuerza activación real, aparece un ícono de Dock
    /// temporal) y muestra la ventana centrada. Llamar una sola vez al
    /// arrancar — `loadModelInBackground` la invoca inmediatamente después de
    /// crear el controller.
    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: ModelLoadProgressView(model: model))
        let newWindow = NSWindow(contentViewController: host)
        // Solo `.titled`: barra de título sin botones de cerrar/minimizar/
        // maximizar (no se pasan `.closable`/`.miniaturizable`/`.resizable`)
        // — la ventana se cierra únicamente vía `dismiss()` cuando los
        // modelos terminan de cargar, nunca a mano por el usuario, y el
        // tamaño es fijo (`setContentSize` abajo, sin `.resizable`).
        newWindow.styleMask = [.titled]
        newWindow.title = "kiki"
        // `isReleasedWhenClosed = false`: nunca liberar la ventana por
        // nuestra cuenta (mismo valor que `SettingsWindowController` —
        // memoria despreciable, una sola instancia por proceso). Ver doc de
        // `dismiss()` sobre por qué además NUNCA se llama `close()` sobre
        // esta ventana: la combinación de `close()` + esta política se probó
        // primero y igual crasheaba (ver ahí).
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(NSSize(width: 360, height: 280))
        newWindow.center()
        newWindow.isMovableByWindowBackground = true
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
    }

    /// Actualiza la etiqueta de fase (p. ej. "Descargando modelo de voz…") y
    /// el progreso 0...1 ya agregado (`ModelLoadProgress.overall`, calculado
    /// por el llamador) que la barra debe mostrar.
    func update(phaseLabel: String, fraction: Double) {
        model.phaseLabel = phaseLabel
        model.fraction = fraction
    }

    /// Oculta la ventana y vuelve a `.accessory` (puro menu-bar, sin Dock) —
    /// simétrico con el `setActivationPolicy(.regular)` de `show()`. Llamado
    /// desde `AppDelegate.markReady()` (éxito, con o sin refinado IA) y desde
    /// el catch de fallo total de `loadModelInBackground` (para no dejar la
    /// ventana de carga pegada en pantalla sobre el menú "Error cargando
    /// modelo").
    ///
    /// `orderOut(nil)`, NUNCA `window.close()`: un primer intento de esta
    /// feature usaba `close()` y reprodujo un EXC_BAD_ACCESS/SIGSEGV
    /// consistente en `objc_release` / `-[_NSWindowTransformAnimation dealloc]`
    /// (confirmado en `~/Library/Logs/DiagnosticReports/Kiki-*.ips`, dos
    /// veces, durante el LAUNCH de verificación de esta feature — persistió
    /// incluso tras fijar `isReleasedWhenClosed = false` y dejar de anular
    /// `window` a `nil`). `close()` dispara el ciclo de vida completo de
    /// cierre de `NSWindow` — incluyendo su animación implícita de cierre —
    /// justo mientras la barra de progreso todavía puede estar animando su
    /// última actualización (100% al terminar `refiner.prepare()`); algo en
    /// esa carrera deja un puntero colgante que Core Animation intenta
    /// liberar en el siguiente commit de transacción. `orderOut(nil)` en
    /// cambio solo saca la ventana de pantalla (mismo mecanismo que usa
    /// `HUDController` para su `NSPanel`, ver `HUDController.show`) sin tocar
    /// el ciclo de vida de cierre — evita el codepath problemático por
    /// completo. Verificado estable en 3 relanzamientos consecutivos tras
    /// este cambio (ver reporte de la feature).
    func dismiss() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class ModelLoadProgressModel: ObservableObject {
    @Published var phaseLabel: String = "Preparando…"
    @Published var fraction: Double = 0
}

private struct ModelLoadProgressView: View {
    @ObservedObject var model: ModelLoadProgressModel

    private var appIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private var percentText: String {
        "\(Int((model.fraction * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                // Fallback si no corre empaquetada como .app (p. ej. `swift run`),
                // igual que `AboutSectionView` en `SettingsWindow.swift`.
                Image(systemName: "waveform.circle.fill")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(kikiAccent)
            }

            Text("Preparando kiki…")
                .font(.title2.bold())

            Text(model.phaseLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(spacing: 4) {
                ProgressView(value: model.fraction)
                    .progressViewStyle(.linear)
                    .tint(kikiAccent)
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Esto solo ocurre la primera vez — luego kiki abre al instante.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 360)
    }
}
