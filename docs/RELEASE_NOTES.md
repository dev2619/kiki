# kiki 1.0.0

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades

### Transcripción en vivo
Mientras hablas, tu texto aparece en una burbuja que fluye en tiempo real:
- Actívalo manteniendo **Fn** o con «escúchame kiki» tras la detección rápida de wake.
- Al soltar la tecla o tras 1.5 segundos de silencio, el texto se inserta al instante — **sin esperar a refinamiento con IA**.
- En modo live, el refinamiento/traducción con IA se salta para ese dictado — el interruptor "Transcripción en vivo" de Ajustes vuelve al modo con refinamiento cuando lo prefieras.
- El texto insertado queda en el portapapeles, como siempre.

**kiki 1.0 completa la experiencia:** dictado en vivo + detección rápida de wake + modelos elegibles + portapapeles — ahora puedes dictar tan rápido como escribes.

## 📦 Instalación

1. Descarga `kiki-1.0.0.dmg`, ábrelo y arrastra **kiki** a Aplicaciones.
2. Primer arranque: **clic derecho sobre kiki.app → Abrir** (no doble clic) y confirma — el .dmg no está notarizado.
3. La primera vez, kiki descarga los modelos principales (Whisper ~1 GB + Qwen ~1.6 GB) con una barra de progreso; el modelo ligero (~75MB) se descarga en segundo plano después del primer arranque, sin bloquear el uso. Requiere internet solo esa vez; después funciona 100% offline.
4. Concede permisos de **Micrófono** y **Accesibilidad** cuando los pida.

## 💻 Requisitos

- macOS 14+ · Apple Silicon (M1 o superior)
- ~3 GB de disco libre para los modelos

## ⚠️ Notas

- El `.dmg` no está notarizado (requiere Apple Developer Program). Gatekeeper pedirá el clic derecho → Abrir la primera vez.
- Los modelos no van dentro del `.dmg` (por eso pesa ~15 MB): se descargan on-demand en el primer arranque.
