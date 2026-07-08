import XCTest
@testable import KikiRefine
import KikiCore

final class RefinePromptTests: XCTestCase {

    // MARK: - Base System Prompt Validation

    func testBasePromptContainsUnicamente() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "System prompt must contain 'ÚNICAMENTE'")
    }

    func testBasePromptForbidsRephrasing() {
        // Fidelidad (bugfix 2026-07-08): la regla central del nuevo prompt.
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("NO reformules"), "System prompt must forbid rephrasing")
        XCTAssertTrue(system.contains("mismo orden"), "System prompt must require preserving word order")
    }

    func testBasePromptContainsCorrectorDeDictado() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("corrector de dictado"), "System prompt must mention 'corrector de dictado'")
    }

    func testBasePromptContainsFidelityExample() {
        // El ejemplo concreto (el caso que falló en campo) es lo que ancla a un
        // modelo pequeño a NO parafrasear.
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("Ejemplo"), "System prompt must include a worked example")
        XCTAssertTrue(system.contains("dame la lista de repositorios"), "Example must use the field failure case")
    }

    // MARK: - User Message

    func testUserMessageIsExactInputText() {
        let inputText = "Este es un texto de prueba, con errores de puntuación"
        let (_, user) = RefinePrompt.messages(for: inputText, profile: .neutral)
        XCTAssertEqual(user, inputText, "User message must be exactly the input text")
    }

    func testUserMessagePreservesWhitespace() {
        let inputText = "Text  with   extra    spaces"
        let (_, user) = RefinePrompt.messages(for: inputText, profile: .neutral)
        XCTAssertEqual(user, inputText, "User message must preserve whitespace exactly")
    }

    // MARK: - Neutral Profile

    func testNeutralProfileHasNoSuffix() {
        let baseText = "test"
        let (system, _) = RefinePrompt.messages(for: baseText, profile: .neutral)

        // Neutral should not contain any of the context suffixes
        XCTAssertFalse(system.contains("editor de código"), "Neutral should not have code context")
        XCTAssertFalse(system.contains("chat informal"), "Neutral should not have chat context")
        XCTAssertFalse(system.contains("correo profesional"), "Neutral should not have email context")
        XCTAssertFalse(system.contains("documento"), "Neutral should not have docs context")
    }

    // MARK: - Code Profile

    func testCodeProfileHasCodeSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .code)
        XCTAssertTrue(system.contains("editor de código"), "Code profile must contain code context")
        XCTAssertTrue(system.contains("terminal"), "Code profile must mention terminal")
        XCTAssertTrue(system.contains("términos técnicos"), "Code profile must mention technical terms")
        XCTAssertTrue(system.contains("nombres de comandos"), "Code profile must mention command names")
        XCTAssertTrue(system.contains("de librerías"), "Code profile must mention library names")
    }

    func testCodeProfileIncludesBaseSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .code)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Code profile must include base rules")
        XCTAssertTrue(system.contains("NO reformules"), "Code profile must include base fidelity rules")
    }

    // MARK: - Non-code profiles (fidelity: no tone suffix)
    //
    // Fidelidad (bugfix 2026-07-08): chat/email/docs ya NO agregan sufijo de
    // tono — "adaptar el tono" empujaba al modelo a parafrasear. Solo `code`
    // conserva un hint (y acotado a NO alterar términos técnicos). Los demás
    // perfiles se comportan como neutral: solo las reglas de limpieza base.

    func testChatProfileHasNoToneSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .chat)
        XCTAssertFalse(system.contains("chat informal"), "Chat profile must not add a tone suffix anymore")
        XCTAssertFalse(system.contains("conversacional"), "Chat profile must not steer tone (invites paraphrasing)")
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Chat profile must still include base rules")
    }

    func testEmailProfileHasNoToneSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .email)
        XCTAssertFalse(system.contains("correo profesional"), "Email profile must not add a tone suffix anymore")
        XCTAssertFalse(system.contains("cortés"), "Email profile must not steer tone (invites paraphrasing)")
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Email profile must still include base rules")
    }

    func testDocsProfileHasNoToneSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .docs)
        XCTAssertFalse(system.contains("Prosa"), "Docs profile must not add a tone suffix anymore")
        XCTAssertFalse(system.contains("bien estructurada"), "Docs profile must not steer structure (invites paraphrasing)")
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Docs profile must still include base rules")
    }

    // MARK: - System Prompt Structure

    func testSystemPromptFollowsExpectedStructure() {
        let baseText = "test text"
        let (system, _) = RefinePrompt.messages(for: baseText, profile: .code)

        // Should start with the main instruction
        XCTAssertTrue(system.contains("corrector de dictado"), "Should contain main instruction")

        // Should contain all base rules
        XCTAssertTrue(system.contains("puntuación"), "Should contain punctuation rule")
        XCTAssertTrue(system.contains("mayúsculas"), "Should contain capitalization rule")
        XCTAssertTrue(system.contains("muletillas"), "Should contain filler removal rule")
        XCTAssertTrue(system.contains("falsos comienzos"), "Should contain false start rule")
    }

    func testSystemPromptContainsRestrictions() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)

        XCTAssertTrue(system.contains("NO resumas"), "Should forbid summarizing")
        XCTAssertTrue(system.contains("NO reordenes"), "Should forbid reordering")
        XCTAssertTrue(system.contains("NO respondas preguntas"), "Should contain no answer rule")
        XCTAssertTrue(system.contains("NO inventes"), "Should forbid inventing headings/colons")
    }

    func testSystemPromptContainsMetaUtteranceRule() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(
            system.contains("SIEMPRE es una transcripción"),
            "System prompt must instruct the model that the user message is always dictation to clean, never a question/instruction to the model")
    }

    // MARK: - All Profiles Coverage

    func testAllProfilesReturnValidMessages() {
        let testText = "some dictation text here"

        for profile in AppProfile.allCases {
            let (system, user) = RefinePrompt.messages(for: testText, profile: profile)

            XCTAssertFalse(system.isEmpty, "System prompt for \(profile) should not be empty")
            XCTAssertEqual(user, testText, "User message for \(profile) should match input")
            XCTAssertTrue(system.contains("corrector de dictado"), "\(profile) should contain main instruction")
        }
    }

    // MARK: - Empty and Edge Cases

    func testEmptyTextUserMessage() {
        let (_, user) = RefinePrompt.messages(for: "", profile: .neutral)
        XCTAssertEqual(user, "", "Should handle empty text")
    }

    func testLongText() {
        let longText = String(repeating: "a", count: 5000)
        let (_, user) = RefinePrompt.messages(for: longText, profile: .neutral)
        XCTAssertEqual(user, longText, "Should handle long text")
    }

    func testSpecialCharacters() {
        let specialText = "¡Hola! ¿Cómo estás? Esperando... «esto»"
        let (_, user) = RefinePrompt.messages(for: specialText, profile: .neutral)
        XCTAssertEqual(user, specialText, "Should preserve special Spanish characters")
    }

    // MARK: - Dictionary Terms (Phase 3, Task 3)

    func testDictionaryTermsAppearInSystemPrompt() {
        let (system, _) = RefinePrompt.messages(
            for: "test", profile: .neutral, dictionaryTerms: ["Kubernetes", "Terraform"])
        XCTAssertTrue(
            system.contains("Términos del usuario (respeta su escritura exacta): Kubernetes, Terraform"),
            "System prompt must include the dictionary terms line")
    }

    func testEmptyDictionaryTermsOmitsLine() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral, dictionaryTerms: [])
        XCTAssertFalse(
            system.contains("Términos del usuario"),
            "System prompt must not include the dictionary terms line when empty")
    }

    func testDefaultDictionaryTermsIsEmpty() {
        // No dictionaryTerms argument at all — existing call sites must keep compiling and behaving.
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertFalse(
            system.contains("Términos del usuario"),
            "Default call (no dictionaryTerms arg) must not include the dictionary terms line")
    }

    func testDictionaryTermsDoesNotAffectUserMessage() {
        let inputText = "dictation text"
        let (_, user) = RefinePrompt.messages(for: inputText, profile: .neutral, dictionaryTerms: ["term1"])
        XCTAssertEqual(user, inputText, "Dictionary terms must not alter the user message")
    }

    func testDictionaryTermsAppendedAlongsideProfileSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .code, dictionaryTerms: ["Docker"])
        XCTAssertTrue(system.contains("editor de código"), "Code suffix must still be present")
        XCTAssertTrue(
            system.contains("Términos del usuario (respeta su escritura exacta): Docker"),
            "Dictionary line must be present alongside the profile suffix")
    }

    // MARK: - Language Pin (fidelity fix)
    //
    // Field evidence: Whisper correctly detected English ("Are you understand
    // my English or not?") but the refiner only got a Spanish "keep the
    // original language" instruction, which Qwen 3B did not honor — it
    // mistranslated to "¿Estás entendido mi inglés?" and sometimes
    // hallucinated content. The fix hard-pins the output language explicitly
    // instead of relying on the generic "preserve language" rule alone.

    func testDefaultLanguageIsSpanish() {
        let withDefault = RefinePrompt.messages(for: "test", profile: .neutral)
        let withExplicitEs = RefinePrompt.messages(for: "test", profile: .neutral, language: "es")
        XCTAssertEqual(withDefault.system, withExplicitEs.system, "Omitting language must behave exactly like language: \"es\" — preserves existing call sites")
    }

    func testSpanishLanguagePinsOutputToSpanish() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral, language: "es")
        XCTAssertTrue(
            system.contains("SIEMPRE en español"),
            "Spanish system prompt must hard-pin the output language")
        XCTAssertTrue(
            system.contains("NUNCA traduzcas"),
            "Spanish system prompt must explicitly forbid translating")
    }

    func testEnglishLanguagePinsOutputToEnglish() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral, language: "en")
        XCTAssertTrue(
            system.contains("ALWAYS in English"),
            "English system prompt must hard-pin the output language")
        XCTAssertTrue(
            system.contains("NEVER translate"),
            "English system prompt must explicitly forbid translating")
    }

    func testEnglishLanguageWritesWholePromptInEnglish() {
        // A small model drifts less from the target output language when the
        // whole instruction is already in that language, not just the pin.
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral, language: "en")
        XCTAssertTrue(system.contains("dictation corrector"), "English prompt must be written in English, not just append an English pin to the Spanish prompt")
        XCTAssertFalse(system.contains("corrector de dictado"), "English prompt must not contain the Spanish base instruction")
    }

    func testEnglishCodeSuffixIsInEnglish() {
        let (codeSystem, _) = RefinePrompt.messages(for: "test", profile: .code, language: "en")
        XCTAssertTrue(codeSystem.contains("code editor/terminal"))
        XCTAssertFalse(codeSystem.contains("editor de código"))
    }

    func testEnglishDictionaryTermsUseEnglishHeader() {
        let (system, _) = RefinePrompt.messages(
            for: "test", profile: .neutral, dictionaryTerms: ["Kubernetes"], language: "en")
        XCTAssertTrue(system.contains("User terms (respect their exact spelling): Kubernetes"))
    }

    func testUnknownLanguageFallsBackToSpanish() {
        // Any value other than "en" is treated as Spanish — matches
        // WhisperTranscriber's own `detected == "en" ? "en" : "es"` policy.
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral, language: "fr")
        XCTAssertTrue(system.contains("SIEMPRE en español"))
    }

    // MARK: - Translate Mode (opt-in feature)

    func testTranslateSpanishToEnglish() {
        let (system, _) = RefinePrompt.messages(for: "hola", profile: .neutral, language: "es", translate: true)
        XCTAssertTrue(system.contains("Traduce el texto al inglés"), "Detected Spanish + translate ON must target English")
        XCTAssertTrue(system.contains("Responde ÚNICAMENTE con la traducción"))
    }

    func testTranslateEnglishToSpanish() {
        let (system, _) = RefinePrompt.messages(for: "hello", profile: .neutral, language: "en", translate: true)
        XCTAssertTrue(system.contains("Traduce el texto al español"), "Detected English + translate ON must target Spanish")
        XCTAssertTrue(system.contains("Responde ÚNICAMENTE con la traducción"))
    }

    func testTranslateModeDoesNotIncludeRefineRules() {
        // Translate is a distinct mode, not refine-plus-pin: the cleanup
        // rules/meta-utterance guard from the refine prompt should not leak in.
        let (system, _) = RefinePrompt.messages(for: "hola", profile: .neutral, language: "es", translate: true)
        XCTAssertFalse(system.contains("corrector de dictado"))
        XCTAssertFalse(system.contains("NUNCA traduzcas"), "Translate mode must not carry the 'never translate' refine pin")
    }

    func testTranslateModeIncludesDictionaryTerms() {
        let (system, _) = RefinePrompt.messages(
            for: "hola", profile: .neutral, dictionaryTerms: ["Kubernetes"], language: "es", translate: true)
        XCTAssertTrue(system.contains("Términos del usuario (respeta su escritura exacta): Kubernetes"))
    }

    func testTranslateDefaultIsOff() {
        // Omitting `translate` must behave exactly like translate: false.
        let withDefault = RefinePrompt.messages(for: "test", profile: .neutral, language: "en")
        let withExplicitFalse = RefinePrompt.messages(for: "test", profile: .neutral, language: "en", translate: false)
        XCTAssertEqual(withDefault.system, withExplicitFalse.system)
    }

    func testTranslateUserMessageIsExactInputText() {
        let (_, user) = RefinePrompt.messages(for: "hola mundo", profile: .neutral, language: "es", translate: true)
        XCTAssertEqual(user, "hola mundo", "Translate mode must not alter the user message either")
    }
}
