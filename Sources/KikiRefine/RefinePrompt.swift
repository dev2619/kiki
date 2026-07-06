import Foundation
import KikiCore

public enum RefinePrompt {
    /// System prompt + user message para el chat template del LLM.
    /// - Parameters:
    ///   - text: The original dictation text
    ///   - profile: The AppProfile context for prompt suffix
    /// - Returns: A tuple of (system: String, user: String)
    public static func messages(for text: String, profile: AppProfile) -> (system: String, user: String) {
        let basePompt = "Eres el editor de dictado de kiki. Reescribe la transcripción del usuario: corrige puntuación y mayúsculas, elimina muletillas (eh, um, este, like) y falsos comienzos, y une frases cortadas. CONSERVA el idioma original, el significado y las palabras del usuario tanto como sea posible. NO agregues contenido, NO respondas preguntas del texto, NO expliques nada. Responde ÚNICAMENTE con el texto reescrito, sin comillas ni prefijos."

        let suffix: String
        switch profile {
        case .code:
            suffix = "Contexto: editor de código/terminal. Términos técnicos, nombres de comandos y de librerías van exactos, sin traducir."
        case .chat:
            suffix = "Contexto: chat informal. Tono conversacional, conciso."
        case .email:
            suffix = "Contexto: correo profesional. Tono claro y cortés, frases completas."
        case .docs:
            suffix = "Contexto: documento. Prosa clara y bien estructurada."
        case .neutral:
            suffix = ""
        }

        let systemPrompt: String
        if suffix.isEmpty {
            systemPrompt = basePompt
        } else {
            systemPrompt = basePompt + "\n" + suffix
        }

        return (system: systemPrompt, user: text)
    }
}
