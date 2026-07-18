import Foundation

public struct WakeMatch: Equatable {
    /// Dictado en el mismo aliento tras la frase ("escúchame kiki, escribe X" → "escribe X").
    /// Vacío si solo se dijo la frase.
    public let remainder: String
}

/// Matchea la frase de activación contra transcripciones REALES de Whisper.
///
/// ## Bug de campo (fix/wake-phrase-matching)
/// El matcher original exigía la secuencia exacta de palabras
/// `["escuchame", "kiki"]` tras normalizar (lowercase + fold de diacríticos +
/// strip de puntuación). Diagnóstico con audio sintetizado (`say`) a través
/// del `WhisperTranscriber` REAL (ver `WakePhraseWhisperDiagnosisTests`,
/// gated con `KIKI_STT_TEST=1`) mostró que Whisper NUNCA produce esa
/// secuencia exacta para "escúchame kiki": el audio corto hace que la
/// detección de idioma de Whisper se decante por inglés, y entonces
/// deletrea "escúchame" fonéticamente como si fueran sílabas en inglés —
/// verbatim observado:
///   - "Eska-Chame-Kiki."             (guion como separador de palabra)
///   - "Escochame Kiki, ..."          (typo de una sola letra: o↔u)
///   - "Oye eska chame kiki."         (partida en DOS tokens: "eska"+"chame")
/// "listen to me kiki" sí transcribe limpio ("Listen to me Kiki.") porque
/// coincide con el idioma detectado.
///
/// Esto NO es un problema de audio/umbral (Whisper SÍ oye la frase con audio
/// limpio) — es que el matcher exacto no tolera ninguna de las formas reales
/// en que Whisper la representa. El fix combina dos mecanismos, ambos
/// acotados para no disparar falsos positivos:
///
/// 1. **Unión de tokens partidos**: la palabra "escuchame" puede aparecer
///    partida en hasta 2 tokens consecutivos ("eska"+"chame"); se prueba la
///    concatenación (sin separador) contra el objetivo antes de descartar.
/// 2. **Fuzzy match acotado** (Levenshtein ≤1) por palabra objetivo
///    ("escuchame"/"eskachame"/"kiki"/"listen"/"me") — cubre typos de una
///    letra ("escochame") y mishearings de una letra del nombre del producto
///    ("kiki"→"kiwi"). El ancla "kiki" es lo bastante infrecuente en habla
///    casual como para que ±1 edit no dispare falsos positivos por sí solo;
///    la secuencia completa (todas las palabras de la frase, en orden,
///    contiguas) es la que mantiene el riesgo bajo incluso combinada con el
///    fuzzing.
///
/// `eskachame` se declara como spelling alternativo EXPLÍCITO (no solo
/// fuzzy ≤1) porque "eska"+"chame" está a distancia 2 de "escuchame"
/// (sustituciones en dos posiciones: c→k, u→a) — más allá del radio ≤1 que
/// mantiene acotados los falsos positivos para el resto de las palabras.
public enum WakePhraseMatcher {
    /// Frases de referencia (documentación/tests) — la fuente de verdad real
    /// del matching vive en `spanishSlots`/`englishSlots` abajo, que
    /// modelan tolerancia a partición de tokens y fuzzy matching por
    /// palabra. Mantenido como API pública estable.
    public static let phrases = ["escuchame kiki", "listen to me kiki"]

    /// Preámbulo máximo (en palabras) tolerado antes de la frase.
    private static let maxPreambleWords = 2

    /// Una "posición" dentro de una frase de activación: una palabra
    /// objetivo que puede (a) aparecer partida en varios tokens consecutivos
    /// de la transcripción (`maxTokens`), y/o (b) tolerar una distancia de
    /// edición acotada (`maxEditDistance`) respecto al objetivo o a alguno
    /// de sus `alternates` (variantes fonéticas observadas que exceden esa
    /// distancia y por eso se listan explícitamente en vez de ampliar el
    /// radio fuzzy global).
    private struct WakeSlot {
        let canonical: String
        let alternates: [String]
        let maxTokens: Int
        let maxEditDistance: Int

        init(_ canonical: String, alternates: [String] = [], maxTokens: Int = 1, maxEditDistance: Int = 1) {
            self.canonical = canonical
            self.alternates = alternates
            self.maxTokens = maxTokens
            self.maxEditDistance = maxEditDistance
        }
    }

    /// "escuchame" tolera partirse en hasta 2 tokens (ver doc de tipo) y
    /// tiene el spelling alternativo "eskachame" (distancia 2, fuera del
    /// radio fuzzy ≤1). "kiki" es el ancla del producto: fuzzy ≤1 cubre
    /// mishearings de una letra ("kiwi") sin abrir la puerta a coincidencias
    /// lejanas.
    private static let spanishSlots: [WakeSlot] = [
        WakeSlot("escuchame", alternates: ["eskachame"], maxTokens: 2, maxEditDistance: 1),
        WakeSlot("kiki", maxTokens: 1, maxEditDistance: 1),
    ]

    /// "to" se deja SIN fuzzy (maxEditDistance 0): es una palabra de 2 letras
    /// donde ±1 edición coincide con casi cualquier otra palabra de 2-3
    /// letras — fuzzearla ampliaría el riesgo de falso positivo sin evidencia
    /// de que Whisper la transcriba mal (el diagnóstico no mostró ningún
    /// caso). El resto de la frase sí tolera ≤1 por instrucción explícita.
    private static let englishSlots: [WakeSlot] = [
        WakeSlot("listen", maxTokens: 1, maxEditDistance: 1),
        WakeSlot("to", maxTokens: 1, maxEditDistance: 0),
        WakeSlot("me", maxTokens: 1, maxEditDistance: 1),
        WakeSlot("kiki", maxTokens: 1, maxEditDistance: 1),
    ]

    /// Comandos de voz de manos libres (2026-07-18). Distintos de la frase de
    /// dictado: NO llevan remainder — son órdenes que se consumen (nunca se
    /// insertan como texto).
    public enum WakeCommand: Equatable {
        case startHandsFree   // "manos libres kiki" / "hands free kiki"
        case stopHandsFree    // "kiki detente" / "detente kiki" / "kiki stop"
    }

    private static let startHandsFreeSlots: [[WakeSlot]] = [
        [WakeSlot("manos"), WakeSlot("libres"), WakeSlot("kiki")],
        [WakeSlot("hands"), WakeSlot("free"), WakeSlot("kiki")],
    ]
    private static let stopHandsFreeSlots: [[WakeSlot]] = [
        [WakeSlot("kiki"), WakeSlot("detente")],
        [WakeSlot("detente"), WakeSlot("kiki")],
        [WakeSlot("kiki"), WakeSlot("stop")],
        [WakeSlot("para"), WakeSlot("kiki")],
    ]

    /// Detecta un comando de voz de manos libres en una utterance. Exige que el
    /// comando sea prácticamente TODA la utterance (poco preámbulo y poca cola)
    /// para no dispararse por una palabra suelta en medio de un dictado normal.
    public static func detectCommand(_ transcript: String) -> WakeCommand? {
        let tokens = normalizedTokensOnly(transcript)
        guard !tokens.isEmpty else { return nil }
        func isWholeCommand(_ slots: [WakeSlot]) -> Bool {
            guard let (start, consumed) = findSlotMatch(slots, in: tokens) else { return false }
            // Casi toda la utterance = el comando (evita falsos positivos
            // cuando "detente"/"para" aparecen dentro de un dictado largo).
            return start <= maxPreambleWords && (tokens.count - (start + consumed)) <= 1
        }
        for slots in startHandsFreeSlots where isWholeCommand(slots) { return .startHandsFree }
        for slots in stopHandsFreeSlots where isWholeCommand(slots) { return .stopHandsFree }
        return nil
    }

    /// Tokens normalizados (lowercase + fold + strip puntuación, partidos por
    /// espacio y guion) — la misma normalización que usa `match`, sin el
    /// back-ref a palabras originales (los comandos no producen remainder).
    private static func normalizedTokensOnly(_ transcript: String) -> [String] {
        var out: [String] = []
        for word in tokenizeOriginal(transcript.trimmingCharacters(in: .whitespaces)) {
            for sub in splitOnHyphen(word) {
                let n = normalizeWord(sub)
                if !n.isEmpty { out.append(n) }
            }
        }
        return out
    }

    /// Matches the transcript against wake phrases.
    /// Returns a WakeMatch if the transcript contains a wake phrase (with ≤2 preamble words tolerated).
    /// Returns nil if no phrase is found or if the phrase appears with >2 preamble words.
    public static func match(_ transcript: String) -> WakeMatch? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespaces)
        guard !trimmedTranscript.isEmpty else { return nil }

        // Tokenización de las palabras ORIGINALES: SOLO por espacios en blanco,
        // para preservar los guiones intactos dentro del dictado (kiki es una
        // app de dictado — "user-name" debe llegar al remainder VERBATIM). El
        // hyphen-split se aplica únicamente al array normalizado de matching
        // (abajo), nunca a las palabras originales de las que se corta el
        // remainder.
        let originalWords = tokenizeOriginal(trimmedTranscript)
        guard !originalWords.isEmpty else { return nil }

        // Array normalizado y partido-por-guion para el matching. Cada token
        // normalizado recuerda de qué índice de `originalWords` provino
        // (`originIndex`), para poder cortar el remainder de `originalWords`
        // (con los guiones intactos) aunque una palabra de la frase se haya
        // partido en varios tokens normalizados por guion. Sin este back-ref,
        // los conteos de tokens de ambos arrays divergen en la región de la
        // frase y el remainder se cortaría en el offset equivocado.
        var normalizedTokens: [String] = []
        var originIndex: [Int] = []
        for (i, word) in originalWords.enumerated() {
            for sub in splitOnHyphen(word) {
                let normalized = normalizeWord(sub)
                guard !normalized.isEmpty else { continue }
                normalizedTokens.append(normalized)
                originIndex.append(i)
            }
        }
        guard !normalizedTokens.isEmpty else { return nil }

        for slots in [spanishSlots, englishSlots] {
            if let (start, consumed) = findSlotMatch(slots, in: normalizedTokens) {
                let endNormalized = start + consumed
                // El remainder arranca en la palabra ORIGINAL dueña del primer
                // token normalizado DESPUÉS de la región matcheada (recuperado
                // vía `originIndex`), o vacío si la frase llegó al final. Así
                // el corte es correcto en términos del array space-tokenizado
                // sin importar cuántos guiones haya partido la frase por dentro.
                let remainder: String
                if endNormalized < normalizedTokens.count {
                    let remainderStart = originIndex[endNormalized]
                    remainder = originalWords[remainderStart...].joined(separator: " ")
                } else {
                    remainder = ""
                }
                return WakeMatch(remainder: remainder)
            }
        }

        return nil
    }

    // MARK: - Private helpers

    /// Tokeniza SOLO por espacios en blanco — preserva los guiones dentro de
    /// cada token (dictado real: "user-name" queda como un único token
    /// verbatim). Es la base de la que se corta el remainder; el hyphen-split
    /// para matching vive aparte en `splitOnHyphen` (ver `match`).
    private static func tokenizeOriginal(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " })
            .map(String.init)
    }

    /// Parte un token por guiones. Los guiones se tratan como separador de
    /// palabra SOLO para el matching (no para el remainder) porque Whisper los
    /// usa para deletrear fonéticamente palabras fuera de vocabulario
    /// ("Eska-Chame-Kiki." — ver doc de tipo). Aislar esto al camino de
    /// matching es lo que evita mutilar guiones del contenido dictado.
    private static func splitOnHyphen(_ token: String) -> [String] {
        token.split(whereSeparator: { $0 == "-" })
            .map(String.init)
    }

    private static func normalizeWord(_ word: String) -> String {
        word
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil) // locale nil = folding independiente del locale del sistema (determinístico entre máquinas)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// Busca la frase (secuencia de `slots`) en `words`, permitiendo hasta
    /// `maxPreambleWords` palabras antes de que empiece. Devuelve el índice
    /// de inicio y cuántos tokens de `words` consumió la frase completa (que
    /// puede ser mayor que `slots.count` si algún slot se partió en varios
    /// tokens).
    private static func findSlotMatch(_ slots: [WakeSlot], in words: [String]) -> (start: Int, consumed: Int)? {
        guard !slots.isEmpty, !words.isEmpty else { return nil }
        let maxStart = min(maxPreambleWords, words.count - 1)
        guard maxStart >= 0 else { return nil }

        for start in 0...maxStart {
            if let consumed = matchSlots(slots, in: words, from: start) {
                return (start, consumed)
            }
        }
        return nil
    }

    /// Intenta consumir todos los `slots`, en orden, empezando en `start`.
    /// Cada slot prueba primero 1 token, luego 2 (hasta `maxTokens`),
    /// concatenados sin separador — así "eska"+"chame" se compara como
    /// "eskachame" contra el objetivo/alternates del slot.
    private static func matchSlots(_ slots: [WakeSlot], in words: [String], from start: Int) -> Int? {
        var idx = start
        for slot in slots {
            guard idx < words.count else { return nil }
            guard let consumed = matchSlot(slot, in: words, at: idx) else { return nil }
            idx += consumed
        }
        return idx - start
    }

    private static func matchSlot(_ slot: WakeSlot, in words: [String], at idx: Int) -> Int? {
        // Guarda contra un `maxTokens` mal configurado (< 1): `1...maxTokens`
        // haría trap de rango con 0. Un slot que no consume ningún token no
        // tiene sentido, así que se trata como "no matchea".
        guard slot.maxTokens >= 1 else { return nil }
        let targets = [slot.canonical] + slot.alternates
        for tokenCount in 1...slot.maxTokens {
            guard idx + tokenCount <= words.count else { break }
            let candidate = words[idx..<(idx + tokenCount)].joined()
            for target in targets {
                if isCloseMatch(candidate, target, maxDistance: slot.maxEditDistance) {
                    return tokenCount
                }
            }
        }
        return nil
    }

    /// `true` si `a` y `b` son iguales, o si difieren en ≤`maxDistance`
    /// ediciones (Levenshtein). `maxDistance` 0 exige igualdad exacta.
    static func isCloseMatch(_ a: String, _ b: String, maxDistance: Int) -> Bool {
        if a == b { return true }
        guard maxDistance > 0 else { return false }
        return levenshteinDistance(a, b) <= maxDistance
    }

    /// Distancia de edición clásica (inserción/borrado/sustitución, costo 1
    /// c/u) entre dos strings cortas — palabras individuales, nunca frases
    /// completas, así que el DP O(n·m) es intrascendente en costo.
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previousRow = Array(0...b.count)
        var currentRow = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            currentRow[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                currentRow[j] = Swift.min(
                    previousRow[j] + 1,      // deletion
                    currentRow[j - 1] + 1,   // insertion
                    previousRow[j - 1] + cost // substitution
                )
            }
            previousRow = currentRow
        }
        return previousRow[b.count]
    }
}
