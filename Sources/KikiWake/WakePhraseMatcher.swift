import Foundation

public struct WakeMatch: Equatable {
    /// Dictado en el mismo aliento tras la frase ("escúchame kiki, escribe X" → "escribe X").
    /// Vacío si solo se dijo la frase.
    public let remainder: String
}

public enum WakePhraseMatcher {
    public static let phrases = ["escuchame kiki", "listen to me kiki"]

    /// Matches the transcript against wake phrases.
    /// Returns a WakeMatch if the transcript contains a wake phrase (with ≤2 preamble words tolerated).
    /// Returns nil if no phrase is found or if the phrase appears with >2 preamble words.
    public static func match(_ transcript: String) -> WakeMatch? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespaces)
        guard !trimmedTranscript.isEmpty else { return nil }

        // Tokenize the transcript into original words
        let originalWords = tokenizeWords(trimmedTranscript)
        guard !originalWords.isEmpty else { return nil }

        // Normalize words for comparison
        let normalizedWords = originalWords.map(normalizeWord(_:))

        // Prepare normalized phrases (word sequences to search for)
        let normalizedPhrases: [[String]] = phrases.map { phrase in
            tokenizeWords(phrase).map(normalizeWord(_:))
        }

        // Search for each phrase in the normalized words
        for normalizedPhrase in normalizedPhrases {
            if let matchIndex = findPhraseIndex(normalizedPhrase, in: normalizedWords) {
                // Check if preamble is ≤ 2 words
                if matchIndex <= 2 {
                    // Calculate remainder from original words
                    let endIndex = matchIndex + normalizedPhrase.count
                    let remainderWords = Array(originalWords[endIndex...])
                    let remainder = remainderWords.joined(separator: " ")
                    return WakeMatch(remainder: remainder)
                }
            }
        }

        return nil
    }

    // MARK: - Private helpers

    private static func tokenizeWords(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func normalizeWord(_ word: String) -> String {
        word
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil) // locale nil = folding independiente del locale del sistema (determinístico entre máquinas)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func findPhraseIndex(_ phrase: [String], in words: [String]) -> Int? {
        guard phrase.count > 0, phrase.count <= words.count else { return nil }

        for i in 0...(words.count - phrase.count) {
            if words[i..<(i + phrase.count)].elementsEqual(phrase) {
                return i
            }
        }

        return nil
    }
}
