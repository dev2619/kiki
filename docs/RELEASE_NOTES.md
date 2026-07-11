# kiki 0.10.0

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### "escúchame kiki" responde hasta 3× más rápido
Un modelo dedicado ultraligero (~75MB) ahora verifica la frase de activación en ~0.2s — antes la verificaba el modelo grande de dictado (~1-2s). La latencia total frase→escucha baja de ~2-3s a **menos de 1 segundo**.
- El dictado en el mismo aliento ("escúchame kiki, escribe…") conserva la calidad de siempre: el modelo grande sigue transcribiendo lo que dictas; el ligero solo decide si dijiste la frase.
- Si el modelo ligero no puede cargar, kiki sigue funcionando exactamente como antes.

## 📦 Instalación

1. Descarga `kiki-0.10.0.dmg`, ábrelo y arrastra **kiki** a Aplicaciones.
2. Primer arranque: **clic derecho sobre kiki.app → Abrir** (no doble clic) y confirma — el .dmg no está notarizado.
3. La primera vez, kiki descarga los modelos principales (Whisper ~1 GB + Qwen ~1.6 GB) con una barra de progreso; el modelo ligero (~75MB) se descarga en segundo plano después del primer arranque, sin bloquear el uso. Requiere internet solo esa vez; después funciona 100% offline.
4. Concede permisos de **Micrófono** y **Accesibilidad** cuando los pida.

## 💻 Requisitos

- macOS 14+ · Apple Silicon (M1 o superior)
- ~3 GB de disco libre para los modelos

## ⚠️ Notas

- El `.dmg` no está notarizado (requiere Apple Developer Program). Gatekeeper pedirá el clic derecho → Abrir la primera vez.
- Los modelos no van dentro del `.dmg` (por eso pesa ~15 MB): se descargan on-demand en el primer arranque.
