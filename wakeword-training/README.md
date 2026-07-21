# Entrenar los modelos de wake-word de kiki

kiki detecta las frases de voz al instante con [LiveKit Wakeword](https://github.com/livekit/livekit-wakeword)
(openWakeWord + cabeza conv-attention, ONNX Runtime / CoreML). Cada frase es un
modelo `.onnx` entrenado con voz sintética (VoxCPM, español). Este directorio
tiene las 3 configs; aquí está la receta para producir los `.onnx`.

**Motor 100% abierto (Apache 2.0), sin cuentas ni keys** — apto para distribuir.

## Frases → archivos → acción en kiki

| Frase | Config | `.onnx` de salida | Acción |
|---|---|---|---|
| "escúchame kiki" | `escuchame-kiki.yaml` | `escuchame_kiki.onnx` | dictado de UNA toma |
| "manos libres kiki" | `manos-libres-kiki.yaml` | `manos_libres_kiki.onnx` | modo continuo ON |
| "kiki detente" | `kiki-detente.yaml` | `kiki_detente.onnx` | modo continuo OFF |

## Requisitos

- macOS + Apple Silicon (usa la GPU vía MPS).
- [`uv`](https://docs.astral.sh/uv/) (`brew install uv`).
- **~25 GB de disco libre** (VoxCPM ~4.6 GB + features ACAV100M ~16 GB + fondos/RIRs).
- Tiempo: VoxCPM sintetiza **secuencialmente ~4.5 s/clip**. Con estas configs
  (`n_samples: 2500`) cada frase toma **~2–4 h** (generación + entrenamiento).
  Las 3 → correr **de noche**. Súbelo a `n_samples: 25000` para calidad prod
  (mucho más lento; ideal en la nube — ver `skypilot/` del repo del motor).

## Pasos

```bash
# 1. Clonar el motor de entrenamiento (una vez)
git clone https://github.com/livekit/livekit-wakeword
cd livekit-wakeword
uv sync --extra train --extra voxcpm --extra eval

# 2. Copiar las 3 configs de kiki aquí
cp /ruta/a/kiki/wakeword-training/configs/*.yaml configs/

# 3. Descargar assets (VoxCPM, fondos, RIRs) — una vez, ~21 GB
uv run livekit-wakeword setup --config configs/escuchame-kiki.yaml

# 4. Entrenar cada frase (genera → aumenta → entrena → exporta → evalúa)
uv run livekit-wakeword run configs/escuchame-kiki.yaml
uv run livekit-wakeword run configs/manos-libres-kiki.yaml
uv run livekit-wakeword run configs/kiki-detente.yaml

# 5. Copiar los .onnx a kiki (nombres EXACTOS — el detector mapea por nombre)
mkdir -p /ruta/a/kiki/App/Resources/wakewords
cp output/escuchame_kiki/escuchame_kiki.onnx     /ruta/a/kiki/App/Resources/wakewords/
cp output/manos_libres_kiki/manos_libres_kiki.onnx /ruta/a/kiki/App/Resources/wakewords/
cp output/kiki_detente/kiki_detente.onnx         /ruta/a/kiki/App/Resources/wakewords/

# 6. Rebuild + probar
cd /ruta/a/kiki && make bundle && open build/kiki.app
```

## Notas

- Sin los `.onnx`, kiki **sigue funcionando** con el camino actual (detección
  por Whisper) — el motor abierto es un upgrade opcional, no un requisito.
- Revisa `output/<modelo>/<modelo>_eval.json`: `optimal_threshold` orienta el
  umbral; `fpph` (falsos positivos/hora) debe ser bajo. Si una frase dispara de
  más, sube `n_samples` y/o agrega `custom_negative_phrases` con lo que la
  confunde, y reentrena.
- Los `.onnx` son pequeños (~cientos de KB) y se versionan/distribuyen con la app.
