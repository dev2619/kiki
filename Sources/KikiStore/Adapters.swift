import Foundation
import KikiCore

/// Adapta `DictionaryStore` (Fase 3, Task 3/4) al protocolo `DictionaryProviding`
/// consumido por `WhisperTranscriber` (actor, executor propio) y `LLMRefiner`
/// (executor concurrente arbitrario) — es decir, `terms()` se invoca desde
/// hilos que NO son MainActor. Las mutaciones (añadir/quitar término), en
/// cambio, llegan siempre desde la ventana de Ajustes (MainActor).
///
/// `DictionaryStore` en sí NO es thread-safe (mutación in-place + persistencia
/// a disco sin lock), así que este adapter nunca expone el store a los
/// lectores cross-thread: mantiene su propio snapshot inmutable
/// (`cachedTerms: [String]`) protegido por un `NSLock`. Las mutaciones
/// (`add`/`remove`, marcadas `@MainActor`) escriben en el store y luego
/// publican el snapshot nuevo bajo el lock; `terms()` (llamable desde
/// cualquier hilo, incluyendo el executor del actor STT y el executor
/// concurrente del refiner) solo lee el snapshot bajo el mismo lock — nunca
/// toca `store` directamente. Esto evita cualquier carrera de datos entre el
/// hilo de lectura (STT/refine) y el hilo de escritura (UI).
public final class DictionaryAdapter: DictionaryProviding, @unchecked Sendable {
    private let store: DictionaryStore
    private let lock = NSLock()
    private var cachedTerms: [String]

    public init(store: DictionaryStore) {
        self.store = store
        self.cachedTerms = store.terms
    }

    /// Lectura para la UI de Ajustes (MainActor). Lee el store directamente
    /// (mismo hilo que las mutaciones) en vez de pasar por el lock/snapshot,
    /// que existen únicamente para el consumo cross-thread de `terms()`.
    @MainActor
    public var displayTerms: [String] { store.terms }

    @MainActor
    public func add(_ term: String) {
        store.add(term)
        publishSnapshot()
    }

    @MainActor
    public func remove(_ term: String) {
        store.remove(term)
        publishSnapshot()
    }

    @MainActor
    private func publishSnapshot() {
        let snapshot = store.terms
        lock.lock()
        cachedTerms = snapshot
        lock.unlock()
    }

    /// Llamado off-MainActor por `WhisperTranscriber` (executor del actor) y
    /// `LLMRefiner` (executor concurrente arbitrario de `DictationController`).
    /// Nunca toca `store` — solo lee el snapshot inmutable bajo lock.
    public func terms() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return cachedTerms
    }
}

/// Adapta `SnippetStore` al protocolo `SnippetExpanding`. `expand()` se
/// invoca exclusivamente desde `DictationController.processTranscriptContent`
/// (método de una clase `@MainActor`) — el mismo actor que las mutaciones del
/// store desde la ventana de Ajustes — así que, a diferencia de
/// `DictionaryAdapter`, no hace falta lock ni snapshot: leer `store.snippets`
/// directamente es seguro.
///
/// Nota de normalización: el trigger debe matchear el texto dictado completo
/// (no un substring) de forma tolerante a mayúsculas/acentos/puntuación,
/// igual que `WakePhraseMatcher.normalizeWord` en `KikiWake`. No se reusa esa
/// función aquí porque (a) es `private` y (b) `KikiStore` no depende de
/// `KikiWake` — acoplar el store de personalización al target del pipeline de
/// audio para reusar una función de 4 líneas no vale el acoplamiento. La
/// normalización usada aquí vive en `SnippetNormalization` (compartida con
/// `SnippetStore.add` para que el dedupe al guardar y el matching en runtime
/// no puedan divergir); replica exactamente la lógica de
/// `WakePhraseMatcher.normalizeWord` (lowercase + diacritic folding con
/// `locale: nil` + strip de puntuación por palabra) — si esa función cambia,
/// replicar el cambio también en `SnippetNormalization`.
public final class SnippetAdapter: SnippetExpanding {
    private let store: SnippetStore

    public init(store: SnippetStore) {
        self.store = store
    }

    public func expand(_ text: String) -> String? {
        let normalizedInput = SnippetNormalization.normalize(text)
        guard !normalizedInput.isEmpty else { return nil }
        return store.snippets.first { SnippetNormalization.normalize($0.trigger) == normalizedInput }?.template
    }
}

/// Adapta `HistoryStore` al protocolo `HistoryRecording`. `record()` se
/// invoca exclusivamente desde `DictationController` (MainActor) — el mismo
/// actor que la mutación "Borrar historial" de la ventana de Ajustes — así
/// que, igual que `SnippetAdapter`, no hace falta lock.
public final class HistoryAdapter: HistoryRecording {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    public func record(_ entry: HistoryRecord) {
        store.append(HistoryEntry(
            date: Date(),
            rawText: entry.rawText,
            finalText: entry.finalText,
            profile: entry.profile.rawValue,
            audioSeconds: entry.audioSeconds))
    }
}
