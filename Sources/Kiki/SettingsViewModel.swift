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

    func clearHistory() {
        historyStore.clear()
        refreshAll()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
