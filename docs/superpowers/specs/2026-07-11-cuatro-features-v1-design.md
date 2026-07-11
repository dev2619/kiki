# kiki — Cuatro features hacia v1.0

**Fecha:** 2026-07-11
**Estado:** Aprobado
**Base:** v0.9.1 (main)

## Alcance y orden

Cuatro features independientes, cada una con su propio ciclo plan→implementación→release, en este orden:

| Orden | Feature | Tamaño | Release |
|---|---|---|---|
| 1 | F2 — Transcripción al clipboard | XS | v0.9.2 |
| 2 | F4 — Wake detection rápida (tiny dedicado) | M | v0.10.0 |
| 3 | F3 — Gestor de modelos | M | v0.11.0 |
| 4 | F1 — Transcripción live con burbuja | L | v1.0.0 |

**Descartado explícitamente:** port a Windows (requiere producto nuevo con otro stack — Swift/AppKit/CoreML/MLX no portan) y build para macOS Intel (MLX es Apple Silicon-only; se reevalúa si hay demanda). Decisión del 2026-07-11.

## F2 — Transcripción al clipboard

**Comportamiento (nuevo default):** al dictar, el texto se inserta en el cursor Y queda en el portapapeles. El restore del clipboard anterior (hoy `restoreDelay` 0.4s en `PasteInserter`) se omite.

- `PasteInserter` gana `restoresClipboard: () -> Bool` (default `{ false }` = la transcripción queda), evaluado en cada insert para que el toggle aplique en caliente. [Ajustado en implementación: closure en vez de `keepInClipboard: Bool` fijo.]
- Settings: toggle **"Restaurar clipboard anterior tras dictar"** (OFF por defecto) — patrón existente `SettingsViewModel` @Published + UserDefaults (key `kiki.restoreClipboard`, naming `kiki.*` del resto de keys).
- Consistencia: en fallo de paste el texto ya quedaba en clipboard; ahora el comportamiento es uniforme.
- Tests: unit de `PasteInserter` con pasteboard nombrado — con flag ON restaura, con flag OFF (default) la transcripción persiste.

## F4 — Wake detection rápida

**Hoy:** frase → 0.5s de silencio (`SpeechSegmenter .listening endSilence`) → Whisper large sobre el segmento (~1-2s) → `WakePhraseMatcher`. Total ~2-3s.

**Nuevo:** un **`openai_whisper-tiny`** (~75MB, multilingüe) residente dedicado exclusivamente a verificar la wake phrase. Inferencia ~100-200ms → latencia total ~0.7-1s.

- `WakeListener.handleListeningSegment` usa el transcriber tiny; el modelo grande queda solo para dictado (armed mode).
- El tiny se descarga en el primer arranque junto al resto (se suma a la ventana de progreso; +75MB).
- `WakePhraseMatcher` no cambia; el umbral de similitud se recalibra con los fixtures de audio existentes (tiny transcribe peor, pero para matchear una frase fija de 4-6 sílabas alcanza).
- `endSilence` de listening queda en 0.5s (ajuste posterior si se quiere más agresividad).
- Memoria: +~200MB residentes (aceptable, target Apple Silicon).
- Tests: suite de fixtures de KikiWake re-validada contra tiny (falsos positivos/negativos); prepare() del tiny con fallback documentado (si tiny falla, degradar al modelo grande como hoy).

## F3 — Gestor de modelos

Nueva sección **"Modelos"** en Settings con dos catálogos curados (hoy ambos modelos son constantes hardcodeadas).

Transcripción (WhisperKit, repo `argmaxinc/whisperkit-coreml`):

| Modelo | Tamaño | Posicionamiento |
|---|---|---|
| `openai_whisper-small_216MB` | ~216MB | Rápido / poca RAM |
| `openai_whisper-large-v3_turbo_954MB` ★ | ~1GB | Base — default, siempre se descarga |
| `openai_whisper-large-v3_turbo` | ~3GB | Máxima calidad — con advertencia de compilación ANE larga |

Refinado (MLX, repo `mlx-community`):

| Modelo | Tamaño | Posicionamiento |
|---|---|---|
| `Qwen2.5-1.5B-Instruct-4bit` | ~1GB | Menos espera |
| `Qwen2.5-3B-Instruct-4bit` ★ | ~2GB | Base — default |
| `Qwen2.5-7B-Instruct-4bit` | ~4.5GB | Macs 32GB+, máxima calidad |

Reglas:

- UI por fila: nombre amigable + tamaño + estado (activo ● / descargado ✓ / descargar ⬇) + acción. Descarga usa `ModelLoadProgressModel` existente sin bloquear el dictado con el modelo activo.
- Preferencias en UserDefaults: `kikiSTTModel`, `kikiRefineModel`. `WhisperTranscriber`/`LLMRefiner` resuelven preferencia → fallback al base si el preferido falla o no está descargado.
- **Hot-swap:** al elegir otro modelo, se carga (con prewarm — lección del bug "Procesando…" eterno) en background y se conmuta al estar listo; mientras tanto sigue el anterior.
- El base STT (954MB) siempre se descarga en el primer arranque — garantía funcional.
- Tests: unit del resolver preferencia/fallback; descargas reales gated por env var (patrón del test de integración STT).

## F1 — Transcripción live con burbuja

**Experiencia:** activar dictado (Fn o wake) → la burbuja live aparece (evolución del HUD pill) → el texto fluye mientras hablas: confirmado en blanco, hipótesis en gris → soltar Fn / silencio 1.5s (manos libres) → **se inserta exactamente el texto mostrado, al instante** (modo live no corre el LLM) y queda en clipboard (F2).

- **Motor:** `AudioStreamTranscriber` de WhisperKit v1.0 (actor con `confirmedSegments`/`unconfirmedSegments` + callback de estado; ya disponible en el checkout pinneado). Alimentado por el mismo `AudioRecorder` (16kHz mono).
- **KikiCore:** nuevo protocolo `StreamTranscribing` (start/stop + callback de parciales) junto al `Transcribing` batch. `DictationController` gana modo live: `recording` con parciales fluyendo → al stop el resultado es lo acumulado; **no hay fase `processing` en live**.
- **HUD:** `HUDModel` += `@Published liveText/unconfirmedText`; `HUDView` renderiza burbuja (ancho máx ~420pt, últimas ~3 líneas con auto-scroll; la pill actual es el estado sin texto).
- **Toggle:** settings **"Transcripción en vivo"**, default ON. OFF = comportamiento actual (batch + refinado LLM). La auto-edición no se pierde: se elige por modo.
- **Manos libres:** tras wake (F4), el armed mode alimenta el mismo stream; fin por el silencio de 1.5s existente.
- Latencia esperada: burbuja ~0.5s detrás de la voz con el modelo base en M1 Max; mejor con `small` (F3).
- Tests: unit del acumulador confirmado/no-confirmado con stream mockeado; integración gated con fixture WAV en chunks; E2E manual (ambos modos de activación, cancelación con Esc, apps reales).

## Restricciones globales (aplican a las 4)

- Todo local, cero telemetría; errores y timings a `KikiLog`.
- Degradación elegante: nunca se pierde un dictado (fallos → texto crudo/clipboard + log).
- Git: rama por feature, Conventional Commits sin Co-Authored-By, stage por filename.
- Cada feature termina con: suite verde, bump de versión, release notes, merge a main.
