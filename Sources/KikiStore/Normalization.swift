import Foundation

/// Normalización compartida de triggers de snippets: lowercase + diacritic
/// folding (`locale: nil`) + strip de puntuación por palabra.
///
/// Usada tanto por `SnippetStore.add` (dedupe al guardar) como por
/// `SnippetAdapter.expand` (matching en runtime contra el texto dictado) —
/// ambas rutas comparten esta única implementación a propósito: si vivieran
/// duplicadas podrían divergir con el tiempo y producir el bug sutil de
/// "guardé un trigger pero nunca hace match" (o viceversa, un duplicado que sí
/// se guardó porque el dedupe usaba una normalización más débil que el
/// matcher).
enum SnippetNormalization {
    static func normalize(_ text: String) -> String {
        text
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word in
                word
                    .lowercased()
                    .folding(options: .diacriticInsensitive, locale: nil)
                    .trimmingCharacters(in: .punctuationCharacters)
            }
            .joined(separator: " ")
    }
}

/// Filtrado puro del Historial (Ajustes → Historial, campo de búsqueda):
/// coincidencia de subcadena sobre `rawText`/`finalText`, case- Y
/// accent-insensitive. Misma TÉCNICA de plegado que `SnippetNormalization`
/// (`.folding(diacriticInsensitive)`) pero SIN partir en palabras ni recortar
/// puntuación por palabra — ahí se necesitaba igualdad exacta de un trigger
/// completo; aquí se necesita que "reunion" (sin tilde, tecleado en el campo
/// de búsqueda) matchee una subcadena dentro de "tengo una reunión mañana",
/// sin tocar ni reordenar el texto de las entradas guardadas. Vive en
/// `KikiStore` (junto a `HistoryEntry`/`HistoryStore`) en vez de en el target
/// de la app para poder testearse con `KikiStoreTests` sin depender de
/// SwiftUI/AppKit.
public enum HistorySearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `true` si `query` (trimmed) es vacía (sin filtro activo) o aparece
    /// como subcadena normalizada de `rawText` o `finalText`.
    public static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }
        let normalizedQuery = normalize(trimmedQuery)
        return normalize(entry.rawText).contains(normalizedQuery)
            || normalize(entry.finalText).contains(normalizedQuery)
    }

    /// Filtra `entries` preservando el orden original — el ViewModel decide
    /// el orden (más reciente primero) ANTES de llamar a esto.
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        entries.filter { matches($0, query: query) }
    }
}
