import AppKit
import KikiAudio
import KikiCore
import KikiInsert
import KikiSTT

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private(set) var controller: DictationController!
    let recorder = AudioRecorder()
    let transcriber = WhisperTranscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestMicrophoneAccess()
        Permissions.ensureAccessibility()

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter())
        controller.delegate = self

        setUpStatusItem()
        loadModelInBackground()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: "kiki")
        statusItem.button?.appearsDisabled = true // hasta que cargue el modelo

        let menu = NSMenu()
        let status = NSMenuItem(title: "Cargando modelo…", action: nil, keyEquivalent: "")
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
        Task {
            do {
                try await self.transcriber.prepare()
                await MainActor.run { self.markReady() }
            } catch {
                NSLog("kiki: error cargando modelo: \(error)")
                await MainActor.run {
                    self.statusItem.menu?.item(withTag: 1)?.title = "Error cargando modelo"
                }
            }
        }
    }

    private func markReady() {
        statusItem.button?.appearsDisabled = false
        statusItem.menu?.item(withTag: 1)?.title = "Listo — mantén Fn para dictar"
    }
}

extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        NSLog("kiki estado: \(state)")
    }

    func dictationDidFail(_ error: DictationError) {
        NSLog("kiki error: \(String(describing: error))")
    }
}
