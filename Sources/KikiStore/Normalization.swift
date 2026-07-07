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
