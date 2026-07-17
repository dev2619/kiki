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
    /// considerarlo infiel.
    ///
    /// Endurecido a 0.15 (2026-07-17, feedback de campo "el dictado lo tomó
    /// bien, tal cual lo dije, pero la transcripción se cambió"): una limpieza
    /// legítima (mayúsculas, puntuación, acentos, quitar muletillas) produce
    /// CERO vocabulario nuevo — los acentos y mayúsculas se pliegan en
    /// `tokenize`, y borrar no agrega. Por tanto, casi cualquier palabra nueva
    /// es un cambio no deseado: el refinador reescribió lo que Whisper ya había
    /// acertado. Con el umbral bajo, ese refinado se RECHAZA y se inserta el
    /// texto crudo y fiel de Whisper. El 0.15 (no 0) deja un margen mínimo para
    /// casos legítimos raros (p. ej. separar dos palabras que Whisper pegó).
    public static let maxNoveltyRatio = 0.15

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

    /// Muletillas/rellenos que el refinado SÍ puede borrar legítimamente — se
    /// excluyen del chequeo de cobertura para no penalizar una limpieza real.
    /// (Alineado con la lista del prompt de refinado.)
    static let fillerTokens: Set<String> = [
        "eh", "em", "este", "pues", "bueno", "osea", "o", "sea", "entonces",
        "digamos", "like", "uh", "um", "mmm", "ah", "mm", "eeh",
    ]

    /// Fracción MÍNIMA de las palabras de contenido del original (excluidas las
    /// muletillas) que deben seguir presentes en el refinado. Por debajo de
    /// esto, el refinado BORRÓ/reordenó contenido real (no solo limpió) — modo
    /// de fallo del bug de campo 2026-07-17: "Yo no dije aquí, dije Kiki." →
    /// "Kiki dije aquí" (perdió la negación). La guardia de novelty no lo veía
    /// porque no agregó vocabulario; esta de cobertura sí.
    public static let minContentCoverage = 0.8

    /// `true` si el refinado PRESERVA el contenido del original: la mayoría de
    /// las palabras de contenido (sin muletillas) del original siguen presentes.
    /// Complementa a `isFaithful` (que ataca palabras AÑADIDAS) atacando el modo
    /// inverso: palabras BORRADAS/reordenadas que cambian el sentido.
    public static func preservesContent(
        original: String,
        refined: String,
        minCoverage: Double = minContentCoverage
    ) -> Bool {
        let originalContent = Set(tokenize(original)).subtracting(fillerTokens)
        guard !originalContent.isEmpty else { return true }
        let refinedTokens = Set(tokenize(refined))
        let preserved = originalContent.filter { refinedTokens.contains($0) }.count
        return Double(preserved) / Double(originalContent.count) >= minCoverage
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
