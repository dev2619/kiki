# kiki

Dictado por voz con IA, **100% local**, para macOS. Mantén **Fn**, habla, suelta — el texto aparece donde esté tu cursor, en cualquier app. Tu voz nunca sale de tu Mac.

> Fase actual: **1 — loop mágico** (hotkey + Whisper local + paste).
> Spec completo: [`docs/superpowers/specs/2026-07-06-kiki-design.md`](docs/superpowers/specs/2026-07-06-kiki-design.md)

## Requisitos

- macOS 14+ · Apple Silicon
- Command Line Tools de Xcode (`xcode-select --install`) — no requiere Xcode completo
- ~3 GB de disco para el modelo Whisper full-precision (se descarga en el primer arranque; la primera carga tarda ~9-10 min por la compilación CoreML — las siguientes son rápidas)

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

   > Importante: tras conceder Accesibilidad por primera vez, **reinicia kiki** — el monitor global de teclado registrado antes del permiso no se reactiva solo.

> Nota dev: con firma ad-hoc, tras cada rebuild puede hacer falta re-toggle del permiso de Accesibilidad.
> Recomendado: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**.

## Arquitectura

Módulos SPM: `KikiCore` (máquina de estados) · `KikiAudio` (mic → 16 kHz mono) · `KikiSTT` (WhisperKit) · `KikiInsert` (paste preservando clipboard) · `Kiki` (menu bar app, hotkey, HUD).

## Notas de alcance (Fase 1)

- Cancelar con Esc durante la grabación (spec §3) no está cableado aún — `cancel()` existe y está testeado; se conecta junto con el modo wake-word en Fase 2.
- Fallo de inserción notifica solo por log (la notificación visual llega con el onboarding de Fase 4).
- Modelo actual: `openai_whisper-large-v3_turbo` (3.0 GB). Variante cuantizada `large-v3_turbo_954MB` disponible como swap de 1 línea — decisión pendiente con datos de latencia reales.
