import XCTest
@testable import KikiStore

/// Cobertura de `HistorySearch` — filtrado puro (sin `HistoryStore`) usado por
/// el campo de búsqueda del Historial en Ajustes. Case- y accent-insensitive
/// sobre `rawText` + `finalText`.
final class HistorySearchTests: XCTestCase {
    private func entry(raw: String, final: String) -> HistoryEntry {
        HistoryEntry(date: Date(), rawText: raw, finalText: final, profile: "default", audioSeconds: 1.0)
    }

    func testEmptyQueryMatchesAllEntries() {
        let entries = [
            entry(raw: "hola", final: "hola"),
            entry(raw: "adios", final: "adios"),
        ]
        XCTAssertEqual(HistorySearch.filter(entries, query: ""), entries)
    }

    func testWhitespaceOnlyQueryMatchesAllEntries() {
        let entries = [entry(raw: "hola", final: "hola")]
        XCTAssertEqual(HistorySearch.filter(entries, query: "   "), entries)
    }

    func testAccentInsensitiveMatch() {
        let entries = [entry(raw: "tengo una reunión mañana", final: "Tengo una reunión mañana")]
        XCTAssertEqual(HistorySearch.filter(entries, query: "reunion").count, 1)
        XCTAssertEqual(HistorySearch.filter(entries, query: "mañana").count, 1)
        XCTAssertEqual(HistorySearch.filter(entries, query: "manana").count, 1)
    }

    func testCaseInsensitiveMatch() {
        let entries = [entry(raw: "Hello World", final: "Hello World")]
        XCTAssertEqual(HistorySearch.filter(entries, query: "hello").count, 1)
        XCTAssertEqual(HistorySearch.filter(entries, query: "WORLD").count, 1)
    }

    func testNoMatchReturnsEmpty() {
        let entries = [entry(raw: "hola mundo", final: "hola mundo")]
        XCTAssertEqual(HistorySearch.filter(entries, query: "xyz"), [])
    }

    func testMatchesEitherRawOrFinalText() {
        let entries = [entry(raw: "raw only term", final: "different final text")]
        XCTAssertEqual(HistorySearch.filter(entries, query: "raw only").count, 1)
        XCTAssertEqual(HistorySearch.filter(entries, query: "different final").count, 1)
        XCTAssertEqual(HistorySearch.filter(entries, query: "nowhere").count, 0)
    }

    func testFilterPreservesOrderAndOnlyKeepsMatches() {
        let match1 = entry(raw: "primera reunión", final: "primera reunión")
        let noMatch = entry(raw: "algo distinto", final: "algo distinto")
        let match2 = entry(raw: "otra reunion", final: "otra reunion")
        let entries = [match1, noMatch, match2]

        XCTAssertEqual(HistorySearch.filter(entries, query: "reunion"), [match1, match2])
    }
}
