import Foundation

/// Máquina de estados del loop de dictado: idle → recording → processing → idle.
/// Los colaboradores se inyectan por protocolo para poder testear con mocks.
@MainActor
public final class DictationController {
    public private(set) var state: DictationState = .idle
    public weak var delegate: DictationControllerDelegate?

    private let recorder: AudioRecording
    private let transcriber: Transcribing
    private let inserter: TextInserting
    private let minimumSamples: Int

    public init(
        recorder: AudioRecording,
        transcriber: Transcribing,
        inserter: TextInserting,
        minimumDuration: TimeInterval = 0.3,
        sampleRate: Double = 16_000
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.inserter = inserter
        self.minimumSamples = Int(minimumDuration * sampleRate)
    }

    public func hotkeyPressed() {
        guard state == .idle else { return }
        do {
            try recorder.start()
            transition(to: .recording)
        } catch {
            delegate?.dictationDidFail(.audioUnavailable(String(describing: error)))
        }
    }

    public func hotkeyReleased() async {
        guard state == .recording else { return }
        let samples = recorder.stop()
        guard samples.count >= minimumSamples else {
            transition(to: .idle) // tap accidental
            return
        }
        transition(to: .processing)
        do {
            let text = try await transcriber.transcribe(samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try inserter.insert(trimmed)
            }
            transition(to: .idle)
        } catch let error as DictationError {
            transition(to: .idle)
            delegate?.dictationDidFail(error)
        } catch {
            transition(to: .idle)
            delegate?.dictationDidFail(.transcriptionFailed(String(describing: error)))
        }
    }

    public func cancel() {
        guard state == .recording else { return }
        _ = recorder.stop()
        transition(to: .idle)
    }

    private func transition(to newState: DictationState) {
        state = newState
        delegate?.dictationStateDidChange(newState)
    }
}
