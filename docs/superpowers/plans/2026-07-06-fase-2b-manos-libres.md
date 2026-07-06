# kiki Fase 2B — "Manos libres" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activación por voz "escúchame kiki" / "listen to me kiki" (toggle en el menú): VAD por energía segmenta el habla, Whisper verifica la frase, chime + captura hasta silencio de 1.5s, y el dictado fluye por el pipeline existente (refinado + paste). Esc cancela la grabación en ambos modos.

**Architecture (enmienda "híbrido evolutivo", spec §4):** módulo nuevo `KikiWake` — `SpeechSegmenter` (máquina de estados de energía/silencio, pura y testeable) + `WakePhraseMatcher` (matching de texto normalizado, puro) + `WakeListener` (loop de audio continuo con su propio AVAudioEngine, coordinado con el pipeline: se pausa mientras el controller no está idle). `KikiCore` gana `process(samples:)` y `processTranscript(_:)` para entrar al pipeline sin hotkey. openWakeWord queda en backlog detrás del mismo protocolo.

**Tech Stack:** Swift (sin dependencias nuevas), AVAudioEngine, WhisperKit ya residente, XCTest.

## Global Constraints

- Los de Fase 1/2A: 16kHz mono Float32, KikiLog, Conventional Commits sin Co-Authored-By, stage por filename, firma kiki-dev, build vía Makefile/xcodebuild
- Parámetros v1 (constantes con nombre, configurables por init): silencio fin-de-dictado **1.5s**; silencio fin-de-segmento en escucha **0.7s**; habla mínima **0.4s**; segmento máximo en escucha **6s** (más largo = conversación, se descarta sin transcribir); dictado máximo armado **30s**; timeout armado→listening **8s**; umbral RMS de habla **0.02**
- Frases de activación: "escuchame kiki" y "listen to me kiki" (matching normalizado: lowercase, sin acentos, sin puntuación)
- Nada del audio de escucha continua se persiste; solo segmentos en RAM que se descartan al no hacer match
- El toggle "Manos libres" persiste en UserDefaults key `kiki.wakeEnabled` (default **false**)
- Trabajar en rama `feature/fase-2b-manos-libres`

## File Structure

```
Sources/
├── KikiCore/DictationController.swift   — MODIFICAR: extraer pipeline compartido
├── KikiWake/
│   ├── WakePhraseMatcher.swift          — puro: normaliza + match + remainder
│   ├── SpeechSegmenter.swift            — puro: chunks+RMS → eventos de segmento
│   └── WakeListener.swift               — engine continuo + estados + delegate
└── Kiki/
    ├── EscMonitor.swift                 — Esc global durante grabación/captura
    ├── AppDelegate.swift                — MODIFICAR: toggle menú, cableo, pausa
    └── HUDController.swift + HUDView.swift — MODIFICAR: estado "Te escucho…"
Tests/
├── KikiCoreTests/DictationControllerTests.swift  — MODIFICAR: + process/processTranscript
└── KikiWakeTests/
    ├── WakePhraseMatcherTests.swift
    └── SpeechSegmenterTests.swift
```

---

### Task 1: KikiCore — pipeline compartido `process(samples:)` / `processTranscript(_:)` (TDD)

**Files:** Modify `Sources/KikiCore/DictationController.swift`, `Tests/KikiCoreTests/DictationControllerTests.swift`

**Interfaces (Produces):**
```swift
extension DictationController {
    /// Corre transcripción→refinado→inserción sobre muestras ya capturadas
    /// (modo wake). Respeta minimumSamples, estados y degradaciones idénticos
    /// a hotkeyReleased.
    public func process(samples: [Float]) async
    /// Corre refinado→inserción sobre texto ya transcrito (dictado en el
    /// mismo aliento que la frase de activación).
    public func processTranscript(_ text: String) async
}
```

Refactor interno: `hotkeyReleased()` queda como `stop recorder → guard mínimo → process(samples:)`; `process` hace transcribe + `processTranscript`; `processTranscript` hace `.processing` → refineOrFallback → insert → `.idle` con el mismo manejo de errores actual. Guards: ambos métodos solo corren desde `.idle` (o desde el flujo interno de hotkeyReleased); `processTranscript` con texto vacío/whitespace → no-op a `.idle`.

**Tests nuevos (RED primero):** `test_processSamplesRunsFullPipeline` (mismas aserciones que el flujo hotkey: estados [.processing, .idle], texto insertado), `test_processSamplesRespectsMinimumDuration`, `test_processTranscriptRefinesAndInserts`, `test_processTranscriptEmptyIsNoop`, `test_processWhileBusyIsIgnored` (estado .processing simulado → ignora). Los 19 tests existentes siguen verdes sin modificar aserciones (el refactor no cambia comportamiento del flujo hotkey).

Commit: `refactor(core): extract shared dictation pipeline for wake mode`

---

### Task 2: WakePhraseMatcher (TDD, puro)

**Files:** Create `Sources/KikiWake/WakePhraseMatcher.swift`, `Tests/KikiWakeTests/WakePhraseMatcherTests.swift`; Modify `Package.swift` (target KikiWake deps [KikiCore] + testTarget)

**Interfaces (Produces):**
```swift
public struct WakeMatch: Equatable {
    /// Dictado en el mismo aliento tras la frase ("escúchame kiki, escribe X" → "escribe X").
    /// Vacío si solo se dijo la frase.
    public let remainder: String
}
public enum WakePhraseMatcher {
    public static let phrases = ["escuchame kiki", "listen to me kiki"]
    /// nil si el transcript no contiene ninguna frase de activación.
    public static func match(_ transcript: String) -> WakeMatch?
}
```

Implementación: tokenizar el transcript original en palabras; normalizar cada palabra (lowercased + `folding(options: [.diacriticInsensitive])` + strip de puntuación con `CharacterSet.punctuationCharacters`); buscar la secuencia de palabras de cada frase dentro de las palabras normalizadas; `remainder` = palabras ORIGINALES posteriores a la secuencia, unidas con espacio. Si la frase aparece pero no al inicio (hasta 2 palabras de preámbulo tipo "oye" son aceptables → tratar como match), más de 2 palabras antes de la frase → nil (es conversación que menciona a kiki, no un comando).

**Tests:** match exacto ES y EN; con acentos y puntuación ("Escúchame, Kiki."); con remainder ("escúchame kiki escribe hola mundo" → remainder "escribe hola mundo" con las palabras originales); preámbulo corto ("oye escúchame kiki" → match); frase enterrada en conversación ("le estaba diciendo que escúchame kiki no funciona" → nil); sin frase → nil; case-insensitive; transcript vacío → nil.

Commit: `feat(wake): wake phrase matcher with same-breath remainder`

---

### Task 3: SpeechSegmenter (TDD, puro)

**Files:** Create `Sources/KikiWake/SpeechSegmenter.swift`, `Tests/KikiWakeTests/SpeechSegmenterTests.swift`

**Interfaces (Produces):**
```swift
public struct SegmenterConfig: Equatable {
    public let speechRMSThreshold: Float      // 0.02
    public let endSilence: TimeInterval       // configurable: 0.7 escucha / 1.5 dictado
    public let minSpeechDuration: TimeInterval // 0.4
    public let maxSegmentDuration: TimeInterval
    public init(...)  // con defaults
}
public enum SegmenterEvent: Equatable {
    case none
    case speechStarted
    case segmentEnded(samples: [Float])
    case segmentDiscarded(reason: String)   // muy corto o excede máximo
}
public final class SpeechSegmenter {
    public init(config: SegmenterConfig, sampleRate: Double = 16_000)
    /// Alimentar con cada chunk (muestras 16kHz) + su RMS; devuelve el evento.
    public func process(chunk: [Float], rms: Float) -> SegmenterEvent
    public func reset()
}
```

Máquina de estados interna: `silence` ⇄ `speech`. En `speech` acumula muestras (incluye ~0.3s de pre-roll: mantener un ring buffer de los últimos chunks en silencio para no cortar el arranque de la frase). Transición speech→silence cuando el RMS < threshold sostenido `endSilence` segundos → `segmentEnded` si duración de habla ≥ minSpeech, si no `segmentDiscarded("corto")`. Si el segmento supera maxSegmentDuration → `segmentDiscarded("máximo")` y reset a silence (esperar próximo silencio real antes de re-armar: flag `awaitingSilence`).

**Tests (sintéticos, chunks de 1600 muestras = 0.1s con RMS inyectado):** habla de 1s entre silencios → un `segmentEnded` con ~muestras esperadas incluyendo pre-roll; habla de 0.2s → `segmentDiscarded`; habla continua > max → `segmentDiscarded("máximo")` y no re-dispara hasta pasar por silencio; dos utterances separadas → dos eventos; `speechStarted` emitido una vez al inicio; reset() limpia estado.

Commit: `feat(wake): energy-based speech segmenter with pre-roll`

---

### Task 4: WakeListener (integración de escucha continua)

**Files:** Create `Sources/KikiWake/WakeListener.swift`; Modify `Package.swift` si hiciera falta (KikiWake ya depende de KikiCore; agregar AVFoundation no requiere manifest)

**Interfaces (Produces):**
```swift
@MainActor
public protocol WakeListenerDelegate: AnyObject {
    func wakeListenerDidArm()                      // frase detectada → chime + HUD "Te escucho…"
    func wakeListenerDidStartCapture()             // empezó el dictado manos libres
    func wakeListenerDidCapture(samples: [Float])  // dictado terminado (silencio 1.5s)
    func wakeListenerDidCaptureSameBreath(text: String) // remainder en el mismo aliento
    func wakeListenerDidDisarm()                   // timeout sin dictado
}
public final class WakeListener {
    public enum State: Equatable { case stopped, listening, armed }
    public private(set) var state: State
    public weak var delegate: WakeListenerDelegate?
    public init(transcriber: Transcribing)
    public func start() throws    // arranca engine + tap (formato vía AudioResampler)
    public func stop()            // detiene todo, descarta buffers
    public func cancelCapture()   // Esc durante armado/captura → vuelve a listening
}
```

Comportamiento:
- Tap de AVAudioEngine propio (mismo patrón que AudioRecorder: resample a 16k + RMS por chunk) alimenta un `SpeechSegmenter` cuyo `endSilence` depende del estado: 0.7s en `listening`, 1.5s en `armed`.
- `listening` + `segmentEnded` → si duración ≤ 6s: `transcriber.transcribe(samples)` (en Task; serializar — un transcribe a la vez, descartando segmentos que lleguen mientras tanto) → `WakePhraseMatcher.match`:
  - match sin remainder → state `armed`, `wakeListenerDidArm()`, arrancar timeout 8s
  - match con remainder → `wakeListenerDidCaptureSameBreath(text: remainder)` y quedarse en `listening`
  - sin match → descartar muestras
- `armed`: `speechStarted` → `wakeListenerDidStartCapture()` (cancela timeout); `segmentEnded` → `wakeListenerDidCapture(samples:)` → state `listening`. Timeout 8s sin habla → `wakeListenerDidDisarm()` → `listening`.
- Los callbacks del tap llegan en audio thread → los eventos hacia delegate saltan con `Task { @MainActor in ... }`.
- KikiLog en cada transición relevante (frase detectada + transcript del segmento matcheado, armado, captura, descartes con motivo — el contenido de segmentos SIN match NO se loggea: solo "segmento descartado (sin frase, Xs)" para no volcar conversación ajena al log).

Sin test unitario del engine (audio real); la lógica testeable ya quedó en Tasks 2-3. Verificación: `swift test` verde + `swift build`.

Commit: `feat(wake): continuous wake listener with armed capture flow`

---

### Task 5: App — toggle, chime, HUD "Te escucho…", Esc y coordinación

**Files:** Create `Sources/Kiki/EscMonitor.swift`; Modify `Sources/Kiki/AppDelegate.swift`, `Sources/Kiki/HUDController.swift`, `Sources/Kiki/HUDView.swift`; Modify `Package.swift` (Kiki deps += KikiWake)

1. **EscMonitor** (patrón HotkeyMonitor): `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` filtrando `keyCode == 53`; callback `onEscape`. Solo activo con monitor global ya autorizado (Accessibility concedida).
2. **HUD**: `HUDModel` gana `@Published var armed: Bool`; `HUDView` muestra pill "👂 Te escucho…" cuando armed && state == .idle; `HUDController.showArmed(_ on: Bool)`.
3. **AppDelegate**:
   - `private var wakeListener: WakeListener!` (init con `transcriber`), delegate = self.
   - Menú: item toggle "Manos libres: \"escúchame kiki\"" (action toggles, checkmark según UserDefaults `kiki.wakeEnabled`; al activar → `try wakeListener.start()` con alert simple si falla; al desactivar → `stop()`). Al arrancar la app, si el default es true y el modelo Whisper cargó → start (encadenar tras `markReady`).
   - **Coordinación de pausa**: en `dictationStateDidChange`: si state != .idle → `wakeListener.stop()` (si estaba activo); al volver a .idle → `start()` de nuevo si el toggle está on. Evita dos engines simultáneos y re-triggers por el propio audio del sistema.
   - Delegate de WakeListener: `didArm` → `NSSound(named: "Glass")?.play()` + `hud.showArmed(true)`; `didStartCapture` → `hud.showArmed(false)` + `hud.show(state: .recording)`; `didCapture(samples)` → `hud.show(state: .idle)` + `Task { await controller.process(samples: samples) }`; `didCaptureSameBreath(text)` → `Task { await controller.processTranscript(text) }`; `didDisarm` → `hud.showArmed(false)`.
   - **EscMonitor** cableado: `onEscape` → si controller.state == .recording → `controller.cancel()`; además `wakeListener.cancelCapture()`. (Esc en .processing no cancela — documentado.)
   - El ícono del menu bar refleja escucha: `mic.fill` normal / `mic.badge.plus`? — usar `waveform` cuando wake activo (elige un SF Symbol razonable y documenta).

Verificación: `swift test` verde; `make bundle` OK (metallib guard); NO lanzar la app.

Commit: `feat(app): hands-free wake mode with Esc cancel and armed HUD`

---

### Task 6: README + cierre

- README: sección "Manos libres (Fase 2B)": cómo activar el toggle, las dos frases, el flujo (frase → chime → dictar → silencio 1.5s), dictado en el mismo aliento, Esc cancela, nota de privacidad (indicador naranja de micrófono permanente mientras el modo esté activo; audio solo en RAM, segmentos sin frase se descartan y no se loggea su contenido), consumo (Whisper corre solo cuando hay habla cerca; openWakeWord en backlog como optimización), limitación conocida (ambientes muy ruidosos pueden armar falsos segmentos — umbral RMS constante v1).
- Notas de alcance: mover wake word a "hecho (v1 híbrida)"; backlog: openWakeWord, umbral adaptativo, "listo" como palabra de cierre (spec la menciona — NO va en v1, documentar).
- Verificación completa + commit `docs: phase 2B README — hands-free mode` (sin push).

---

## Self-review

- Spec §3 wake phrase ✅ (Tasks 4-5), silencio 1.5s ✅, Esc cancela grabación ✅ (ambos modos, Task 5), toggle en menú + ícono ✅. "decir 'listo' para terminar" → explícitamente diferido (Task 6 lo documenta). Chime ✅. HUD armado ✅.
- Sin placeholders; Tasks 1-3 con código/tests completos; Tasks 4-5 detallados con autoridad de adaptación en APIs de audio.
- Consistencia de firmas: `process(samples:)`/`processTranscript` (Task 1) consumidos en Task 5; `WakeMatch.remainder` (Task 2) → `didCaptureSameBreath(text:)` (Tasks 4-5); `SegmenterEvent` (Task 3) → WakeListener (Task 4).
- Privacidad: transcripts sin match no se loggean (Task 4) — coherente con posicionamiento.
