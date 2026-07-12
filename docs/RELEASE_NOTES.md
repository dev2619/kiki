# kiki 0.11.0

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### Elige tus modelos (Ajustes → Modelos)
Nueva sección para adaptar kiki a tu Mac:
- **Transcripción:** rápido (~216 MB), balanceado (~1 GB, el de siempre) o máxima calidad (~3 GB).
- **Refinado con IA:** ligero (~1 GB), balanceado (~2 GB, el de siempre) o máxima calidad (~4.5 GB, para Macs con 32 GB+).
- Los cambios aplican al instante, sin reiniciar: el modelo nuevo se descarga con barra de progreso y kiki sigue funcionando con el actual hasta que está listo.
- El modelo base siempre queda como respaldo — si algo falla, kiki nunca se queda sin dictado.

## 📦 Instalación

1. Descarga `kiki-0.11.0.dmg`, ábrelo y arrastra **kiki** a Aplicaciones.
2. Primer arranque: **clic derecho sobre kiki.app → Abrir** (no doble clic) y confirma — el .dmg no está notarizado.
3. La primera vez, kiki descarga los modelos principales (Whisper ~1 GB + Qwen ~1.6 GB) con una barra de progreso; el modelo ligero (~75MB) se descarga en segundo plano después del primer arranque, sin bloquear el uso. Requiere internet solo esa vez; después funciona 100% offline.
4. Concede permisos de **Micrófono** y **Accesibilidad** cuando los pida.

## 💻 Requisitos

- macOS 14+ · Apple Silicon (M1 o superior)
- ~3 GB de disco libre para los modelos

## ⚠️ Notas

- El `.dmg` no está notarizado (requiere Apple Developer Program). Gatekeeper pedirá el clic derecho → Abrir la primera vez.
- Los modelos no van dentro del `.dmg` (por eso pesa ~15 MB): se descargan on-demand en el primer arranque.
