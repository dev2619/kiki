# kiki — Diseño de producto y arquitectura

**Fecha:** 2026-07-06
**Estado:** Aprobado
**Repo:** https://github.com/dev2619/kiki

## 1. Posicionamiento

**"Wispr Flow, pero privado y tuyo."** App de dictado por voz con IA para macOS: se activa por hotkey o por voz, funciona en cualquier aplicación, y la IA convierte el habla natural en texto limpio y formateado. A diferencia de Wispr Flow, **todo el procesamiento ocurre on-device**: la voz nunca sale del Mac, costo marginal $0 por uso, funciona offline.

### Commodity (paridad funcional con Wispr Flow)

- Hold-to-talk con hotkey global + HUD flotante con waveform
- Texto insertado donde esté el cursor, en cualquier app
- Auto-edición con IA: muletillas, puntuación, formato
- Diccionario personal (nombres propios, términos técnicos)
- Snippets por voz (trigger hablado → plantilla)
- Detección de contexto por app (tono según Slack / VS Code / Mail…)
- Multi-idioma con detección automática

### Personalizable (propio de kiki)

- **100% local** — diferenciador #1 (privacidad, offline, sin suscripción obligatoria)
- **Activación por voz** estilo Siri: "escúchame kiki" / "listen to me kiki"
- Español e inglés como idiomas de primera clase
- Marca, UI visual y copy propios (se replican patrones de UX, no assets ni textos de Wispr)

## 2. Objetivo de negocio

MVP validable: herramienta funcional para uso propio primero, con arquitectura preparada para monetizar después. **Sin billing, cuentas ni stubs de licencia en el MVP** — solo fronteras de módulos limpias como punto de extensión. Cero telemetría externa.

## 3. Interacción

| Modo | Inicio | Fin | Uso típico |
|---|---|---|---|
| **Hold-to-talk** | Mantener Fn (configurable) | Soltar Fn | Dictados precisos, control total |
| **Wake phrase** | Decir "escúchame kiki" / "listen to me kiki" (chime + HUD) | Silencio ~1.5s (o decir "listo") | Manos libres, estilo Siri |

Flujo core:

1. Activación (tecla o frase) → HUD pill flotante en la parte inferior con waveform en vivo.
2. Al terminar (soltar tecla / silencio): HUD pasa a "procesando".
3. Whisper transcribe → LLM limpia y formatea según contexto de la app activa → texto insertado en el cursor.
4. **Latencia objetivo: < 2s** para dictados de ~15s en Apple Silicon.

Tap corto sin hablar cancela; Esc cancela durante grabación. El modo wake phrase se activa/desactiva desde el menu bar (el ícono refleja el estado de escucha).

## 4. Arquitectura

App de menu bar nativa (sin ícono en Dock), **Swift + SwiftUI**, modularizada con Swift Package Manager:

```
kiki/
├── Kiki (app target)   — menu bar, HUD, settings UI, onboarding de permisos
├── KikiCore            — orquestador del pipeline (máquina de estados)
├── KikiAudio           — captura de micrófono (AVAudioEngine, 16kHz mono)
├── KikiWake            — escucha continua manos libres:
│                          • [ENMIENDA 2026-07-06, decisión "híbrido evolutivo"]
│                            v1: VAD por energía segmenta habla y Whisper (ya
│                            residente) verifica la frase de activación por
│                            texto — cero dependencias nuevas, ES/EN desde el
│                            día 1. openWakeWord (modelo dedicado ~1MB always-on,
│                            entrenado con TTS sintético) queda en backlog como
│                            optimización de consumo detrás del mismo protocolo.
│                          • Detección de fin de habla por silencio (~1.5s)
│                          • Nada se persiste sin activación (segmentos en RAM)
├── KikiSTT             — WhisperKit (CoreML, large-v3-turbo), ES/EN auto-detect
├── KikiRefine          — LLM local vía MLX (Qwen 3B 4-bit): limpieza, tono por
│                          contexto, expansión de snippets
├── KikiInsert          — inserción de texto: paste sintético (Cmd+V con
│                          preservación del clipboard) + fallback Accessibility API
├── KikiContext         — app activa (NSWorkspace) → perfil: code/chat/email/docs
└── KikiStore           — SQLite: diccionario, snippets, historial, settings
```

Decisiones de stack (con razones):

- **Swift nativo** sobre Tauri/Electron: acceso directo a Accessibility/AVFoundation, WhisperKit y MLX optimizados para Apple Silicon, binario liviano, sensación nativa.
- **STT local (WhisperKit)** sobre cloud: privacidad, costo $0, offline. Es el pilar del posicionamiento.
- **LLM local (MLX + Qwen 3B 4-bit)** sobre cloud: coherente con "todo local"; la limpieza de texto es tarea simple donde un modelo pequeño alcanza.
- **openWakeWord (open source)** sobre Porcupine/Picovoice: cero dependencias comerciales, sin sorpresas de licenciamiento al monetizar. Costo: 1-2 días extra de integración.
- **Batch al soltar** sobre streaming: transcripción completa al terminar el dictado. Arquitectura simple y robusta para MVP; streaming en vivo queda como evolución v2 sobre esta base.

## 5. Flujo de datos

```
Activación (Fn down / wake phrase detectada)
  ──► KikiAudio graba ──► buffer PCM 16kHz
Fin (Fn up / silencio VAD)
  ──► KikiSTT: Whisper + initial prompt con diccionario ──► texto crudo
    ► KikiContext: app activa ──► perfil de tono
    ► KikiRefine: LLM (limpiar + formatear según perfil + snippets) ──► texto final
    ► KikiInsert: pega en el cursor
    ► KikiStore: guarda en historial (crudo + final)
```

El diccionario personal se inyecta en **dos puntos**: initial prompt de Whisper (mejora el reconocimiento de términos como "Kubernetes", "PostgreSQL") y prompt del LLM (corrige spelling). Los snippets se resuelven en KikiRefine (trigger hablado → plantilla).

## 6. Features del MVP

| Feature | Implementación |
|---|---|
| Diccionario personal | CRUD en settings + inyección en STT/LLM. Auto-aprendizaje de correcciones → v2 |
| Contexto por app | Mapa bundle-id → perfil (VS Code→code, Slack→casual, Mail→formal, default→neutral), editable en settings |
| Multi-idioma ES/EN | Whisper auto-detect; el LLM refina en el idioma dictado |
| Snippets | Lista trigger→plantilla en settings; matching en KikiRefine |
| Wake phrase | "escúchame kiki" / "listen to me kiki", toggle + umbral de confianza + tiempo de silencio en settings |
| Historial | Últimos dictados (crudo vs final) en settings, copiable |

## 7. Manejo de errores

- Sin permiso de mic/accesibilidad → onboarding guiado con deep-links a System Settings.
- Falla o timeout del LLM (>5s) → **degradación elegante**: se pega la transcripción cruda de Whisper. Nunca se pierde un dictado.
- Falla de inserción (app rechaza paste) → texto queda en clipboard + notificación.
- Modelos no descargados → primer arranque los descarga con progreso (Whisper ~600MB, LLM ~2GB, wake word ~1MB).
- Falsos positivos del wake word → umbral configurable; frases largas (4-6 sílabas) los minimizan por diseño.
- Errores se loggean localmente; cero telemetría externa.

## 8. Testing

- **Unit (objetivo 80% en módulos de lógica):** KikiRefine (prompts/parsing con LLM mockeado), KikiContext (mapeo de perfiles), KikiStore, máquina de estados de KikiCore, KikiWake (fixtures de audio para falsos positivos/negativos).
- **Integration:** pipeline completo con fixtures WAV → texto esperado (Whisper real, local).
- **E2E:** checklist manual (hotkey en apps reales, permisos, clipboard, wake phrase en ambiente ruidoso) — automatizar Accessibility API no es práctico en MVP.

## 9. Fases de construcción

1. **Fase 1 — Loop mágico:** hotkey global + grabación + Whisper + paste. HUD mínimo. *Valida el producto desde el primer día.*
2. **Fase 2 — Inteligencia + manos libres:** KikiRefine (LLM local) + KikiContext + KikiWake (wake phrase + VAD).
3. **Fase 3 — Personalización:** settings UI, diccionario, snippets, historial.
4. **Fase 4 — Pulido:** onboarding de permisos, descarga de modelos con progreso, .dmg firmado y notarizado.

## 10. Proyecto

- **Repo local:** `~/kiki` → `https://github.com/dev2619/kiki.git`
- **Vault:** proyecto `kiki` en `01-PROJECTS/kiki/` + fila en `INDEX.md` (regla global de vault)
- **Requisitos de sistema:** macOS 14+, Apple Silicon (M1+), ~4GB de disco para modelos
