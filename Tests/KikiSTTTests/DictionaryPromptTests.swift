import XCTest
@testable import KikiSTT

final class DictionaryPromptTests: XCTestCase {
    /// Fake encoder: 1 token per character (simple, deterministic for testing).
    private func fakeEncoder(_ text: String) -> [Int] {
        Array(0..<text.count)
    }

    // MARK: - Basic Packing

    func testPackTerms_AllTermsFit() {
        let terms = ["hola", "mundo", "prueba"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Glosario: ",
            budget: 50,
            encode: fakeEncoder
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Glosario: hola, mundo, prueba")
    }

    func testPackTerms_PartialTermsFit() {
        // Budget is tight; only first two terms fit
        let terms = ["abc", "def", "ghijklmnopqrstuvwxyz"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Glosario: ",
            budget: 25,
            encode: fakeEncoder
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Glosario: abc, def")
    }

    // MARK: - Edge Cases: Overflow & Empty

    func testPackTerms_FirstTermOverflows() {
        // Even the first term exceeds budget; should return nil
        let terms = ["verylongword"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Glosario: ",
            budget: 5,
            encode: fakeEncoder
        )
        XCTAssertNil(result)
    }

    func testPackTerms_EmptyTerms() {
        // No terms provided; should return nil
        let result = WhisperTranscriber.packTerms(
            [],
            header: "Glosario: ",
            budget: 100,
            encode: fakeEncoder
        )
        XCTAssertNil(result)
    }

    // MARK: - Language-Aware Headers

    func testPackTerms_EnglishHeader() {
        let terms = ["apple", "banana"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Dictionary: ",
            budget: 50,
            encode: fakeEncoder
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("Dictionary: ") ?? false)
        XCTAssertEqual(result, "Dictionary: apple, banana")
    }

    func testPackTerms_SpanishHeader() {
        let terms = ["manzana", "plátano"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Glosario: ",
            budget: 50,
            encode: fakeEncoder
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("Glosario: ") ?? false)
        XCTAssertEqual(result, "Glosario: manzana, plátano")
    }

    // MARK: - Header Included in Budget

    func testPackTerms_HeaderIncludedInBudget() {
        // Header "Glosario: " is 10 chars. Budget 20 allows header + "abc, def" (9 chars) = 19 total
        let terms = ["abc", "def", "ghijklmnop"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Glosario: ",
            budget: 20,
            encode: fakeEncoder
        )
        // "Glosario: abc, def" = 10 + 9 = 19 chars, which fits
        XCTAssertEqual(result, "Glosario: abc, def")
    }

    func testPackTerms_BudgetTight() {
        // Very tight budget; should pack at least the header + first term if it fits exactly
        let terms = ["hi"]
        let result = WhisperTranscriber.packTerms(
            terms,
            header: "Dictionary: ",
            budget: 14,  // "Dictionary: hi" = 14 chars
            encode: fakeEncoder
        )
        XCTAssertEqual(result, "Dictionary: hi")
    }
}
