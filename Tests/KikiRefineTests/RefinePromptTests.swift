import XCTest
@testable import KikiRefine
import KikiCore

final class RefinePromptTests: XCTestCase {

    // MARK: - Base System Prompt Validation

    func testBasePromptContainsUnicamente() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "System prompt must contain 'ÚNICAMENTE'")
    }

    func testBasePromptContainsIdiomaOriginal() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("idioma original"), "System prompt must contain 'idioma original'")
    }

    func testBasePromptContainsEditorDeDictado() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(system.contains("editor de dictado"), "System prompt must mention 'editor de dictado'")
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
        XCTAssertTrue(system.contains("Términos técnicos"), "Code profile must mention technical terms")
        XCTAssertTrue(system.contains("nombres de comandos"), "Code profile must mention command names")
        XCTAssertTrue(system.contains("de librerías"), "Code profile must mention library names")
    }

    func testCodeProfileIncludesBaseSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .code)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Code profile must include base rules")
        XCTAssertTrue(system.contains("idioma original"), "Code profile must include base rules")
    }

    // MARK: - Chat Profile

    func testChatProfileHasChatSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .chat)
        XCTAssertTrue(system.contains("chat informal"), "Chat profile must contain chat context")
        XCTAssertTrue(system.contains("Tono conversacional"), "Chat profile must mention conversational tone")
        XCTAssertTrue(system.contains("conciso"), "Chat profile must mention conciseness")
    }

    func testChatProfileIncludesBaseSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .chat)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Chat profile must include base rules")
        XCTAssertTrue(system.contains("idioma original"), "Chat profile must include base rules")
    }

    // MARK: - Email Profile

    func testEmailProfileHasEmailSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .email)
        XCTAssertTrue(system.contains("correo profesional"), "Email profile must contain email context")
        XCTAssertTrue(system.contains("Tono claro"), "Email profile must mention clear tone")
        XCTAssertTrue(system.contains("cortés"), "Email profile must mention courtesy")
        XCTAssertTrue(system.contains("frases completas"), "Email profile must mention complete sentences")
    }

    func testEmailProfileIncludesBaseSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .email)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Email profile must include base rules")
        XCTAssertTrue(system.contains("idioma original"), "Email profile must include base rules")
    }

    // MARK: - Docs Profile

    func testDocsProfileHasDocsSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .docs)
        XCTAssertTrue(system.contains("documento"), "Docs profile must contain document context")
        XCTAssertTrue(system.contains("Prosa clara"), "Docs profile must mention clear prose")
        XCTAssertTrue(system.contains("bien estructurada"), "Docs profile must mention well-structured")
    }

    func testDocsProfileIncludesBaseSuffix() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .docs)
        XCTAssertTrue(system.contains("ÚNICAMENTE"), "Docs profile must include base rules")
        XCTAssertTrue(system.contains("idioma original"), "Docs profile must include base rules")
    }

    // MARK: - System Prompt Structure

    func testSystemPromptFollowsExpectedStructure() {
        let baseText = "test text"
        let (system, _) = RefinePrompt.messages(for: baseText, profile: .code)

        // Should start with the main instruction
        XCTAssertTrue(system.contains("editor de dictado"), "Should contain main instruction")

        // Should contain all base rules
        XCTAssertTrue(system.contains("corrige puntuación"), "Should contain punctuation rule")
        XCTAssertTrue(system.contains("mayúsculas"), "Should contain capitalization rule")
        XCTAssertTrue(system.contains("muletillas"), "Should contain filler removal rule")
        XCTAssertTrue(system.contains("falsos comienzos"), "Should contain false start rule")
        XCTAssertTrue(system.contains("une frases cortadas"), "Should contain phrase joining rule")
    }

    func testSystemPromptContainsRestrictions() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)

        XCTAssertTrue(system.contains("NO agregues contenido"), "Should contain no addition rule")
        XCTAssertTrue(system.contains("NO respondas preguntas"), "Should contain no answer rule")
        XCTAssertTrue(system.contains("NO expliques"), "Should contain no explanation rule")
    }

    func testSystemPromptContainsMetaUtteranceRule() {
        let (system, _) = RefinePrompt.messages(for: "test", profile: .neutral)
        XCTAssertTrue(
            system.contains("SIEMPRE una transcripción"),
            "System prompt must instruct the model that the user message is always dictation to rewrite, never a question/instruction to the model")
    }

    // MARK: - All Profiles Coverage

    func testAllProfilesReturnValidMessages() {
        let testText = "some dictation text here"

        for profile in AppProfile.allCases {
            let (system, user) = RefinePrompt.messages(for: testText, profile: profile)

            XCTAssertFalse(system.isEmpty, "System prompt for \(profile) should not be empty")
            XCTAssertEqual(user, testText, "User message for \(profile) should match input")
            XCTAssertTrue(system.contains("editor de dictado"), "\(profile) should contain main instruction")
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
}
