# kiki 0.9.1

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### Refinado fiel a tus palabras (fix principal)
El refinado con IA ahora **corrige, no reescribe**. Antes podía parafrasear el dictado (p. ej. convertía *"Dame la lista de repositorios ya automatizados"* en *"Lista de repositorios automatizados:"*). Ahora:
- Conserva **todas tus palabras y la estructura de la frase** — una orden sigue siendo orden, una pregunta sigue siendo pregunta.
- Solo quita muletillas (eh, em, o sea, like) y arregla puntuación y mayúsculas.
- **Guardia de fidelidad:** si el modelo introduce vocabulario que no dijiste, se descarta y se inserta la transcripción cruda.
- Nuevo interruptor **"Refinar dictado con IA"** (Ajustes → General): apágalo para insertar exactamente lo que transcribe Whisper, sin que la IA toque nada.

## 📦 Instalación

1. Descarga `kiki-0.9.1.dmg`, ábrelo y arrastra **kiki** a Aplicaciones.
2. Primer arranque: **clic derecho sobre kiki.app → Abrir** (no doble clic) y confirma — el .dmg no está notarizado.
3. La primera vez, kiki descarga los modelos (Whisper ~1 GB + Qwen ~1.6 GB) con una barra de progreso. Requiere internet solo esa vez; después funciona 100% offline.
4. Concede permisos de **Micrófono** y **Accesibilidad** cuando los pida.

## 💻 Requisitos

- macOS 14+ · Apple Silicon (M1 o superior)
- ~3 GB de disco libre para los modelos

## ⚠️ Notas

- El `.dmg` no está notarizado (requiere Apple Developer Program). Gatekeeper pedirá el clic derecho → Abrir la primera vez.
- Los modelos no van dentro del `.dmg` (por eso pesa ~15 MB): se descargan on-demand en el primer arranque.
