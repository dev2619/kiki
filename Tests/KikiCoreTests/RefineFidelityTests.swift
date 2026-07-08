import XCTest
@testable import KikiCore

final class RefineFidelityTests: XCTestCase {

    // MARK: - Faithful cleanups pass

    func testIdenticalTextIsFaithful() {
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "Dame la lista de repositorios",
            refined: "Dame la lista de repositorios"))
    }

    func testFillerRemovalIsFaithful() {
        // Limpieza legítima: solo se borran palabras, no se agrega vocabulario.
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "eh dame la lista de repositorios o sea los automatizados",
            refined: "Dame la lista de repositorios, los automatizados."))
    }

    func testPunctuationAndCaseChangesAreFaithful() {
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "necesito que revises el pipeline de ci",
            refined: "Necesito que revises el pipeline de CI."))
    }

    func testDroppingWordsWithoutAddingIsStillFaithful() {
        // El modo de fallo por SOLO borrar (sin vocabulario nuevo) NO lo cubre
        // esta guardia léxica — es responsabilidad del prompt. Documentado:
        // aquí la novelty es 0, así que pasa. La red de seguridad ataca el
        // fallo dañino (introducir palabras nuevas).
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "Dame la lista de repositorios ya automatizados",
            refined: "Lista de repositorios automatizados"))
    }

    // MARK: - Paraphrase / hallucination with new vocabulary fails

    func testAnsweringTheQuestionIsUnfaithful() {
        // El refinador respondió el dictado en vez de limpiarlo: vocabulario
        // completamente nuevo.
        XCTAssertFalse(RefineFidelity.isFaithful(
            original: "qué hora es",
            refined: "Son las tres de la tarde"))
    }

    func testHeavyParaphraseWithNewWordsIsUnfaithful() {
        XCTAssertFalse(RefineFidelity.isFaithful(
            original: "prueba de dictado con kiki",
            refined: "A continuación presento una demostración del sistema de reconocimiento"))
    }

    // MARK: - Dictionary terms are allowed extra vocabulary

    func testDictionaryTermCorrectionIsFaithful() {
        // Whisper escribió "cubernetes"; el diccionario tiene "Kubernetes".
        // Corregir a la escritura del diccionario no debe contar como infiel.
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "despliega en cubernetes",
            refined: "Despliega en Kubernetes.",
            allowedExtraTerms: ["Kubernetes"]))
    }

    // MARK: - Edge cases

    func testEmptyRefinedIsFaithful() {
        // La guardia de vacío vive en DictationController; aquí no objetamos.
        XCTAssertTrue(RefineFidelity.isFaithful(original: "hola", refined: ""))
    }

    func testAccentAndCaseInsensitiveMatching() {
        // "Automatizados" (mayúscula) y "automatizados" cuentan igual; los
        // acentos se pliegan.
        XCTAssertTrue(RefineFidelity.isFaithful(
            original: "revisa la configuración automática",
            refined: "Revisa la configuracion automatica."))
    }

    func testTokenizeStripsPunctuation() {
        XCTAssertEqual(
            RefineFidelity.tokenize("Hola, ¿cómo estás? ¡Bien!"),
            ["hola", "como", "estas", "bien"])
    }
}
