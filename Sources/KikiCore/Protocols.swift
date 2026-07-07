import Foundation

public enum DictationState: Equatable {
    case idle
    case recording
    case processing
}

public enum DictationError: Error, Equatable {
    case audioUnavailable(String)
    case transcriptionFailed(String)
    case insertionFailed(String)
}

/// Captura de micrófono. `stop()` devuelve las muestras acumuladas
/// en 16 kHz mono Float32.
public protocol AudioRecording: AnyObject {
    func start() throws
    func stop() -> [Float]
}

public protocol Transcribing: AnyObject {
    func transcribe(_ samples: [Float]) async throws -> String
}

public protocol TextInserting: AnyObject {
    func insert(_ text: String) throws
}

@MainActor
public protocol DictationControllerDelegate: AnyObject {
    func dictationStateDidChange(_ state: DictationState)
    func dictationDidFail(_ error: DictationError)
    /// Se dispara justo después de insertar texto con éxito (path de snippet
    /// o de refinado/crudo), en ambos modos (hotkey y manos-libres). Default
    /// vacío vía extensión para no romper conformers/tests existentes que no
    /// lo necesitan.
    func dictationDidInsert()
}

extension DictationControllerDelegate {
    public func dictationDidInsert() {}
}

public enum AppProfile: String, Equatable, CaseIterable {
    case code, chat, email, docs, neutral
}

public protocol ContextProviding: AnyObject {
    func currentProfile() -> AppProfile
}

public protocol Refining: AnyObject {
    /// Devuelve el texto refinado. Lanza si falla; el controller degrada a crudo.
    func refine(_ text: String, profile: AppProfile) async throws -> String
}

public struct HistoryRecord: Equatable {
    public let rawText: String
    public let finalText: String
    public let profile: AppProfile
    public let audioSeconds: Double

    public init(rawText: String, finalText: String, profile: AppProfile, audioSeconds: Double) {
        self.rawText = rawText
        self.finalText = finalText
        self.profile = profile
        self.audioSeconds = audioSeconds
    }
}

public protocol HistoryRecording: AnyObject {
    func record(_ entry: HistoryRecord)
}

public protocol SnippetExpanding: AnyObject {
    /// Devuelve la plantilla si el texto (dictado completo) coincide con un trigger; nil si no.
    func expand(_ text: String) -> String?
}

public protocol DictionaryProviding: AnyObject {
    func terms() -> [String]
}
