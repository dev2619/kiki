# kiki 0.9.2

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### La transcripción queda en tu portapapeles
Después de dictar, el texto se inserta donde está el cursor **y queda copiado en el portapapeles** — pégalo con ⌘V en cualquier otra app sin volver a dictar.
- Nuevo interruptor **"Restaurar clipboard anterior tras dictar"** (Ajustes): actívalo si prefieres el comportamiento anterior (kiki devolvía al portapapeles lo que tenías copiado antes de dictar).

## 📦 Instalación

1. Descarga `kiki-0.9.2.dmg`, ábrelo y arrastra **kiki** a Aplicaciones.
2. Primer arranque: **clic derecho sobre kiki.app → Abrir** (no doble clic) y confirma — el .dmg no está notarizado.
3. La primera vez, kiki descarga los modelos (Whisper ~1 GB + Qwen ~1.6 GB) con una barra de progreso. Requiere internet solo esa vez; después funciona 100% offline.
4. Concede permisos de **Micrófono** y **Accesibilidad** cuando los pida.

## 💻 Requisitos

- macOS 14+ · Apple Silicon (M1 o superior)
- ~3 GB de disco libre para los modelos

## ⚠️ Notas

- El `.dmg` no está notarizado (requiere Apple Developer Program). Gatekeeper pedirá el clic derecho → Abrir la primera vez.
- Los modelos no van dentro del `.dmg` (por eso pesa ~15 MB): se descargan on-demand en el primer arranque.
