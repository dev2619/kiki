import XCTest
@testable import KikiWake

final class WakePhraseMatcherTests: XCTestCase {

    // MARK: - Exact matches

    func testExactMatchSpanish() {
        let result = WakePhraseMatcher.match("escuchame kiki")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testExactMatchEnglish() {
        let result = WakePhraseMatcher.match("listen to me kiki")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    // MARK: - Accents and punctuation

    func testWithAccentsAndPunctuation() {
        let result = WakePhraseMatcher.match("Escúchame, Kiki.")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testWithMixedAccentsAndPunctuation() {
        let result = WakePhraseMatcher.match("¡Escúchame kiki!")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    // MARK: - Remainder preservation

    func testRemainderWithSpanish() {
        let result = WakePhraseMatcher.match("escuchame kiki escribe hola mundo")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "escribe hola mundo")
    }

    func testRemainderWithEnglish() {
        let result = WakePhraseMatcher.match("listen to me kiki please do something")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "please do something")
    }

    func testRemainderPreservesOriginalCasing() {
        let result = WakePhraseMatcher.match("escuchame kiki DO SOMETHING")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "DO SOMETHING")
    }

    func testRemainderPreservesAccents() {
        let result = WakePhraseMatcher.match("escuchame kiki escribe en español")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "escribe en español")
    }

    // MARK: - Preamble handling (≤2 words tolerated)

    func testShortPreambleOneWord() {
        let result = WakePhraseMatcher.match("hey listen to me kiki")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testShortPreambleTwoWords() {
        let result = WakePhraseMatcher.match("hey there listen to me kiki")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testShortPreambleWithRemainder() {
        let result = WakePhraseMatcher.match("oye escuchame kiki hazlo ahora")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "hazlo ahora")
    }

    // MARK: - Too much preamble (>2 words before phrase)

    func testTooMuchPreamble() {
        let result = WakePhraseMatcher.match("le estaba diciendo que escuchame kiki no funciona")
        XCTAssertNil(result)
    }

    func testThreeWordPreamble() {
        let result = WakePhraseMatcher.match("hey buddy friend escuchame kiki")
        XCTAssertNil(result)
    }

    func testEnglishTooMuchPreamble() {
        let result = WakePhraseMatcher.match("please tell me listen to me kiki")
        XCTAssertNil(result)
    }

    // MARK: - No phrase

    func testNoPhraseInTranscript() {
        let result = WakePhraseMatcher.match("tell me something else")
        XCTAssertNil(result)
    }

    func testEmptyTranscript() {
        let result = WakePhraseMatcher.match("")
        XCTAssertNil(result)
    }

    func testOnlyWhitespace() {
        let result = WakePhraseMatcher.match("   ")
        XCTAssertNil(result)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitiveSpanish() {
        let result = WakePhraseMatcher.match("ESCUCHAME KIKI")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testCaseInsensitiveEnglish() {
        let result = WakePhraseMatcher.match("LISTEN TO ME KIKI")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testMixedCase() {
        let result = WakePhraseMatcher.match("EsCuChAmE kIkI")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    // MARK: - Complex real-world scenarios

    func testWithMultipleSpaces() {
        let result = WakePhraseMatcher.match("escuchame    kiki   write   this")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "write this")
    }

    func testWithTrailingPunctuation() {
        let result = WakePhraseMatcher.match("escuchame kiki, por favor.")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "por favor.")
    }

    func testWithLeadingPunctuation() {
        let result = WakePhraseMatcher.match("(escuchame) kiki")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remainder, "")
    }

    func testPhrasesProperty() {
        XCTAssertEqual(WakePhraseMatcher.phrases.count, 2)
        XCTAssert(WakePhraseMatcher.phrases.contains("escuchame kiki"))
        XCTAssert(WakePhraseMatcher.phrases.contains("listen to me kiki"))
    }

    func testWakeMatchEquatable() {
        let match1 = WakeMatch(remainder: "hello")
        let match2 = WakeMatch(remainder: "hello")
        let match3 = WakeMatch(remainder: "world")

        XCTAssertEqual(match1, match2)
        XCTAssertNotEqual(match1, match3)
    }
}
