import AppKit
import KikiAudio
import KikiContext
import KikiCore
import KikiInsert
import KikiRefine
import KikiSTT
import KikiStore
import KikiWake

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let wakeEnabledKey = "kiki.wakeEnabled"
    private static let wakeMenuItemTag = 2

    /// `Application Support/kiki`, ubicación real de los stores de
    /// personalización (Fase 3, Task 4) — separada de cualquier directorio
    /// temporal usado en tests.
    private static let personalizationDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("kiki")
    }()

    private var statusItem: NSStatusItem!
    private(set) var controller: DictationController!
    let recorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let refiner = LLMRefiner()
    let appContext = FrontmostAppContext()
    private var hotkey: HotkeyMonitor!
    private var escMonitor: EscMonitor!
    private var wakeToggleShortcut: WakeToggleShortcut!
    private var hud: HUDController!
    private var wakeListener: WakeListener!
    private var wakeEnabled = UserDefaults.standard.bool(forKey: AppDelegate.wakeEnabledKey)
    private var wakePausedByDictation = false
    /// `true` cuando la pausa en curso (`dictationStateDidChange` con
    /// `state != .idle`) fue originada por una captura de manos-libres
    /// (`wakeListenerDidCapture`/`wakeListenerDidCaptureSameBreath`), en vez
    /// de por el hotkey. Determina si al volver a `.idle` el listener se
    /// reanuda con `resumeArmed()` (sesión continua, sin perder el arme) o
    /// con `start()` (listening simple, como en una pausa por hotkey). Se
    /// fija en `true` justo antes de lanzar `controller.process`/
    /// `processTranscript` y se limpia apenas se consume en el resume.
    private var resumeAsArmed = false

    // Stores + adapters de personalización (Fase 3, Task 3/4). AppDelegate es
    // el dueño fuerte de todo esto; los providers que se inyectan en
    // transcriber/refiner son `weak`, así que esta es la única referencia
    // fuerte que los mantiene vivos.
    let dictionaryStore = DictionaryStore(directory: AppDelegate.personalizationDirectory)
    let snippetStore = SnippetStore(directory: AppDelegate.personalizationDirectory)
    let historyStore = HistoryStore(directory: AppDelegate.personalizationDirectory)
    private lazy var dictionaryAdapter = DictionaryAdapter(store: dictionaryStore)
    private lazy var snippetAdapter = SnippetAdapter(store: snippetStore)
    private lazy var historyAdapter = HistoryAdapter(store: historyStore)
    private var settingsViewModel: SettingsViewModel!
    private var settingsWindowController: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestMicrophoneAccess()
        Permissions.ensureAccessibility()

        settingsViewModel = SettingsViewModel(
            dictionaryAdapter: dictionaryAdapter,
            snippetStore: snippetStore,
            historyStore: historyStore,
            wakeEnabled: wakeEnabled,
            onToggleWake: { [weak self] in self?.toggleWake() })
        settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter(),
            refiner: refiner,
            context: appContext,
            snippets: snippetAdapter,
            history: historyAdapter)
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

        wakeToggleShortcut = WakeToggleShortcut(onToggle: { [weak self] in
            Task { @MainActor in self?.toggleWake() }
        })
        wakeToggleShortcut.start()
    }

    private func setUpStatusItem() {
        // variableLength: el ícono lleva el logo y, con manos libres activo,
        // el sufijo "👂" — el ancho cambia según el estado.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.appearsDisabled = true // hasta que cargue el modelo

        let menu = NSMenu()
        let status = NSMenuItem(title: "Cargando modelos…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ajustes…",
            action: #selector(openSettings),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    /// Glifo de marca de kiki (barra-punto-barra-punto) como template image:
    /// negro sólido + alfa, macOS lo tiñe según la barra clara/oscura igual
    /// que los íconos del sistema. El estado del modo manos libres se refleja
    /// con la variante `MenuBarIconActive` (mismo mark + punto de estado bajo
    /// la línea base) en vez del antiguo sufijo "👂" — `button.title` queda
    /// SIEMPRE vacío. Fallback al SF Symbol si el recurso no carga.
    private func updateStatusIcon() {
        let resourceName = wakeEnabled ? "MenuBarIconActive@2x" : "MenuBarIcon@2x"
        if let iconURL = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let glyph = NSImage(contentsOf: iconURL) {
            glyph.size = NSSize(width: 18, height: 18)
            glyph.isTemplate = true
            statusItem.button?.image = glyph
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: wakeEnabled ? "waveform" : "mic.fill",
                accessibilityDescription: "kiki")
        }
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageLeading
    }

    @MainActor @objc private func openSettings() {
        settingsWindowController.show()
    }

    @MainActor @objc private func toggleWake() {
        if wakeEnabled {
            wakeListener.stop()
            hud.showArmed(false)
            // Si el toggle se apaga a mitad de una captura manos-libres (HUD
            // mostrando "Escuchando…" desde wakeListenerDidStartCapture), el
            // stop() de arriba no limpia ese estado — sin esto la pill queda
            // pegada en pantalla aunque el dictado por hotkey siga funcionando.
            if controller.state == .idle { hud.show(state: .idle) }
            wakePausedByDictation = false
            resumeAsArmed = false
            wakeEnabled = false
            UserDefaults.standard.set(false, forKey: Self.wakeEnabledKey)
            SoundCues.play(.disarmed)
            hud.showTransient("Manos libres desactivado")
        } else {
            do {
                try wakeListener.start()
                wakeEnabled = true
                UserDefaults.standard.set(true, forKey: Self.wakeEnabledKey)
                SoundCues.play(.armed)
                hud.showTransient("Manos libres activado")
            } catch {
                wakeStartFailed(error, context: "al activar manos libres")
                let alert = NSAlert()
                alert.messageText = "No se pudo activar el modo manos libres"
                alert.informativeText = String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        statusItem.menu?.item(withTag: Self.wakeMenuItemTag)?.state = wakeEnabled ? .on : .off
        updateStatusIcon()
        settingsViewModel.syncWakeEnabled(wakeEnabled)
    }

    /// Centraliza la reacción a un `start()` que falla, tanto en el toggle
    /// manual como en los arranques automáticos (launch/resume): sin esto,
    /// un fallo silencioso dejaba `wakeEnabled=true` y el checkmark del menú
    /// en "on" mientras el micrófono manos-libres estaba realmente muerto
    /// (desync ON/dead-mic indetectable para el usuario).
    @MainActor private func wakeStartFailed(_ error: Error, context: String) {
        KikiLog.log("kiki wake: error \(context): \(error)")
        wakeEnabled = false
        UserDefaults.standard.set(false, forKey: Self.wakeEnabledKey)
        statusItem.menu?.item(withTag: Self.wakeMenuItemTag)?.state = .off
        updateStatusIcon()
        settingsViewModel.syncWakeEnabled(wakeEnabled)
    }

    private func loadModelInBackground() {
        // Un solo Task (hereda MainActor) para que la carga de Whisper y la
        // del LLM queden serializadas — evita llamadas concurrentes a
        // prepare() en ambos modelos.
        Task {
            // Diccionario personal (Fase 3, Task 3/4): se inyecta ANTES de
            // prepare() para que ya esté disponible desde la primera
            // transcripción/refinado, no solo desde el segundo dictado en
            // adelante. `transcriber` es un actor → requiere `await`;
            // `refiner` es una clase plana → llamada síncrona directa.
            await self.transcriber.setDictionaryProvider(self.dictionaryAdapter)
            self.refiner.setDictionaryProvider(self.dictionaryAdapter)

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

    @MainActor private func markReady(refinementAvailable: Bool = true) {
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
                wakeStartFailed(error, context: "al iniciar manos libres en el arranque")
            }
        }
    }
}

extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        hud.show(state: state)

        // Belt-and-suspenders contra `resumeAsArmed` stale: `.recording`
        // SOLO puede originarse en el hotkey — el flujo manos-libres
        // (`wakeListenerDidCapture`/`wakeListenerDidCaptureSameBreath`) va
        // directo a `.processing` vía `DictationController.transcribeAndProcess`,
        // nunca pasa por `.recording`. Si una notificación de captura
        // manos-libres stale (carrera con un `stop()` concurrente — fenced en
        // `WakeListener.notify`, pero esto es un segundo cinturón) alcanzó a
        // fijar `resumeAsArmed = true` justo antes de que el usuario tomara
        // control manual con Fn, este reset la limpia al arrancar la pausa
        // originada por el hotkey — así el resume al soltar Fn usa `start()`
        // (listening simple) y no `resumeArmed()` (mic armado sin frase ni
        // chime, regresión de privacidad).
        if state == .recording {
            resumeAsArmed = false
        }

        // Coordinación de pausa: evita dos engines de audio simultáneos (el
        // AudioRecorder del dictado por hotkey y el AVAudioEngine interno de
        // WakeListener) y evita que el propio audio del dictado dispare
        // falsos positivos de la frase de activación.
        if state != .idle && wakeEnabled {
            wakeListener.stop()
            // Si la pausa la originó una captura de manos-libres
            // (`resumeAsArmed`), la pill "👂 Te escucho…" debe persistir en
            // pantalla durante todo el procesamiento — no ocultarla aquí.
            // Para una pausa por hotkey (no armado, o el usuario interrumpe
            // manualmente), sí se oculta: evita que quede una pill "armada"
            // pegada en pantalla si la sesión termina perdiéndose.
            if !resumeAsArmed { hud.showArmed(false) }
            wakePausedByDictation = true
        } else if state == .idle && wakePausedByDictation && wakeEnabled {
            do {
                if resumeAsArmed {
                    try wakeListener.resumeArmed()
                } else {
                    try wakeListener.start()
                }
            } catch {
                wakeStartFailed(error, context: "al reanudar manos libres tras dictado")
            }
            wakePausedByDictation = false
            resumeAsArmed = false
        }
    }

    func dictationDidFail(_ error: DictationError) {
        KikiLog.log("kiki error: \(String(describing: error))")
        hud.show(state: .idle)
    }

    /// Cue "inserted": suena en AMBOS modos (hotkey y manos-libres) porque
    /// este delegate cubre las dos rutas — `DictationController` no
    /// distingue el origen de la captura, solo notifica tras insertar.
    func dictationDidInsert() {
        SoundCues.play(.inserted)
    }
}

extension AppDelegate: WakeListenerDelegate {
    func wakeListenerDidArm() {
        SoundCues.play(.armed)
        hud.showArmed(true)
    }

    func wakeListenerDidStartCapture() {
        SoundCues.play(.captureStart)
        // No hud.showArmed(false) aquí: la sesión sigue armada durante toda
        // la captura y el procesamiento — solo se desarma vía
        // wakeListenerDidDisarm (timeout/Esc) o el toggle. El pill de
        // "Escuchando…" reemplaza visualmente al de "Te escucho…" mientras
        // state == .recording (HUDView no consulta `armed` en ese caso), y
        // el de "Te escucho…" vuelve solo al retornar a idle+armed.
        hud.show(state: .recording)
    }

    func wakeListenerDidCapture(samples: [Float]) {
        // Marca la pausa que sigue (dictationStateDidChange) como originada
        // por manos-libres: el resume debe usar resumeArmed(), no start(),
        // para no perder la sesión continua ni pedir la frase de nuevo.
        resumeAsArmed = true
        // No hud.show(state: .idle) aquí: controller.process() dispara
        // dictationStateDidChange(.processing) casi de inmediato vía su
        // delegate, así que un orderOut(.idle) intermedio solo producía un
        // flicker visible de la pill entre "Escuchando…" y "Procesando…".
        Task { await controller.process(samples: samples) }
    }

    func wakeListenerDidCaptureSameBreath(text: String) {
        // Mismo razonamiento que wakeListenerDidCapture: el dictado en el
        // mismo aliento también abre/continúa una sesión continua — tras
        // procesarlo, el listener debe reanudar armado, no volver a
        // listening plano.
        resumeAsArmed = true
        Task { await controller.processTranscript(text) }
    }

    func wakeListenerDidDisarm() {
        SoundCues.play(.disarmed)
        hud.showArmed(false)
        resumeAsArmed = false
        // Ver comentario equivalente en toggleWake: cubre el caso en que el
        // desarmado llega mientras la captura ya estaba en curso (p.ej.
        // segmentDiscarded con el listener armado) y la pill de "Escuchando…"
        // quedó pegada en pantalla sin que ningún otro camino la limpie.
        if controller.state == .idle { hud.show(state: .idle) }
    }
}
