# kiki Fase 1 — "Loop mágico" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App de menu bar para macOS: mantienes Fn presionada, hablas, sueltas — WhisperKit transcribe local y el texto se pega donde esté el cursor, con HUD flotante de estados.

**Architecture:** Paquete SPM con librerías por módulo (KikiCore = máquina de estados con protocolos inyectables; KikiAudio, KikiSTT, KikiInsert = adaptadores concretos) + un executable target `Kiki` (AppKit/SwiftUI) que los cablea. El `.app` bundle se ensambla con Makefile + firma ad-hoc (no hay Xcode full ni certificados en la máquina — solo Command Line Tools).

**Tech Stack:** Swift 5.10 language mode (compilador 6.2 vía CLT), SPM, AVFoundation, AppKit + SwiftUI (HUD), WhisperKit (STT local, CoreML), XCTest.

## Global Constraints

- macOS deployment target: **14.0** (spec: "macOS 14+, Apple Silicon")
- Swift tools version del manifest: **5.10** (mantiene language mode v5; evita fricción de strict concurrency de Swift 6 con AppKit)
- Dependencia única de terceros: `https://github.com/argmaxinc/WhisperKit.git`, `from: "0.9.0"`
- Modelo STT preferido: `"large-v3_turbo"` con fallback al recomendado del device (`WhisperKit()` sin config)
- Bundle ID: `com.dev2619.kiki` — Ejecutable: `Kiki` — Nombre app: `kiki`
- Sample rate interno: **16 kHz mono Float32** en todo el pipeline
- Duración mínima de dictado: **0.3 s** (menos = tap accidental, se cancela)
- Git: stage por filename (nunca `git add -A`), Conventional Commits, **sin** trailer `Co-Authored-By`
- Todo error se loggea local con `NSLog`; cero telemetría
- Build sin Xcode: solo `swift build` / `swift test` / Makefile (**no** usar `xcodebuild`)

## Development caveats (leer antes de empezar)

1. **Firma ad-hoc y permisos TCC:** el bundle se firma con `-` (ad-hoc). El permiso de **Micrófono** persiste por bundle ID entre rebuilds. El permiso de **Accesibilidad** puede requerir re-toggle (off→on en System Settings → Privacy & Security → Accessibility) después de cada rebuild porque la firma ad-hoc no tiene identidad estable. Es fricción esperada de desarrollo; se resuelve en Fase 4 con certificado.
2. **Tecla Fn/🌐:** para que el hold de Fn no dispare el picker de emoji ni el dictado nativo de macOS, en el Mac de prueba: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.
3. **Primer arranque lento:** WhisperKit descarga el modelo (~600 MB+) y CoreML lo compila la primera vez. El menu bar icon aparece atenuado hasta que el modelo está listo.

## File Structure

```
kiki/
├── Package.swift
├── Makefile
├── .gitignore
├── App/
│   └── Info.plist                          — LSUIElement, mic usage description
├── Sources/
│   ├── KikiCore/
│   │   ├── Protocols.swift                 — DictationState/Error, AudioRecording, Transcribing, TextInserting, delegate
│   │   └── DictationController.swift       — máquina de estados idle→recording→processing→idle
│   ├── KikiAudio/
│   │   ├── AudioResampler.swift            — cualquier formato → 16kHz mono Float32 + RMS
│   │   └── AudioRecorder.swift             — AVAudioEngine tap, conforma AudioRecording
│   ├── KikiInsert/
│   │   ├── ClipboardManager.swift          — snapshot/restore del pasteboard
│   │   └── PasteInserter.swift             — Cmd+V sintético, conforma TextInserting
│   ├── KikiSTT/
│   │   └── WhisperTranscriber.swift        — wrapper WhisperKit, conforma Transcribing
│   └── Kiki/                               — executable target (app)
│       ├── main.swift
│       ├── AppDelegate.swift
│       ├── HotkeyMonitor.swift             — Fn (keyCode 63) global monitor
│       ├── Permissions.swift               — mic + accessibility preflight
│       ├── HUDController.swift             — NSPanel flotante no-activante
│       └── HUDView.swift                   — SwiftUI: estados escuchando/procesando
└── Tests/
    ├── KikiCoreTests/DictationControllerTests.swift
    ├── KikiAudioTests/AudioResamplerTests.swift
    ├── KikiInsertTests/ClipboardManagerTests.swift
    └── KikiSTTTests/WhisperTranscriberIntegrationTests.swift   — gated por env var
```

---

### Task 1: Scaffold del paquete SPM

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/KikiCore/Protocols.swift` (placeholder mínimo compilable, se completa en Task 2)
- Create: `Sources/KikiAudio/AudioResampler.swift` (placeholder)
- Create: `Sources/KikiInsert/ClipboardManager.swift` (placeholder)
- Create: `Sources/KikiSTT/WhisperTranscriber.swift` (placeholder)
- Create: `Sources/Kiki/main.swift` (placeholder)

**Interfaces:**
- Produces: paquete `kiki` que compila con `swift build`; targets `KikiCore`, `KikiAudio`, `KikiInsert`, `KikiSTT`, executable `Kiki`.

- [ ] **Step 1: Crear Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "kiki",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(name: "KikiCore"),
        .target(name: "KikiAudio", dependencies: ["KikiCore"]),
        .target(name: "KikiInsert", dependencies: ["KikiCore"]),
        .target(
            name: "KikiSTT",
            dependencies: [
                "KikiCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Kiki",
            dependencies: ["KikiCore", "KikiAudio", "KikiInsert", "KikiSTT"]
        ),
        .testTarget(name: "KikiCoreTests", dependencies: ["KikiCore"]),
        .testTarget(name: "KikiAudioTests", dependencies: ["KikiAudio"]),
        .testTarget(name: "KikiInsertTests", dependencies: ["KikiInsert"]),
        .testTarget(
            name: "KikiSTTTests",
            dependencies: ["KikiSTT", "KikiAudio"]
        ),
    ]
)
```

- [ ] **Step 2: Crear .gitignore**

```gitignore
.build/
build/
.swiftpm/
*.xcodeproj
.DS_Store
```

- [ ] **Step 3: Crear placeholders compilables**

`Sources/KikiCore/Protocols.swift`:
```swift
// Placeholder — se completa en Task 2.
```

`Sources/KikiAudio/AudioResampler.swift`:
```swift
import KikiCore
// Placeholder — se completa en Task 3.
```

`Sources/KikiInsert/ClipboardManager.swift`:
```swift
import KikiCore
// Placeholder — se completa en Task 4.
```

`Sources/KikiSTT/WhisperTranscriber.swift`:
```swift
import KikiCore
import WhisperKit
// Placeholder — se completa en Task 5.
```

`Sources/Kiki/main.swift`:
```swift
print("kiki placeholder")
```

- [ ] **Step 4: Verificar que compila (descarga WhisperKit la primera vez, tarda unos minutos)**

Run: `cd ~/kiki && swift build`
Expected: `Build complete!` (warnings de WhisperKit son aceptables)

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources/KikiCore/Protocols.swift Sources/KikiAudio/AudioResampler.swift Sources/KikiInsert/ClipboardManager.swift Sources/KikiSTT/WhisperTranscriber.swift Sources/Kiki/main.swift
git commit -m "chore: SPM scaffold with module targets and WhisperKit dependency"
```

---

### Task 2: KikiCore — protocolos y máquina de estados (TDD)

**Files:**
- Modify: `Sources/KikiCore/Protocols.swift`
- Create: `Sources/KikiCore/DictationController.swift`
- Test: `Tests/KikiCoreTests/DictationControllerTests.swift`

**Interfaces:**
- Produces (los demás tasks consumen esto — firmas exactas):
  - `public enum DictationState: Equatable { case idle, recording, processing }`
  - `public enum DictationError: Error, Equatable { case audioUnavailable(String), transcriptionFailed(String), insertionFailed(String) }`
  - `public protocol AudioRecording: AnyObject { func start() throws; func stop() -> [Float] }`
  - `public protocol Transcribing: AnyObject { func transcribe(_ samples: [Float]) async throws -> String }`
  - `public protocol TextInserting: AnyObject { func insert(_ text: String) throws }`
  - `public protocol DictationControllerDelegate: AnyObject { func dictationStateDidChange(_ state: DictationState); func dictationDidFail(_ error: DictationError) }`
  - `@MainActor public final class DictationController` con `init(recorder:transcriber:inserter:minimumDuration:sampleRate:)`, `func hotkeyPressed()`, `func hotkeyReleased() async`, `func cancel()`, `var state`, `weak var delegate`

- [ ] **Step 1: Escribir los tests que fallan**

`Tests/KikiCoreTests/DictationControllerTests.swift`:
```swift
import XCTest
@testable import KikiCore

// MARK: - Mocks

final class MockRecorder: AudioRecording {
    var started = false
    var stopCalled = false
    var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000) // 1 s
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() -> [Float] {
        stopCalled = true
        return samplesToReturn
    }
}

final class MockTranscriber: Transcribing {
    var textToReturn = "hello world"
    var errorToThrow: Error?
    var receivedSamples: [Float] = []

    func transcribe(_ samples: [Float]) async throws -> String {
        receivedSamples = samples
        if let errorToThrow { throw errorToThrow }
        return textToReturn
    }
}

final class MockInserter: TextInserting {
    var inserted: [String] = []
    var errorToThrow: Error?

    func insert(_ text: String) throws {
        if let errorToThrow { throw errorToThrow }
        inserted.append(text)
    }
}

final class SpyDelegate: DictationControllerDelegate {
    var states: [DictationState] = []
    var errors: [DictationError] = []

    func dictationStateDidChange(_ state: DictationState) { states.append(state) }
    func dictationDidFail(_ error: DictationError) { errors.append(error) }
}

// MARK: - Tests

@MainActor
final class DictationControllerTests: XCTestCase {
    private var recorder: MockRecorder!
    private var transcriber: MockTranscriber!
    private var inserter: MockInserter!
    private var delegate: SpyDelegate!
    private var controller: DictationController!

    override func setUp() async throws {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        delegate = SpyDelegate()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter)
        controller.delegate = delegate
    }

    func test_pressStartsRecording() {
        controller.hotkeyPressed()
        XCTAssertTrue(recorder.started)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(delegate.states, [.recording])
    }

    func test_releaseTranscribesInsertsAndReturnsToIdle() async {
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.states, [.recording, .processing, .idle])
        XCTAssertEqual(transcriber.receivedSamples.count, 16_000)
    }

    func test_shortTapIsCancelledWithoutTranscribing() async {
        recorder.samplesToReturn = Array(repeating: 0.1, count: 1_000) // < 0.3 s * 16 kHz
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_emptyTranscriptionInsertsNothing() async {
        transcriber.textToReturn = "  \n "
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func test_transcriptionResultIsTrimmed() async {
        transcriber.textToReturn = "  hola mundo \n"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func test_recorderStartFailureReportsErrorAndStaysIdle() {
        recorder.startError = NSError(domain: "test", code: 1)
        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors.count, 1)
        guard case .audioUnavailable = delegate.errors.first else {
            return XCTFail("expected .audioUnavailable, got \(String(describing: delegate.errors.first))")
        }
    }

    func test_transcriberErrorReturnsToIdleAndReports() async {
        transcriber.errorToThrow = NSError(domain: "test", code: 2)
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors.count, 1)
        guard case .transcriptionFailed = delegate.errors.first else {
            return XCTFail("expected .transcriptionFailed, got \(String(describing: delegate.errors.first))")
        }
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func test_inserterErrorReturnsToIdleAndReports() async {
        inserter.errorToThrow = DictationError.insertionFailed("no pudo pegar")
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors, [.insertionFailed("no pudo pegar")])
    }

    func test_pressWhileRecordingIsIgnored() {
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        XCTAssertEqual(delegate.states, [.recording])
    }

    func test_releaseWhileIdleIsIgnored() async {
        await controller.hotkeyReleased()
        XCTAssertFalse(recorder.stopCalled)
        XCTAssertTrue(delegate.states.isEmpty)
    }

    func test_cancelWhileRecordingReturnsToIdleWithoutInserting() {
        controller.hotkeyPressed()
        controller.cancel()
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }
}
```

- [ ] **Step 2: Reemplazar el placeholder de Protocols.swift**

`Sources/KikiCore/Protocols.swift`:
```swift
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
```

- [ ] **Step 3: Correr tests para verificar que fallan por compilación**

Run: `swift test --filter DictationControllerTests 2>&1 | tail -5`
Expected: error de compilación — `DictationController` no existe todavía.

- [ ] **Step 4: Implementar DictationController**

`Sources/KikiCore/DictationController.swift`:
```swift
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
```

- [ ] **Step 5: Correr tests para verificar que pasan**

Run: `swift test --filter DictationControllerTests 2>&1 | tail -5`
Expected: `Executed 11 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Sources/KikiCore/Protocols.swift Sources/KikiCore/DictationController.swift Tests/KikiCoreTests/DictationControllerTests.swift
git commit -m "feat(core): dictation state machine with injectable collaborators"
```

---

### Task 3: KikiAudio — resampler (TDD) + AudioRecorder

**Files:**
- Modify: `Sources/KikiAudio/AudioResampler.swift`
- Create: `Sources/KikiAudio/AudioRecorder.swift`
- Test: `Tests/KikiAudioTests/AudioResamplerTests.swift`

**Interfaces:**
- Consumes: `AudioRecording` de KikiCore.
- Produces:
  - `public enum AudioResampler { static let targetFormat: AVAudioFormat; static func resampleTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float]; static func rms(_ samples: [Float]) -> Float }`
  - `public final class AudioRecorder: AudioRecording` con `init()`, `var onLevel: ((Float) -> Void)?`

- [ ] **Step 1: Escribir los tests que fallan**

`Tests/KikiAudioTests/AudioResamplerTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import KikiAudio

final class AudioResamplerTests: XCTestCase {
    /// Buffer estéreo 48 kHz con una senoidal de 440 Hz en ambos canales.
    private func makeStereo48kBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = sinf(2 * .pi * 440 * Float(frame) / 48_000)
            data[0][frame] = value
            data[1][frame] = value
        }
        return buffer
    }

    func test_resamples48kStereoTo16kMono() {
        let buffer = makeStereo48kBuffer(frames: 4_800) // 0.1 s
        let samples = AudioResampler.resampleTo16kMono(buffer)
        // 0.1 s a 16 kHz ≈ 1600 muestras (tolerancia por primado del converter)
        XCTAssertGreaterThan(samples.count, 1_400)
        XCTAssertLessThanOrEqual(samples.count, 1_700)
    }

    func test_resampledSignalKeepsEnergy() {
        let buffer = makeStereo48kBuffer(frames: 4_800)
        let samples = AudioResampler.resampleTo16kMono(buffer)
        // La senoidal de amplitud 1.0 tiene RMS ≈ 0.707; tras resamplear debe conservarse aproximadamente.
        let rms = AudioResampler.rms(samples)
        XCTAssertGreaterThan(rms, 0.5)
        XCTAssertLessThan(rms, 0.9)
    }

    func test_passthroughWhenAlready16kMono() {
        let format = AudioResampler.targetFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for frame in 0..<1_600 { buffer.floatChannelData![0][frame] = 0.25 }
        let samples = AudioResampler.resampleTo16kMono(buffer)
        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.001)
    }

    func test_rmsOfSilenceIsZero() {
        XCTAssertEqual(AudioResampler.rms(Array(repeating: 0, count: 100)), 0, accuracy: 0.0001)
    }

    func test_rmsOfEmptyIsZero() {
        XCTAssertEqual(AudioResampler.rms([]), 0)
    }
}
```

- [ ] **Step 2: Correr tests para verificar que fallan**

Run: `swift test --filter AudioResamplerTests 2>&1 | tail -5`
Expected: error de compilación — `AudioResampler` no tiene miembros aún.

- [ ] **Step 3: Implementar AudioResampler**

`Sources/KikiAudio/AudioResampler.swift` (reemplaza el placeholder):
```swift
import AVFoundation

/// Conversión de buffers PCM de cualquier formato al formato canónico
/// del pipeline: 16 kHz, mono, Float32 no intercalado.
public enum AudioResampler {
    public static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public static func resampleTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format == targetFormat {
            return samples(from: buffer)
        }
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return []
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return []
        }
        var inputConsumed = false
        converter.convert(to: output, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return samples(from: output)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrtf(sumOfSquares / Float(samples.count))
    }

    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
```

- [ ] **Step 4: Correr tests para verificar que pasan**

Run: `swift test --filter AudioResamplerTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Implementar AudioRecorder (sin test unitario — requiere micrófono real; se valida en el checklist E2E de Task 8)**

`Sources/KikiAudio/AudioRecorder.swift`:
```swift
import AVFoundation
import KikiCore

/// Captura del micrófono por defecto con AVAudioEngine.
/// Acumula muestras ya convertidas a 16 kHz mono Float32.
public final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private let collectQueue = DispatchQueue(label: "com.dev2619.kiki.audio-collect")
    private var collected: [Float] = []

    /// Nivel RMS por chunk, para animar el HUD. Se invoca en un hilo de audio.
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public func start() throws {
        collectQueue.sync { collected = [] }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = AudioResampler.resampleTo16kMono(buffer)
            self.collectQueue.async { self.collected.append(contentsOf: chunk) }
            self.onLevel?(AudioResampler.rms(chunk))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return collectQueue.sync { collected }
    }
}
```

- [ ] **Step 6: Verificar que todo el paquete compila y los tests siguen verdes**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: `Build complete!` y 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/KikiAudio/AudioResampler.swift Sources/KikiAudio/AudioRecorder.swift Tests/KikiAudioTests/AudioResamplerTests.swift
git commit -m "feat(audio): 16kHz mono resampler with RMS + AVAudioEngine recorder"
```

---

### Task 4: KikiInsert — clipboard snapshot/restore (TDD) + paste sintético

**Files:**
- Modify: `Sources/KikiInsert/ClipboardManager.swift`
- Create: `Sources/KikiInsert/PasteInserter.swift`
- Test: `Tests/KikiInsertTests/ClipboardManagerTests.swift`

**Interfaces:**
- Consumes: `TextInserting`, `DictationError` de KikiCore.
- Produces:
  - `public struct ClipboardSnapshot`
  - `public enum ClipboardManager { static func snapshot(of:) -> ClipboardSnapshot; static func restore(_:to:); static func setString(_:on:) }`
  - `public final class PasteInserter: TextInserting` con `init(pasteboard:restoreDelay:)` (defaults `.general`, `0.4`)

- [ ] **Step 1: Escribir los tests que fallan**

`Tests/KikiInsertTests/ClipboardManagerTests.swift`:
```swift
import XCTest
import AppKit
@testable import KikiInsert

final class ClipboardManagerTests: XCTestCase {
    // Pasteboard con nombre propio: los tests NO tocan el clipboard real del usuario.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.dev2619.kiki.tests"))
        pasteboard.clearContents()
    }

    func test_snapshotAndRestoreString() {
        ClipboardManager.setString("contenido original", on: pasteboard)
        let snapshot = ClipboardManager.snapshot(of: pasteboard)

        ClipboardManager.setString("texto dictado", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")

        ClipboardManager.restore(snapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "contenido original")
    }

    func test_restoreEmptySnapshotLeavesPasteboardEmpty() {
        let emptySnapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString("algo", on: pasteboard)
        ClipboardManager.restore(emptySnapshot, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func test_snapshotPreservesMultipleTypes() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("texto plano", forType: .string)
        item.setData(Data([0x01, 0x02]), forType: NSPasteboard.PasteboardType("com.dev2619.kiki.custom"))
        pasteboard.writeObjects([item])

        let snapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString("sobrescrito", on: pasteboard)
        ClipboardManager.restore(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "texto plano")
        XCTAssertEqual(
            pasteboard.data(forType: NSPasteboard.PasteboardType("com.dev2619.kiki.custom")),
            Data([0x01, 0x02]))
    }

    func test_setStringReplacesContents() {
        ClipboardManager.setString("uno", on: pasteboard)
        ClipboardManager.setString("dos", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "dos")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }
}
```

- [ ] **Step 2: Correr tests para verificar que fallan**

Run: `swift test --filter ClipboardManagerTests 2>&1 | tail -5`
Expected: error de compilación — `ClipboardManager` no tiene miembros aún.

- [ ] **Step 3: Implementar ClipboardManager**

`Sources/KikiInsert/ClipboardManager.swift` (reemplaza el placeholder):
```swift
import AppKit

/// Copia inmutable del contenido del pasteboard, para restaurar
/// el clipboard del usuario después de pegar el dictado.
public struct ClipboardSnapshot {
    public let items: [[NSPasteboard.PasteboardType: Data]]
}

public enum ClipboardManager {
    public static func snapshot(of pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { entry, type in
                if let data = item.data(forType: type) { entry[type] = data }
            }
        }
        return ClipboardSnapshot(items: items)
    }

    public static func restore(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    public static func setString(_ string: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
```

- [ ] **Step 4: Correr tests para verificar que pasan**

Run: `swift test --filter ClipboardManagerTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Implementar PasteInserter (el CGEvent en sí se valida manualmente en Task 8 — requiere permiso de Accesibilidad)**

`Sources/KikiInsert/PasteInserter.swift`:
```swift
import AppKit
import KikiCore

/// Inserta texto en la app activa: pone el texto en el clipboard,
/// sintetiza Cmd+V y restaura el clipboard original tras un delay.
public final class PasteInserter: TextInserting {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval

    public init(pasteboard: NSPasteboard = .general, restoreDelay: TimeInterval = 0.4) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
    }

    public func insert(_ text: String) throws {
        let snapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString(text, on: pasteboard)
        do {
            try synthesizeCmdV()
        } catch {
            // Falló el paste: dejamos el texto en el clipboard (spec §7)
            // para que el usuario pueda pegarlo a mano. No restauramos.
            throw error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
            ClipboardManager.restore(snapshot, to: pasteboard)
        }
    }

    private func synthesizeCmdV() throws {
        let vKeyCode: CGKeyCode = 9
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            throw DictationError.insertionFailed("no se pudo crear el CGEvent de Cmd+V")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 6: Verificar build + tests verdes**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: `Build complete!` y 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/KikiInsert/ClipboardManager.swift Sources/KikiInsert/PasteInserter.swift Tests/KikiInsertTests/ClipboardManagerTests.swift
git commit -m "feat(insert): clipboard-preserving paste via synthetic Cmd+V"
```

---

### Task 5: KikiSTT — wrapper de WhisperKit + test de integración gated

**Files:**
- Modify: `Sources/KikiSTT/WhisperTranscriber.swift`
- Test: `Tests/KikiSTTTests/WhisperTranscriberIntegrationTests.swift`

**Interfaces:**
- Consumes: `Transcribing`, `DictationError` de KikiCore; `AudioResampler` de KikiAudio (solo en el test).
- Produces: `public final class WhisperTranscriber: Transcribing` con `init()`, `func prepare() async throws`, `var isReady: Bool`.

- [ ] **Step 1: Implementar WhisperTranscriber**

`Sources/KikiSTT/WhisperTranscriber.swift` (reemplaza el placeholder):
```swift
import Foundation
import KikiCore
import WhisperKit

/// Transcripción local con WhisperKit (CoreML). El modelo se descarga
/// de Hugging Face en el primer arranque y queda cacheado en disco.
public final class WhisperTranscriber: Transcribing {
    public static let preferredModel = "large-v3_turbo"

    private var whisperKit: WhisperKit?
    public private(set) var isReady = false

    public init() {}

    /// Carga (y si hace falta descarga) el modelo. Llamar una vez al arrancar.
    public func prepare() async throws {
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: Self.preferredModel))
            NSLog("kiki stt: modelo cargado (\(Self.preferredModel))")
        } catch {
            NSLog("kiki stt: \(Self.preferredModel) no disponible (\(error)); usando modelo recomendado")
            whisperKit = try await WhisperKit()
        }
        isReady = true
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let whisperKit else {
            throw DictationError.transcriptionFailed("el modelo todavía no está cargado")
        }
        var options = DecodingOptions()
        options.task = .transcribe
        options.detectLanguage = true // ES/EN auto (spec §6)
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
```

- [ ] **Step 2: Verificar que compila**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Si la API de WhisperKit difiere (nombres de `WhisperKitConfig`, `DecodingOptions` o `transcribe(audioArray:decodeOptions:)`), consultar la versión resuelta en `Package.resolved` y el README de https://github.com/argmaxinc/WhisperKit para esa versión, y ajustar solo las llamadas — la interfaz pública de `WhisperTranscriber` no cambia.

- [ ] **Step 3: Escribir el test de integración (gated — descarga el modelo, tarda minutos la primera vez)**

`Tests/KikiSTTTests/WhisperTranscriberIntegrationTests.swift`:
```swift
import XCTest
import AVFoundation
import KikiAudio
@testable import KikiSTT

/// Test de integración real (modelo Whisper + audio sintetizado con `say`).
/// Se corre solo con: KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests
final class WhisperTranscriberIntegrationTests: XCTestCase {
    func test_transcribesSynthesizedEnglishSpeech() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_STT_TEST"] == "1",
            "gated: exportar KIKI_STT_TEST=1 (descarga el modelo, ~600MB+)")

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-stt-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Sintetizar voz con el TTS del sistema, directo a WAV 16 kHz Float32.
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", wavURL.path,
            "--data-format=LEF32@16000",
            "hello world this is a dictation test",
        ]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say falló")

        let samples = try loadSamples(url: wavURL)
        XCTAssertGreaterThan(samples.count, 16_000, "el fixture debe durar más de 1 s")

        let transcriber = WhisperTranscriber()
        try await transcriber.prepare()
        XCTAssertTrue(transcriber.isReady)

        let text = try await transcriber.transcribe(samples)
        let normalized = text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") && normalized.contains("test"),
            "transcripción inesperada: '\(text)'")
    }

    private func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw NSError(domain: "fixture", code: 1)
        }
        try file.read(into: buffer)
        return AudioResampler.resampleTo16kMono(buffer)
    }
}
```

- [ ] **Step 4: Verificar que el test queda skipped por defecto**

Run: `swift test --filter WhisperTranscriberIntegrationTests 2>&1 | tail -3`
Expected: `Executed 1 test, with 1 test skipped`

- [ ] **Step 5: Correr el test de integración real (una vez; descarga el modelo)**

Run: `KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests 2>&1 | tail -5`
Expected: `Executed 1 test, with 0 failures` (puede tardar varios minutos la primera vez por la descarga + compilación CoreML)

- [ ] **Step 6: Commit**

```bash
git add Sources/KikiSTT/WhisperTranscriber.swift Tests/KikiSTTTests/WhisperTranscriberIntegrationTests.swift
git commit -m "feat(stt): WhisperKit transcriber with gated integration test"
```

---

### Task 6: App target — menu bar, permisos, Info.plist y bundle

**Files:**
- Modify: `Sources/Kiki/main.swift`
- Create: `Sources/Kiki/AppDelegate.swift`
- Create: `Sources/Kiki/Permissions.swift`
- Create: `App/Info.plist`
- Create: `Makefile`

**Interfaces:**
- Consumes: `DictationController`, `AudioRecorder`, `WhisperTranscriber`, `PasteInserter`.
- Produces: `kiki.app` ensamblable con `make bundle`; `AppDelegate` con propiedad `controller: DictationController` que Task 7 y 8 extienden.

- [ ] **Step 1: Reemplazar main.swift**

`Sources/Kiki/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar app, sin Dock
app.run()
```

- [ ] **Step 2: Crear Permissions.swift**

`Sources/Kiki/Permissions.swift`:
```swift
import AVFoundation
import ApplicationServices

enum Permissions {
    /// Dispara el prompt de micrófono en el primer arranque.
    static func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("kiki permisos: micrófono \(granted ? "concedido" : "denegado")")
        }
    }

    /// Muestra el prompt del sistema para Accesibilidad si no está concedido.
    /// Necesario para el monitor global de Fn y el Cmd+V sintético.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("kiki permisos: accesibilidad \(trusted ? "concedida" : "pendiente")")
        return trusted
    }
}
```

- [ ] **Step 3: Crear AppDelegate.swift (sin hotkey ni HUD todavía — llegan en Tasks 7-8)**

`Sources/Kiki/AppDelegate.swift`:
```swift
import AppKit
import KikiAudio
import KikiCore
import KikiInsert
import KikiSTT

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private(set) var controller: DictationController!
    let recorder = AudioRecorder()
    let transcriber = WhisperTranscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestMicrophoneAccess()
        Permissions.ensureAccessibility()

        controller = DictationController(
            recorder: recorder,
            transcriber: transcriber,
            inserter: PasteInserter())
        controller.delegate = self

        setUpStatusItem()
        loadModelInBackground()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "mic.fill", accessibilityDescription: "kiki")
        statusItem.button?.appearsDisabled = true // hasta que cargue el modelo

        let menu = NSMenu()
        let status = NSMenuItem(title: "Cargando modelo…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 1
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Salir de kiki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func loadModelInBackground() {
        Task {
            do {
                try await self.transcriber.prepare()
                await MainActor.run { self.markReady() }
            } catch {
                NSLog("kiki: error cargando modelo: \(error)")
                await MainActor.run {
                    self.statusItem.menu?.item(withTag: 1)?.title = "Error cargando modelo"
                }
            }
        }
    }

    private func markReady() {
        statusItem.button?.appearsDisabled = false
        statusItem.menu?.item(withTag: 1)?.title = "Listo — mantén Fn para dictar"
    }
}

extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        NSLog("kiki estado: \(state)")
    }

    func dictationDidFail(_ error: DictationError) {
        NSLog("kiki error: \(String(describing: error))")
    }
}
```

- [ ] **Step 4: Crear App/Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>kiki</string>
    <key>CFBundleDisplayName</key>
    <string>kiki</string>
    <key>CFBundleIdentifier</key>
    <string>com.dev2619.kiki</string>
    <key>CFBundleExecutable</key>
    <string>Kiki</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>kiki usa el micrófono para transcribir tu dictado. Todo el procesamiento es 100% local: tu voz nunca sale de este Mac.</string>
</dict>
</plist>
```

- [ ] **Step 5: Crear Makefile**

Importante: las líneas de receta van con TAB, no espacios.

```make
APP := build/kiki.app
BIN := .build/release/Kiki
SIGN_ID ?= -

.PHONY: build test bundle run clean

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp $(BIN) $(APP)/Contents/MacOS/Kiki
	# Bundles de recursos de dependencias SPM (si existen)
	-cp -R .build/release/*.bundle $(APP)/Contents/Resources/ 2>/dev/null
	codesign --force --sign "$(SIGN_ID)" $(APP)
	@echo "OK → $(APP)"

run: bundle
	open $(APP)

clean:
	rm -rf .build build
```

- [ ] **Step 6: Build, bundle y smoke test manual**

Run: `make bundle`
Expected: `OK → build/kiki.app` sin errores de codesign.

Run: `make run`
Expected (verificación manual):
1. Aparece el ícono de micrófono en la barra de menú (atenuado mientras carga el modelo).
2. Primer arranque: prompt de micrófono (aceptar) y prompt de Accesibilidad (abrir System Settings y activar kiki).
3. Al terminar la carga del modelo, el ícono se ve normal y el menú dice "Listo — mantén Fn para dictar".
4. "Salir de kiki" termina la app.

Ver logs en vivo: `log stream --predicate 'process == "Kiki"' --style compact`

- [ ] **Step 7: Commit**

```bash
git add Sources/Kiki/main.swift Sources/Kiki/AppDelegate.swift Sources/Kiki/Permissions.swift App/Info.plist Makefile
git commit -m "feat(app): menu bar app with permissions preflight and model loading"
```

---

### Task 7: HotkeyMonitor — Fn global press/release

**Files:**
- Create: `Sources/Kiki/HotkeyMonitor.swift`
- Modify: `Sources/Kiki/AppDelegate.swift`

**Interfaces:**
- Consumes: `controller.hotkeyPressed()` / `controller.hotkeyReleased()` de Task 6.
- Produces: `final class HotkeyMonitor` con `init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void)`, `func start()`, `func stop()`.

- [ ] **Step 1: Crear HotkeyMonitor.swift**

`Sources/Kiki/HotkeyMonitor.swift`:
```swift
import AppKit

/// Observa la tecla Fn (🌐, keyCode 63) globalmente vía NSEvent flagsChanged.
/// Requiere que la app esté autorizada en Accesibilidad.
final class HotkeyMonitor {
    static let fnKeyCode: UInt16 = 63

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var monitor: Any?
    private var isDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let pressed = event.modifierFlags.contains(.function)
        if pressed && !isDown {
            isDown = true
            onPress()
        } else if !pressed && isDown {
            isDown = false
            onRelease()
        }
    }
}
```

- [ ] **Step 2: Cablear el monitor en AppDelegate**

En `Sources/Kiki/AppDelegate.swift`, agregar la propiedad (junto a `transcriber`):
```swift
    private var hotkey: HotkeyMonitor!
```

Y al final de `applicationDidFinishLaunching`, después de `loadModelInBackground()`:
```swift
        hotkey = HotkeyMonitor(
            onPress: { [weak self] in
                Task { @MainActor in self?.controller.hotkeyPressed() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in await self?.controller.hotkeyReleased() }
            })
        hotkey.start()
```

- [ ] **Step 3: Verificación manual del hotkey**

Run: `make run` y luego `log stream --predicate 'process == "Kiki"' --style compact`

Checklist (con Accesibilidad ya concedida — si se re-buildeó, re-toggle en System Settings):
1. Con otra app en primer plano, mantener Fn ≥1 s: el log muestra `kiki estado: recording`.
2. Soltar Fn: log muestra `kiki estado: processing` y luego `kiki estado: idle`.
3. Tap corto de Fn (<0.3 s): vuelve a `idle` sin `processing`.

- [ ] **Step 4: Commit**

```bash
git add Sources/Kiki/HotkeyMonitor.swift Sources/Kiki/AppDelegate.swift
git commit -m "feat(app): global Fn hold-to-talk hotkey monitor"
```

---

### Task 8: HUD flotante + cableo final y E2E manual

**Files:**
- Create: `Sources/Kiki/HUDView.swift`
- Create: `Sources/Kiki/HUDController.swift`
- Modify: `Sources/Kiki/AppDelegate.swift`

**Interfaces:**
- Consumes: `DictationState` de KikiCore; `recorder.onLevel` de KikiAudio.
- Produces: `@MainActor final class HUDController` con `init()`, `func show(state: DictationState)`, `func updateLevel(_ level: Float)`.

- [ ] **Step 1: Crear HUDView.swift**

`Sources/Kiki/HUDView.swift`:
```swift
import SwiftUI
import KikiCore

final class HUDModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(1 + CGFloat(min(model.level * 8, 1.5)))
                    .animation(.easeOut(duration: 0.1), value: model.level)
                Text("Escuchando…")
            case .processing:
                ProgressView()
                    .controlSize(.small)
                Text("Procesando…")
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Crear HUDController.swift**

`Sources/Kiki/HUDController.swift`:
```swift
import AppKit
import SwiftUI
import KikiCore

/// Panel flotante tipo pill, centrado abajo, que nunca roba el foco
/// de la app donde el usuario está dictando.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private let model = HUDModel()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(state: DictationState) {
        model.state = state
        switch state {
        case .idle:
            panel.orderOut(nil)
        case .recording, .processing:
            positionAtBottomCenter()
            panel.orderFrontRegardless()
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 24))
    }
}
```

- [ ] **Step 3: Cablear HUD en AppDelegate**

En `Sources/Kiki/AppDelegate.swift`:

Agregar propiedad (junto a `hotkey`):
```swift
    private var hud: HUDController!
```

En `applicationDidFinishLaunching`, después de crear `controller` y antes de `setUpStatusItem()`:
```swift
        hud = HUDController()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.updateLevel(level) }
        }
```

Y reemplazar la extensión delegate para que use el HUD:
```swift
extension AppDelegate: DictationControllerDelegate {
    func dictationStateDidChange(_ state: DictationState) {
        NSLog("kiki estado: \(state)")
        hud.show(state: state)
    }

    func dictationDidFail(_ error: DictationError) {
        NSLog("kiki error: \(String(describing: error))")
        hud.show(state: .idle)
    }
}
```

- [ ] **Step 4: Build + tests completos**

Run: `swift test 2>&1 | tail -3 && make bundle`
Expected: 0 failures, `OK → build/kiki.app`

- [ ] **Step 5: Checklist E2E manual (el criterio de éxito de la Fase 1)**

Preparación: `make run`, re-conceder Accesibilidad si hace falta, esperar "Listo" en el menú. Verificar System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing**.

1. Abrir Notas (o TextEdit), poner el cursor en un documento.
2. Mantener Fn → aparece el HUD pill abajo con "Escuchando…" y el punto rojo pulsa al hablar.
3. Decir: "hola, esto es una prueba de dictado con kiki" → soltar Fn.
4. HUD pasa a "Procesando…" y en <3 s el texto aparece donde estaba el cursor.
5. Verificar clipboard preservado: copiar "AAA" antes de dictar; después del dictado, Cmd+V pega "AAA" de nuevo.
6. Repetir dictado en otra app (Slack, navegador, VS Code) — funciona igual.
7. Dictar en inglés: "this is an English test" — transcribe correctamente (auto-detect).
8. Tap corto de Fn sin hablar → el HUD aparece y desaparece, no se pega nada.
9. Dictar sin conexión a internet (WiFi off, modelo ya descargado) → funciona igual (todo local).

- [ ] **Step 6: Commit**

```bash
git add Sources/Kiki/HUDView.swift Sources/Kiki/HUDController.swift Sources/Kiki/AppDelegate.swift
git commit -m "feat(app): floating HUD with recording level and processing states"
```

---

### Task 9: README + cierre de fase

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: documentación de build/run para cualquier colaborador (o subagente) futuro.

- [ ] **Step 1: Crear README.md**

```markdown
# kiki

Dictado por voz con IA, **100% local**, para macOS. Mantén **Fn**, habla, suelta — el texto aparece donde esté tu cursor, en cualquier app. Tu voz nunca sale de tu Mac.

> Fase actual: **1 — loop mágico** (hotkey + Whisper local + paste).
> Spec completo: [`docs/superpowers/specs/2026-07-06-kiki-design.md`](docs/superpowers/specs/2026-07-06-kiki-design.md)

## Requisitos

- macOS 14+ · Apple Silicon
- Command Line Tools de Xcode (`xcode-select --install`) — no requiere Xcode completo
- ~1 GB de disco para el modelo Whisper (se descarga en el primer arranque)

## Build & run

```bash
make test     # unit tests
make bundle   # ensambla build/kiki.app (firma ad-hoc)
make run      # abre la app
```

Test de integración STT (descarga el modelo):

```bash
KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests
```

## Permisos (primer arranque)

1. **Micrófono** — prompt automático.
2. **Accesibilidad** — System Settings → Privacy & Security → Accessibility → activar kiki. Necesario para la tecla Fn global y para pegar el texto.

> Nota dev: con firma ad-hoc, tras cada rebuild puede hacer falta re-toggle del permiso de Accesibilidad.
> Recomendado: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Arquitectura

Módulos SPM: `KikiCore` (máquina de estados) · `KikiAudio` (mic → 16 kHz mono) · `KikiSTT` (WhisperKit) · `KikiInsert` (paste preservando clipboard) · `Kiki` (menu bar app, hotkey, HUD).
```

- [ ] **Step 2: Verificación final completa**

Run: `swift test 2>&1 | tail -3 && make bundle`
Expected: 0 failures, bundle OK.

- [ ] **Step 3: Commit y push**

```bash
git add README.md
git commit -m "docs: build, permissions and architecture README"
git push origin main
```

---

## Self-review (hecho al escribir el plan)

- **Cobertura del spec (Fase 1):** hotkey hold-to-talk ✅ (Task 7), grabación 16 kHz ✅ (Task 3), Whisper local ES/EN auto ✅ (Task 5), paste con clipboard preservado ✅ (Task 4), HUD estados ✅ (Task 8), degradación de errores a idle + log ✅ (Task 2), latencia <2-3 s se valida en E2E (Task 8). Fuera de alcance Fase 1 (por spec): LLM, wake word, diccionario, snippets, settings, historial.
- **Placeholders:** los únicos "placeholder" son archivos de Task 1 que tasks posteriores reemplazan con código completo incluido en este plan.
- **Consistencia de tipos:** firmas de `AudioRecording`/`Transcribing`/`TextInserting` idénticas en Tasks 2-8; `HUDController.show(state:)`/`updateLevel(_:)` coinciden entre Task 8 steps; `controller`/`recorder`/`transcriber` expuestos en Task 6 y consumidos en 7-8.
