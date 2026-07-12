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

    /// Lee `kiki.alwaysListening` de `UserDefaults`, default `true` cuando la
    /// clave está ausente (pedido explícito del owner: la frase de activación
    /// debe funcionar desde el primer arranque, sin acción previa). Mismo
    /// patrón de "ausente vs. false" que `SettingsViewModel.soundCuesEnabled`
    /// — `bool(forKey:)` no distingue ambos casos, así que se chequea
    /// `object(forKey:) != nil` explícitamente. La clave vive en
    /// `SettingsViewModel.alwaysListeningDefaultsKey` (fuente de escritura),
    /// igual que `translateEnabledDefaultsKey`.
    private static func effectiveAlwaysListening() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: SettingsViewModel.alwaysListeningDefaultsKey) != nil
            ? defaults.bool(forKey: SettingsViewModel.alwaysListeningDefaultsKey)
            : true
    }

    /// Lee `kiki.historyCap` de `UserDefaults` para construir `historyStore`
    /// con el cap persistido por el usuario (control "cantidad a conservar"
    /// en Ajustes → Historial) en vez del default fijo de `HistoryStore`.
    /// Mismo patrón "ausente vs. inválido" que `effectiveWakeRMSThreshold()`:
    /// `integer(forKey:)` no distingue "clave ausente" de "0", así que se
    /// exige > 0 explícitamente antes de confiar en el valor guardado.
    private static func effectiveHistoryCap() -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsViewModel.historyCapDefaultsKey)
        return stored > 0 ? stored : 200
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
    /// F3 Task 2: construido con la preferencia efectiva del usuario (cae al
    /// modelo base si no hay preferencia guardada o si quedó inválida — ver
    /// `ModelPreference.effectiveModelId`), no con `WhisperTranscriber.preferredModel`
    /// a secas.
    let transcriber = WhisperTranscriber(model: ModelPreference.effectiveModelId(for: .stt))
    /// Verificador tiny de la frase de activación (F4). Se prepara en
    /// background DESPUÉS de los modelos principales (75MB, sin UI de
    /// progreso); hasta que está listo — o si falla — WakeListener verifica
    /// con `transcriber` (fallback = comportamiento pre-F4). No participa de
    /// `ModelPreference` (variante fija, no seleccionable por el usuario).
    let wakeTranscriber = WhisperTranscriber(model: WhisperTranscriber.wakeModel)
    /// Retención fuerte del bias provider del tiny (el transcriber lo guarda
    /// weak — mismo patrón que los adapters de personalización).
    private let wakePhraseBias = WakePhraseBiasProvider()
    /// F3 Task 2: mismo patrón que `transcriber` — preferencia efectiva del
    /// usuario, con fallback al modelo base.
    let refiner = LLMRefiner(model: ModelPreference.effectiveModelId(for: .refine))
    let appContext = FrontmostAppContext()
    private var hotkey: HotkeyMonitor!
    private var escMonitor: EscMonitor!
    private var wakeToggleShortcut: WakeToggleShortcut!
    private var hud: HUDController!
    private var wakeListener: WakeListener!
    private var wakeEnabled = UserDefaults.standard.bool(forKey: AppDelegate.wakeEnabledKey)
    /// Espejo de lectura de `kiki.alwaysListening`. La fuente de escritura es
    /// `SettingsViewModel.alwaysListening.didSet` (mismo patrón que
    /// `translateEnabled`/`.kikiTranslateEnabledChanged`) — `AppDelegate` lee
    /// el valor inicial directamente de `UserDefaults` al arrancar y luego se
    /// mantiene sincronizado vía `.kikiAlwaysListeningChanged`
    /// (`handleAlwaysListeningChanged`), que además arranca/para el
    /// `wakeListener` en caliente. Cuando es `true`, la frase de activación
    /// funciona sin que `wakeEnabled` (el toggle "Manos libres") esté
    /// encendido — ver `markReady`, `dictationStateDidChange` y `toggleWake`.
    private var alwaysListening = AppDelegate.effectiveAlwaysListening()
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
    let historyStore = HistoryStore(
        directory: AppDelegate.personalizationDirectory,
        cap: AppDelegate.effectiveHistoryCap())
    private lazy var dictionaryAdapter = DictionaryAdapter(store: dictionaryStore)
    private lazy var snippetAdapter = SnippetAdapter(store: snippetStore)
    private lazy var historyAdapter = HistoryAdapter(store: historyStore)
    private var settingsViewModel: SettingsViewModel!
    private var settingsWindowController: SettingsWindowController!
    /// Ventana "Preparando kiki…" (progreso de descarga+carga de modelos del
    /// primer arranque, ver `ModelLoadProgressWindow.swift`). Creada e
    /// inmediatamente mostrada al inicio de `loadModelInBackground` — NO es
    /// un singleton reabrible como `settingsWindowController`, se destruye
    /// (`dismiss()`) apenas los modelos terminan de cargar.
    private var modelLoadProgressWindowController: ModelLoadProgressWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // F3 Task 2: consistencia catálogo↔constantes — atrapa en debug si
        // `ModelCatalog`'s `isBase` entry (Task 1) alguna vez se desincroniza
        // de la constante `preferredModel` hardcodeada en cada engine (la que
        // usa el fallback-a-base de `prepare()`, ver `WhisperTranscriber`/
        // `LLMRefiner`). `transcriber`/`refiner` ya se construyeron arriba
        // (stored properties) antes de que este método corra, así que estos
        // asserts solo verifican consistencia — no afectan qué modelo cargó
        // cada instancia.
        assert(ModelCatalog.baseOption(for: .stt).id == WhisperTranscriber.preferredModel)
        assert(ModelCatalog.baseOption(for: .refine).id == LLMRefiner.preferredModel)

        Permissions.requestMicrophoneAccess()
        Permissions.ensureAccessibility()

        settingsViewModel = SettingsViewModel(
            dictionaryAdapter: dictionaryAdapter,
            snippetStore: snippetStore,
            historyStore: historyStore,
            // F3 Task 3: la sección Modelos de Ajustes necesita invocar
            // `switchModel` en los engines reales — se inyectan las mismas
            // instancias que usa `DictationController` (el view model NO
            // toca `wakeTranscriber`: su variante tiny es fija, fuera de
            // `ModelPreference`).
            transcriber: transcriber,
            refiner: refiner,
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

        // Reacciona en caliente cuando el toggle "Escucha siempre activa" de
        // Ajustes cambia (`SettingsViewModel.alwaysListening.didSet`, mismo
        // patrón de notificación que `.kikiTranslateEnabledChanged` arriba) —
        // arranca/para `wakeListener` según corresponda (ver
        // `handleAlwaysListeningChanged`). Igual que el observer de arriba,
        // `wakeListener` puede no existir todavía en este punto del arranque;
        // `handleAlwaysListeningChanged` solo se dispara tras la primera
        // mutación real del toggle desde la UI, que requiere la ventana de
        // Ajustes abierta y por tanto la app ya completamente inicializada.
        NotificationCenter.default.addObserver(
            forName: .kikiAlwaysListeningChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAlwaysListeningChanged() }
        }

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter(restoresClipboard: {
                UserDefaults.standard.bool(forKey: SettingsViewModel.restoreClipboardDefaultsKey)
            }),
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
            translateEnabled: { [weak self] in self?.settingsViewModel.translateEnabled ?? false },
            // Interruptor "Refinar dictado con IA" (default ON): mismo patrón
            // que `translateEnabled` — closure que relee la fuente de verdad en
            // cada refinado, sin efectos de ciclo de vida. `?? true` respeta el
            // default ON si el settingsViewModel aún no existe.
            refineEnabled: { [weak self] in self?.settingsViewModel.refineEnabled ?? true })
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
        // "Activo" ya no es solo `wakeEnabled` (el toggle "Manos libres"):
        // con `alwaysListening` encendido, el listener puede estar
        // efectivamente escuchando (`.listening`/`.armed`, cualquier estado
        // salvo `.stopped`) sin que ese toggle esté prendido — el glifo debe
        // reflejar que kiki SÍ está escuchando la frase en ese caso. No se
        // llama `wakeListener.state` (que hace `queue.sync`) desde ningún
        // hot path de audio, así que el costo es despreciable aquí.
        let isActive = wakeEnabled || (alwaysListening && wakeListener.state != .stopped)
        let resourceName = isActive ? "MenuBarIconActive@2x" : "MenuBarIcon@2x"
        if let iconURL = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let glyph = NSImage(contentsOf: iconURL) {
            glyph.size = NSSize(width: 18, height: 18)
            glyph.isTemplate = true
            statusItem.button?.image = glyph
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: isActive ? "waveform" : "mic.fill",
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
            // stopAndFlush() (no stop() liso): apagar manos-libres es un
            // "ya terminé de hablar" intencional del usuario — si había un
            // segmento de habla en curso sin cerrar (típicamente por ruido
            // ambiente que ni el drop relativo pudo despejar, ver
            // `SpeechSegmenter.endDropRatio`), se vuelca y se pega en vez de
            // perderse. Ruteado también desde ⌥⌘K con manos-libres ON, ver
            // `wakeToggleShortcut` más abajo. Contraste con el `stop()` liso
            // (descarta) usado por la coordinación de pausa por dictado en
            // `dictationStateDidChange` y por `cancelCapture()`/Esc — esos
            // son "pausar"/"cancelar", no "ya terminé".
            wakeListener.stopAndFlush()
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
            // `stopAndFlush()` paró el listener POR COMPLETO — pero si
            // `alwaysListening` sigue encendido, este toggle ya NO es el
            // prerequisito de la frase (ver doc de `alwaysListening`): hay
            // que re-arrancarlo en `.listening` fresco (sin arme heredado,
            // frase de nuevo) para que "escúchame kiki" siga funcionando tras
            // apagar "Manos libres".
            if alwaysListening {
                do {
                    try wakeListener.start()
                } catch {
                    wakeStartFailed(error, context: "al reanudar escucha siempre activa tras apagar manos libres")
                }
            }
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
    /// `armViaShortcut()` solo corre con `wakeEnabled` en OFF — pero con
    /// `alwaysListening` en su default `true`, el listener normalmente YA está
    /// corriendo en `.listening` (arrancado en `markReady`) cuando se pulsa
    /// ⌥⌘K, así que el `stop()` de abajo es ahora el caso COMÚN (baja de
    /// `.listening` a `.stopped` para que `armDirectly()` pueda re-armar
    /// fresco), no una rareza. Con `alwaysListening` en OFF sí es el caso raro
    /// (el listener suele estar `.stopped` ya) y el `stop()` solo cubre un
    /// desync wakeEnabled/listener. En ambos casos, sin el `stop()`,
    /// `armDirectly()` se ignoraría en silencio (log "ya activo") y el usuario
    /// quedaría con el modo recién encendido pero SIN arme — peor que el costo
    /// de un `stop()` de más.
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

    /// Reacciona a `.kikiAlwaysListeningChanged` (posteado por
    /// `SettingsViewModel.alwaysListening.didSet`, ver doc de `alwaysListening`
    /// arriba): releé `UserDefaults` (fuente de verdad de escritura) y
    /// arranca/para `wakeListener` para que el toggle de Ajustes tenga efecto
    /// inmediato sin esperar al próximo ciclo de pausa/resume del hotkey.
    ///
    /// Si hay un dictado por HOTKEY en curso (`wakePausedByDictation`, el
    /// listener ya está parado por `dictationStateDidChange`), no se toca el
    /// engine aquí — el propio resume al volver a `.idle` releerá
    /// `alwaysListening` (ya actualizado arriba) y decidirá correctamente sin
    /// crear una carrera entre este handler y la pausa por dictado. OJO: ese
    /// guard NO cubre una sesión manos-libres `.armed` (abierta por la frase);
    /// la rama OFF de abajo la maneja con `stopAndFlush()` — ver ahí.
    @MainActor private func handleAlwaysListeningChanged() {
        let key = SettingsViewModel.alwaysListeningDefaultsKey
        let defaults = UserDefaults.standard
        let newValue = defaults.object(forKey: key) != nil ? defaults.bool(forKey: key) : true
        guard newValue != alwaysListening else { return }
        alwaysListening = newValue
        updateStatusIcon()
        guard !wakePausedByDictation else { return }
        if alwaysListening {
            guard wakeListener.state == .stopped else { return }
            do {
                try wakeListener.start()
            } catch {
                wakeStartFailed(error, context: "al activar escucha siempre activa")
            }
            updateStatusIcon()
        } else if !wakeEnabled {
            // Apagado y `wakeEnabled` también OFF: nada más quiere el
            // listener corriendo. El guard de `wakePausedByDictation` de
            // arriba solo descarta una pausa por HOTKEY — NO una sesión
            // manos-libres `.armed` abierta por la frase (que con
            // `alwaysListening` ON puede existir con `wakeEnabled` en OFF).
            // Por eso `stopAndFlush()` (no `stop()` liso), igual que la rama
            // OFF de `toggleWake`: apagar la escucha siempre activa es un
            // "ya terminé" del usuario, así que se vuelca el dictado en curso
            // en vez de perderlo, y se limpia la pill "Te escucho…"/
            // "Escuchando…" que si no quedaría pegada para siempre (ambos
            // flags en OFF → ningún camino futuro la limpiaría).
            wakeListener.stopAndFlush()
            hud.showArmed(false)
            if controller.state == .idle { hud.show(state: .idle) }
            updateStatusIcon()
        }
    }

    private static let sttPhaseLabel = "Descargando modelo de voz…"
    private static let llmPhaseLabel = "Descargando modelo de IA…"

    /// Muestra la ventana "Preparando kiki…" INCONDICIONALMENTE al arrancar
    /// — no solo cuando hay una descarga real de 2.7GB de por medio. En un
    /// arranque en caliente (modelos ya cacheados) `prepare()` igual tarda
    /// unos segundos por el prewarm/load de CoreML y la carga de pesos MLX,
    /// así que la ventana queda en pantalla ese rato corto y se autodescarta
    /// en `markReady()` — informativo y nunca un flash roto a medio pintar,
    /// más simple que un guard por tiempo transcurrido (ver spec de la
    /// feature: "simplest robust approach").
    @MainActor private func loadModelInBackground() {
        modelLoadProgressWindowController = ModelLoadProgressWindowController()
        modelLoadProgressWindowController.show()
        updateLoadProgress(phase1: 0, phase2: 0, phaseLabel: Self.sttPhaseLabel)

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
                // El callback de progreso de WhisperKit (descarga HF +
                // transiciones de `modelStateCallback` para prewarm/load,
                // ver `WhisperTranscriber.loadModel`) puede
                // dispararse desde cualquier hilo — se salta a MainActor
                // aquí antes de tocar la ventana/el menú.
                try await self.transcriber.prepare(progressHandler: { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateLoadProgress(phase1: fraction, phase2: 0, phaseLabel: Self.sttPhaseLabel)
                    }
                })
            } catch {
                KikiLog.log("kiki: error cargando modelo de transcripción: \(error)")
                await MainActor.run {
                    self.statusItem.menu?.item(withTag: 1)?.title = "Error cargando modelo"
                    self.modelLoadProgressWindowController.dismiss()
                }
                return
            }

            do {
                // Fase 1 (Whisper) ya está completa en este punto — se fija
                // en 1.0 para que la barra no retroceda al arrancar la fase 2.
                try await self.refiner.prepare(progressHandler: { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateLoadProgress(phase1: 1, phase2: fraction, phaseLabel: Self.llmPhaseLabel)
                    }
                })
                await MainActor.run { self.markReady() }
            } catch {
                KikiLog.log("kiki: error cargando modelo de refinado LLM: \(error)")
                await MainActor.run { self.markReady(refinementAvailable: false) }
            }

            // F4: el tiny del wake se carga al final, sin bloquear el arranque
            // ni la UI de progreso. El listener ya funciona con el modelo
            // grande mientras tanto.
            do {
                await self.wakeTranscriber.setDictionaryProvider(self.wakePhraseBias)
                try await self.wakeTranscriber.prepare()
                self.wakeListener.setWakeVerifier(self.wakeTranscriber)
                KikiLog.log("kiki wake: verificador tiny activo (con prompt-bias)")
            } catch {
                KikiLog.log("kiki wake: tiny no cargó (\(error)); se sigue verificando con el modelo principal")
            }
        }
    }

    /// Combina el progreso de ambas fases (`ModelLoadProgress.overall`, Whisper
    /// peso 0.4 / Qwen peso 0.6 — ver doc del tipo) y refleja el total en la
    /// ventana de carga Y en el ítem de menú "Descargando modelos… X%" como
    /// indicador secundario liviano (visible sin abrir/enfocar la ventana).
    @MainActor private func updateLoadProgress(phase1: Double, phase2: Double, phaseLabel: String) {
        let overall = ModelLoadProgress.overall(phase1: phase1, phase2: phase2)
        modelLoadProgressWindowController.update(phaseLabel: phaseLabel, fraction: overall)
        let percent = Int((overall * 100).rounded())
        statusItem.menu?.item(withTag: 1)?.title = "Descargando modelos… \(percent)%"
    }

    @MainActor private func markReady(refinementAvailable: Bool = true) {
        modelLoadProgressWindowController.dismiss()
        statusItem.button?.appearsDisabled = false
        statusItem.menu?.item(withTag: 1)?.title = refinementAvailable
            ? "Listo — mantén Fn para dictar"
            : "Listo (sin refinado IA)"

        // El listener de manos libres depende del mismo WhisperTranscriber
        // que el dictado por hotkey — solo arranca una vez que el modelo
        // terminó de cargar, independientemente de si el refinado LLM quedó
        // disponible o no. Arranca si CUALQUIERA de los dos quiere el
        // listener corriendo: `wakeEnabled` (toggle "Manos libres" ON, quizás
        // persistido de una sesión anterior) o `alwaysListening` (default
        // `true` — la frase debe funcionar desde el primer arranque sin
        // ninguna acción previa, ver doc de `alwaysListening`).
        if wakeEnabled || alwaysListening {
            do {
                try wakeListener.start()
            } catch {
                wakeStartFailed(error, context: "al iniciar manos libres en el arranque")
            }
        }
        updateStatusIcon()
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
        //
        // Gateado por `wakeEnabled || alwaysListening`: con `alwaysListening`
        // encendido el listener puede estar corriendo (escuchando la frase)
        // aunque `wakeEnabled` esté OFF — sigue habiendo que pararlo durante
        // CUALQUIER dictado por hotkey (evita el doble engine) y reanudarlo
        // al volver a `.idle`, sin que el toggle "Manos libres" sea
        // prerequisito de ninguna de las dos mitades.
        if state != .idle && (wakeEnabled || alwaysListening) {
            wakeListener.stop()
            // Si la pausa la originó una captura de manos-libres
            // (`resumeAsArmed`), la pill "👂 Te escucho…" debe persistir en
            // pantalla durante todo el procesamiento — no ocultarla aquí.
            // Para una pausa por hotkey (no armado, o el usuario interrumpe
            // manualmente), sí se oculta: evita que quede una pill "armada"
            // pegada en pantalla si la sesión termina perdiéndose.
            if !resumeAsArmed { hud.showArmed(false) }
            wakePausedByDictation = true
        } else if state == .idle && wakePausedByDictation && (wakeEnabled || alwaysListening) {
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
        updateStatusIcon()
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
        // Además gateado por `wakeEnabled || alwaysListening`: si ninguno de
        // los dos quería el modo manos-libres activo cuando la captura llegó
        // (p.ej. el usuario apagó "Manos libres" Y `alwaysListening` está
        // OFF mientras la captura estaba en vuelo), el dictado se entrega y
        // pega igual, pero no debe rearmar el mic tras procesar. Con
        // `alwaysListening` ON, la frase pudo haber armado esta sesión SIN
        // que `wakeEnabled` estuviera encendido — el resume debe seguir
        // tratándola como sesión vigente igual que con el toggle prendido.
        resumeAsArmed = (wakeEnabled || alwaysListening) && sessionIsCurrent
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
        // listening plano. Gateado por `wakeEnabled || alwaysListening` y por
        // el token de frescura por las mismas razones (ver traza de la
        // carrera arriba y el comentario equivalente en wakeListenerDidCapture).
        resumeAsArmed = (wakeEnabled || alwaysListening) && sessionIsCurrent
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
