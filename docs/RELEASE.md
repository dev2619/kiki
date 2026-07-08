# Publicar kiki fuera del App Store (GitHub Releases)

## Arquitectura de distribución

kiki se distribuye como **base ligera + descarga de modelos en el primer arranque** (exactamente lo que querías):

| Componente | Tamaño | Dónde |
|---|---|---|
| `.dmg` (lo que se descarga) | **~15 MB** | GitHub Release |
| App instalada (`kiki.app`) | ~52 MB | `/Applications` |
| Modelo Whisper (STT) | ~1.0 GB | `~/Documents/huggingface/…` (auto, 1er arranque) |
| Modelo Qwen 3B (refinado/traducción) | ~1.6 GB | `~/Library/Caches/models/…` (auto, 1er arranque) |
| **Total en disco tras instalar y usar** | **~2.7 GB** | app + modelos |

Los modelos **no** van en el .dmg: WhisperKit y MLX los descargan de Hugging Face automáticamente la primera vez que kiki carga (unos minutos, una sola vez; luego quedan cacheados). Por eso el .dmg es pequeño.

## ¿Encapsular todo o descargar la base?

**Recomendado: descargar la base (lo actual).**
- **Base + modelos on-demand (actual):** .dmg de 15 MB, modelos al primer arranque. Cabe en GitHub (límite ~2 GB por archivo de release). Estándar de la industria.
- **Todo encapsulado (modelos dentro del .dmg):** .dmg de ~2.7 GB → **excede el límite de 2 GB por asset de GitHub Releases**, habría que partirlo; descarga enorme; solo tiene sentido para uso 100% offline desde el día 1. No recomendado para GitHub.

## Pasos para publicar

1. **Build del .dmg** (ya hecho): `make dmg` → `build/kiki-0.8.0.dmg`.
2. **Tag de la versión** (por SSH, ya empujado): `git tag v0.8.0 && git push origin v0.8.0`.
3. **Crear el Release en GitHub** — dos opciones:
   - **Web:** github.com/dev2619/kiki → Releases → "Draft a new release" → elegir el tag `v0.8.0` → arrastrar `build/kiki-0.8.0.dmg` como asset → publicar.
   - **CLI:** `gh release create v0.8.0 build/kiki-0.8.0.dmg --title "kiki 0.8.0" --notes-file docs/RELEASE_NOTES.md` (requiere token de `dev2619` con scope `repo` — el token actual solo tiene `copilot,user`).

## Gatekeeper (sin notarización)

El .dmg no está notarizado (requiere Apple Developer Program, $99/año). En otro Mac, la primera vez el usuario debe:
- **Clic derecho sobre kiki.app → Abrir** (en vez de doble clic), y confirmar en el diálogo. Solo la primera vez.
- Alternativa por terminal: `xattr -dr com.apple.quarantine /Applications/kiki.app`.

Para distribución sin fricción (doble-clic normal) haría falta: inscribirse en Apple Developer Program → firmar con Developer ID → `notarytool` → `stapler`. Es el paso de la Fase 4 pendiente.

## Requisitos del usuario final

- macOS 14+ · Apple Silicon (M1+)
- ~3 GB de disco libre para los modelos
- Conexión a internet solo en el primer arranque (descarga de modelos); luego funciona 100% offline
