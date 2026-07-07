# kiki Fase 3.7 — "Dictado extenso + Modo traducción" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Specs (feedback del owner 2026-07-07):**
1. **Dictado extenso:** validar/soportar dictados largos. Muro actual: en sesión armada, un tramo de habla continua > `maxSegmentDuration` (30s) se descarta ENTERO (`segmentDiscarded("máximo")`) — inaceptable para dictado extenso. Cambio: **rollover** — al alcanzar el tope en modo armado, EMITIR el segmento (se procesa/pega) y **continuar capturando sin perder audio** (el habla sigue; el siguiente segmento arranca de inmediato). En modo escucha (vigilancia de frase) se mantiene el descarte (un monólogo ambiental de 6s no es la frase).
2. **Modo traducción (función especial):** toggle "Traducir al dictar" (menú + Ajustes→General, UserDefaults `kiki.translateEnabled`, default false). Con el modo activo: se detecta el idioma hablado (es/en, ya existe) y el paso de IA **traduce al otro idioma** en vez de refinar (es→en, en→es). Aplica en ambos modos (hotkey y manos libres).

## Global Constraints

- Heredados (tests verdes 209/4, xcodebuild, kiki-dev, Conventional Commits sin Co-Authored-By, stage por filename, rama `feature/fase-3-7-extenso-translate`)
- **Rollover (T1):** `SegmenterConfig` gana `emitOnMaxDuration: Bool = false` (legacy intacto). Con true: al proyectar exceso del tope, emitir `segmentEnded(samples)` con lo acumulado y continuar EN estado speech (nuevo segmento inmediato, sin awaitingSilence, sin perder el chunk actual — va al segmento nuevo). WakeListener: armedConfig con true; listeningConfig false. Nota Whisper: segmentos ≤30s alinean con la ventana del modelo.
- **Traducción (T2):** el idioma detectado debe fluir del transcriptor al paso de IA. `WhisperTranscriber` ya detecta es/en; exponerlo SIN romper `Transcribing` (decisión sugerida: struct `TranscriptionOutput {text, language}` con método nuevo en protocolo + default que envuelve `transcribe`, o propiedad `lastDetectedLanguage` en el actor — el implementador decide y documenta; los mocks existentes no deben requerir cambios masivos).
  - `RefinePrompt` gana modo translate: system prompt dedicado — "Traduce al {inglés|español}. Conserva significado, tono y formato. Responde ÚNICAMENTE con la traducción." (+ términos del diccionario se respetan sin traducir).
  - `LLMRefiner`/pipeline: con translate activo, `minRefinableLength` NO aplica (traducir "hola" es legítimo) y los guards de longitud sospechosa se relajan (traducción legítima varía longitud: aceptar 0.3x–3.5x).
  - Menú: item "Traducir al dictar" con checkmark (entre Manos libres y el separador); Ajustes→General: toggle equivalente espejado (mismo patrón que manos libres/sonidos).
  - HUD: pill de procesamiento muestra "Traduciendo…" cuando el modo está activo (en vez de "Procesando…").
  - Historial: registra crudo (idioma original) y final (traducido) — ya soportado.
- Latencia: traducción es una generación LLM equivalente al refinado (~1-3s típicos); sin cambios de presupuesto.

## Tasks

### Task 1: Rollover de segmentos en modo armado (TDD)
Files: Sources/KikiWake/SpeechSegmenter.swift (+config flag+lógica), Sources/KikiWake/WakeListener.swift (armedConfig emitOnMaxDuration: true), Tests/KikiWakeTests/ (nuevos casos: al tope emite y sigue en speech; el chunk que cruza va al nuevo segmento; dos rollovers consecutivos; legacy discard con flag false intacto — 18+ tests existentes intocables).
Commit: `feat(wake): segment rollover for extended dictation`

### Task 2: Modo traducción
Files: Sources/KikiSTT/WhisperTranscriber.swift (exponer idioma), Sources/KikiCore/{Protocols,DictationController}.swift (flujo idioma→refine + toggle translate como parámetro/provider), Sources/KikiRefine/{RefinePrompt,LLMRefiner}.swift (prompt translate + guards relajados), Sources/Kiki/{AppDelegate,SettingsWindow,SettingsViewModel,HUDController,HUDView}.swift (toggles + HUD "Traduciendo…"), README.
TDD en lo puro (RefinePrompt translate, controller con mock translate-aware, guards); integración LLM real: 1 corrida gated con caso es→en.
Commit: `feat(translate): live translation mode between es/en`

### Task 3: README + cierre + validación extenso
Guía de dictado extenso en README (rollover ~30s chunks, qué esperar); notas de alcance.
