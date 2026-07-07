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
    private static let translateMenuItemTag = 3
    /// Umbral RMS de habla para `WakeListener`, calibrable en campo sin
    /// rebuild — ver `WakeListener.init`. Ejemplo de uso en un mic marginal:
    /// `defaults write com.dev2619.kiki kiki.wakeRMSThreshold 0.004`.
    private static let wakeRMSThresholdKey = "kiki.wakeRMSThreshold"

    /// Lee `kiki.wakeRMSThreshold` de `UserDefaults` si está presente y es
    /// > 0; si no, cae al default de `WakeListener`. `UserDefaults` no
    /// distingue "ausente" de "0.0" con `double(forKey:)`, por eso se
    /// exige > 0 explícitamente en vez de solo comprobar `object(forKey:) != nil`.
    private static func effectiveWakeRMSThreshold() -> Float {
        let stored = UserDefaults.standard.double(forKey: wakeRMSThresholdKey)
        guard stored > 0 else { return WakeListener.defaultSpeechRMSThreshold }
        return Float(stored)
    }

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

        // Mantiene el checkmark del ítem de menú "Traducir al dictar"
        // sincronizado si el toggle se cambia desde Ajustes en vez del menú
        // (ver doc de `syncTranslateMenuCheckmark`). `statusItem` todavía no
        // existe en este punto — el handler solo se dispara tras
        // `setUpStatusItem()`, así que el `?.` de `syncTranslateMenuCheckmark`
        // es suficiente, no hace falta guardar/quitar este observer (vive
        // todo el ciclo de vida del proceso, igual que `AppDelegate`).
        NotificationCenter.default.addObserver(
            forName: .kikiTranslateEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncTranslateMenuCheckmark() }
        }

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter(),
            refiner: refiner,
            context: appContext,
            snippets: snippetAdapter,
            history: historyAdapter,
            // Fase: fidelidad de idioma. `transcriber` conforma también
            // `LanguageDetecting` (ver `WhisperTranscriber`) — el mismo
            // actor que ya se inyecta como `Transcribing` se reinyecta aquí
            // para que el controller pueda leer, tras cada transcripción, el
            // idioma que Whisper detectó y fijárselo al refinador en vez de
            // dejarlo a la deriva (bug de campo: inglés mistraducido/
            // alucinado por el refinador de 3B).
            languageProvider: transcriber,
            // Fix 2 (modo traducción, opt-in): se lee `UserDefaults`
            // directamente en vez de empujar el valor a través de un
            // adapter/provider — a diferencia del diccionario personal, este
            // flag no tiene efectos secundarios de ciclo de vida (no arranca/
            // para ningún engine de audio como `wakeEnabled`), así que un
            // closure que relee `settingsViewModel.translateEnabled` en cada
            // refinado (siempre en MainActor, igual que este closure) es
            // suficiente y evita otro protocolo/adapter.
            translateEnabled: { [weak self] in self?.settingsViewModel.translateEnabled ?? false })
        controller.delegate = self

        wakeListener = WakeListener(transcriber: transcriber, speechRMSThreshold: Self.effectiveWakeRMSThreshold())
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

        // ⌥⌘K con manos-libres OFF arma el dictado DIRECTAMENTE
        // (`armViaShortcut`, sin frase); con manos-libres ON (escuchando o ya
        // armado) apaga todo — mismo camino que el toggle del menú
        // (`toggleWake`, semántica OFF sin cambios). Dos intents distintos
        // para el mismo atajo según el estado vigente — ver README §Manos
        // libres.
        wakeToggleShortcut = WakeToggleShortcut(onToggle: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.wakeEnabled {
                    self.toggleWake()
                } else {
                    self.armViaShortcut()
                }
            }
        })
        wakeToggleShortcut.start()
    }

    private func setUpStatusItem() {
        // El glifo es cuadrado y sin título, pero variableLength tolera
        // futuros indicadores junto al ícono sin recortar.
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

        let translateItem = NSMenuItem(
            title: "Traducir al dictar",
            action: #selector(toggleTranslate),
            keyEquivalent: "")
        translateItem.target = self
        translateItem.tag = Self.translateMenuItemTag
        // Lee `UserDefaults` directamente en vez de `settingsViewModel.translateEnabled`:
        // `setUpStatusItem()` corre sin `@MainActor` (se invoca síncrono
        // desde `applicationDidFinishLaunching`, que tampoco lo es — mismo
        // patrón que el resto del arranque, que solo toca estado
        // MainActor-isolated envuelto en `Task { @MainActor in ... }`), y
        // `SettingsViewModel` sí es `@MainActor`. `UserDefaults` no está
        // aislado a ningún actor, así que leerlo aquí es seguro y evita
        // reordenar el arranque solo por esto.
        translateItem.state = UserDefaults.standard.bool(forKey: SettingsViewModel.translateEnabledDefaultsKey) ? .on : .off
        menu.addItem(translateItem)
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

    /// Alterna "Traducir al dictar" desde el ítem de menú — delega en
    /// `settingsViewModel.translateEnabled` (única fuente de verdad,
    /// persistida vía su `didSet`) en vez de mantener un booleano paralelo,
    /// así el menú y Ajustes nunca pueden desincronizarse. El checkmark se
    /// actualiza aquí mismo Y desde `syncTranslateMenuCheckmark()` (llamado
    /// vía `.kikiTranslateEnabledChanged`) para cubrir también el caso en
    /// que el usuario cambia el toggle desde la ventana de Ajustes.
    @MainActor @objc private func toggleTranslate() {
        settingsViewModel.translateEnabled.toggle()
    }

    @MainActor private func syncTranslateMenuCheckmark() {
        // `statusItem` es un IUO fijado en `setUpStatusItem()` — guard
        // defensivo en vez de forzar el desenvuelto, por si esta notificación
        // llegara antes de que el menú exista (no debería pasar en la
        // práctica: solo se postea al mutar `settingsViewModel.translateEnabled`,
        // algo que solo el usuario puede disparar ya con la app corriendo).
        guard let statusItem else { return }
        statusItem.menu?.item(withTag: Self.translateMenuItemTag)?.state =
            settingsViewModel.translateEnabled ? .on : .off
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

    /// ⌥⌘K con manos-libres OFF: no solo activa el modo, ARMA el dictado
    /// directamente — el usuario habla de inmediato, sin decir la frase de
    /// activación. Ruteado solo desde el estado OFF (ver `wakeToggleShortcut`
    /// arriba); con manos-libres ON el mismo atajo cae en `toggleWake()`
    /// (semántica existente, sin cambios).
    ///
    /// Encendido del modo: mismos efectos secundarios que la rama ON de
    /// `toggleWake()` (persistir `wakeEnabled`, checkmark del menú, ícono),
    /// pero SIN `wakeListener.start()` — en su lugar `armDirectly()` aterriza
    /// directo en `.armed`, saltándose `.listening` por completo.
    ///
    /// Timeouts: `armDirectly()` es un arme FRESCO — el primer timeout de
    /// desarmado es el INICIAL de 8s, igual que un arme por frase: si no
    /// dictas nada tras el atajo, el mic no queda caliente 45s. La primera
    /// captura entregada asciende la sesión al régimen continuo de 45s por
    /// el camino normal (`handleSegmentEnded`). `resumeArmed()` NO sirve
    /// aquí: ese entry point continúa una sesión con captura ya entregada y
    /// arranca directo en el régimen de 45s.
    ///
    /// `armDirectly()` comparte la misma precondición que `start()` (guard
    /// `_state == .stopped` en `WakeListener`). Por el ruteo de arriba,
    /// `armViaShortcut()` solo corre con `wakeEnabled` en OFF, así que
    /// `wakeListener` debería estar siempre `.stopped` en este punto (nunca
    /// se arrancó, o `toggleWake()`/`wakeStartFailed()` ya lo pararon) — el
    /// `stop()` defensivo de abajo solo cubre un desync wakeEnabled/listener
    /// que no debería ocurrir por construcción (ver paranoia equivalente en
    /// `wakeStartFailed`), pero dejarlo sin cubrir significaría que
    /// `armDirectly()` se ignoraría en silencio (log "ya activo") y el
    /// usuario quedaría con el modo recién encendido pero SIN arme — peor
    /// que el costo de un `stop()` de más.
    ///
    /// A diferencia de `arm()` (armado por frase, dentro de `WakeListener`),
    /// `armDirectly()` NO dispara `wakeListenerDidArm()` — esa notificación
    /// es específica del camino "frase detectada". Por eso el cue (`Glass`,
    /// mismo sonido que un arme por frase — misma intención semántica: "ya
    /// puedes hablar") y el HUD armado se disparan aquí mismo en vez de
    /// depender del delegate.
    @MainActor private func armViaShortcut() {
        guard controller.state == .idle else {
            hud.showTransient("No disponible durante un dictado")
            return
        }
        if !wakeEnabled {
            wakeEnabled = true
            UserDefaults.standard.set(true, forKey: Self.wakeEnabledKey)
            settingsViewModel.syncWakeEnabled(wakeEnabled)
            statusItem.menu?.item(withTag: Self.wakeMenuItemTag)?.state = .on
            updateStatusIcon()
        }
        if wakeListener.state != .stopped {
            wakeListener.stop()
        }
        do {
            try wakeListener.armDirectly()
            SoundCues.play(.armed)
            hud.showArmed(true)
        } catch {
            wakeStartFailed(error, context: "al armar directamente vía atajo")
        }
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
        // Fase: fidelidad de idioma / Fix 2. Se fija ANTES de `hud.show`
        // (que es lo que efectivamente pone la pill en pantalla) para que la
        // primera pintura de "Procesando…"/"Traduciendo…" ya sea correcta —
        // solo importa al ENTRAR a `.processing`, pero fijarlo siempre es
        // inocuo (mismo valor durante `.recording`/`.idle`, donde `HUDView`
        // ni lo lee).
        if state == .processing {
            hud.setTranslating(settingsViewModel.translateEnabled)
        }
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
    /// También postea `.kikiDictationInserted` (Fase 3.6, Task 2) para que
    /// la pestaña Historial de Ajustes se refresque en vivo si la ventana
    /// está abierta — `SettingsViewModel` es quien observa esta notificación.
    func dictationDidInsert() {
        SoundCues.play(.inserted)
        NotificationCenter.default.post(name: .kikiDictationInserted, object: nil)
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

    func wakeListenerDidCapture(samples: [Float], sessionIsCurrent: Bool) {
        // Guarda contra el ordenamiento donde otro dictado OCUPA el
        // controller al llegar esta captura: hotkey ya grabando/procesando, o
        // una segunda utterance manos-libres mientras la anterior todavía se
        // procesa. Descartar explícitamente en vez de dejar que
        // `controller.process` la rechace por su cuenta, porque eso dejaría
        // `resumeAsArmed` pegado en `true` sin que nada lo limpie después.
        guard controller.state == .idle else {
            KikiLog.log("kiki: captura descartada — controller en \(controller.state)")
            return
        }
        // Traza de la carrera stale (dos capas de defensa, sin fence en
        // WakeListener para capturas — el habla real nunca se descarta):
        // 1) La captura stale llega mientras el hotkey aún ocupa
        //    `.recording`/`.processing` → el guard de arriba la descarta y
        //    ningún flag queda fijado.
        // 2) La Task de captura venía starved en el MainActor y corre
        //    DESPUÉS de que el ciclo de hotkey completo terminó (controller
        //    de vuelta en `.idle`, `wakeEnabled` aún `true`) → el guard de
        //    estado ya no la distingue de una captura fresca, pero
        //    `sessionIsCurrent` llega en `false` (el stop() de ese ciclo
        //    avanzó `session` en WakeListener) y evita fijar `resumeAsArmed`
        //    — sin el token, el resume rearmaría el mic sin frase ni chime
        //    (regresión de privacidad). El habla se procesa igual: la
        //    frescura solo gatea el efecto de estado, nunca la entrega.
        // Además gateado por `wakeEnabled`: si el usuario apagó el modo
        // manos-libres mientras la captura estaba en vuelo, el dictado se
        // entrega y pega igual, pero no debe rearmar el mic tras procesar.
        resumeAsArmed = wakeEnabled && sessionIsCurrent
        // No hud.show(state: .idle) aquí: controller.process() dispara
        // dictationStateDidChange(.processing) casi de inmediato vía su
        // delegate, así que un orderOut(.idle) intermedio solo producía un
        // flicker visible de la pill entre "Escuchando…" y "Procesando…".
        Task { await controller.process(samples: samples) }
    }

    func wakeListenerDidCaptureSameBreath(text: String, language: String, sessionIsCurrent: Bool) {
        // Mismo guard que wakeListenerDidCapture — ver comentario ahí.
        guard controller.state == .idle else {
            KikiLog.log("kiki: captura descartada — controller en \(controller.state)")
            return
        }
        // Mismo razonamiento que wakeListenerDidCapture: el dictado en el
        // mismo aliento también abre/continúa una sesión continua — tras
        // procesarlo, el listener debe reanudar armado, no volver a
        // listening plano. Gateado por `wakeEnabled` y por el token de
        // frescura por las mismas razones (ver traza de la carrera arriba).
        resumeAsArmed = wakeEnabled && sessionIsCurrent
        // `language` viene capturado JUNTO con el texto por WakeListener (misma
        // unidad serializada que su `transcribe()`), así que se pasa explícito
        // — el controller NO debe releerlo del transcriber en este path (cierre
        // de la TOCTOU, ver `processTranscript`/`wakeListenerDidCaptureSameBreath`).
        Task { await controller.processTranscript(text, language: language) }
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
