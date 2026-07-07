# kiki — Brand Prompt Kit

Sistema de prompts para generar el logo y toda la imaginería comercial de kiki de forma
**consistente y replicable** en cualquier generador (Midjourney, gpt-image, Ideogram, Flux).

## Identidad (la base conceptual)

- **Producto:** dictado por voz con IA, 100% local y privado, para macOS.
- **Personalidad:** cercana, ágil, confiable. "kiki" es un nombre juguetón de dos sílabas — la marca es amigable, no corporativa fría.
- **Concepto visual central (el hook abstracto):** la palabra **k-i-k-i** tiene ritmo alto-bajo-alto-bajo. Se representa como una **onda de voz de 4 elementos: barra alta, punto, barra alta, punto** — las barras son las "k", los puntos son las "i". La onda ES el nombre. Ese es el símbolo abstracto replicable.
- **Paleta fija (usar SIEMPRE los hex):**
  - Tinta: `#22263A` (azul-negro suave)
  - Violeta primario: `#7C5CFC`
  - Violeta claro (gradiente): `#A78BFA`
  - Crema fondo: `#FAF7F2`
  - Blanco puro solo para modo oscuro invertido

---

## BLOQUE DE FUNDACIÓN (pegar al inicio de TODO prompt)

```
Brand system for "kiki", a private on-device AI voice dictation app for Mac.
Minimalist flat vector style, generous negative space, soft rounded geometry,
no gradients except a single vertical violet gradient #7C5CFC → #A78BFA on the
voice-wave element. Palette strictly limited to: deep ink #22263A, violet
#7C5CFC, light violet #A78BFA, warm cream #FAF7F2. Friendly, modern, trustworthy
tech brand — Apple-ecosystem aesthetic, never corporate or skeuomorphic.
Signature abstract mark: a 4-element voice waveform reading as "k-i-k-i" —
tall rounded bar, dot, tall rounded bar, dot — evoking both a soundwave and
the brand name.
```

## 1. Logo de producto / app icon (master)

```
[BLOQUE DE FUNDACIÓN]
App icon for macOS, rounded-square squircle on warm cream #FAF7F2 background.
Centered composition: the signature kiki waveform mark (tall bar, dot, tall
bar, dot) in violet gradient, floating above the lowercase wordmark "kiki" in
a soft rounded geometric sans-serif, deep ink #22263A, slightly plump friendly
letterforms. Perfect symmetry, crisp vector edges, no shadows, no 3D, no
texture. Flat minimal design, production-ready app icon.
```

## 2. Símbolo solo (favicon, menu bar, avatar pequeño)

```
[BLOQUE DE FUNDACIÓN]
Standalone abstract logomark, no text: only the kiki 4-element voice waveform
(tall rounded bar, dot, tall rounded bar, dot) in solid violet #7C5CFC on
transparent background. Monoline weight, perfectly balanced spacing, works at
16px. Flat vector, single color version.
```

## 3. Wordmark horizontal (web, documentos)

```
[BLOQUE DE FUNDACIÓN]
Horizontal lockup: lowercase wordmark "kiki" in rounded geometric sans-serif,
deep ink #22263A, with the two "i" letters topped by violet #7C5CFC dots that
echo the waveform mark. To the left, the 4-element waveform symbol in violet
gradient. Clean baseline alignment, flat vector on white background.
```

## 4. Imaginería comercial (hero / landing / social)

Plantilla — cambiar solo la [ESCENA]:

```
[BLOQUE DE FUNDACIÓN]
Commercial brand illustration: [ESCENA]. Flat minimal illustration style with
soft rounded shapes, cream #FAF7F2 background, ink #22263A line work, violet
#7C5CFC accents only on voice/sound elements. The kiki waveform mark appears
subtly integrated in the scene. Lots of negative space, editorial composition,
no photorealism, no stock-photo look.
```

Escenas listas:
- `a person speaking naturally at a MacBook, violet voice waves flowing from them into clean text lines on screen`
- `a Mac menu bar close-up with the kiki mark glowing gently, ambient home-office scene`
- `a shield formed by voice waves — privacy concept, everything stays inside a Mac silhouette`
- `hands-free moment: person cooking/walking while violet waves travel to a laptop across the room`

## 5. Lista negativa (añadir si el generador lo soporta)

```
--no photorealism, 3D render, skeuomorphism, drop shadows, neon glow, robot
faces, microphone clipart, extra colors, busy backgrounds, text other than "kiki"
```

## Reglas de consistencia

1. **Nunca** cambies los hex ni añadas colores; el violeta va SOLO en elementos de voz/sonido.
2. Reutiliza la MISMA imagen del ícono actual como **referencia de imagen** cuando el generador lo permita (Midjourney `--sref`, gpt-image con imagen adjunta) + fija seed si existe.
3. "kiki" siempre en minúsculas, tipografía redondeada; jamás mayúsculas ni serif.
4. El símbolo abstracto (barra-punto-barra-punto) es la unidad mínima de marca — si algo lleva marca, lleva eso.
5. Una generación por concepto → elegir → iterar sobre la elegida con "same style, but ..." en vez de regenerar de cero.
