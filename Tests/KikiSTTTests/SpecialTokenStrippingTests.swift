import XCTest
@testable import KikiSTT

/// Tests de `WhisperTranscriber.stripSpecialTokens`, que limpia los tokens
/// especiales de Whisper (`<|startoftranscript|>`, `<|es|>`, `<|transcribe|>`,
/// `<|1.48|>`, `<|endoftext|>`…) del texto CRUDO del callback de progreso del
/// streaming (bug de campo 2026-07-17: se colaban en la nube de texto en vivo).
final class SpecialTokenStrippingTests: XCTestCase {
    func testStripsTimestampAndEndToken() {
        XCTAssertEqual(
            WhisperTranscriber.stripSpecialTokens("hoy, bueno<|1.48|><|endoftext|>"),
            "hoy, bueno")
    }

    func testStripsPrefillTokens() {
        XCTAssertEqual(
            WhisperTranscriber.stripSpecialTokens("<|startoftranscript|><|es|><|transcribe|><|0.00|> accedes a un tipo de resultado"),
            "accedes a un tipo de resultado")
    }

    func testStripsTokensInTheMiddle() {
        XCTAssertEqual(
            WhisperTranscriber.stripSpecialTokens("para resumirlo,<|3.70|><|endoftext|>"),
            "para resumirlo,")
    }

    func testLeavesCleanTextUntouched() {
        XCTAssertEqual(
            WhisperTranscriber.stripSpecialTokens("un texto perfectamente normal"),
            "un texto perfectamente normal")
    }

    func testCollapsesDoubleSpacesLeftByRemoval() {
        XCTAssertEqual(
            WhisperTranscriber.stripSpecialTokens("hola <|0.00|> mundo"),
            "hola mundo")
    }
}
