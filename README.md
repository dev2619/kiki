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
