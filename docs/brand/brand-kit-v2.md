# kiki — Brand Kit v2 (rediseño estratégico)

v1 (`brand-prompts.md`) sigue vigente como marca operativa. Este kit es el proceso de
rediseño: estrategia → territorios → convergencia → sistema. **Regla de oro: la IA
bosqueja, la geometría consagra** — el mark final siempre se reconstruye como vector/código;
los PNG generados son sketches de concepto.

## 0. Brief estratégico (gobierna todos los prompts)

- **Diferenciador único:** privacidad — tu voz NUNCA sale de tu Mac. (La "voz" es el
  commodity de la categoría: Wispr, Siri, Superwhisper, el dictado de macOS — todos usan
  ondas/barras. Un mark de kiki debe poseer algo que ellos no puedan.)
- **Arquetipo:** compañero cercano (no herramienta corporativa). Cálido, ágil, confiable.
- **Restricción funcional dura:** todo mark debe sobrevivir a 16px, en un solo color,
  invertido, y en fila junto a los logos de la competencia.
- **Paleta heredada de v1** (se aplica DESPUÉS de elegir forma): tinta #22263A, violeta
  #7C5CFC→#A78BFA (solo en elementos de voz), crema #FAF7F2.

## 1. Reglas de craft para todo prompt de logo

1. **Monocromo primero** — la forma se decide en negro sobre blanco; color al final.
2. **Sheets, no imágenes únicas** — pedir 6-9 variaciones por generación.
3. **Una variable por iteración** — "same mark, but ..." nunca regenerar de cero.
4. **Describir significado y función**, no solo estética.
5. **Prueba de mesa** — generar la candidata en contexto: barra de menú macOS entre
   íconos del sistema, y junto a competidores.

## 2. Territorios de exploración (divergencia)

Cada territorio = una metáfora distinta. Prompt plantilla de exploración (monocromo):

```
Logomark exploration sheet, 9 distinct variations in a 3x3 grid, black shapes
on white, flat vector, no text, no color. Single concept: [METÁFORA].
Must survive at 16 pixels and in one color. Minimalist, soft rounded geometry,
friendly not corporate.
```

- **A. Contenido/adentro (privacidad — RECOMENDADO):** `[METÁFORA]` = "a voice wave
  that lives fully INSIDE a closed rounded container — the container reads as a screen /
  a safe / a home; the voice never touches the edge; privacy made visible"
- **B. Letterform k:** `[METÁFORA]` = "abstract geometric construction from the letter k —
  two mirrored k shapes creating symmetry, negative space between them forms a subtle
  spark or wave"
- **C. Eco/doble:** `[METÁFORA]` = "two identical soft shapes in dialogue — the two
  syllables ki-ki as twin forms, one speaking one echoing"
- **D. La pausa:** `[METÁFORA]` = "the silence between phrases — negative space is the
  protagonist; a wave interrupted by a deliberate calm gap"

## 3. Concepto convergido (Territorio A — decisión v2)

**El mark v2:** un **marco redondeado cerrado** (esquinas continuas, eco de una pantalla
de Mac / caja fuerte) que **contiene** la onda kiki (ADN del v1: barra-punto-barra-punto;
en tamaños mínimos se simplifica a barra-punto-barra). La voz vive adentro y nunca toca
el borde → el diferenciador de privacidad, contado sin palabras.

Descripción canónica para TODOS los prompts v2:

```
The kiki v2 signature mark: a closed rounded-square outline with smooth
continuous corners (evoking a screen / a safe space), containing centered
inside it a small voice waveform of four elements — tall rounded bar, dot,
tall rounded bar, dot — with generous breathing room so the wave never
touches the frame. The voice stays inside: privacy made visible. No text.
```

## 4. Prompts de producción v2

### 4.1 Logo de producto / app icon (squircle, sin texto)

```
Brand system for "kiki", a private on-device AI voice dictation app for Mac.
Minimalist flat vector, soft rounded geometry, friendly trustworthy, Apple-
ecosystem aesthetic. Palette strictly: deep ink #22263A, violet #7C5CFC to
light violet #A78BFA (vertical gradient, only on voice elements), warm cream
#FAF7F2. [DESCRIPCIÓN CANÓNICA]. macOS app icon: rounded squircle filled warm
cream #FAF7F2; the closed frame outline in deep ink #22263A with medium even
stroke; the four waveform elements inside in vertical violet gradient. Mark
occupies ~60% of icon width, optically centered. NO text, no letters. Crisp
flat vector, no shadows, no 3D, production-ready, PNG.
```

### 4.2 Glifo barra de menú (transparente, template)

```
macOS menu bar status icon (template image), single solid black glyph on
FULLY TRANSPARENT background, PNG with alpha. The kiki v2 mark simplified for
16-18px: a closed rounded-square outline with continuous corners, containing
a minimal three-element voice wave — short rounded bar, tall rounded bar,
small dot — centered with clear breathing room, never touching the frame.
One flat color, monoline stroke, no container fill, no text, no gradient,
no shadow. Perfectly centered, crisp vector edges, legible at 16 pixels.
```

### 4.3 Validación en contexto (prueba de mesa)

```
The kiki v2 mark rendered small in a realistic macOS menu bar mockup among
system icons (wifi, battery, bluetooth), dark menu bar, glyph tinted white.
Then a second row: the mark at 16px next to the logos of Siri, generic voice
assistant apps — evaluating distinctiveness.
```

## 5. Pipeline de adopción (cuando el v2 gane)

1. Elegir de los sheets → iterar con "same mark, but ..." (una variable).
2. **Reconstruir en geometría** (código/vector — como el glifo v1 de la barra).
3. Regenerar `.icns` + `MenuBarIcon@2x.png` + actualizar `brand-prompts.md` (v1 → archivo).
4. La paleta, HUD y ventana de Ajustes no cambian — solo el mark.
