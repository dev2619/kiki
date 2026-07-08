import Foundation

/// Red de seguridad de fidelidad del refinado (bugfix 2026-07-08).
///
/// El prompt de refinado es la defensa principal contra que el LLM parafrasee
/// el dictado, pero un modelo de 3B puede desviarse igual. Esta guardia,
/// puramente léxica, detecta el modo de fallo más dañino: el refinador
/// INTRODUCE vocabulario que el usuario nunca dijo — porque respondió una
/// pregunta del texto, alucinó, o reformuló con palabras nuevas. Una limpieza
/// legítima (quitar muletillas, arreglar puntuación/mayúsculas) NUNCA agrega
/// palabras nuevas: solo borra o normaliza. Así que "el refinado trae muchas
/// palabras que no están en el original" es una señal segura de infidelidad,
/// sin castigar la limpieza normal (que solo elimina).
///
/// NO se aplica en modo traducción: traducir cambia el vocabulario por diseño.
public enum RefineFidelity {
    /// Fracción máxima de palabras del texto refinado que pueden estar
    /// ausentes del original (más el diccionario del usuario) antes de
    /// considerarlo infiel. 0.5 = si más de la mitad del refinado es
    /// vocabulario nuevo, es paráfrasis/alucinación, no limpieza.
    public static let maxNoveltyRatio = 0.5

    /// `true` si `refined` es una limpieza fiel de `original`: no introduce
    /// demasiado vocabulario nuevo. `allowedExtraTerms` son términos del
    /// diccionario del usuario (correcciones de escritura legítimas que el
    /// refinador puede aplicar aunque Whisper los haya transcrito distinto).
    public static func isFaithful(
        original: String,
        refined: String,
        allowedExtraTerms: [String] = []
    ) -> Bool {
        let refinedTokens = tokenize(refined)
        // Sin palabras que evaluar → nada que objetar (las guardias de longitud
        // vacía viven en DictationController).
        guard !refinedTokens.isEmpty else { return true }

        var allowed = Set(tokenize(original))
        for term in allowedExtraTerms {
            allowed.formUnion(tokenize(term))
        }

        let novelCount = refinedTokens.reduce(into: 0) { count, token in
            if !allowed.contains(token) { count += 1 }
        }
        let noveltyRatio = Double(novelCount) / Double(refinedTokens.count)
        return noveltyRatio <= maxNoveltyRatio
    }

    /// Normaliza a palabras comparables: minúsculas, sin acentos, partido por
    /// cualquier cosa que no sea letra o dígito. Así "Repositorios," y
    /// "repositorios" cuentan igual, y la puntuación (que el refinado sí puede
    /// cambiar legítimamente) no genera falsos "nuevos".
    static func tokenize(_ text: String) -> [String] {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .lowercased()
        return folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
