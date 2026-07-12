# F1 — Transcripción live con burbuja Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mientras dictas (Fn o manos libres), una burbuja muestra el texto en tiempo casi-real; al terminar se inserta el texto final al instante (sin LLM en modo live), y queda en el clipboard (F2).

**Architecture:** Re-transcripción chunked sobre el pipeline propio — descartado `AudioStreamTranscriber` de WhisperKit porque posee su propio micrófono (`startRecordingLive` sobre su `AudioProcessing`; verificado en el checkout, sin API para alimentar samples externos). En su lugar: `AudioRecorder` gana `onChunk`; un `LiveTranscriptionCoordinator` (KikiCore, TDD con transcriber mockeado) acumula samples y dispara pases de re-transcripción (~1/s, nunca solapados — el actor de Whisper ya serializa) publicando parciales; al stop hace el pass final del buffer completo (autoritativo — cubre la cola de audio posterior al último tick). `DictationController` gana modo live (closure `liveEnabled`, patrón `refineEnabled`): parciales al delegate, finalize sin refine/translate. El HUD crece a burbuja (panel redimensionable). Manos libres: `WakeListener` gana `onArmedChunk` (display-only — la inserción sigue llegando por `wakeListenerDidCapture` y el controller la procesa en modo live sin LLM).

**Tech Stack:** Swift 5.10, WhisperKit v1.0 (batch API existente), SwiftUI/AppKit, XCTest.

## Global Constraints

- Spec §F1 (con enmienda de motor — el task final actualiza el spec con `[Ajustado en implementación]`)
- Toggle `kiki.liveTranscription`, **default ON** (patrón ausente→true de `refineEnabled`/`soundCuesEnabled` en SettingsViewModel)
- En modo live NO corre el LLM: ni refine ni translate para ese dictado (el footer del toggle lo dice); historial SÍ se registra; clipboard (F2) y `dictationDidInsert` idénticos
- Los parciales pasan por el `transcribe()` existente (gates de alucinación incluidos — un parcial corto suprimido = burbuja sigue en "Escuchando…", correcto); el texto insertado sale SIEMPRE del pass final del buffer completo
- Cadencia de parciales: nuevo pass cuando (a) no hay pass en vuelo, (b) ≥`minPassInterval` (0.8s) desde el inicio del pass anterior, (c) hay ≥`minNewAudio` (0.4s) de audio nuevo. Tiempo inyectable (`now: () -> Date`) para tests
- Privacidad: los parciales NO se loggean (contenido); solo timings/conteos
- Nunca se pierde dictado: si el pass final falla → fallback al último parcial mostrado; si tampoco hay → error path existente
- Tests: `swift test`; app `make build`; NO `make run`. Git: rama `feature/live-transcription`; Conventional Commits; sin Co-Authored-By; stage por filename
- Versión final: `1.0.0` (CFBundleVersion `6`)

---

### Task 1: AudioRecorder.onChunk

**Files:** Modify `Sources/KikiAudio/AudioRecorder.swift`.
**Interfaces — Produces:** `public var onChunk: (([Float]) -> Void)?` — samples 16kHz mono del chunk recién resampleado, invocado en el hilo de audio (documentar igual que `onLevel`: no bloquear). Se dispara ADEMÁS de acumular en `collected` (stop() no cambia).
**Steps:** leer el tap actual (el chunk resampleado ya existe junto a `onLevel`); agregar la propiedad + invocación; doc-comment estilo del archivo; `swift test` (suite existente intacta — no hay test nuevo viable sin mic real; la lógica testeable vive en Task 2); commit `feat(audio): per-chunk sample callback for live transcription`.

### Task 2: LiveTranscriptionCoordinator (TDD)

**Files:** Create `Sources/KikiCore/LiveTranscriptionCoordinator.swift`; Test `Tests/KikiCoreTests/LiveTranscriptionCoordinatorTests.swift`.
**Interfaces — Produces:**
```swift
@MainActor
public final class LiveTranscriptionCoordinator {
    public init(
        transcriber: Transcribing,
        minPassInterval: TimeInterval = 0.8,
        minNewAudioSeconds: Double = 0.4,
        sampleRate: Double = 16_000,
        now: @escaping () -> Date = Date.init)
    /// Parcial nuevo (texto completo acumulado hasta ahora). nil = sin texto aún.
    public var onPartial: ((String) -> Void)?
    public func start()
    /// Alimenta un chunk (hop desde el audio thread lo hace el caller).
    public func append(_ chunk: [Float])
    /// Pass final sobre el buffer completo; espera el pass en vuelo si hay.
    /// Devuelve el texto final (o el último parcial si el pass final falla; "" si nada).
    public func finish() async -> String
    public func cancel()
}
```
**Semántica a testear (mock Transcribing con respuestas programadas + now inyectado):** (1) append no dispara pass hasta acumular `minNewAudio`; (2) pases nunca solapados (mock lento + appends → un solo pass en vuelo, el siguiente arranca al terminar si hay audio nuevo y pasó el intervalo); (3) onPartial recibe el texto de cada pass completado (en orden); (4) parcial vacío (gate de alucinación) NO borra un parcial previo no-vacío (la burbuja no parpadea); (5) finish() espera el pass en vuelo, corre el pass final con TODO el buffer y devuelve su texto; (6) finish() con pass final que lanza → devuelve el último parcial; (7) cancel() → onPartial no vuelve a dispararse ni finish pendiente entrega. Pases via `Task` con fence de generación (patrón session-fence de WakeListener, versión simple).
**Commit:** `feat(core): live transcription coordinator with chunked re-transcription`

### Task 3: Modo live en DictationController (TDD)

**Files:** Modify `Sources/KikiCore/DictationController.swift`, `Sources/KikiCore/Protocols.swift`; Test ampliar `Tests/KikiCoreTests/DictationControllerTests.swift`.
**Interfaces — Produces:**
- `DictationControllerDelegate` += `func dictationLivePartialDidChange(_ text: String?)` (nil = limpiar burbuja; llega en MainActor como el resto).
- `DictationController.init` gana `liveEnabled: @escaping () -> Bool = { false }` y `liveCoordinatorFactory: (() -> LiveTranscriptionCoordinator?)? = nil` (factory para no construir coordinator en batch; el controller lo crea al empezar un dictado live y lo suelta al terminar).
- Flujo hotkey live: `hotkeyPressed` con `liveEnabled()` → además de `recorder.start()`, crea coordinator, `start()`, y el caller (AppDelegate) conecta `recorder.onChunk` → `controller.liveChunk(_:)` (nuevo método público que reenvía al coordinator; hop a MainActor lo hace AppDelegate). Parciales → delegate. `hotkeyReleased` live: `recorder.stop()` (samples completos van al coordinator via `finish()`? NO — el coordinator ya tiene los chunks; usar `finish()`), delegate parcial nil, estado `.processing` breve durante el pass final, `processTranscriptContent(finalText, ...)` con refine/translate SALTADOS (nuevo parámetro interno o check `liveEnabled` capturado al inicio del dictado — capturarlo al PRESS, no re-leerlo al release), historial + insert + clipboard como siempre.
- `process(samples:)` (wake): si el dictado nació live (AppDelegate lo indica — nuevo parámetro `skipRefine: Bool = false` o variante `processLive(samples:)`) → transcribe batch del buffer entregado + skip refine/translate. (Los parciales de wake los pinta AppDelegate directo al HUD con su propio coordinator display-only — el controller no participa hasta la entrega.)
- `cancel()` live: coordinator.cancel() + parcial nil.
**Tests:** mocks existentes + coordinator con transcriber mock: (1) press live → estado recording y parciales fluyen al delegate; (2) release live → inserta el texto del pass final, refine mock NUNCA llamado aunque refineEnabled=true; (3) translate tampoco; (4) historial registrado; (5) live OFF → camino batch intacto (suite existente); (6) cancel live limpia parcial; (7) liveEnabled capturado al press (cambiar el toggle mid-dictado no cambia el flujo en curso).
**Commit:** `feat(core): live dictation mode with partial delivery and LLM bypass`

### Task 4: Burbuja en el HUD

**Files:** Modify `Sources/Kiki/HUDView.swift`, `Sources/Kiki/HUDController.swift`.
**Interfaces — Produces:** `HUDModel` += `@Published var liveText: String?`; `HUDController.updateLiveText(_ text: String?)`.
**Contrato visual:** con `liveText != nil` y estado `.recording`: burbuja (reemplaza el pill) — texto blanco, fondo cápsula/rect redondeado negro 0.75, `maxWidth 420`, hasta ~3 líneas visibles (las últimas — `truncationMode(.head)` o ScrollView bloqueado al fondo), el punto rojo pulsante se mantiene como indicador a la izquierda. Panel: `HUDController` debe REDIMENSIONAR el NSPanel (hoy fijo 220×48): al mostrar/actualizar liveText calcular tamaño (hasta 440×110) con `setContentSize` + re-centrar bottom-center; al volver a pill, tamaño original. `.processing` con liveText ≠ nil: mantener la burbuja con spinner pequeño (el pass final es breve) en vez del pill "Procesando…".
**Verificación:** `swift test` + `make build` (visual en E2E manual del cierre).
**Commit:** `feat(app): live text bubble HUD with resizable panel`

### Task 5: Toggle + cableo completo (hotkey y manos libres)

**Files:** Modify `Sources/Kiki/SettingsViewModel.swift`, `Sources/Kiki/SettingsWindow.swift`, `Sources/Kiki/AppDelegate.swift`, `Sources/KikiWake/WakeListener.swift`.
**Contrato:**
- Toggle "Transcripción en vivo" default ON (patrón ausente→true), key `kiki.liveTranscription`, Section propia con footer: en vivo se inserta lo que ves al soltar, sin refinado ni traducción por IA en ese dictado; apágalo para volver al modo batch con IA.
- AppDelegate: `controller` init gana `liveEnabled: { UserDefaults... }` + factory con `self.transcriber`; `recorder.onChunk = { chunk in Task { @MainActor in self?.controller.liveChunk(chunk) } }`; delegate nuevo método → `hud.updateLiveText(text)`.
- WakeListener: `public var onArmedChunk: (([Float]) -> Void)?` — invocado (sobre `queue`, documentado) SOLO en estado `.armed` con cada chunk crudo que el segmenter armado acumula de habla activa (leer dónde el armed segmenter recibe samples; si el punto natural es pre-segmentación, entregar los chunks de habla detectada — precisión: display-only, no necesita exactitud de bordes). AppDelegate (si live ON y sesión armed): coordinator display-only propio alimentado por esos chunks → `hud.updateLiveText`; al `wakeListenerDidCapture(samples:)` → `coordinator.cancel()` + limpiar + `controller.processLive(samples:)` (o `process(samples:, skipRefine: true)` según Task 3); same-breath: sin live (ya viene texto).
- Esc/cancel paths limpian la burbuja (`updateLiveText(nil)`).
**Verificación:** `swift test` + `make build`.
**Commit:** `feat(app): live transcription wiring for hotkey and hands-free flows`

### Task 6: Versión 1.0.0 + spec + release notes

**Files:** `App/Info.plist` (0.11.0→1.0.0, CFBundleVersion 5→6), `docs/RELEASE_NOTES.md`, `docs/superpowers/specs/2026-07-11-cuatro-features-v1-design.md` (§F1: motor `[Ajustado en implementación: re-transcripción chunked propia — AudioStreamTranscriber posee su propio micrófono y no acepta samples externos; el pass final autoritativo cubre la cola de audio]` + confirmed/unconfirmed simplificado a un solo texto parcial).
**Notes 1.0.0:** header + sección "Transcripción en vivo" (burbuja mientras hablas, inserción instantánea al soltar, sin espera de IA; toggle para volver al modo refinado; funciona con Fn y con "escúchame kiki") + nota de que 1.0 completa la experiencia; Instalación con `kiki-1.0.0.dmg`.
**Verificación:** `swift test` + `make bundle`. Commit `chore: bump version to 1.0.0 (live transcription)`.

---

## Self-review

- **Cobertura spec §F1:** burbuja live ambos modos ✅ (T4/T5), fin por soltar tecla y por silencio manos-libres ✅ (T3/T5 — el silencio lo sigue detectando WakeListener, sin cambios), inserción instantánea sin LLM ✅ (T3), toggle default ON ✅ (T5), clipboard F2 ✅ (flujo insert intacto), motor ajustado con evidencia ✅ (header + T6).
- **Desviaciones documentadas:** confirmed/unconfirmed (blanco/gris) del spec se simplifica a un solo texto parcial — el chunked re-decode no produce segmentos confirmados estables sin la técnica clipTimestamps; anotado para T6 y como optimización futura (clipTimestamps + segmentos confirmados).
- **Consistencia:** `liveChunk(_:)`/`finish()`/`onPartial` idénticos T2/T3/T5; `updateLiveText` T4/T5; key `kiki.liveTranscription` T5.
- **Placeholders:** contratos completos con semántica numerada de tests; integraciones instruyen lectura del código real (patrón validado F2-F4).
