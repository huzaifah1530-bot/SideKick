"""Generate SideKick's accent-matched alternate app icons.

Each variant rotates the hue of the primary icon so its top-left gradient colour
matches an accent colour bucket. The white bolt keeps its colour because white
has no saturation. Run from the repository root after changing the primary icon:

    python scripts/generate-tinted-icons.py

Requires Pillow and NumPy. The output is committed, so CI does not run this.
Keep STEP and the naming in sync with SideKick/Services/AppIconVariant.swift.
"""
from __future__ import annotations

import colorsys
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "SideKick" / "Assets.xcassets"
SOURCE = CATALOG / "AppIcon.appiconset" / "SideKickIcon-1024.png"
STEP = 30  # degrees between buckets; 360 / STEP icons including the primary


def contents(filename: str) -> str:
    return json.dumps({
        "images": [{"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n"


PREVIEW_SIZE = 180  # LiveContainer caches 60 pt icons at 3x


def preview_contents(filename: str) -> str:
    return json.dumps({
        "images": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n"


def write(name: str, image: Image.Image) -> None:
    folder = CATALOG / f"{name}.appiconset"
    folder.mkdir(exist_ok=True)
    filename = f"{name}-1024.png"
    image.save(folder / filename, optimize=True)
    (folder / "Contents.json").write_text(contents(filename), encoding="utf-8")
    # Image sets can be loaded at runtime; app icon sets cannot.
    preview_name = name.replace("AppIcon", "AppIconPreview", 1)
    preview = CATALOG / f"{preview_name}.imageset"
    preview.mkdir(exist_ok=True)
    preview_file = f"{preview_name}.png"
    image.resize((PREVIEW_SIZE, PREVIEW_SIZE), Image.LANCZOS).save(preview / preview_file, optimize=True)
    (preview / "Contents.json").write_text(preview_contents(preview_file), encoding="utf-8")


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    # Report the reference hue so AppIconVariant.referenceHue stays accurate.
    r, g, b = (c / 255 for c in source.getpixel((8, 8)))
    print(f"Top-left reference hue: {colorsys.rgb_to_hsv(r, g, b)[0] * 360:.1f} degrees")

    # Preview of the primary icon only; its app icon set is maintained by hand.
    folder = CATALOG / "AppIconPreview.imageset"
    folder.mkdir(exist_ok=True)
    source.resize((PREVIEW_SIZE, PREVIEW_SIZE), Image.LANCZOS).save(folder / "AppIconPreview.png", optimize=True)
    (folder / "Contents.json").write_text(preview_contents("AppIconPreview.png"), encoding="utf-8")

    hsv = np.array(source.convert("HSV"), dtype=np.int16)
    for degrees in range(STEP, 360, STEP):
        rotated = hsv.copy()
        rotated[..., 0] = (rotated[..., 0] + round(degrees * 256 / 360)) % 256
        write(f"AppIcon-Hue{degrees:03d}", Image.fromarray(rotated.astype(np.uint8), "HSV").convert("RGB"))

    # Greys, black and white accents have no hue to match.
    write("AppIcon-Mono", source.convert("L").convert("RGB"))
    print("Wrote", len(range(STEP, 360, STEP)) + 1, "alternate icons")


if __name__ == "__main__":
    main()
