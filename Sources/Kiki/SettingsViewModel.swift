import AppKit
import KikiCore
import KikiRefine
import KikiSTT
import KikiStore
import KikiWake

/// Estado observable de la ventana de Ajustes. Marcado `@MainActor` en
/// bloque: todas sus mutaciones (añadir/quitar término o snippet, borrar
/// historial, copiar al portapapeles) llegan desde la UI de SwiftUI, que ya
/// corre en MainActor — así que no hace falta ningún lock aquí, a diferencia
/// de `DictionaryAdapter` (que sí cruza al hilo del STT/refiner).
///
/// Refresco simple por diseño (Task 4): tras cada mutación se relee el
/// estado completo de los stores en vez de mantener diffs incrementales —
/// los stores son pequeños (diccionario/snippets personales, historial
/// acotado a `cap` entradas) y esto evita bugs de desincronización.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var terms: [String] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published private(set) var wakeEnabled: Bool

    // Info de solo lectura para la pestaña "General". Se lee directamente de
    // las fuentes de verdad (KikiWake/KikiSTT/KikiRefine) en vez de
    // duplicar los strings a mano, para no desincronizarse si cambian.
    let hotkeyDescription = "Fn (mantener presionada mientras hablas)"
    let wakePhrasesDescription = WakePhraseMatcher.phrases.joined(separator: "  /  ")
    let sttModelDescription = WhisperTranscriber.preferredModel
    let refineModelDescription = LLMRefiner.preferredModel

    private let dictionaryAdapter: DictionaryAdapter
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore
    private let onToggleWake: () -> Void

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
        refreshAll()
    }

    func refreshAll() {
        terms = dictionaryAdapter.displayTerms
        snippets = snippetStore.snippets
        // Más reciente primero: más útil para revisar/copiar el último dictado.
        historyEntries = historyStore.entries.reversed()
    }

    /// Llamado por `AppDelegate` cuando el estado real de "Manos libres"
    /// cambia por una vía distinta al toggle de esta ventana (menú de la
    /// barra de estado, fallo al arrancar el listener, arranque de la app).
    /// La ventana de Ajustes nunca es la fuente de verdad de este estado.
    func syncWakeEnabled(_ enabled: Bool) {
        wakeEnabled = enabled
    }

    /// El Toggle de la pestaña General llama esto en vez de asignar
    /// `wakeEnabled` directamente: delega en la MISMA lógica que el ítem de
    /// menú (`AppDelegate.toggleWake`), que es quien de verdad arranca/para
    /// `WakeListener` y persiste `UserDefaults` — así ambos toggles quedan
    /// consistentes por construcción en vez de duplicar la lógica.
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
