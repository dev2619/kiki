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

public protocol DictationControllerDelegate: AnyObject {
    func dictationStateDidChange(_ state: DictationState)
    func dictationDidFail(_ error: DictationError)
}
