# kiki

Dictado por voz con IA, **100% local**, para macOS. Mantén **Fn**, habla, suelta — el texto aparece donde esté tu cursor, en cualquier app. Tu voz nunca sale de tu Mac.

> Fase actual: **2B — manos libres** (hotkey + Whisper local + LLM Qwen2.5-3B + paste + wake phrase "escúchame kiki").
> Spec completo: [`docs/superpowers/specs/2026-07-06-kiki-design.md`](docs/superpowers/specs/2026-07-06-kiki-design.md)

## Requisitos

- macOS 14+ · Apple Silicon
- **Xcode completo** (desde App Store o xcode.apple.com) — el build requiere `xcodebuild` para compilar los shaders Metal de MLX (Fase 2A); no basta con Command Line Tools
- ~3 GB de disco para los modelos descargados en el primer arranque:
  - Whisper cuantizado (openai_whisper-large-v3_turbo): 954 MB
  - Qwen2.5-3B-Instruct-4bit: ~1.8 GB
  - Tokenizers: ~200 MB
  - Nota: la primera carga de ambos modelos incluye prewarm ANE/CoreML y puede tardar varios minutos — las siguientes son rápidas

## Build & run

```bash
make test     # unit tests
make bundle   # ensambla build/kiki.app (firma ad-hoc)
make run      # abre la app
```

Test de integración STT (descarga el modelo Whisper):

```bash
KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests
```

Test de integración LLM (descarga Qwen2.5-3B; requiere xcodebuild, no swift test):

```bash
TEST_RUNNER_KIKI_LLM_TEST=1 xcodebuild test -scheme kiki -destination 'platform=macOS' -only-testing:KikiRefineTests/LLMRefinerIntegrationTests
```

(El prefijo `TEST_RUNNER_` es necesario: xcodebuild solo propaga al test runner las variables así prefijadas.)

## Permisos (primer arranque)

1. **Micrófono** — prompt automático.
2. **Accesibilidad** — System Settings → Privacy & Security → Accessibility → activar kiki. Necesario para la tecla Fn global y para pegar el texto.

   > Importante: tras conceder Accesibilidad por primera vez, **reinicia kiki** — el monitor global de teclado registrado antes del permiso no se reactiva solo.

> Nota dev: la app se firma con el cert local estable `kiki-dev` (login keychain), así los
> permisos TCC y el cache ANE/CoreML sobreviven a los rebuilds. Si no existe el cert
> (máquina nueva): generarlo con openssl (`extendedKeyUsage=codeSigning`), exportar p12
> `-legacy`, `security import -T /usr/bin/codesign` y `security add-trusted-cert -p codeSign`.
> Fallback sin cert: `make SIGN_ID=-` (ad-hoc; re-toggle de Accesibilidad tras cada rebuild).
> Recomendado: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Arquitectura

Módulos SPM: `KikiCore` (máquina de estados) · `KikiAudio` (mic → 16 kHz mono) · `KikiSTT` (WhisperKit) · `KikiRefine` (LLM Qwen + tone profiles) · `KikiContext` (app detection + tone mapping) · `KikiInsert` (paste preservando clipboard) · `KikiWake` (wake word detection + VAD) · `Kiki` (menu bar app, hotkey, HUD).

## Refinado con IA (Fase 2A)

Tras transcribir con Whisper, el texto se pasa a un modelo LLM local (Qwen2.5-3B-Instruct-4bit, ~1.8 GB) que:
- Limpia muletillas típicas (uh, eh, hmm)
- Añade puntuación
- Adapta el tono según la app activa (detectada con Accessibility API)

**Perfiles de tono por tipo de app:**

| Tipo | Perfil | Apps |
|------|--------|------|
| code | neutral-técnico (sin emojis, snake_case en vars) | VS Code, Xcode, JetBrains, Terminal, iTerm, Sublime, Warp |
| chat | casual-coloquial (emojis OK, lenguaje relajado) | Slack, Discord, Telegram, WhatsApp, Messages |
| email | formal-profesional (saludos, cierres, sin coloquialismos) | Mail, Outlook, Spark |
| docs | formal-narrativo (párrafos bien estructurados) | Notes, TextEdit, Obsidian, Word, Notion |
| resto | neutral (sin cambios estilísticos) | cualquier otra app |

**Regla de degradación:**
- Si el modelo LLM falla a cargar, o la refinación tarda >5s, se inserta el texto crudo de Whisper sin pérdida de información.
- Si el modelo no se descarga en el inicio, el menú dice "Listo (sin refinado IA)" — la app funciona con Whisper solo (Fase 1).
- El dictado nunca se pierde: siempre hay algo que insertar.

## Manos libres (Fase 2B)

**Activación:** Menú 🎤 → "Manos libres" (toggle; desactivado por defecto, almacenado en UserDefaults).

**Frases de activación:**
- **"escúchame kiki"** — inicia grabación de micrófono en modo manos libres
- **"listen to me kiki"** — variante en inglés (ambas frases detectadas por modelo VAD+Whisper híbrido)

**Flujo de dictado:**
1. Di la frase de activación → **chime** + "👂 Te escucho…" (HUD naranja con waveform animado)
2. Dicta el texto (mientras el modo esté activo, el ícono del menú cambia a waveform)
3. **Silencio de 1.5 segundos** → fin de grabación, transcripción y refinado (mismo flujo que hotkey)
4. Texto insertado donde esté el cursor

**Dictado en el mismo aliento:** Puedes decir la frase y el texto en una sola oración:
- _"Escúchame kiki, escribe: el protocolo TCP establece una conexión de tres vías"_ → la frase se descarta, solo se transcribe y refina "el protocolo TCP…"

**Cancelación:** Presiona **Esc** en cualquier momento durante la grabación (ambos modos: hotkey y manos libres) para descartar la grabación.

**Privacidad:**
- Mientras el modo manos libres esté activo, el indicador de micrófono en la barra de estado muestra un punto **naranja permanente** (aviso de que el micrófono está monitoreando).
- **Todo el audio se procesa en RAM y se descarta inmediatamente** — nunca se graba a disco.
- Los segmentos de conversación que **no contienen la frase de activación** se descartan sin ser transcritos. Si un segmento supera 6 segundos y no activa la frase, su contenido **nunca se escribe al log**.
- Solo se registran transcripts que contienen la frase de activación.

**Consumo de recursos:**
- **Whisper corre bajo demanda:** el modelo solo se invoca cuando hay habla cerca del Mac (VAD por análisis de energía filtra silencio y ruido ambiental muy bajo, reduciendo falsos positivos).
- **openWakeWord (optimización futura):** modelo dedicado ~1 MB para detección de frase más eficiente — pendiente en backlog.

**Limitaciones conocidas:**
- **Ambientes muy ruidosos:** pueden disparar segmentos de grabación falsos si el umbral de RMS (energy threshold) se cruza. En v1 usamos un umbral fijo; umbral adaptativo está en backlog.
- **"Listo" como palabra de cierre:** la spec lo menciona (§3) como forma alternativa de terminar dictado; **no implementado en v1** — en backlog junto con otras mejoras de UX.

## Notas de alcance (Fase 2A-2B)

**Fase 2A implementada:**
- ✓ Refinado LLM local (Qwen2.5-3B-Instruct-4bit, ~1.8 GB)
- ✓ Detección de app y mapeo de perfiles de tono
- ✓ Degradación elegante (timeout 5s → Whisper crudo)
- ✓ Modelo Whisper cuantizado (`openai_whisper-large-v3_turbo_954MB`) con prewarm

**Fase 2B implementada (v1 híbrida):**
- ✓ Wake word (VAD + Whisper híbrido: detección por frase "escúchame kiki" / "listen to me kiki")
- ✓ Toggle en menú + UserDefaults (default OFF)
- ✓ Chime + HUD "👂 Te escucho…"
- ✓ Dictado en el mismo aliento (frase se descarta)
- ✓ Cancelación con Esc en ambos modos (hotkey y manos libres)
- ✓ Indicador naranja de micrófono activo
- ✓ Audio solo en RAM, segmentos sin frase no se loggean

**Pendiente (optimizaciones 2B):**
- openWakeWord (modelo dedicado ~1 MB) — alternativa más eficiente a VAD+Whisper
- Umbral de energía adaptativo (v1 usa RMS fijo — env muy ruidosos pueden generar falsos segmentos)
- "Listo" como palabra de cierre (spec §3 lo menciona; no va en v1)
- Seam de audio testeable para WakeListener (mejorar cobertura de tests)

**Pendiente (Fase 3):**
- Diccionario custom de palabras (spec §9)
- Snippets y macros (spec §9)
- Settings UI para perfiles de tono y desactivación de refinado

**Notas técnicas:**
- **Decisión 2026-07-06 (Whisper):** la variante full-precision (3 GB) disparaba compilaciones ANE de 10-30 min en la primera inferencia (ANECompilerService al 95% CPU, app bloqueada en "Procesando…") y se re-pagaban tras cada rebuild por la firma ad-hoc. Con la cuantizada + prewarm, la compilación ocurre en la carga y la inferencia queda en segundos.
- **Decisión 2026-07-06 (LLM + Metal):** Qwen2.5-3B con MLX requiere `xcodebuild` para compilar los shaders Metal en la carga; no es posible con CLT solo. La carga es ~10–20s en primer arranque (compilación + prewarm), las inferencias siguientes ~2-3s (medido: 2.2s de generación real con el modelo ya en caché, ver `.superpowers/sdd/task-2a4-report.md`).
- **Decisión 2026-07-06 (latencia end-to-end vs spec Fase 1):** la latencia total de dictado con refinado (~3-4s: STT + generación LLM) excede el objetivo <2s del spec Fase 1. Decisión registrada: aceptado en Fase 2A (el refinado con IA es una mejora nueva, no parte del baseline original), tuning en Fase 3 (candidatos: modelo 1.5B, prompt más corto, streaming).
- **Decisión 2026-07-06 (wake v1 híbrida):** VAD por energía + transcripción Whisper en segmentos detecta la frase con suficiente confiabilidad para v1. openWakeWord (modelo especializado) es más eficiente pero requiere investigación — en backlog como optimización.
