import XCTest
@testable import KikiSTT

/// Tests de la función pura `WhisperTranscriber.isLikelyHallucination`, que
/// implementa la gate de rechazo de alucinaciones de silencio/ruido de
/// Whisper (bug de campo 2026-07-06: ~1.2s de silencio ambiente → "Thank
/// you." / "Gracias." pegado sin que el usuario dijera nada).
final class HallucinationDetectionTests: XCTestCase {
    // MARK: - Confidence gate (primary)

    func testFieldCase_ThankYouOnSilence_IsRejected() {
        // Caso de campo real: ~1.2s de silencio, Whisper alucina "Thank you."
        // con noSpeechProb alto.
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "Thank you.",
                noSpeechProb: 0.8,
                avgLogProb: -0.3,
                audioSeconds: 1.2
            )
        )
    }

    func testRealSpeech_LowNoSpeechProb_LongAudio_IsNotRejected() {
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "Hola quiero que me ayudes",
                noSpeechProb: 0.1,
                avgLogProb: -0.3,
                audioSeconds: 5.0
            )
        )
    }

    func testVeryLowAvgLogProb_AloneTriggersRejection() {
        // avgLogprob muy negativo por sí solo (sin noSpeechProb alto) también
        // debe disparar la gate: es la otra señal de baja confianza.
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "algo que no tiene sentido",
                noSpeechProb: 0.05,
                avgLogProb: -1.5,
                audioSeconds: 3.0
            )
        )
    }

    func testHighConfidence_NormalSpeech_IsNotRejected() {
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "recuérdame comprar leche mañana por la mañana",
                noSpeechProb: 0.02,
                avgLogProb: -0.15,
                audioSeconds: 4.0
            )
        )
    }

    // MARK: - Confidence gate boundaries

    func testNoSpeechProb_ExactlyAtThreshold_IsRejected() {
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "algo",
                noSpeechProb: WhisperTranscriber.noSpeechProbThreshold,
                avgLogProb: 0.0,
                audioSeconds: 3.0
            )
        )
    }

    func testNoSpeechProb_JustBelowThreshold_DoesNotTriggerConfidenceGate() {
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "una frase normal y suficientemente larga",
                noSpeechProb: WhisperTranscriber.noSpeechProbThreshold - 0.01,
                avgLogProb: 0.0,
                audioSeconds: 3.0
            )
        )
    }

    func testAvgLogProb_ExactlyAtThreshold_IsRejected() {
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "algo",
                noSpeechProb: 0.0,
                avgLogProb: WhisperTranscriber.avgLogProbThreshold,
                audioSeconds: 3.0
            )
        )
    }

    func testAvgLogProb_JustAboveThreshold_DoesNotTriggerConfidenceGate() {
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "una frase normal y suficientemente larga",
                noSpeechProb: 0.0,
                avgLogProb: WhisperTranscriber.avgLogProbThreshold + 0.01,
                audioSeconds: 3.0
            )
        )
    }

    // MARK: - Denylist gate (secondary defense-in-depth)

    func testGracias_ShortTextShortAudio_BorderlineConfidence_IsRejected() {
        // "gracias" (7 chars) sobre 1s de audio, confianza NO extrema (no
        // dispara la gate primaria por sí sola) — debe caer en la denylist.
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "gracias",
                noSpeechProb: 0.4,
                avgLogProb: -0.5,
                audioSeconds: 1.0
            )
        )
    }

    func testGracias_InsideLongHighConfidenceDictation_IsNotRejected() {
        let longText = String(
            repeating: "esto es una prueba de dictado largo con contenido real, ",
            count: 4
        ) + "y al final digo gracias por escuchar todo esto"
        XCTAssertGreaterThan(longText.count, 20)
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: longText,
                noSpeechProb: 0.02,
                avgLogProb: -0.1,
                audioSeconds: 12.0
            )
        )
    }

    func testDenylistPhrase_ShortTextButLongAudio_IsNotRejected() {
        // Audio largo (>2s) desactiva la denylist aunque el texto final sea
        // corto y coincida textualmente — evita descartar un "gracias" real
        // dicho tras una pausa larga.
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "gracias",
                noSpeechProb: 0.3,
                avgLogProb: -0.5,
                audioSeconds: 2.5
            )
        )
    }

    func testDenylistPhrase_ShortAudioButLongText_IsNotRejected() {
        // No debería ocurrir en la práctica (texto largo en audio corto),
        // pero la gate de longitud de texto debe respetarse igual.
        let text = "esto no es una frase de la denylist en absoluto"
        XCTAssertGreaterThan(text.count, WhisperTranscriber.hallucinationTextLengthThreshold)
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: text,
                noSpeechProb: 0.3,
                avgLogProb: -0.5,
                audioSeconds: 1.0
            )
        )
    }

    func testNonDenylistedShortPhrase_ShortAudio_BorderlineConfidence_IsNotRejected() {
        // Frase corta y audio corto, pero NO está en la denylist ni dispara
        // la gate de confianza: debe sobrevivir (evita falsos positivos).
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "hola Juan",
                noSpeechProb: 0.3,
                avgLogProb: -0.5,
                audioSeconds: 1.0
            )
        )
    }

    func testDenylistPhrase_CaseAndPunctuationNormalized() {
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "Gracias.",
                noSpeechProb: 0.4,
                avgLogProb: -0.5,
                audioSeconds: 1.0
            )
        )
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "  THANK YOU  ",
                noSpeechProb: 0.4,
                avgLogProb: -0.5,
                audioSeconds: 1.0
            )
        )
    }

    // MARK: - Denylist gate boundaries

    func testAudioSeconds_ExactlyAtThreshold_DenylistStillApplies() {
        XCTAssertTrue(
            WhisperTranscriber.isLikelyHallucination(
                text: "gracias",
                noSpeechProb: 0.4,
                avgLogProb: -0.5,
                audioSeconds: WhisperTranscriber.hallucinationAudioSecondsThreshold
            )
        )
    }

    func testAudioSeconds_JustAboveThreshold_DenylistDoesNotApply() {
        XCTAssertFalse(
            WhisperTranscriber.isLikelyHallucination(
                text: "gracias",
                noSpeechProb: 0.4,
                avgLogProb: -0.5,
                audioSeconds: WhisperTranscriber.hallucinationAudioSecondsThreshold + 0.01
            )
        )
    }
}
