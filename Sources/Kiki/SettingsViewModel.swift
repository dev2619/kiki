import AppKit
import KikiCore
import KikiRefine
import KikiSTT
import KikiStore
import KikiWake

/// Notificación local (Fase 3.6, Task 2) posteada por `AppDelegate` desde
/// `dictationDidInsert()` tras CADA dictado insertado (hotkey o manos
/// libres) — permite que la pestaña Historial de Ajustes se refresque en
/// vivo sin que el usuario tenga que cerrar/reabrir la ventana.
extension Notification.Name {
    static let kikiDictationInserted = Notification.Name("kiki.dictationInserted")

    /// Posteada por `SettingsViewModel.translateEnabled.didSet` (Fase:
    /// fidelidad de idioma / Fix 2) cada vez que el toggle "Traducir al
    /// dictar" cambia desde Ajustes — permite que `AppDelegate` mantenga el
    /// checkmark del ítem de menú equivalente sincronizado sin que
    /// `SettingsViewModel` conozca nada sobre `NSMenuItem`.
    static let kikiTranslateEnabledChanged = Notification.Name("kiki.translateEnabledChanged")

    /// Posteada por `SettingsViewModel.alwaysListening.didSet` (modo
    /// always-listening) cada vez que el toggle "Escucha siempre activa"
    /// cambia desde Ajustes — permite que `AppDelegate` arranque/pare
    /// `WakeListener` en caliente sin que `SettingsViewModel` conozca nada
    /// sobre el listener ni el engine de audio (mismo desacople que
    /// `.kikiTranslateEnabledChanged`).
    static let kikiAlwaysListeningChanged = Notification.Name("kiki.alwaysListeningChanged")
}

/// Secciones del sidebar de Ajustes (`NavigationSplitView`, Fase 3.6). El
/// orden de `allCases` define el orden de aparición en la lista.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictionary
    case snippets
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictionary: return "Diccionario"
        case .snippets: return "Snippets"
        case .history: return "Historial"
        case .about: return "Acerca de"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .history: return "clock"
        case .about: return "info.circle"
        }
    }
}

/// Estado observable de la ventana de Ajustes. Marcado `@MainActor` en
/// bloque: todas sus mutaciones (añadir/quitar término o snippet, borrar
/// historial, copiar al portapapeles) llegan desde la UI de SwiftUI, que ya
/// corre en MainActor — así que no hace falta ningún lock aquí, a diferencia
/// de `DictionaryAdapter` (que sí cruza al hilo del STT/refiner).
///
/// Refresco simple por diseño (Task 4): tras cada mutación se relee el
/// estado completo de los stores en vez de mantener diffs incrementales —
/// los stores son pequeños (diccionario/snippets personales, historial
/// acotado a `cap` entradas) y esto evita bugs de desincronización. El
/// mismo `refreshAll()` es el que atiende el refresco en vivo del Historial
/// (Fase 3.6, Task 2): se dispara tanto al recibir `.kikiDictationInserted`
/// como cuando la ventana de Ajustes vuelve a ser key window
/// (`SettingsWindowController` observa `NSWindow.didBecomeKeyNotification`).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var terms: [String] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published private(set) var wakeEnabled: Bool

    /// Toggle "Sonidos de confirmación" (Ajustes → General). Espejo directo
    /// de `SoundCues.enabledDefaultsKey` — el `didSet` es la única fuente de
    /// escritura a `UserDefaults` para esta clave desde la UI; `SoundCues`
    /// la lee de forma independiente en cada `play(_:)`, así que no hace
    /// falta ninguna notificación cruzada.
    @Published var soundCuesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundCuesEnabled, forKey: SoundCues.enabledDefaultsKey)
        }
    }

    /// Toggle "Refinar dictado con IA" (Ajustes → General, bugfix de fidelidad
    /// 2026-07-08). Default ON — la limpieza (muletillas, puntuación) agrega
    /// valor. Apagado = insertar EXACTAMENTE la transcripción de Whisper, sin
    /// que el LLM toque nada; para el usuario que prefiere sus palabras literales
    /// a cualquier corrección automática. Mismo patrón "ausente = true" que
    /// `soundCuesEnabled`. `AppDelegate` lee la misma clave directamente en la
    /// closure `refineEnabled` que pasa a `DictationController`, así que el
    /// `didSet` solo persiste — sin notificación cruzada.
    @Published var refineEnabled: Bool {
        didSet {
            UserDefaults.standard.set(refineEnabled, forKey: Self.refineEnabledDefaultsKey)
        }
    }

    /// `nonisolated` por la misma razón que `translateEnabledDefaultsKey`:
    /// `AppDelegate` la lee fuera de MainActor en la closure `refineEnabled`.
    nonisolated static let refineEnabledDefaultsKey = "kiki.refineEnabled"

    /// Toggle "Traducir al dictar" (Ajustes → General, Fase: fidelidad de
    /// idioma / Fix 2). Default OFF (`bool(forKey:)` de `UserDefaults`
    /// devuelve `false` cuando la clave no existe, así que no hace falta el
    /// chequeo `object(forKey:) != nil` que sí usa `soundCuesEnabled`, cuyo
    /// default es `true`). Espejo directo de `translateEnabledDefaultsKey` —
    /// el `didSet` es la única fuente de escritura a `UserDefaults` desde la
    /// UI; `AppDelegate` lee la misma clave directamente al refinar (closure
    /// `translateEnabled` pasado a `DictationController`) y al fijar el
    /// modo del HUD, así que no hace falta ninguna notificación cruzada —
    /// mismo patrón que `soundCuesEnabled`. `AppDelegate` sí observa
    /// `.kikiTranslateEnabledChanged` para mantener el checkmark del ítem de
    /// menú "Traducir al dictar" sincronizado si el toggle se cambia desde
    /// Ajustes en vez del menú.
    @Published var translateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(translateEnabled, forKey: Self.translateEnabledDefaultsKey)
            NotificationCenter.default.post(name: .kikiTranslateEnabledChanged, object: nil)
        }
    }

    /// `nonisolated` a propósito: es un `String` inmutable (Sendable) y se
    /// lee desde `AppDelegate.setUpStatusItem()`, que corre sin `@MainActor`
    /// — sin este marcador, el acceso a un `static let` de una clase
    /// `@MainActor` hereda su aislamiento y ese call site no compila (Swift 6).
    nonisolated static let translateEnabledDefaultsKey = "kiki.translateEnabled"

    /// Toggle "Escucha siempre activa" (Ajustes → General, modo
    /// always-listening). Mismo patrón que `soundCuesEnabled`: el `didSet` es
    /// la única fuente de escritura a `UserDefaults` desde la UI. Default
    /// `true` (a diferencia de `soundCuesEnabled`/`translateEnabled`) por
    /// pedido explícito del owner — la frase "escúchame kiki" debe funcionar
    /// desde el primer arranque de la app, sin ningún toggle ni atajo previo.
    ///
    /// A diferencia de `soundCuesEnabled`/`translateEnabled` (sin efectos de
    /// ciclo de vida), este toggle SÍ necesita arrancar/parar el
    /// `WakeListener` — pero `SettingsViewModel` no tiene ninguna referencia
    /// al listener ni al engine de audio (por diseño, ver el resto de esta
    /// clase). En vez de inyectar esa dependencia, el `didSet` postea
    /// `.kikiAlwaysListeningChanged` (mismo patrón de notificación que
    /// `translateEnabled` ya usa para el checkmark del menú) y `AppDelegate`
    /// reacciona arrancando/parando el engine — ver
    /// `AppDelegate.handleAlwaysListeningChanged`.
    @Published var alwaysListening: Bool {
        didSet {
            UserDefaults.standard.set(alwaysListening, forKey: Self.alwaysListeningDefaultsKey)
            NotificationCenter.default.post(name: .kikiAlwaysListeningChanged, object: nil)
        }
    }

    /// `nonisolated` por la misma razón que `translateEnabledDefaultsKey`:
    /// `AppDelegate.effectiveAlwaysListening()` la lee fuera de MainActor.
    nonisolated static let alwaysListeningDefaultsKey = "kiki.alwaysListening"

    /// F2 (spec 2026-07-11): tras dictar, la transcripción queda en el
    /// clipboard por defecto. Este toggle opt-in restaura el contenido
    /// anterior del clipboard ~0.4s después del paste (comportamiento
    /// pre-0.9.2). Sin efectos de ciclo de vida: `PasteInserter` lee la
    /// preferencia en cada insert vía closure, así que el cambio aplica
    /// en caliente sin notificaciones.
    @Published var restoreClipboardAfterDictation: Bool {
        didSet {
            UserDefaults.standard.set(
                restoreClipboardAfterDictation, forKey: Self.restoreClipboardDefaultsKey)
        }
    }

    /// `nonisolated`: `AppDelegate` construye el `PasteInserter` (y su
    /// closure lee esta key) fuera del init de SettingsViewModel.
    nonisolated static let restoreClipboardDefaultsKey = "kiki.restoreClipboard"

    /// Cap configurable del Historial (Ajustes → Historial, control
    /// "cantidad a conservar"), default 200 — mismo default que
    /// `HistoryStore.init(cap:)`. El `didSet` es la única fuente de escritura
    /// a `UserDefaults` desde la UI Y quien empuja el nuevo valor a
    /// `historyStore.setCap(_:)` para que el recorte (si el nuevo cap es
    /// menor) sea inmediato, no solo tras el próximo `append`.
    ///
    /// `nonisolated` por la misma razón que `translateEnabledDefaultsKey`/
    /// `alwaysListeningDefaultsKey`: `AppDelegate.effectiveHistoryCap()` lee
    /// esta clave al construir `historyStore`, ANTES de que exista
    /// `SettingsViewModel` (que sí es `@MainActor`).
    nonisolated static let historyCapDefaultsKey = "kiki.historyCap"

    @Published var historyCap: Int {
        didSet {
            UserDefaults.standard.set(historyCap, forKey: Self.historyCapDefaultsKey)
            historyStore.setCap(historyCap)
            refreshAll()
        }
    }

    /// Sección seleccionada del sidebar, persistida en `UserDefaults` y
    /// restaurada la próxima vez que se abre Ajustes (Fase 3.6, Task 2).
    @Published var selectedSection: SettingsSection {
        didSet {
            UserDefaults.standard.set(selectedSection.rawValue, forKey: Self.settingsSectionKey)
        }
    }

    // Info de solo lectura para la sección "General". Se lee directamente de
    // las fuentes de verdad (KikiWake/KikiSTT/KikiRefine) en vez de
    // duplicar los strings a mano, para no desincronizarse si cambian.
    let hotkeyDescription = "Fn (mantener presionada mientras hablas)"
    let wakePhrasesDescription = WakePhraseMatcher.phrases.joined(separator: "  /  ")
    let sttModelDescription = WhisperTranscriber.preferredModel
    let refineModelDescription = LLMRefiner.preferredModel

    private static let settingsSectionKey = "kiki.settingsSection"

    private let dictionaryAdapter: DictionaryAdapter
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore
    private let onToggleWake: () -> Void
    private var dictationObserver: NSObjectProtocol?

    init(
        dictionaryAdapter: DictionaryAdapter,
        snippetStore: SnippetStore,
        historyStore: HistoryStore,
        wakeEnabled: Bool,
        onToggleWake: @escaping () -> Void
    ) {
        self.dictionaryAdapter = dictionaryAdapter
        self.snippetStore = snippetStore
        self.historyStore = historyStore
        self.wakeEnabled = wakeEnabled
        self.onToggleWake = onToggleWake

        let defaults = UserDefaults.standard
        self.soundCuesEnabled = defaults.object(forKey: SoundCues.enabledDefaultsKey) != nil
            ? defaults.bool(forKey: SoundCues.enabledDefaultsKey)
            : true
        self.refineEnabled = defaults.object(forKey: Self.refineEnabledDefaultsKey) != nil
            ? defaults.bool(forKey: Self.refineEnabledDefaultsKey)
            : true
        self.translateEnabled = defaults.bool(forKey: Self.translateEnabledDefaultsKey)
        self.alwaysListening = defaults.object(forKey: Self.alwaysListeningDefaultsKey) != nil
            ? defaults.bool(forKey: Self.alwaysListeningDefaultsKey)
            : true
        self.restoreClipboardAfterDictation =
            UserDefaults.standard.bool(forKey: Self.restoreClipboardDefaultsKey)
        // `integer(forKey:)` devuelve 0 cuando la clave está ausente — un cap
        // de 0 no tiene sentido, así que se trata como "sin configurar" y cae
        // al default 200 (mismo default que `HistoryStore.init(cap:)`).
        let storedHistoryCap = defaults.integer(forKey: Self.historyCapDefaultsKey)
        self.historyCap = storedHistoryCap > 0 ? storedHistoryCap : 200
        if let rawSection = defaults.string(forKey: Self.settingsSectionKey),
           let restored = SettingsSection(rawValue: rawSection) {
            self.selectedSection = restored
        } else {
            self.selectedSection = .general
        }

        refreshAll()

        dictationObserver = NotificationCenter.default.addObserver(
            forName: .kikiDictationInserted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    deinit {
        if let dictationObserver {
            NotificationCenter.default.removeObserver(dictationObserver)
        }
    }

    func refreshAll() {
        terms = dictionaryAdapter.displayTerms
        snippets = snippetStore.snippets
        // Más reciente primero: más útil para revisar/copiar el último dictado.
        historyEntries = historyStore.entries.reversed()
    }

    /// Llamado por `AppDelegate` cuando el estado real de "Manos libres"
    /// cambia por una vía distinta al toggle de esta ventana (menú de la
    /// barra de estado, atajo global ⌥⌘K, fallo al arrancar el listener,
    /// arranque de la app). La ventana de Ajustes nunca es la fuente de
    /// verdad de este estado.
    func syncWakeEnabled(_ enabled: Bool) {
        wakeEnabled = enabled
    }

    /// El Toggle de la sección General llama esto en vez de asignar
    /// `wakeEnabled` directamente: delega en la MISMA lógica que el ítem de
    /// menú y el atajo ⌥⌘K (`AppDelegate.toggleWake`), que es quien de
    /// verdad arranca/para `WakeListener` y persiste `UserDefaults` — así
    /// los tres caminos quedan consistentes por construcción en vez de
    /// duplicar la lógica.
    func requestToggleWake() {
        onToggleWake()
    }

    // MARK: - Diccionario

    func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dictionaryAdapter.add(trimmed)
        refreshAll()
    }

    func removeTerm(_ term: String) {
        dictionaryAdapter.remove(term)
        refreshAll()
    }

    // MARK: - Snippets

    func addSnippet(trigger: String, template: String) {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedTemplate.isEmpty else { return }
        snippetStore.add(Snippet(trigger: trimmedTrigger, template: trimmedTemplate))
        refreshAll()
    }

    func removeSnippet(trigger: String) {
        snippetStore.remove(trigger: trigger)
        refreshAll()
    }

    // MARK: - Historial

    /// Texto del campo de búsqueda de Historial. El filtrado en sí es puro y
    /// vive en `HistorySearch` (KikiStore, testeado sin SwiftUI/AppKit);
    /// este `@Published` solo dispara el recómputo de `filteredHistoryEntries`
    /// vía SwiftUI.
    @Published var historySearchQuery = ""

    /// Vista filtrada de `historyEntries` (ya en orden "más reciente
    /// primero") sobre la que la sección Historial debe iterar en vez de
    /// `historyEntries` directamente. Query vacía → todas las entradas.
    var filteredHistoryEntries: [HistoryEntry] {
        HistorySearch.filter(historyEntries, query: historySearchQuery)
    }

    func clearHistory() {
        historyStore.clear()
        historySearchQuery = ""
        refreshAll()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
