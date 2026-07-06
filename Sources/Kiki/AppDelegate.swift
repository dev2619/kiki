import AppKit
import KikiAudio
import KikiContext
import KikiCore
import KikiInsert
import KikiRefine
import KikiSTT

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private(set) var controller: DictationController!
    let recorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let refiner = LLMRefiner()
    let appContext = FrontmostAppContext()
    private var hotkey: HotkeyMonitor!
    private var hud: HUDController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestMicrophoneAccess()
        Permissions.ensureAccessibility()

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter(),
            refiner: refiner,
            context: appContext)
        controller.delegate = self

        hud = HUDController()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.updateLevel(level) }
        }

        setUpStatusItem()
        loadModelInBackground()

        hotkey = HotkeyMonitor(
            onPress: { [weak self] in
                Task { @MainActor in self?.controller.hotkeyPressed() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in await self?.controller.hotkeyReleased() }
            })
        hotkey.start()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: "kiki")
        statusItem.button?.appearsDisabled = true // hasta que cargue el modelo

        let menu = NSMenu()
        let status = NSMenuItem(title: "Cargando modelos…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Salir de kiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func loadModelInBackground() {
        // Un solo Task (hereda MainActor) para que la carga de Whisper y la
        // del LLM queden serializadas — evita llamadas concurrentes a
        // prepare() en ambos modelos.
        Task {
            do {
                try await self.transcriber.prepare()
            } catch {
                KikiLog.log("kiki: error cargando modelo de transcripción: \(error)")
                await MainActor.run {
                    self.statusItem.menu?.item(withTag: 1)?.title = "Error cargando modelo"
                }
                return
            }

            do {
                try await self.refiner.prepare()
                await MainActor.run { self.markReady() }
            } catch {
                KikiLog.log("kiki: error cargando modelo de refinado LLM: \(error)")
                await MainActor.run { self.markReady(refinementAvailable: false) }
            }
        }
    }

    private func markReady(refinementAvailable: Bool = true) {
        statusItem.button?.appearsDisabled = false
        statusItem.menu?.item(withTag: 1)?.title = refinementAvailable
            ? "Listo — mantén Fn para dictar"
            : "Listo (sin refinado IA)"
    }
}

extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        hud.show(state: state)
    }

    func dictationDidFail(_ error: DictationError) {
        KikiLog.log("kiki error: \(String(describing: error))")
        hud.show(state: .idle)
    }
}
