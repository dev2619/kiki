import AVFoundation
import KikiCore
import Speech

/// Preview en vivo con Apple Speech (`SFSpeechRecognizer`), 100% en el
/// dispositivo. Da el texto "palabra a palabra" mientras el usuario habla, para
/// que la nube muestre lo que dice en TIEMPO REAL. Es DISPLAY-ONLY: el texto que
/// se inserta lo produce el pase final de Whisper (batch, preciso). Así se ve en
/// vivo sin tocar la precisión ni la privacidad (a diferencia del coordinator
/// live de Whisper, que re-transcribía y fallaba la detección de idioma).
///
/// No es `@MainActor`: el callback de `recognitionTask` llega en un hilo
/// arbitrario y `append(_:)` se invoca desde el hilo de audio; el salto a main
/// para `onPartial` se hace explícito aquí.
final class ApplePreviewRecognizer {
    /// Parcial en vivo (en el hilo main). `nil`/"" cuando aún no hay palabras.
    var onPartial: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Pide autorización de reconocimiento de voz (una vez). El preview solo
    /// arranca si queda `authorized`.
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            KikiLog.log("kiki permisos: reconocimiento de voz \(status == .authorized ? "concedido" : "\(status.rawValue)")")
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    /// Arranca una sesión de preview para el `locale` dado. Requiere soporte
    /// on-device (privacidad); si no lo hay, no arranca y el HUD cae a la onda.
    func start(locale: Locale) {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            KikiLog.log("kiki preview: sin autorización — preview en vivo desactivado")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            KikiLog.log("kiki preview: recognizer no disponible para \(locale.identifier)")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            KikiLog.log("kiki preview: on-device no soportado para \(locale.identifier) — preview en vivo omitido")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // 100% local — nunca a la nube
        req.taskHint = .dictation
        self.recognizer = recognizer
        self.request = req
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async { self.onPartial?(text) }
        }
    }

    /// Alimenta un buffer nativo del micrófono (desde el tap del recorder).
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Termina la sesión. Whisper toma el relevo para el pase final.
    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }
}
