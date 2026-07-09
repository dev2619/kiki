# Documentación técnica — kiki

> Guía completa para desarrolladores y para entender a fondo cómo funciona kiki.
> Para descargar e instalar la app, ve al [README](../README.md).

**Estado:** MVP completo (Fases 1–3 + pulido 3.6/3.7/3.8). Dictado por tecla y manos libres, refinado con IA local, modo traducción es⇄en, diccionario/snippets/historial, y atajos de teclado estándar.
Spec completo: [`superpowers/specs/2026-07-06-kiki-design.md`](superpowers/specs/2026-07-06-kiki-design.md) · Marca: [`brand/`](brand/)

## Índice

- [Requisitos de desarrollo](#requisitos-de-desarrollo)
- [Build & run](#build--run)
- [Distribución (.dmg)](#distribución-dmg)
- [Permisos (primer arranque)](#permisos-primer-arranque)
- [Arquitectura](#arquitectura)
- [Refinado con IA](#refinado-con-ia)
- [Escucha siempre activa](#escucha-siempre-activa)
- [Modo traducción](#modo-traducción)
- [Manos libres](#manos-libres)
- [Personalización (diccionario, snippets, historial)](#personalización)
- [Notas de alcance por fase](#notas-de-alcance-por-fase)
- [Decisiones técnicas](#decisiones-técnicas)

## Requisitos de desarrollo

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
make bundle   # ensambla build/kiki.app (firma local kiki-dev)
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

## Distribución (.dmg)

```bash
make dmg      # ensambla build/kiki-<version>.dmg
```

`make dmg` genera un `.dmg` con `kiki.app` y un symlink a `/Applications` (arrástralo para instalar), vía `hdiutil` — sin dependencias externas. El nombre del archivo toma la versión de `CFBundleShortVersionString` en `App/Info.plist`.

Para publicar el release en GitHub, ver la guía paso a paso en [`RELEASE.md`](RELEASE.md).

> **Gatekeeper:** el `.dmg` **no está notarizado** (requiere Apple Developer Program — pendiente). En un Mac distinto al de desarrollo, macOS bloqueará el primer lanzamiento; hay que hacer **clic derecho → Abrir** sobre `kiki.app` (una sola vez) para saltar el aviso de "desarrollador no identificado".

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

Módulos SPM: `KikiCore` (máquina de estados) · `KikiAudio` (mic → 16 kHz mono) · `KikiSTT` (WhisperKit) · `KikiRefine` (LLM Qwen + tone profiles) · `KikiContext` (app detection + tone mapping) · `KikiInsert` (paste preservando clipboard) · `KikiWake` (wake word detection + VAD) · `KikiStore` (persistencia JSON: diccionario, snippets, historial) · `Kiki` (menu bar app, hotkey, HUD).

## Refinado con IA

Tras transcribir con Whisper, el texto se pasa a un modelo LLM local (Qwen2.5-3B-Instruct-4bit, ~1.8 GB) que hace una **corrección mínima y fiel**:
- Quita muletillas y rellenos (eh, em, este, o sea, like) y falsos comienzos
- Corrige puntuación y mayúsculas
- **Conserva tus palabras exactas y la estructura de la frase** — no reformula, no resume, no reordena, no cambia el tipo de frase (una orden sigue siendo orden, una pregunta sigue siendo pregunta)

> **Fidelidad primero (2026-07-08).** El refinado corrige, no reescribe. Antes adaptaba el "tono" según la app y eso hacía que el modelo parafraseara tus palabras (p. ej. convertía "Dame la lista…" en "Lista de…:"). Ahora el único ajuste por app que sobrevive es en editores de código/terminal: los términos técnicos, comandos y nombres de librerías se dejan **exactos**, sin traducir.

**Toggle "Refinar dictado con IA"** (Ajustes → General, activado por defecto): apágalo para insertar **exactamente** la transcripción de Whisper, sin que la IA toque nada. La traducción es un modo aparte y sigue funcionando aunque el refinado esté apagado.

**Reglas de degradación (el dictado nunca se pierde — siempre se inserta algo):**
- Si el modelo LLM falla a cargar, o la refinación tarda >5s, se inserta el texto crudo de Whisper.
- **Guardia de fidelidad:** si el refinado introduce demasiado vocabulario que no dijiste (señal de que parafraseó o "respondió" el dictado en vez de limpiarlo), se descarta y se inserta el texto crudo.
- Si el modelo no se descarga en el inicio, el menú dice "Listo (sin refinado IA)" — la app funciona con Whisper solo (Fase 1).

## Escucha siempre activa

Con **"Escucha siempre activa"** (Ajustes → General, activado por defecto), decir *"escúchame kiki"* / *"listen to me kiki"* inicia el dictado **sin tocar nada** — ni el toggle ni ⌥⌘K ni una tecla. El micrófono queda atento desde que kiki arranca.

- El reconocimiento de la frase es tolerante a cómo Whisper la transcribe realmente (a veces la escribe fonético, "Eska-Chame-Kiki", por su detección de idioma en frases cortas): matching por slots con tolerancia a errores y a palabras partidas, exigiendo siempre ambas partes para no dispararse solo.
- ⌥⌘K y el toggle siguen sirviendo para dictar al instante sin frase.
- **Consecuencia:** el micrófono permanece abierto de forma continua, así que macOS muestra su indicador naranja de micrófono siempre encendido mientras kiki corre. Ese indicador es de macOS, no de kiki. **Tip:** en ese mismo menú de macOS (Centro de Control → micrófono) activa **"Voice Isolation"** para filtrar ruido de fondo y mejorar la precisión.

## Modo traducción

Toggle **"Traducir al dictar"** en el menú 🎤 y en Ajustes → General (apagado por defecto).

- **Apagado (fidelidad):** kiki fija la salida al idioma que detecta Whisper y **nunca traduce** — hablas en inglés, escribe en inglés; hablas en español, escribe en español. (Esto corrige la deriva del modelo pequeño, que sin fijar idioma a veces traducía o inventaba.)
- **Encendido (traducción):** habla en un idioma y kiki escribe en el otro — español↔inglés, detectando automáticamente el idioma de origen. El HUD muestra "Traduciendo…". Los términos del diccionario se respetan sin traducir.

El idioma detectado por Whisper se pasa junto al texto hasta el paso de IA, así que la elección de idioma corresponde exactamente a la frase dictada (sin condiciones de carrera entre transcripciones).

## Manos libres

**Activación:** dos entradas, dos intents distintos:
- **Menú 🎤 → "Manos libres"** (toggle; desactivado por defecto, almacenado en UserDefaults) — solo **vigilancia**: activa la escucha de la frase de activación, sin armar el dictado.
- **Atajo global ⌥⌘K** — **dictar ya**: con manos libres apagado, ⌥⌘K enciende el modo Y arma el dictado **directamente, sin decir la frase** (**Glass** + pill "👂 Te escucho…", listo para hablar de inmediato). La frase de activación sigue funcionando en paralelo mientras el modo queda activo. Un segundo ⌥⌘K (con manos libres ya activo, escuchando o armado) apaga todo — sesión + modo (**Bottle** + pill "Manos libres desactivado"), mismo efecto que apagar el toggle del menú.

**Frases de activación:**
- **"escúchame kiki"** — inicia grabación de micrófono en modo manos libres
- **"listen to me kiki"** — variante en inglés (ambas frases detectadas por modelo VAD+Whisper híbrido)

**Sonidos de confirmación (Fase 3.6):**
- **Glass** — frase de activación detectada (inicio de sesión)
- **Tink** — inicio de captura de audio (aún escuchando)
- **Pop** — texto insertado en ambos modos (hotkey y manos libres)
- **Bottle** — fin de sesión de manos libres

Todos los sonidos se pueden desactivar en **Ajustes → General → Sonidos**.

**Indicador de estado:** Cuando manos libres está activo, el ícono 🎤 en la barra de menús muestra un **punto de estado integrado bajo el símbolo**, indicando que el micrófono está monitoreando (ambigüedad visual cero respecto a antes).

**Flujo de dictado (sesión continua):** la frase de activación abre una sesión de dictado que queda armada entre utterances — no hace falta repetirla para cada frase que quieras dictar.
1. Di la frase de activación → **Glass** + "👂 Te escucho…" (HUD naranja con waveform animado)
2. Dicta el texto (mientras el modo esté activo, el ícono del menú cambia a waveform)
3. **Silencio de 1.5 segundos** → fin de la utterance, transcripción, refinado y pegado (mismo flujo que hotkey); **Pop** suena al insertar
4. Texto insertado donde esté el cursor, y el HUD vuelve a "👂 Te escucho…" — la sesión sigue armada, lista para la siguiente utterance sin repetir la frase
5. La **sesión de dictado** termina con **Esc**, tras **45 segundos de silencio** sin nueva utterance (**Bottle** suena), o usando el **dictado por tecla (Fn)** — el hotkey toma control explícito del micrófono (privacidad primero: una acción manual manda sobre la sesión manos-libres). En los tres casos el **modo manos libres sigue activo**: kiki vuelve a la vigilancia por frase, y decir la frase reabre la sesión. Para apagar **todo** (sesión + modo), usa **⌥⌘K** o el toggle del menú

Nota sobre timeouts: si dices la frase (o armas con **⌥⌘K**) y no dictas nada después, el desarmado es más rápido (**8 segundos**) que el de silencio entre utterances dentro de una sesión ya en marcha (**45 segundos**) — evita quedarte "armado" indefinidamente por una frase suelta o un atajo accidental, sin cortar de golpe una sesión de dictado real mientras piensas la siguiente frase.

**Dictado en el mismo aliento:** Puedes decir la frase y el texto en una sola oración:
- _"Escúchame kiki, escribe: el protocolo TCP establece una conexión de tres vías"_ → la frase se descarta, solo se transcribe y refina "el protocolo TCP…". Esto también abre la sesión continua: tras pegar el texto, el HUD vuelve a "👂 Te escucho…" para la siguiente utterance.

**Cancelación:** Presiona **Esc** en cualquier momento durante la grabación (ambos modos: hotkey y manos libres) para descartar la grabación. En manos libres, Esc también **termina la sesión de dictado** — el **modo sigue activo**, de vuelta a esperar la frase de activación desde cero; apagar todo es con **⌥⌘K** o el toggle del menú.

**Privacidad:**
- Mientras el modo manos libres esté activo, el indicador de micrófono en la barra de estado muestra un punto **naranja permanente** (aviso de que el micrófono está monitoreando).
- **Todo el audio se procesa en RAM y se descarta inmediatamente** — nunca se graba a disco.
- Los segmentos de conversación que **no contienen la frase de activación** se descartan sin ser transcritos. Si un segmento supera 6 segundos y no activa la frase, su contenido **nunca se escribe al log**.
- Solo se registran transcripts que contienen la frase de activación.

**Consumo de recursos:**
- **Whisper corre bajo demanda:** el modelo solo se invoca cuando hay habla cerca del Mac (VAD por análisis de energía filtra silencio y ruido ambiental muy bajo, reduciendo falsos positivos).
- **openWakeWord (optimización futura):** modelo dedicado ~1 MB para detección de frase más eficiente — pendiente en backlog.

**Limitaciones conocidas:**
- **Ambientes muy ruidosos:** pueden disparar segmentos de grabación falsos si el umbral de RMS (energy threshold, default `0.008`) se cruza. En v1 usamos un umbral fijo; umbral adaptativo está en backlog. El log incluye diagnóstico de calibración (`kiki wake: pico RMS últimos 10s: ...`) durante las primeras ventanas de 10s tras cada arranque de manos libres, útil para ajustar el umbral al micrófono real del usuario.
- **"Listo" como palabra de cierre:** la spec lo menciona (§3) como forma alternativa de terminar dictado; **no implementado en v1** — en backlog junto con otras mejoras de UX.

## Personalización

**Ajustes desde el menú:** Menú 🎤 → "Ajustes…" (Cmd+,) abre la ventana de configuración con una **barra lateral con 5 secciones** (Fase 3.6):
1. **General** — toggle de Sonidos (Glass, Tink, Pop, Bottle), refinado con IA, traducción, escucha siempre activa
2. **Diccionario** — términos personalizados (nombres, palabras técnicas, neologismos)
3. **Snippets** — macros y atajos de expansión
4. **Historial** — últimos dictados con refresco en vivo y fechas relativas
5. **Acerca de** — versión, créditos, enlaces

**Diccionario personal:**
- Añade términos propios (nombres, palabras técnicas, neologismos) que mejoran la precisión de Whisper.
- Se inyecta en el prompt inicial de Whisper (encabezado language-aware, ~120 tokens de cap) **y** en el prompt del sistema del LLM.
- Lista de términos cuya escritura exacta se respeta (ej. añade `Kubernetes`, `TCP`, `Fulano Pérez` y kiki los reconocerá y escribirá tal cual).
- Máx. ~40 entradas por idioma sin exceder el cap de tokens.

**Snippets:**
- Macros: di exactamente el trigger → se inserta la plantilla sin pasar por el LLM.
- Matching determinístico (normalización completa del trigger: lowercase, sin acentos, espacios condensados).
- Cero latencia: la expansión es instantánea, no requiere IA.
- Ej: trigger "firma corta" (tal como lo dirías en voz alta) → plantilla "Saludos, Ana" (sin refinado, listo en ms).

**Historial (mejorado en 3.6 y 3.8):**
- Cada fila muestra `[crudo: texto de Whisper] [final: texto después de refinado]`.
- **Cantidad configurable (Fase 3.8)** — elige cuántas dictadas conservar: 50 / 100 / 200 (default) / 500 / 1000. Se guardan las más recientes; las más antiguas se descartan (FIFO). No hay expiración por tiempo.
- **Búsqueda/filtro (Fase 3.8)** — campo de búsqueda que filtra por texto (crudo + final), insensible a mayúsculas y acentos ("reunion" encuentra "reunión").
- **Refresco en vivo** — se actualiza automáticamente al completarse cada dictado.
- **Fechas relativas** — "hace 2 minutos", etc.
- Botón copiar por fila; "Borrar todo" (no se puede deshacer).
- 100% local en JSON — nunca sale del Mac.

**Diccionario / Snippets (funcional desde 3.8):**
- Al abrir la sección, el cursor entra automáticamente en el campo de entrada; agrega con Enter o el botón +; el botón de borrar (basura) es siempre visible por fila.

**Persistencia:**
- Diccionario, snippets e historial se guardan en JSON atómico en `~/Library/Application Support/kiki/` (v1 basada en JSON; migración a SQLite abierta para v2).

## Notas de alcance por fase

**Fase 2A implementada:**
- ✓ Refinado LLM local (Qwen2.5-3B-Instruct-4bit, ~1.8 GB)
- ✓ Detección de app y mapeo de perfiles de tono
- ✓ Degradación elegante (timeout 5s → Whisper crudo)
- ✓ Modelo Whisper cuantizado (`openai_whisper-large-v3_turbo_954MB`) con prewarm

**Fase 2B implementada (v1 híbrida):**
- ✓ Wake word (VAD + Whisper híbrido: detección por frase "escúchame kiki" / "listen to me kiki")
- ✓ Toggle en menú + UserDefaults (default OFF)
- ✓ Chime + HUD "👂 Te escucho…"
- ✓ Sesión de dictado continua: la frase arma una sesión que sigue armada entre utterances (8s de timeout inicial sin dictado, 45s de silencio entre utterances dentro de la sesión) hasta Esc, toggle OFF o el timeout
- ✓ Dictado en el mismo aliento (frase se descarta), también abre sesión continua
- ✓ Cancelación con Esc en ambos modos (hotkey y manos libres); en manos libres termina la sesión completa
- ✓ Indicador naranja de micrófono activo
- ✓ Audio solo en RAM, segmentos sin frase no se loggean
- ✓ Diagnóstico de calibración de RMS en el log (primeras ventanas de 10s tras cada arranque)

**Pendiente (optimizaciones 2B):**
- openWakeWord (modelo dedicado ~1 MB) — alternativa más eficiente a VAD+Whisper
- Umbral de energía adaptativo (v1 usa RMS fijo — env muy ruidosos pueden generar falsos segmentos)
- "Listo" como palabra de cierre (spec §3 lo menciona; no va en v1)
- Seam de audio testeable para WakeListener (mejorar cobertura de tests)

**Fase 3 implementada (personalización):**
- ✓ Diccionario custom de palabras (inyección en Whisper + prompt del LLM)
- ✓ Snippets y macros (matching determinístico, expansión sin latencia)
- ✓ Historial local (cap configurable, copyable, clearable, JSON persistente)
- ✓ Settings UI con secciones (Diccionario, Snippets, Historial, General, Acerca de)
- ✓ Persistencia JSON atómico en Application Support

**Fase 3.6 implementada (UX polish — sound cues & redesigned settings):**
- ✓ 4 sonidos de confirmación (Glass, Tink, Pop, Bottle) con toggle en Settings → General
- ✓ Atajo global ⌥⌘K para alternar manos libres desde cualquier app (confirmación visual en HUD)
- ✓ Indicador de estado en el ícono 🎤 (punto integrado cuando manos libres está activo — fin del emoji 👂)
- ✓ Detección más rápida de la frase de activación: corte de segmento en escucha 0.5s (antes 0.7s); el fin de utterance en sesión sigue en 1.5s
- ✓ Settings rediseñado: sidebar con 5 secciones (General, Diccionario, Snippets, Historial, Acerca de); historial con refresco en vivo y fechas relativas

**Fase 3.8 implementada (usabilidad):**
- ✓ Escucha siempre activa (la frase arma sin tocar nada; default ON)
- ✓ Diccionario/Snippets funcionales (foco de campo + borrar siempre visible + Enter para agregar)
- ✓ Historial: cap configurable (50/100/200/500/1000) + filtro de búsqueda

**Fase 4 (hardening quick-wins + empaquetado, en curso):**
- ✓ Sidecar `.corrupt` en `JSONStore`: un JSON corrupto se respalda (renombrado, no borrado) antes de reiniciar el store vacío — recuperable para forense
- ✓ Higiene de inputs en los stores: strings vacíos/solo-espacios se rechazan en `DictionaryStore.add` y `SnippetStore.add` (trigger o template vacío → no-op)
- ✓ Dedupe de snippets con la misma normalización que el matching en runtime (lowercase + diacríticos + puntuación) — "café" y "cafe" ya no producen duplicados
- ✓ Empaquetado `.dmg` (`make dmg`) + descarga on-demand de modelos con barra de progreso en el primer arranque
- ✓ Fidelidad del refinado (2026-07-08): corrección mínima que conserva las palabras + guardia de fidelidad + toggle para apagar el refinado

**Pendiente (Fase 4 — empaquetado y distribución):**
- Onboarding guiado de permisos (micrófono, Accesibilidad)
- Notarización y hardened runtime (requiere Apple Developer Program)
- Auto-update mechanism

**Backlog acumulado (sin planificar aún):**
- openWakeWord (optimización de eficiencia de wake word)
- Umbral de energía adaptativo
- "Listo" como palabra de cierre
- Auto-aprendizaje del diccionario (expansión automática de palabras frecuentes)
- Seam audio testeable para WakeListener

## Decisiones técnicas

- **Decisión 2026-07-06 (Whisper):** la variante full-precision (3 GB) disparaba compilaciones ANE de 10-30 min en la primera inferencia (ANECompilerService al 95% CPU, app bloqueada en "Procesando…") y se re-pagaban tras cada rebuild por la firma ad-hoc. Con la cuantizada + prewarm, la compilación ocurre en la carga y la inferencia queda en segundos.
- **Decisión 2026-07-06 (LLM + Metal):** Qwen2.5-3B con MLX requiere `xcodebuild` para compilar los shaders Metal en la carga; no es posible con CLT solo. La carga es ~10–20s en primer arranque (compilación + prewarm), las inferencias siguientes ~2-3s (medido: 2.2s de generación real con el modelo ya en caché, ver `.superpowers/sdd/task-2a4-report.md`).
- **Decisión 2026-07-06 (latencia end-to-end vs spec Fase 1):** la latencia total de dictado con refinado (~3-4s: STT + generación LLM) excede el objetivo <2s del spec Fase 1. Decisión registrada: aceptado en Fase 2A (el refinado con IA es una mejora nueva, no parte del baseline original), tuning en Fase 3 (candidatos: modelo 1.5B, prompt más corto, streaming).
- **Decisión 2026-07-06 (wake v1 híbrida):** VAD por energía + transcripción Whisper en segmentos detecta la frase con suficiente confiabilidad para v1. openWakeWord (modelo especializado) es más eficiente pero requiere investigación — en backlog como optimización.
- **Decisión 2026-07-06 (KikiStore: JSON vs SQLite):** v1 usa persistencia JSON atómica en `~/Library/Application Support/kiki/` (diccionario, snippets, historial, config). JSON es suficiente para volúmenes iniciales (~40 entradas de diccionario, ~100 snippets, 200 items de historial); migración a SQLite está abierta para v2 si la complejidad de consultas o el volumen crece.
- **Decisión 2026-07-08 (fidelidad del refinado):** el refinado pasó de "reescribir/adaptar tono" a "corrección mínima fiel". El prompt de tono empujaba a un modelo de 3B a parafrasear las palabras del usuario. Se reescribió el prompt (conservar palabras + estructura, ejemplo trabajado), se quitaron los sufijos de tono chat/email/docs, y se añadió una guardia de fidelidad léxica + un toggle para apagar el refinado por completo.
