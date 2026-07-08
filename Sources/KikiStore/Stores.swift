import Foundation
import KikiCore

public final class DictionaryStore {
    private let directory: URL
    private let fileURL: URL

    public private(set) var terms: [String] = []

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("dictionary.json")

        // Load from file
        if let loadedTerms: [String] = JSONStore.load(from: fileURL) {
            self.terms = loadedTerms
        }
    }

    public func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = trimmed.lowercased()

        // Check for duplicate (case-insensitive)
        if terms.contains(where: { $0.lowercased() == normalized }) {
            return
        }

        terms.append(trimmed)
        persist()
    }

    public func remove(_ term: String) {
        let normalized = term.trimmingCharacters(in: .whitespaces).lowercased()
        terms.removeAll { $0.lowercased() == normalized }
        persist()
    }

    private func persist() {
        JSONStore.save(terms, to: fileURL)
    }
}

public final class SnippetStore {
    private let directory: URL
    private let fileURL: URL

    public private(set) var snippets: [Snippet] = []

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("snippets.json")

        // Load from file
        if let loadedSnippets: [Snippet] = JSONStore.load(from: fileURL) {
            self.snippets = loadedSnippets
        }
    }

    public func add(_ snippet: Snippet) {
        let trimmedTrigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTemplate = snippet.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedTemplate.isEmpty else { return }

        // Dedupe with the SAME normalization SnippetAdapter uses to match
        // dictated text at runtime (lowercase + diacritic folding + per-word
        // punctuation strip) — see SnippetNormalization — so "café" and
        // "cafe" collide here exactly like they would at match time.
        let normalizedTrigger = SnippetNormalization.normalize(trimmedTrigger)
        if snippets.contains(where: { SnippetNormalization.normalize($0.trigger) == normalizedTrigger }) {
            return
        }

        snippets.append(snippet)
        persist()
    }

    public func remove(trigger: String) {
        let normalizedTrigger = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        snippets.removeAll { $0.trigger.trimmingCharacters(in: .whitespaces).lowercased() == normalizedTrigger }
        persist()
    }

    private func persist() {
        JSONStore.save(snippets, to: fileURL)
    }
}

public final class HistoryStore {
    private let directory: URL
    private let fileURL: URL

    public private(set) var cap: Int
    public private(set) var entries: [HistoryEntry] = []

    public init(directory: URL, cap: Int = 200) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("history.json")
        self.cap = cap

        // Load from file
        if let loadedEntries: [HistoryEntry] = JSONStore.load(from: fileURL) {
            self.entries = loadedEntries
        }
    }

    public func append(_ entry: HistoryEntry) {
        entries.append(entry)
        trimToCapIfNeeded()
        persist()
    }

    public func clear() {
        entries.removeAll()
        persist()
    }

    /// Cambia el cap en caliente (Ajustes → Historial, control de "cantidad a
    /// conservar"). Si el nuevo cap es MENOR que el número de entradas
    /// actuales, recorta de inmediato a las más recientes (mismo criterio
    /// FIFO que `append`/`trimToCapIfNeeded`) y persiste el resultado. Si es
    /// MAYOR, no hace nada más que levantar el techo — las entradas
    /// existentes se conservan tal cual y el historial puede volver a crecer
    /// hasta el nuevo límite con los próximos `append`.
    public func setCap(_ newCap: Int) {
        guard newCap > 0 else { return }
        cap = newCap
        trimToCapIfNeeded()
        persist()
    }

    private func trimToCapIfNeeded() {
        if entries.count > cap {
            // Keep the NEWEST entries (trim from the beginning)
            entries = Array(entries.suffix(cap))
        }
    }

    private func persist() {
        JSONStore.save(entries, to: fileURL)
    }
}
