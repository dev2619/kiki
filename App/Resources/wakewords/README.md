# Modelos wake-word (.onnx)

Aquí van los modelos entrenados de las frases de voz. kiki los carga al
arrancar (ver `AppDelegate.makeWakeWordDetector`); si faltan, cae a la
detección por Whisper.

Nombres EXACTOS (el detector mapea por nombre de archivo):

| Archivo | Frase | Acción |
|---|---|---|
| `escuchame_kiki.onnx` | "escúchame kiki" | dictado de una toma |
| `manos_libres_kiki.onnx` | "manos libres kiki" | modo continuo ON |
| `kiki_detente.onnx` | "kiki detente" | modo continuo OFF |

Para entrenarlos: ver `wakeword-training/README.md` en la raíz del repo.
