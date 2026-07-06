import AppKit
import KikiAudio
import KikiContext
import KikiCore
import KikiInsert
import KikiRefine
import KikiSTT
import KikiWake

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let wakeEnabledKey = "kiki.wakeEnabled"
    private static let wakeMenuItemTag = 2

    private var statusItem: NSStatusItem!
    private(set) var controller: DictationController!
    let recorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let refiner = LLMRefiner()
    let appContext = FrontmostAppContext()
    private var hotkey: HotkeyMonitor!
    private var escMonitor: EscMonitor!
    private var hud: HUDController!
    private var wakeListener: WakeListener!
    private var wakeEnabled = UserDefaults.standard.bool(forKey: AppDelegate.wakeEnabledKey)
    private var wakePausedByDictation = false

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

        wakeListener = WakeListener(transcriber: transcriber)
        wakeListener.delegate = self

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

        escMonitor = EscMonitor(onEscape: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state == .recording {
                    self.controller.cancel()
                }
                self.wakeListener?.cancelCapture()
            }
        })
        escMonitor.start()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.appearsDisabled = true // hasta que cargue el modelo

        let menu = NSMenu()
        let status = NSMenuItem(title: "Cargando modelos…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())

        let wakeItem = NSMenuItem(
            title: "Manos libres: \"escúchame kiki\"",
            action: #selector(toggleWake),
            keyEquivalent: "")
        wakeItem.target = self
        wakeItem.tag = Self.wakeMenuItemTag
        wakeItem.state = wakeEnabled ? .on : .off
        menu.addItem(wakeItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Salir de kiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        statusItem.menu = menu

        updateStatusIcon()
    }

    /// `waveform` cuando el modo manos libres está activo, `mic.fill` en el
    /// modo normal (solo hotkey Fn) — refleja de un vistazo si kiki está
    /// escuchando ambiente continuamente o solo mientras se mantiene Fn.
    private func updateStatusIcon() {
        let symbolName = wakeEnabled ? "waveform" : "mic.fill"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: "kiki")
    }

    @MainActor @objc private func toggleWake() {
        if wakeEnabled {
            wakeListener.stop()
            hud.showArmed(false)
            wakePausedByDictation = false
            wakeEnabled = false
            UserDefaults.standard.set(false, forKey: Self.wakeEnabledKey)
        } else {
            do {
                try wakeListener.start()
                wakeEnabled = true
                UserDefaults.standard.set(true, forKey: Self.wakeEnabledKey)
            } catch {
                KikiLog.log("kiki wake: error al activar manos libres: \(error)")
                let alert = NSAlert()
                alert.messageText = "No se pudo activar el modo manos libres"
                alert.informativeText = String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
                // revert: dejar el toggle apagado tal como estaba.
                wakeEnabled = false
                UserDefaults.standard.set(false, forKey: Self.wakeEnabledKey)
            }
        }
        statusItem.menu?.item(withTag: Self.wakeMenuItemTag)?.state = wakeEnabled ? .on : .off
        updateStatusIcon()
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

        // El listener de manos libres depende del mismo WhisperTranscriber
        // que el dictado por hotkey — solo arranca una vez que el modelo
        // terminó de cargar, independientemente de si el refinado LLM quedó
        // disponible o no.
        if wakeEnabled {
            do {
                try wakeListener.start()
            } catch {
                KikiLog.log("kiki wake: error al iniciar manos libres en el arranque: \(error)")
            }
        }
    }
}

extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        hud.show(state: state)

        // Coordinación de pausa: evita dos engines de audio simultáneos (el
        // AudioRecorder del dictado por hotkey y el AVAudioEngine interno de
        // WakeListener) y evita que el propio audio del dictado dispare
        // falsos positivos de la frase de activación.
        if state != .idle && wakeEnabled {
            wakeListener.stop()
            hud.showArmed(false)
            wakePausedByDictation = true
        } else if state == .idle && wakePausedByDictation && wakeEnabled {
            try? wakeListener.start()
            wakePausedByDictation = false
        }
    }

    func dictationDidFail(_ error: DictationError) {
        KikiLog.log("kiki error: \(String(describing: error))")
        hud.show(state: .idle)
    }
}

extension AppDelegate: WakeListenerDelegate {
    func wakeListenerDidArm() {
        NSSound(named: "Glass")?.play()
        hud.showArmed(true)
    }

    func wakeListenerDidStartCapture() {
        hud.showArmed(false)
        hud.show(state: .recording)
    }

    func wakeListenerDidCapture(samples: [Float]) {
        hud.show(state: .idle)
        Task { await controller.process(samples: samples) }
    }

    func wakeListenerDidCaptureSameBreath(text: String) {
        Task { await controller.processTranscript(text) }
    }

    func wakeListenerDidDisarm() {
        hud.showArmed(false)
    }
}
