#!/usr/bin/env python3
"""Generate kiki's menu bar glyphs: normal + "active" (manos-libres armado).

Dependency: Pillow (`pip install Pillow`). Any Python 3 interpreter with
Pillow installed works — this repo was generated with a throwaway venv
(`python -m venv .venv && .venv/bin/pip install Pillow && .venv/bin/python
scripts/generate-menubar-icons.py`), there is nothing kiki-specific about
the interpreter.

Mark: "bar-dot-bar-dot" — two vertical capsule bars, each followed by a
small circular dot, drawn solid black on a transparent background. macOS
treats `MenuBarIcon*.png` as a template image (`NSImage.isTemplate = true`,
set at runtime in AppDelegate) and tints it to match the menu bar, so only
alpha matters here — RGB is always black.

The "active" variant (armed / manos-libres ON) adds a third, smaller dot
centered under the whole mark's baseline — the menu bar communicates wake
state via glyph shape alone, no color, no emoji (Fase 3.6, task-361).

Proportions (see docs/superpowers/plans/2026-07-07-fase-3-6-ux-sound-polish.md,
Global Constraints — measured from the original hand-tuned
MenuBarIcon@2x.png committed in a3bf896, which established the mark this
script reproduces parametrically): unit u = S/6.2 (S = canvas side in px);
bar height = 3.7u; dot diameter = bar width = 1.05u; gap between adjacent
elements = 0.6u. The "active" state dot reuses the same 0.6u gap and 1.05u
diameter, placed below the mark on the same vertical axis it would occupy
for spacing consistency — both variants render the bar-dot-bar-dot mark at
the IDENTICAL position (computed as if the state dot were always present),
so toggling wake never shifts the mark, only reveals/hides the state dot.
"""
from pathlib import Path

from PIL import Image, ImageDraw

APP_DIR = Path(__file__).resolve().parent.parent / "App"

# Internal render resolution multiplier: draw at SUPERSAMPLE× the target
# size and downsample with LANCZOS for clean anti-aliased edges at the tiny
# final sizes (18px / 36px) that vector-less PIL primitives can't give
# directly.
SUPERSAMPLE = 8


def render(size: int, active: bool) -> Image.Image:
    ss = size * SUPERSAMPLE
    u = ss / 6.2
    bar_h = 3.7 * u
    d = 1.05 * u  # dot diameter; bars share the same width for one visual weight
    gap = 0.6 * u
    bar_w = d

    mark_w = 4 * d + 3 * gap  # bar + gap + dot + gap + bar + gap + dot
    state_gap = gap
    state_d = d
    total_h = bar_h + state_gap + state_d  # reserved even when state dot is hidden

    left = (ss - mark_w) / 2
    top = (ss - total_h) / 2
    bar_top = top
    bar_bottom = bar_top + bar_h

    img = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    x = left
    for _ in range(2):
        # Bar: a full vertical capsule (semicircular caps top and bottom).
        draw.rounded_rectangle(
            [x, bar_top, x + bar_w, bar_bottom],
            radius=bar_w / 2,
            fill=(0, 0, 0, 255))
        x += bar_w + gap
        # Dot: bottom-aligned with the bar (sits in the bar's lower third).
        dot_cx = x + d / 2
        dot_cy = bar_bottom - d / 2
        draw.ellipse(
            [dot_cx - d / 2, dot_cy - d / 2, dot_cx + d / 2, dot_cy + d / 2],
            fill=(0, 0, 0, 255))
        x += d + gap

    if active:
        state_cx = ss / 2
        state_cy = bar_bottom + state_gap + state_d / 2
        draw.ellipse(
            [state_cx - state_d / 2, state_cy - state_d / 2,
             state_cx + state_d / 2, state_cy + state_d / 2],
            fill=(0, 0, 0, 255))

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    variants = [
        ("MenuBarIcon.png", 18, False),
        ("MenuBarIcon@2x.png", 36, False),
        ("MenuBarIconActive.png", 18, True),
        ("MenuBarIconActive@2x.png", 36, True),
    ]
    for filename, size, active in variants:
        out = APP_DIR / filename
        render(size, active).save(out)
        print(f"wrote {out} ({size}x{size}, active={active})")


if __name__ == "__main__":
    main()
